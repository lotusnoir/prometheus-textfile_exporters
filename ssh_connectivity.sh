#!/usr/bin/env bash
#
# ssh_connectivity.sh
#
# Checks SSH connectivity to VMs from vSphere and writes metrics for Prometheus textfile collector.
# Runs multiple SSH checks in parallel to speed up execution.

### Secrets
VSPHERE_SECRET_PATH="machines/prod/apps/terraform/vsphere"
VSPHERE_DATA=$(vault kv get -mount=kv -format=json "$VSPHERE_SECRET_PATH")
VSPHERE_USER=$(echo "$VSPHERE_DATA" | jq -r '.data.data.vsphere_username')
VSPHERE_PASS=$(echo "$VSPHERE_DATA" | jq -r '.data.data.vsphere_password')
VSPHERE_SERVER=$(echo "$VSPHERE_DATA" | jq -r '.data.data.vsphere_server')

SSH_SECRET_PATH="machines/prod/apps/terraform/ssh"
SSH_DATA=$(vault kv get -mount=kv -format=json "$SSH_SECRET_PATH")
declare -A SSH_USERS
SSH_USERS["app-ansible"]="$(echo "$SSH_DATA" | jq -r '.data.data.ssh_password')"
SSH_USERS["app-test-login"]="$(echo "$SSH_DATA" | jq -r '.data.data.app_test_login_password')"

### Paths
TMP_FILE=$(mktemp)
EXPORTER_DIR="/var/lib/node_exporter"
METRICS_FILE="${EXPORTER_DIR}/ssh_connectivity.prom"

### Various
MAX_JOBS=20
SSH_TIMEOUT=10
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=no"

### vsphere select vms names
INCLUDE_LIST=('^vm-')
EXCLUDE_LIST=('vm-talos.*' 'vm-wec.*' 'vm-citrix.*' 'vm-ad-dc.*' 'vm-board.*' 'vm-elipse.*' 'vm-gatewaydwh.*' 'vm-gitrunr.*' 'vm-ndsvc.*' 'vm-protectsys.*' 'vm-provtools.*' 'vm-sig.*' 'vm-syno.*' 'vm-testad.*' 'vm-veeam.*' 'vm-wsus.*' 'vm-windows.*')


############################################################################
# === Step 1: Authenticate to vSphere API ===
SESSION=$(curl -s -k -X POST \
  -u "${VSPHERE_USER}:${VSPHERE_PASS}" \
  "https://${VSPHERE_SERVER}/rest/com/vmware/cis/session" \
  | jq -r '.value')

if [[ -z "$SESSION" || "$SESSION" == "null" ]]; then
  echo "Failed to authenticate to vSphere API" >&2
  exit 1
fi

# === Step 2: Get list of VMs (filter names starting with vm-) ===
# Convert Bash array to jq regex OR pattern
EXCLUDE_REGEX=$(IFS="|"; echo "${EXCLUDE_LIST[*]}")
INCLUDE_REGEX=$(IFS="|"; echo "${INCLUDE_LIST[*]}")

VM_LIST=$(curl -s -k -X GET \
  -H "vmware-api-session-id: ${SESSION}" \
  "https://${VSPHERE_SERVER}/rest/vcenter/vm" \
  | jq -c --arg exclude_regex "$EXCLUDE_REGEX" --arg include_regex "$INCLUDE_REGEX" '
      .value[]
      | select(.power_state=="POWERED_ON")      # only powered on
      | select(.name | test($include_regex))           # only vm-* names
      | select(.name | test($exclude_regex) | not)    # exclude patterns
  ')

# === Step 3: Test SSH connections in parallel ===

# Create temporary file for metrics
{
    echo "# HELP ssh_connection_up SSH connectivity status (1=up, 0=down)."
    echo "# TYPE ssh_connection_up gauge"
    echo "# HELP ssh_connection_latency_seconds SSH connection latency in seconds (0 if failed)."
    echo "# TYPE ssh_connection_latency_seconds gauge"
} > "$TMP_FILE"

# Function to test SSH connection
ssh_test() {
    local vm_name=$1
    local user=$2
    local pass=$3

    local start_time=$(date +%s.%N)
    OUTPUT=$(timeout $SSH_TIMEOUT sshpass -p "$pass" ssh $SSH_OPTS -n "$user@$vm_name" "echo success" 2>&1)
    EXIT_CODE=$?
    local end_time=$(date +%s.%N)

    local latency=0
    if [ $EXIT_CODE -eq 0 ]; then
        status=1
        latency=$(awk "BEGIN {print $end_time - $start_time}")
    else
        status=0
    fi

    # Write to temp file safely
    echo "ssh_connection_up{vm=\"$vm_name\",user=\"$user\"} $status"
    #echo "ssh_connection_latency_seconds{vm=\"$vm_name\",user=\"$user\"} $latency"
}

# Semaphore function to limit parallel jobs
limit_jobs() {
    local current_jobs
    while :; do
        current_jobs=$(jobs -rp | wc -l)
        (( current_jobs < MAX_JOBS )) && break
        sleep 0.1
    done
}

# Launch SSH tests
for vm in $VM_LIST; do
    VM_NAME=$(echo "$vm" | jq -r '.name')

    for USER in "${!SSH_USERS[@]}"; do
        PASS="${SSH_USERS[$USER]}"

        limit_jobs
        ssh_test "$VM_NAME" "$USER" "$PASS" >> "$TMP_FILE" 2>/dev/null &
    done
done

# Wait for all background jobs to finish
wait

# Move temp file to final metrics file
{
    grep '^#' "$TMP_FILE"
    grep -v '^#' "$TMP_FILE" | sort
} > "$METRICS_FILE"
