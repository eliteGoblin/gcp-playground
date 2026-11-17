#!/usr/bin/env bash
# Copy the Terraform bootstrap outputs into GitHub repository variables.
# The workflows read these variables. None of them is a secret: the pipeline
# uses Workload Identity Federation, so there is no key to store.
#
# Usage: scripts/set-github-vars.sh [owner/repo]
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
bootstrap="$repo_root/terraform/bootstrap"
repo="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

out() { terraform -chdir="$bootstrap" output -raw "$1"; }

project_id="$(sed -n 's/^project_id *= *"\(.*\)"/\1/p' "$bootstrap/terraform.tfvars")"
[ -n "$project_id" ] || { echo "project_id not found in terraform.tfvars" >&2; exit 1; }

set_var() {
  local name="$1" value="$2"
  [ -n "$value" ] || { echo "empty value for $name" >&2; exit 1; }
  gh variable set "$name" --repo "$repo" --body "$value"
  echo "set $name"
}

set_var GCP_PROJECT_ID "$project_id"
set_var GCP_REGION "australia-southeast1"
set_var GCP_WORKLOAD_IDENTITY_PROVIDER "$(out workload_identity_provider)"
set_var GCP_TF_PLAN_SA "$(out tf_plan_service_account)"
set_var GCP_TF_APPLY_SA "$(out tf_apply_service_account)"
set_var GCP_CI_IMAGES_SA "$(out ci_images_service_account)"
