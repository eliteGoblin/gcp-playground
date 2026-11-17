#!/usr/bin/env bash
# One-time bootstrap of Argo CD. After this, Argo CD manages itself and every
# other cluster component from Git (gitops/platform/apps).
#
# Usage: scripts/bootstrap-argocd.sh
# Needs: kubectl context on the target cluster, helm.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
chart_version="10.18.0" # keep equal to gitops/platform/apps/argocd.yaml

echo "kubectl context: $(kubectl config current-context)"

helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version "$chart_version" \
  --namespace argocd --create-namespace \
  --values "$repo_root/gitops/bootstrap/argocd-values.yaml" \
  --wait --timeout 10m

kubectl apply -f "$repo_root/gitops/bootstrap/root-app.yaml"
kubectl -n argocd get applications
