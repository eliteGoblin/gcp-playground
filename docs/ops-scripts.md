# Ops scripts

## cluster_report.py

A read-only health report for the GKE cluster. It runs only `kubectl get`, uses only the Python standard library, and takes about 5 seconds.

It checks:

1. Nodes: count by pool, Spot vs on-demand, NotReady nodes, kubelet version skew.
2. Pods: Pending for more than 5 minutes, CrashLoopBackOff, ImagePullBackOff, restarts above a threshold.
3. Argo CD applications that are not `Synced` and `Healthy`.
4. Warning events in the last N minutes, grouped by reason.
5. Deployments and Argo Rollouts with fewer ready replicas than desired.

A missing CRD (for example Argo CD) is reported as "not installed: skipped".

Run it: `python3 scripts/cluster_report.py [--json] [--namespace NS] [--since-minutes 30] [--restart-threshold 5] [--context CTX]`

Exit codes: `0` healthy, `1` at least one finding, `2` data could not be collected (kubectl missing, cluster not reachable, a kubectl call failed).

Example from the live cluster (event messages are cut at 100 characters):

```text
[1] Nodes: 3 total, 1 spot, 2 on-demand
    pools: nap-e2-standard-2-spot-9vbjcixi=1, system=2
[2] Unhealthy pods (restarts > 5): none
[3] Argo CD apps not Synced+Healthy: none
[4] Warning events, last 30 min (by reason): 3
    ! FailedCreate x21: Error creating: admission webhook "ivpol.mutate.kyverno.svc-fail" denied the request: Policy verify-
    ! Unhealthy x3: Readiness probe failed: Get "http://10.20.0.18:8084/healthz": dial tcp 10.20.0.18:8084: connect: con
[5] Workloads with ready < desired: none
Result: 3 finding(s)
```

Tests: `python3 -m unittest discover -s scripts`. CI runs them and `shellcheck` in `.github/workflows/scripts.yml`.
