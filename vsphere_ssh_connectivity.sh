#!/usr/bin/env bash
#===============================================================================
#         FILE:  ssh_connectivity.sh
#
#        USAGE:  ./ssh_connectivity.sh
#
#  DESCRIPTION:  Checks SSH connectivity to VMs from vSphere and writes metrics
#                for Prometheus node_exporter textfile collector.
#                Runs multiple SSH checks in parallel.
#
#  REQUIREMENTS: bash 4+, sshpass, jq, curl, timeout
#       AUTHOR:  Philippe
#      VERSION: 2.0
#      CREATED: 2025-10-02
#===============================================================================

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

############################################################################
### Pre-checks
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "$(basename "$0") must be run as root!" >&2
        exit 2
    fi
}

require_root

############################################################################
# --- Variables avec surcharge possible via ENV ---

VSPHERE_SECRET_PATH="${VSPHERE_SECRET_PATH:-machines/prod/apps/terraform/vsphere}"
# Récupération des infos vSphere depuis Vault si non surchargées
if [ -z "${VSPHERE_SERVER:-}" ] || [ -z "${VSPHERE_USER:-}" ] || [ -z "${VSPHERE_PASS:-}" ]; then
    if [ -z "$VAULT_TOKEN" ]; then echo "ERROR: VAULT_TOKEN is not set, exiting."; exit 1; fi
    VSPHERE_DATA=$(vault kv get -mount=kv -format=json "$VSPHERE_SECRET_PATH")
    VSPHERE_SERVER="${VSPHERE_SERVER:-$(echo "$VSPHERE_DATA" | jq -r '.data.data.vsphere_server')}"
    VSPHERE_USER="${VSPHERE_USER:-$(echo "$VSPHERE_DATA" | jq -r '.data.data.vsphere_username')}"
    VSPHERE_PASS="${VSPHERE_PASS:-$(echo "$VSPHERE_DATA" | jq -r '.data.data.vsphere_password')}"
fi

SSH_SECRET_PATH="${SSH_SECRET_PATH:-machines/prod/apps/terraform/ssh}"
SSH_KEYS_TO_USE=(${SSH_KEYS_TO_USE[@]:-})
declare -A SSH_USERS

# récupère depuis Vault seulement si SSH_KEYS_TO_USE est défini
if [ "${#SSH_KEYS_TO_USE[@]}" -ne 0 ]; then
    if SSH_DATA=$(vault kv get -mount=kv -format=json "$SSH_SECRET_PATH" 2>/dev/null); then
        for key in "${SSH_KEYS_TO_USE[@]}"; do
            value=$(jq -r ".data.data.\"${key}_password\" // empty" <<< "$SSH_DATA")
            if [ -n "$value" ]; then
                SSH_USERS["$key"]="$value"
            fi
        done
    fi
else
    # --- Surcharge spécifique depuis ENV ---
    # pour chaque login, si une variable ENV SSH_USERS_<login>=<mdp> existe, on surcharge
    for user in "${!SSH_USERS[@]}"; do
        env_var="SSH_USERS_${user}"
        if [ -n "${!env_var:-}" ]; then
            SSH_USERS["$user"]="${!env_var}"
        fi
    done
fi

INCLUDE_LIST=(${INCLUDE_LIST[@]:-("^vm-")})
EXCLUDE_LIST=(${EXCLUDE_LIST[@]:-("vm-talos.*" "vm-windows.*" "vm-citrix.*")})
MAX_JOBS=${MAX_JOBS:-20}
SSH_TIMEOUT=${SSH_TIMEOUT:-30}
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=no}"

############################################################################
### === Step 1: Authenticate to vSphere API ===
SESSION=$(curl --noproxy '*' -s -k -X POST \
  -u "${VSPHERE_USER}:${VSPHERE_PASS}" \
  "https://${VSPHERE_SERVER}/rest/com/vmware/cis/session" \
  | jq -r '.value')

if [[ -z "$SESSION" || "$SESSION" == "null" ]]; then
  echo "Failed to authenticate to vSphere API" >&2
  exit 1
fi

### === Step 2: Get list of VMs (filter names starting with vm-) ===
# Convert Bash array to jq regex OR pattern
EXCLUDE_REGEX=$(IFS="|"; echo "${EXCLUDE_LIST[*]}")
INCLUDE_REGEX=$(IFS="|"; echo "${INCLUDE_LIST[*]}")

VM_LIST=$(curl --noproxy '*' -s -k -X GET \
  -H "vmware-api-session-id: ${SESSION}" \
  "https://${VSPHERE_SERVER}/rest/vcenter/vm" \
  | jq -c --arg exclude_regex "$EXCLUDE_REGEX" --arg include_regex "$INCLUDE_REGEX" '
      .value[]
      | select(.power_state=="POWERED_ON")      	# only powered on
      | select(.name | test($include_regex))           	# include patterns
      | select(.name | test($exclude_regex) | not)    	# exclude patterns
  ')

### === Step 3: Test SSH connections in parallel ===

echo "# HELP ssh_connection_up SSH connectivity status (1=connection up, 0=connection error)."
echo "# TYPE ssh_connection_up gauge"
echo "# HELP ssh_connection_latency_seconds SSH connection latency in seconds (0 if failed)."
echo "# TYPE ssh_connection_latency_seconds gauge"

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

    # Print atomically using subshell
    {
        echo "ssh_connection_up{vm=\"$vm_name\",user=\"$user\"} $status"
        echo "ssh_connection_latency_seconds{vm=\"$vm_name\",user=\"$user\"} $latency"
    } 
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
        ssh_test "$VM_NAME" "$USER" "$PASS" &
    done
done

# Wait for all background jobs to finish
wait
