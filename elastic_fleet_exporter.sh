#!/usr/bin/env bash
# Export Elastic Fleet agent statuses as Prometheus metrics (stdout version)
# Supports overriding via environment variables:
#   KIBANA_URL="https://your-kibana" AUTH="user:password" ./export_fleet_metrics.sh

set -euo pipefail

# --- Config (can be overridden via environment variables) ---
KIBANA_URL="${KIBANA_URL:-https://kibana.url.fr}"
AUTH="${AUTH:-elastixc:xxxxxxxxxxxxxx}"

TMPDIR=$(mktemp -d)
POLICIES="${TMPDIR}/policies.txt"
AGENTS="${TMPDIR}/agents.txt"

# --- Fetch policies ---
curl -s -k -u "$AUTH" -H "kbn-xsrf: true" \
  "$KIBANA_URL/api/fleet/agent_policies" \
| jq -r '.items[] | [.id, .name] | @tsv' > "$POLICIES"

# --- Fetch agents ---
curl -s -k -u "$AUTH" -H "kbn-xsrf: true" \
  "$KIBANA_URL/api/fleet/agents?perPage=1000" \
| jq -r '.items[] | [.local_metadata.host.name, .policy_id, .status] | @tsv' > "$AGENTS"

# --- Map statuses to numeric values ---
status_value() {
  case "$1" in
    online) echo 1 ;;
    degraded) echo 2 ;;
    *) echo 0 ;;  # offline or unknown
  esac
}

# --- Output Prometheus metrics to stdout ---
echo "# HELP elastic_fleet_enrollment_status Elastic Fleet agent enrollment status (1=online, 2=degraded, 0=offline)"
echo "# TYPE elastic_fleet_enrollment_status gauge"

awk -F'\t' 'NR==FNR {
  id=$1
  name=""
  for (i=2; i<=NF; i++) name = name (i>2 ? " " : "") $i
  map[id]=name
  next
}
{
  policy = (map[$2] ? map[$2] : $2)
  printf("%s\t%s\t%s\n", $1, policy, $3)
}' "$POLICIES" "$AGENTS" |
while IFS=$'\t' read -r host policy status; do
  val=$(status_value "$status")
  echo "elastic_fleet_enrollment_status{hostname=\"${host}\",policy=\"${policy}\"} ${val}"
done

rm -rf "$TMPDIR"
