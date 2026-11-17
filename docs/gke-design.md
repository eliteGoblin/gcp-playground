# GKE design

Status: built and running in project `gke-platform-demo-dce5` (Kubernetes 1.35.8-gke.1796000 on 2026-11-18). The items in this file were applied through Terraform and Argo CD, except the two items marked "not built".

Assumption: "MILKRUN level" means a small platform team that runs production microservices for a consumer app. The design therefore prefers Google-managed components to self-hosted components. I have no information about MILKRUN's real platform.

Scope: public path only. Users reach the apps from the internet. Nodes and the control plane have no public IP address.

## Request path

```
User -> Cloud DNS (public zone) -> Global external Application Load Balancer (Certificate Manager cert, Cloud Armor)
     -> Gateway API (GKE Gateway controller) -> container-native load balancing (NEG) -> Pod
Pod egress -> Cloud NAT -> internet
```

## Cluster

| Topic | Decision | Reason |
|---|---|---|
| Mode | Standard | Shows node pools, upgrades, and Spot; Autopilot hides them |
| Location | Regional control plane, `australia-southeast1`, nodes in 2 zones | Control plane stays available during a zone failure and during upgrades |
| Version | Stable release channel | Google tests each version in Rapid and Regular first |
| Upgrades | Automatic, maintenance window at night (Sydney time), surge upgrade | No manual version work; a window limits the risk period |
| Control plane access | DNS-based endpoint with IAM; IP endpoints disabled | No public IP endpoint and no bastion host |
| Terraform module | `terraform-google-modules/kubernetes-engine` (private cluster submodule) | Google-maintained module |

## Nodes

| Topic | Decision | Reason |
|---|---|---|
| System pool | 1 small on-demand node per zone | ArgoCD and policy components must not be preempted |
| Application nodes | No fixed pool. The ComputeClass `spot-first` creates Spot node pools when Pods need them | Google recommends auto-created pools; no idle nodes |
| Batch pool | `batch-spot`: Spot nodes, 0 to 2 per zone, taint `dedicated=batch:NoSchedule` | Interruptible jobs run apart from services; the pool costs nothing when no job runs |
| Node scaling | Cluster Autoscaler plus a custom ComputeClass with node pool auto-creation: prefer Spot (e2, then n2d), use on-demand when Spot is not available | The GKE-native equivalent of Karpenter (Karpenter is mainly used on AWS EKS) |
| Pod scaling | HPA for the HTTP service; KEDA for the Pub/Sub consumer (scales on backlog, to 0 when the queue is empty); VPA in recommendation mode | Event-driven scaling matches the demo app |
| Image | Container-Optimized OS with containerd | Google default, minimal OS |
| Hardening | Shielded nodes, secure boot, auto-repair, auto-upgrade | Google hardening guide |
| Node identity | Dedicated service account with minimum roles | The default Compute Engine service account has too many permissions |

## Network

| Topic | Decision | Reason |
|---|---|---|
| VPC | Custom VPC, one subnet, secondary ranges for Pods and Services (VPC-native) | Required for private clusters and NEG |
| Nodes | Private nodes | No node is reachable from the internet |
| Egress | Cloud NAT on a Cloud Router | Private nodes need it to pull images from outside Google and to call external APIs |
| Dataplane | Dataplane V2 (eBPF, Cilium) | Built-in NetworkPolicy enforcement and network policy logging |
| Policy | Default-deny NetworkPolicy per namespace, then explicit allow rules | Limits lateral movement between services |
| Ingress | Gateway API, class `gke-l7-global-external-managed` | Current Google recommendation; replaces Ingress |
| Edge protection | One Cloud Armor policy (rate limit and a preconfigured WAF rule) | Basic protection at low cost |
| DNS | Public Cloud DNS zone for the new domain; external-dns creates records from Gateway routes | No manual DNS records |
| Certificate | Certificate Manager, Google-managed wildcard certificate with DNS authorization | Certificate is issued before the load balancer exists; renewal is automatic |
| Cluster DNS | NodeLocal DNSCache | Lower DNS latency and fewer DNS failures under load |

## Security

| Topic | Decision |
|---|---|
| Pod identity | Workload Identity Federation for GKE; no service account keys |
| CI identity | GitHub Actions uses OIDC with Workload Identity Federation; no stored keys |
| Secrets | Secret Manager, read by Pods through the Secret Manager add-on |
| Secret encryption | Application-layer secrets encryption with a Cloud KMS key |
| Admission | Pod Security Admission `restricted` on app namespaces; Kyverno for custom rules (signed images only, no `latest` tag, resource limits required) |
| Images | Artifact Registry with vulnerability scanning; Trivy scan and cosign signature in CI; Kyverno verifies the signature at admission. Binary Authorization is enabled on the cluster with the default allow policy (an attestation policy is not built) |
| Posture | GKE Security Posture dashboard (standard tier). A kubescape scan in CI is not built |
| Audit | Cloud Audit Logs for the control plane |

## Components

Google-managed add-ons (enabled in Terraform):

| Add-on | Purpose |
|---|---|
| Gateway API controller | Creates the load balancer from Gateway and HTTPRoute objects |
| Managed Service for Prometheus | Metrics collection and storage without a self-hosted Prometheus |
| Cloud Logging and Cloud Monitoring (system and workload) | Logs and platform metrics |
| Workload Identity Federation | Pod access to Google APIs |
| Secret Manager add-on | Mounts secrets into Pods |
| NodeLocal DNSCache | DNS cache on each node |
| Cluster autoscaler, HPA, VPA | Capacity and Pod scaling |
| Cost allocation | Cost per namespace and label in the billing export |

Installed by ArgoCD (GitOps):

| Component | Purpose |
|---|---|
| ArgoCD | Applies all cluster manifests from Git (app-of-apps) |
| Argo Rollouts | Canary releases and automatic rollback |
| external-dns | Writes DNS records to Cloud DNS |
| Kyverno | Policy as code at admission |
| KEDA | Event-driven Pod autoscaling from Pub/Sub backlog |
| OpenTelemetry Collector | Not built: the demo app has no trace instrumentation |
| Grafana | Dashboards on top of Managed Prometheus, through the Managed Prometheus query frontend |
| Demo app | 2 services with Pub/Sub between them |

Not installed, with the reason: cert-manager (Certificate Manager covers it), self-hosted Prometheus (Managed Prometheus covers it), service mesh (2 services do not need it), ingress-nginx (Gateway API covers it).

## Terraform and pipeline

| Topic | Decision |
|---|---|
| Modules | Google-maintained modules from `terraform-google-modules` (network, cloud-nat, kubernetes-engine, cloud-dns); thin local wrappers only where needed |
| State | GCS bucket with object versioning; one state for `bootstrap` and one for the environment |
| Pipeline | GitHub Actions: `fmt`, `validate`, tflint, Trivy config scan, checkov, `plan` on pull request, `apply` on merge to `main` |
| Drift detection | Scheduled `terraform plan -detailed-exitcode` each day; exit code 2 opens a GitHub issue |
| Terraform Cloud / Enterprise | Not used |

Enterprise options that this demo skips are in [enterprise-upgrades.md](enterprise-upgrades.md).
