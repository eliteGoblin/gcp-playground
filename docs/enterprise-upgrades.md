# Enterprise upgrade options

This file lists what a large company adds to the demo design, and why the demo skips it. Product names and behaviour are from memory and are not verified against current Google documentation.

## Infrastructure as Code

| Topic | Demo | Enterprise option | When it is worth it |
|---|---|---|---|
| Drift detection | Scheduled `terraform plan -detailed-exitcode` each day in GitHub Actions; exit code 2 opens an issue | Same scheduled plan per environment with an alert to Slack or PagerDuty; HCP Terraform health assessments; Cloud Asset Inventory feeds and Audit Log alerts for changes made outside Terraform | Many workspaces, or people with console write access |
| Drift prevention | Not applicable (one user) | Humans get read-only access in production; write access only through the pipeline service account; break-glass access with an alert | Always in production; it removes most drift at the source |
| Run platform | GitHub Actions | HCP Terraform / Terraform Enterprise, Atlantis, or Spacelift: run queue, state locking UI, private module registry | Several teams share modules and state |
| Policy as code | tflint, Trivy config scan, checkov | OPA / Conftest or Sentinel on the plan output; Organization Policy constraints as the hard limit | Compliance requirements, many contributors |
| Environments | One environment | One root per environment (dev, staging, prod) with the same modules and different variables; promotion by pull request | More than one environment |
| Module versions | Pinned registry versions | Private registry, Renovate for version updates, module tests | Shared modules across teams |

## Network

| Topic | Demo | Enterprise option |
|---|---|---|
| Firewall | VPC firewall rules and NetworkPolicy | Cloud NGFW Enterprise (intrusion prevention, TLS inspection); cost is per endpoint per hour plus per GB |
| VPC layout | One VPC in one project | Shared VPC with host and service projects, or hub-and-spoke with Network Connectivity Center |
| Private DNS zones | None; the demo has only public names | Private Cloud DNS zones for names that must not resolve from the internet: internal load balancers, databases, service-to-service names across clusters |
| DNSSEC | Off | On for public zones |
| Google API access | Private Google Access | Private Service Connect endpoints, VPC Service Controls perimeter against data exfiltration |
| Egress control | Cloud NAT, all destinations allowed | Secure Web Proxy or FQDN-based egress policies; fixed NAT addresses for partner allowlists |
| Edge | One Cloud Armor policy | Cloud Armor Enterprise (adaptive protection, DDoS response team), Cloud CDN |
| Certificates | Google-managed public certificate | Certificate Authority Service for internal certificates and mutual TLS |

## Cluster

| Topic | Demo | Enterprise option |
|---|---|---|
| Availability | One regional cluster | Clusters in 2 regions with multi-cluster Gateway; fleet management |
| Upgrades | Surge upgrade, one maintenance window | Blue-green node pool upgrades, rollout sequencing (staging cluster first, then production), maintenance exclusions for peak trading periods |
| Backup | None (state is in Git) | Backup for GKE for stateful workloads |
| Access | IAM on one Google account | Google Groups for RBAC, Privileged Access Manager for time-limited admin access |
| Encryption | KMS key for Kubernetes secrets | Customer-managed keys (CMEK) for node disks, Artifact Registry, and logs; Confidential GKE Nodes |
| Service mesh | None | Cloud Service Mesh for mutual TLS and traffic policy between many services |
| Multi-tenancy | Namespaces | Namespace per team with quotas, hierarchical policies, separate node pools or clusters for sensitive workloads |

## Security and supply chain

| Topic | Demo | Enterprise option |
|---|---|---|
| Image admission | Binary Authorization in audit mode; Kyverno verifies cosign signatures | Binary Authorization in enforce mode with attestations from the pipeline; SLSA provenance |
| Threat detection | GKE Security Posture (standard tier) | Security Command Center Premium or Enterprise with Container Threat Detection; a runtime tool such as Falco or a commercial CNAPP |
| Vulnerability management | Trivy in CI, Artifact Registry scanning | Continuous scanning of running workloads, patch deadlines per severity, base image rebuild automation |
| Secrets | Secret Manager | Automatic rotation, per-secret IAM, access audit alerts |
| Organization controls | None (no organization on a personal account) | Organization Policy (no public IP addresses, no service account keys, allowed regions), folder hierarchy, central log sink |

## Observability and operations

| Topic | Demo | Enterprise option |
|---|---|---|
| Metrics and logs | Managed Prometheus, Cloud Logging, Grafana | Central observability project with scoped metrics, log sinks to BigQuery, or a vendor (Dynatrace, Datadog) |
| Alerting | One SLO with a burn-rate alert, sent by email | SLO per service, PagerDuty or Opsgenie on-call rotation, runbook link in each alert |
| Incident process | Not applicable | Incident roles, post-incident review template, error budget policy |
| Cost | Cost allocation labels | Billing export to BigQuery, budgets with alerts per team, committed use discounts |
| Data | Pub/Sub only | Cloud SQL with high availability and point-in-time recovery, read replicas, tested restore |
