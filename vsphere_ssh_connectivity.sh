#!/usr/bin/env bash
#===============================================================================
#         FILE:  vsphere_ssh_connectivity.sh
#
#        USAGE:  ./vsphere_ssh_connectivity.sh
#
#  DESCRIPTION:  Checks SSH connectivity to powered-on VMs from vSphere and
#                writes metrics for Prometheus node_exporter textfile collector.
#                SSH checks are executed continuously in parallel.
#
#  REQUIREMENTS: bash 5+, sshpass, jq, curl, vault
#       AUTHOR:  Philippe
#      VERSION: 2.3
#===============================================================================

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

############################################################################
### Pre-checks
############################################################################

if [[ "$(id -u)" -ne 0 ]]; then
    echo "$(basename "$0") must be run as root!" >&2
    exit 2
fi

############################################################################
### Variables
############################################################################

VSPHERE_SECRET_PATH="${VSPHERE_SECRET_PATH:-machines/prod/apps/terraform/vsphere}"

SSH_SECRET_PATH="${SSH_SECRET_PATH:-machines/prod/apps/terraform/ssh}"

MAX_JOBS="${MAX_JOBS:-80}"
SSH_TIMEOUT="${SSH_TIMEOUT:-30}"

SSH_OPTS="${SSH_OPTS:--o NumberOfPasswordPrompts=1
-o PasswordAuthentication=yes
-o PubkeyAuthentication=no
-o KbdInteractiveAuthentication=no
-o StrictHostKeyChecking=no
-o UserKnownHostsFile=/dev/null
-o GlobalKnownHostsFile=/dev/null
-o ConnectTimeout=$SSH_TIMEOUT
-o BatchMode=no}"

############################################################################
### SSH users
############################################################################

declare -A SSH_USERS

# Convert SSH_KEYS_TO_USE into an array safely.
SSH_KEYS_TO_USE=(${SSH_KEYS_TO_USE:-})

if [[ "${#SSH_KEYS_TO_USE[@]}" -ne 0 ]]; then

    if [[ -z "${VAULT_TOKEN:-}" ]]; then
        echo "ERROR: VAULT_TOKEN is not set, exiting." >&2
        exit 1
    fi

    if SSH_DATA=$(vault kv get \
        -mount=kv \
        -format=json \
        "$SSH_SECRET_PATH" 2>/dev/null
    ); then

        for key in "${SSH_KEYS_TO_USE[@]}"; do

            value=$(jq -r \
                ".data.data.\"${key}_password\" // empty" \
                <<< "$SSH_DATA")

            if [[ -n "$value" ]]; then
                SSH_USERS["$key"]="$value"
            fi

        done

    fi

else

    # Optional environment override:
    # SSH_USERS_<login>=<password>
    #
    # Example:
    # SSH_USERS_admin='password'

    while IFS='=' read -r env_name env_value; do

        if [[ "$env_name" == SSH_USERS_* ]]; then

            user="${env_name#SSH_USERS_}"

            if [[ -n "$user" && -n "$env_value" ]]; then
                SSH_USERS["$user"]="$env_value"
            fi

        fi

    done < <(env)

fi

if [[ "${#SSH_USERS[@]}" -eq 0 ]]; then
    echo "ERROR: No SSH users configured." >&2
    exit 1
fi

############################################################################
### vSphere credentials
############################################################################

if [[ -z "${VSPHERE_SERVER:-}" ||
      -z "${VSPHERE_USER:-}" ||
      -z "${VSPHERE_PASS:-}" ]]; then

    if [[ -z "${VAULT_TOKEN:-}" ]]; then
        echo "ERROR: VAULT_TOKEN is not set, exiting." >&2
        exit 1
    fi

    VSPHERE_DATA=$(vault kv get \
        -mount=kv \
        -format=json \
        "$VSPHERE_SECRET_PATH")

    VSPHERE_SERVER="${VSPHERE_SERVER:-$(
        jq -r '.data.data.vsphere_server' <<< "$VSPHERE_DATA"
    )}"

    VSPHERE_USER="${VSPHERE_USER:-$(
        jq -r '.data.data.vsphere_username' <<< "$VSPHERE_DATA"
    )}"

    VSPHERE_PASS="${VSPHERE_PASS:-$(
        jq -r '.data.data.vsphere_password' <<< "$VSPHERE_DATA"
    )}"

fi

############################################################################
### VM filters
############################################################################

INCLUDE_LIST=(${INCLUDE_LIST:-"^vm-"})

EXCLUDE_LIST=(${EXCLUDE_LIST:-"vm-talos.* vm-windows.* vm-citrix.*"})

EXCLUDE_REGEX=$(IFS='|'; echo "${EXCLUDE_LIST[*]}")
INCLUDE_REGEX=$(IFS='|'; echo "${INCLUDE_LIST[*]}")

############################################################################
### Step 1: Authenticate to vSphere API
############################################################################

SESSION=$(
    curl \
        --noproxy '*' \
        -s \
        -k \
        -X POST \
        -u "${VSPHERE_USER}:${VSPHERE_PASS}" \
        "https://${VSPHERE_SERVER}/rest/com/vmware/cis/session" |
    jq -r '.value'
)

if [[ -z "$SESSION" || "$SESSION" == "null" ]]; then
    echo "Failed to authenticate to vSphere API" >&2
    exit 1
fi

############################################################################
### Step 2: Get powered-on VM list
############################################################################

mapfile -t VM_LIST < <(
    curl \
        --noproxy '*' \
        -s \
        -k \
        -X GET \
        -H "vmware-api-session-id: ${SESSION}" \
        "https://${VSPHERE_SERVER}/rest/vcenter/vm" |
    jq -r \
        --arg exclude_regex "$EXCLUDE_REGEX" \
        --arg include_regex "$INCLUDE_REGEX" '
            .value[]
            | select(.power_state == "POWERED_ON")
            | select(.name | test($include_regex))
            | select(.name | test($exclude_regex) | not)
            | .name
        '
)

############################################################################
### Diagnostics
############################################################################

VM_COUNT="${#VM_LIST[@]}"
USER_COUNT="${#SSH_USERS[@]}"
EXPECTED_CHECKS=$((VM_COUNT * USER_COUNT))

#echo "VMs: ${VM_COUNT}" >&2
#echo "SSH users: ${USER_COUNT}" >&2
#echo "Expected SSH checks: ${EXPECTED_CHECKS}" >&2
#echo "MAX_JOBS: ${MAX_JOBS}" >&2

if [[ "$VM_COUNT" -eq 0 ]]; then
    echo "WARNING: No VMs found." >&2
    exit 0
fi

############################################################################
### Prometheus headers
############################################################################

echo "# HELP ssh_connection_up SSH connectivity status (1=connection up, 0=connection error)."
echo "# TYPE ssh_connection_up gauge"

echo "# HELP ssh_connection_latency_seconds SSH connection latency in seconds (0 if failed)."
echo "# TYPE ssh_connection_latency_seconds gauge"

############################################################################
### SSH check
############################################################################

ssh_test() {

    local vm_name="$1"
    local user="$2"
    local pass="$3"

    local start_us
    local end_us
    local delta_us
    local latency

    # EPOCHREALTIME gives seconds.microseconds.
    # Remove the decimal point => microseconds since epoch.
    start_us=${EPOCHREALTIME/./}

    if sshpass -p "$pass" \
        ssh \
            $SSH_OPTS \
            "${user}@${vm_name}" \
            "exit" \
            2>/dev/null
    then

        end_us=${EPOCHREALTIME/./}

        delta_us=$((10#$end_us - 10#$start_us))

        latency=$(printf '%d.%06d' \
            "$((delta_us / 1000000))" \
            "$((delta_us % 1000000))")

        printf 'ssh_connection_up{vm="%s",user="%s"} 1\n' \
            "$vm_name" \
            "$user"

        printf 'ssh_connection_latency_seconds{vm="%s",user="%s"} %s\n' \
            "$vm_name" \
            "$user" \
            "$latency"

    else

        printf 'ssh_connection_up{vm="%s",user="%s"} 0\n' \
            "$vm_name" \
            "$user"

    fi

    return 0
}

export SSH_OPTS
export -f ssh_test

############################################################################
### Step 3: Build the SSH job queue
############################################################################
#
# We generate one NUL-separated triplet:
#
#   VM_NAME
#   USER
#   PASSWORD
#
# for every SSH check.
#
# xargs maintains a continuous pool of MAX_JOBS processes:
#
#   job finishes -> next job starts immediately
#
############################################################################

JOB_QUEUE=$(mktemp)

cleanup() {
    rm -f "$JOB_QUEUE"
}

trap cleanup EXIT

for VM_NAME in "${VM_LIST[@]}"; do

    for USER in "${!SSH_USERS[@]}"; do

        printf '%s\0%s\0%s\0' \
            "$VM_NAME" \
            "$USER" \
            "${SSH_USERS[$USER]}" \
            >> "$JOB_QUEUE"

    done

done

############################################################################
### Validate queue
############################################################################

QUEUE_ARGS=$(
    tr '\0' '\n' < "$JOB_QUEUE" |
    wc -l
)

if [[ "$QUEUE_ARGS" -ne $((EXPECTED_CHECKS * 3)) ]]; then

    echo "ERROR: Invalid SSH job queue." >&2
    echo "Expected arguments: $((EXPECTED_CHECKS * 3))" >&2
    echo "Actual arguments:   ${QUEUE_ARGS}" >&2

    exit 1

fi

############################################################################
### Step 4: Execute SSH checks continuously in parallel
############################################################################

xargs \
    -0 \
    -r \
    -n 3 \
    -P "$MAX_JOBS" \
    bash -c '
        ssh_test "$1" "$2" "$3"
    ' _ \
    < "$JOB_QUEUE"

exit 0
