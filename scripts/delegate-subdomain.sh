#!/usr/bin/env bash
# Delegate the platform subdomain from the parent zone at Cloudflare to Cloud DNS.
#
# The parent domain stays at Cloudflare. This script adds one NS record per
# Cloud DNS name server for the subdomain, so only names under the subdomain
# are answered by Cloud DNS. Existing records of the parent zone do not change.
#
# Idempotent: an NS record that already exists is left as it is.
# Rollback:   scripts/delegate-subdomain.sh --remove
#
# Needs: CLOUDFLARE_PAT in the environment (token with "Zone DNS: Edit" on the
# parent zone only), terraform initialised in terraform/envs/demo, jq, curl.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
env_dir="$repo_root/terraform/envs/demo"
api="https://api.cloudflare.com/client/v4"
action="${1:-add}"

: "${CLOUDFLARE_PAT:?CLOUDFLARE_PAT is not set}"

subdomain="$(sed -n 's/^domain *= *"\(.*\)"/\1/p' "$env_dir/terraform.tfvars")"
[ -n "$subdomain" ] || { echo "domain not found in terraform.tfvars" >&2; exit 1; }
parent="${subdomain#*.}"

cf() { curl -sS --fail-with-body -H "Authorization: Bearer $CLOUDFLARE_PAT" -H "Content-Type: application/json" "$@"; }

zone_id="$(cf "$api/zones?name=$parent" | jq -r '.result[0].id // empty')"
[ -n "$zone_id" ] || { echo "zone $parent not found with this token" >&2; exit 1; }

existing="$(cf "$api/zones/$zone_id/dns_records?type=NS&name=$subdomain&per_page=100")"

if [ "$action" = "--remove" ]; then
  echo "$existing" | jq -r '.result[] | "\(.id) \(.content)"' | while read -r id content; do
    cf -X DELETE "$api/zones/$zone_id/dns_records/$id" >/dev/null
    echo "removed NS $subdomain -> $content"
  done
  exit 0
fi

name_servers="$(terraform -chdir="$env_dir" output -json name_servers | jq -r '.[]' | sed 's/\.$//')"
[ "$(echo "$name_servers" | grep -c .)" -ge 2 ] || { echo "no name servers in terraform output; apply the edge first" >&2; exit 1; }

for ns in $name_servers; do
  if echo "$existing" | jq -e --arg ns "$ns" '.result[] | select(.content == $ns)' >/dev/null; then
    echo "exists  NS $subdomain -> $ns"
  else
    cf -X POST "$api/zones/$zone_id/dns_records" \
      --data "$(jq -n --arg name "$subdomain" --arg ns "$ns" '{type: "NS", name: $name, content: $ns, ttl: 300}')" >/dev/null
    echo "created NS $subdomain -> $ns"
  fi
done
