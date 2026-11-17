#!/usr/bin/env python3
"""Read-only health report for the GKE cluster. Uses only `kubectl get`.

Exit codes: 0 = healthy, 1 = at least one finding, 2 = data could not be collected.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from typing import Any

TIMEOUT_S = 20
PENDING_LIMIT = timedelta(minutes=5)
BAD_WAITING = {"CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull"}


class CollectError(Exception):
    """kubectl failed or returned unusable data (exit code 2)."""


class NotInstalled(Exception):
    """The resource type does not exist in the cluster (missing CRD)."""


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def kubectl_json(args: list[str], context: str | None) -> dict[str, Any]:
    cmd = ["kubectl"] + (["--context", context] if context else [])
    cmd += ["--request-timeout=15s", "get", *args, "-o", "json"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_S, check=False)
    except FileNotFoundError as exc:
        raise CollectError("kubectl not found in PATH") from exc
    except subprocess.TimeoutExpired as exc:
        raise CollectError(f"kubectl timed out after {TIMEOUT_S}s: get {args[0]}") from exc
    if proc.returncode != 0:
        err = proc.stderr.strip()
        if "doesn't have a resource type" in err or "no matches for kind" in err:
            raise NotInstalled(args[0])
        raise CollectError(f"kubectl get {args[0]} failed: {err or 'exit ' + str(proc.returncode)}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise CollectError(f"kubectl get {args[0]} returned invalid JSON") from exc


def analyze_nodes(nodes: dict[str, Any]) -> dict[str, Any]:
    pools: Counter[str] = Counter()
    versions: Counter[str] = Counter()
    spot = on_demand = 0
    findings: list[str] = []
    for node in nodes.get("items", []):
        labels = node["metadata"].get("labels", {})
        pools[labels.get("cloud.google.com/gke-nodepool", "unknown")] += 1
        if labels.get("cloud.google.com/gke-spot") == "true":
            spot += 1
        else:
            on_demand += 1
        versions[node["status"]["nodeInfo"]["kubeletVersion"]] += 1
        ready = [c for c in node["status"].get("conditions", []) if c["type"] == "Ready"]
        if not ready or ready[0]["status"] != "True":
            findings.append(f"node NotReady: {node['metadata']['name']}")
    if len(versions) > 1:
        findings.append("kubelet version skew: " + ", ".join(f"{v} x{c}" for v, c in sorted(versions.items())))
    return {"total": sum(pools.values()), "pools": dict(pools), "spot": spot,
            "on_demand": on_demand, "versions": dict(versions), "findings": findings}


def analyze_pods(pods: dict[str, Any], now: datetime, restart_threshold: int) -> list[str]:
    findings: list[str] = []
    for pod in pods.get("items", []):
        meta, status = pod["metadata"], pod.get("status", {})
        name = f"{meta['namespace']}/{meta['name']}"
        phase = status.get("phase")
        if phase == "Pending" and now - parse_time(meta["creationTimestamp"]) > PENDING_LIMIT:
            findings.append(f"{name}: Pending for more than 5 minutes")
        for cs in status.get("containerStatuses", []) + status.get("initContainerStatuses", []):
            reason = cs.get("state", {}).get("waiting", {}).get("reason")
            if reason in BAD_WAITING:
                findings.append(f"{name}: container {cs['name']} {reason}")
            elif cs.get("restartCount", 0) > restart_threshold and phase != "Succeeded":
                findings.append(f"{name}: container {cs['name']} restarted {cs['restartCount']} times")
    return findings


def analyze_apps(apps: dict[str, Any]) -> list[str]:
    findings = []
    for app in apps.get("items", []):
        sync = app.get("status", {}).get("sync", {}).get("status", "Unknown")
        health = app.get("status", {}).get("health", {}).get("status", "Unknown")
        if (sync, health) != ("Synced", "Healthy"):
            findings.append(f"{app['metadata']['name']}: sync={sync} health={health}")
    return findings


def analyze_events(events: dict[str, Any], now: datetime, since: timedelta) -> list[dict[str, Any]]:
    groups: dict[str, dict[str, Any]] = defaultdict(lambda: {"count": 0, "example": ""})
    for ev in events.get("items", []):
        if ev.get("type") != "Warning":
            continue
        stamp = ev.get("lastTimestamp") or ev.get("eventTime") or ev["metadata"]["creationTimestamp"]
        if now - parse_time(stamp) > since:
            continue
        group = groups[ev.get("reason", "Unknown")]
        group["count"] += ev.get("count") or 1
        group["example"] = group["example"] or ev.get("message", "")
    ranked = sorted(groups.items(), key=lambda kv: -kv[1]["count"])
    return [{"reason": r, "count": g["count"], "example": g["example"]} for r, g in ranked]


def analyze_workloads(items: dict[str, Any], kind: str) -> list[str]:
    findings = []
    for obj in items.get("items", []):
        desired = obj.get("spec", {}).get("replicas", 1)
        ready = obj.get("status", {}).get("readyReplicas", 0)
        if ready < desired:
            meta = obj["metadata"]
            findings.append(f"{kind} {meta['namespace']}/{meta['name']}: ready {ready}/{desired}")
    return findings


def build_report(args: argparse.Namespace, now: datetime) -> dict[str, Any]:
    ctx = args.context
    ns = ["-n", args.namespace] if args.namespace else ["-A"]
    report: dict[str, Any] = {"skipped": [], "apps": []}
    # Nodes are cluster-wide, so --namespace does not apply to them.
    report["nodes"] = analyze_nodes(kubectl_json(["nodes"], ctx))
    report["pods"] = analyze_pods(kubectl_json(["pods", *ns], ctx), now, args.restart_threshold)
    report["events"] = analyze_events(
        kubectl_json(["events", *ns, "--field-selector", "type=Warning"], ctx),
        now, timedelta(minutes=args.since_minutes))
    workloads = analyze_workloads(kubectl_json(["deployments", *ns], ctx), "Deployment")
    try:
        report["apps"] = analyze_apps(kubectl_json(["applications.argoproj.io", "-n", "argocd"], ctx))
    except NotInstalled:
        report["skipped"].append("Argo CD applications: not installed: skipped")
    try:
        workloads += analyze_workloads(kubectl_json(["rollouts.argoproj.io", *ns], ctx), "Rollout")
    except NotInstalled:
        report["skipped"].append("Argo Rollouts: not installed: skipped")
    report["workloads"] = workloads
    report["finding_count"] = (len(report["nodes"]["findings"]) + len(report["pods"])
                               + len(report["apps"]) + len(report["events"]) + len(workloads))
    return report


def render_list(title: str, items: list[str]) -> list[str]:
    return [f"\n{title}: {len(items) or 'none'}"] + [f"    ! {i}" for i in items]


def render_text(report: dict[str, Any], args: argparse.Namespace) -> str:
    n = report["nodes"]
    pools = ", ".join(f"{p}={c}" for p, c in sorted(n["pools"].items()))
    now = datetime.now(timezone.utc)
    lines = [f"Cluster report {now:%Y-%m-%d %H:%M:%SZ}"
             f" (context: {args.context or 'current'}, namespace: {args.namespace or 'all'})",
             f"\n[1] Nodes: {n['total']} total, {n['spot']} spot, {n['on_demand']} on-demand",
             f"    pools: {pools}"]
    lines += [f"    ! {f}" for f in n["findings"]]
    lines += render_list(f"[2] Unhealthy pods (restarts > {args.restart_threshold})", report["pods"])
    lines += render_list("[3] Argo CD apps not Synced+Healthy", report["apps"])
    events = [f"{e['reason']} x{e['count']}: {e['example'][:100]}" for e in report["events"]]
    lines += render_list(f"[4] Warning events, last {args.since_minutes} min (by reason)", events)
    lines += render_list("[5] Workloads with ready < desired", report["workloads"])
    lines += [f"\nSkipped: {s}" for s in report["skipped"]]
    total = report["finding_count"]
    lines.append(f"\nResult: {str(total) + ' finding(s)' if total else 'HEALTHY'}")
    return "\n".join(lines)


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Read-only GKE cluster health report.")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    p.add_argument("--namespace", help="limit pods, events and workloads to one namespace")
    p.add_argument("--since-minutes", type=int, default=30, help="Warning event window (default 30)")
    p.add_argument("--restart-threshold", type=int, default=5, help="restart count limit (default 5)")
    p.add_argument("--context", help="kubectl context (default: current)")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        report = build_report(args, datetime.now(timezone.utc))
    except CollectError as exc:
        print(f"ERROR: could not collect data: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2) if args.json else render_text(report, args))
    return 1 if report["finding_count"] else 0


if __name__ == "__main__":
    sys.exit(main())
