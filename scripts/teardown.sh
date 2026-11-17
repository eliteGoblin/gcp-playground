#!/usr/bin/env bash
# Remove the demo platform to stop the cost. This is destructive and not reversible.
#
# Order matters:
#   1. Remove the Cloudflare delegation (so no public name points at a deleted zone).
#   2. Delete Argo CD applications. This removes the Gateway, so GKE deletes the
#      load balancer, and removes external-dns records while external-dns still runs.
#   3. terraform destroy of the environment (cluster, network, DNS zone, certificate).
#   4. The bootstrap root (state bucket, CI identities) stays. Delete the project to remove everything.
#
# Usage: scripts/teardown.sh --yes-destroy-demo
set -euo pipefail

[ "${1:-}" = "--yes-destroy-demo" ] || { echo "This destroys the demo platform. Run with --yes-destroy-demo" >&2; exit 1; }

repo_root="$(git rev-parse --show-toplevel)"
env_dir="$repo_root/terraform/envs/demo"

echo "== 1. Cloudflare delegation"
"$repo_root/scripts/delegate-subdomain.sh" --remove

echo "== 2. Argo CD applications (load balancer and DNS records)"
# Delete the root first so it does not create the child applications again.
kubectl -n argocd delete application root --wait=true --timeout=10m || true
kubectl -n argocd delete applications --all --wait=true --timeout=15m || true
# Node pools that ComputeClass created are not in Terraform state.
kubectl delete computeclass --all --wait=true || true

echo "== 3. Terraform destroy"
# The KMS key has prevent_destroy. Cloud KMS key rings cannot be deleted, so the
# key and key ring are removed from state only; the key version is destroyed with the project.
terraform -chdir="$env_dir" state rm module.gke.google_kms_crypto_key_iam_member.gke_agent module.gke.google_kms_crypto_key.secrets module.gke.google_kms_key_ring.gke || true
sed -i.bak 's/prevent_destroy = true/prevent_destroy = false/' "$repo_root/terraform/modules/gke/main.tf"
terraform -chdir="$env_dir" destroy -auto-approve
mv "$repo_root/terraform/modules/gke/main.tf.bak" "$repo_root/terraform/modules/gke/main.tf"

echo "== done. The project, state bucket, and CI identities still exist."
echo "   To remove everything: gcloud projects delete <project id>"
