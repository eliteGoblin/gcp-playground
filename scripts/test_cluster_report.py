"""Unit tests for cluster_report. Run: python3 -m unittest discover -s scripts"""
import contextlib
import io
import subprocess
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cluster_report as cr  # noqa: E402

NOW = datetime(2026, 11, 18, 12, 0, tzinfo=timezone.utc)


def ts(minutes_ago: int) -> str:
    return (NOW - timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def node(name, pool, version="v1.33.1", spot=False, ready="True"):
    labels = {"cloud.google.com/gke-nodepool": pool}
    if spot:
        labels["cloud.google.com/gke-spot"] = "true"
    return {"metadata": {"name": name, "labels": labels},
            "status": {"nodeInfo": {"kubeletVersion": version},
                       "conditions": [{"type": "Ready", "status": ready}]}}


def pod(name, phase="Running", age=60, waiting=None, restarts=0):
    cs = {"name": "c", "restartCount": restarts,
          "state": {"waiting": {"reason": waiting}} if waiting else {"running": {}}}
    return {"metadata": {"name": name, "namespace": "orders", "creationTimestamp": ts(age)},
            "status": {"phase": phase, "containerStatuses": [cs]}}


class AnalysisTests(unittest.TestCase):
    def test_nodes_counts_and_findings(self):
        data = {"items": [node("a", "system"), node("b", "spot", "v1.34.0", spot=True, ready="False")]}
        r = cr.analyze_nodes(data)
        self.assertEqual((r["total"], r["spot"], r["on_demand"]), (2, 1, 1))
        self.assertTrue(any("NotReady: b" in f for f in r["findings"]))
        self.assertTrue(any("skew" in f for f in r["findings"]))

    def test_nodes_healthy(self):
        self.assertEqual(cr.analyze_nodes({"items": [node("a", "system")]})["findings"], [])

    def test_pods(self):
        data = {"items": [pod("ok"), pod("pend", "Pending", age=10), pod("newpend", "Pending", age=1),
                          pod("crash", waiting="CrashLoopBackOff"), pod("pull", waiting="ImagePullBackOff"),
                          pod("flappy", restarts=9), pod("fine", restarts=5)]}
        text = "\n".join(cr.analyze_pods(data, NOW, 5))
        for name in ("pend", "crash", "pull", "flappy"):
            self.assertIn(f"orders/{name}:", text)
        self.assertNotIn("orders/newpend", text)
        self.assertNotIn("orders/fine", text)
        self.assertNotIn("orders/ok:", text)

    def test_apps(self):
        def mk(n, s, h):
            return {"metadata": {"name": n}, "status": {"sync": {"status": s}, "health": {"status": h}}}
        data = {"items": [mk("good", "Synced", "Healthy"), mk("bad", "OutOfSync", "Healthy"),
                          mk("sick", "Synced", "Degraded")]}
        self.assertEqual(len(cr.analyze_apps(data)), 2)

    def test_events_grouped_and_windowed(self):
        def mk(reason, mins, msg, typ="Warning"):
            return {"type": typ, "reason": reason, "message": msg, "lastTimestamp": ts(mins),
                    "metadata": {"creationTimestamp": ts(mins)}}
        data = {"items": [mk("BackOff", 5, "first"), mk("BackOff", 6, "second"), mk("Old", 90, "x"),
                          mk("Normal", 1, "y", typ="Normal")]}
        r = cr.analyze_events(data, NOW, timedelta(minutes=30))
        self.assertEqual(r, [{"reason": "BackOff", "count": 2, "example": "first"}])

    def test_workloads(self):
        def mk(n, d, r):
            return {"metadata": {"namespace": "orders", "name": n},
                    "spec": {"replicas": d}, "status": {"readyReplicas": r} if r else {}}
        data = {"items": [mk("ok", 2, 2), mk("low", 3, 1), mk("zero", 2, 0)]}
        self.assertEqual(len(cr.analyze_workloads(data, "Deployment")), 2)


def run_proc(returncode=0, stdout="{}", stderr=""):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class CollectTests(unittest.TestCase):
    def test_kubectl_failure_is_exit_2(self):
        with mock.patch("subprocess.run", return_value=run_proc(1, "", "Unable to connect to the server")):
            self.assertEqual(cr.main(["--context", "nope"]), 2)

    def test_kubectl_missing_is_exit_2(self):
        with mock.patch("subprocess.run", side_effect=FileNotFoundError):
            self.assertEqual(cr.main([]), 2)

    def test_timeout_is_exit_2(self):
        with mock.patch("subprocess.run", side_effect=subprocess.TimeoutExpired("kubectl", 20)):
            self.assertEqual(cr.main([]), 2)

    def test_missing_crd_is_skipped_not_failed(self):
        def fake(cmd, **kw):
            if any("argoproj.io" in c for c in cmd):
                return run_proc(1, "", 'error: the server doesn\'t have a resource type "applications"')
            return run_proc(0, '{"items": []}')
        with mock.patch("subprocess.run", side_effect=fake), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cr.main(["--json"]), 0)
            report = cr.build_report(cr.parse_args([]), NOW)
        self.assertEqual(len(report["skipped"]), 2)
        self.assertEqual(report["finding_count"], 0)


if __name__ == "__main__":
    unittest.main()
