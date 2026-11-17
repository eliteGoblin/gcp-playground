#!/usr/bin/env bash
# Set a new random password for the read-only Argo CD account "demo".
# The account is declared in Git (gitops/bootstrap/argocd-values.yaml).
# The password is never in Git: this script writes the bcrypt hash to the
# argocd-secret Secret and saves the plain value in output/ (gitignored).
#
# Usage: scripts/set-argocd-demo-password.sh
# Needs: kubectl context on the cluster, argocd CLI (for the bcrypt hash), openssl, jq.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
out="$repo_root/output/argocd-demo-credentials.txt"
mkdir -p "$repo_root/output"

password="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
hash="$(argocd account bcrypt --password "$password")"
mtime="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
patch="$(jq --null-input --arg h "$hash" --arg t "$mtime" '{stringData: {"accounts.demo.password": $h, "accounts.demo.passwordMtime": $t}}')"

kubectl --namespace argocd patch secret argocd-secret --type merge --patch "$patch" >/dev/null

umask 077
printf 'url: https://argocd.gke.frankbluemind.com\nuser: demo\npassword: %s\nrole: read-only\n' "$password" > "$out"
echo "password set for account demo; saved in $out"
