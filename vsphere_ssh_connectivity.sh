#!/usr/bin/env bash
#===============================================================================
#         FILE:  vsphere_ssh_connectivity.sh
#
#        USAGE:  ./vsphere_ssh_connectivity.sh
#
#  DESCRIPTION:
#                Tests SSH connectivity to every powered-on VM from vSphere,
#                for each configured SSH login, and emits Prometheus textfile
#                metrics:
#
#                  ssh_connection_up{vm,user,ssh_error}
#                      1 = SSH connection succeeded
#                      0 = SSH connection failed (see ssh_error for reason)
#
#                  ssh_connection_latency_seconds{vm,user}
#                      Connection time in seconds (only emitted on success)
#
#                  ssh_connectivity_scrape_error
#                      1 = at least one fatal error occurred (vCenter auth,
#                          VM listing...); metrics below may be incomplete
#
#                Labels:
#                  ssh_error : ok | timeout | auth_failed | refused |
#                              dns_resolution | no_route | host_key |
#                              net_timeout | conn_closed | other
#
#  REQUIREMENTS: bash 5+, sshpass, jq, curl, xargs, timeout
#                (optionally: Vault CLI if SSH_KEYS_TO_USE/VSPHERE_* unset)
#
#    ARGUMENTS:  None (all configuration is via environment variables below).
#
#  ENVIRONMENT:
#                --- vCenter connection ---
#                VSPHERE_SECRET_PATH   Vault KV path for vCenter creds
#                                      (default: machines/prod/apps/terraform/vsphere)
#                VSPHERE_SERVER        vCenter FQDN/IP (from Vault if unset)
#                VSPHERE_USER          vCenter username (from Vault if unset)
#                VSPHERE_PASS          vCenter password (from Vault if unset)
#
#                --- SSH logins to test ---
#                SSH_KEYS_TO_USE       Space-separated login names to fetch
#                                      from Vault (reads "<login>_password"
#                                      under SSH_SECRET_PATH)
#                SSH_SECRET_PATH       Vault KV path for SSH creds
#                                      (default: machines/prod/apps/terraform/ssh)
#                SSH_USERS_<login>     Alternative to Vault: set the password
#                                      directly, e.g. SSH_USERS_admin='pass'
#                                      (used only if SSH_KEYS_TO_USE is empty)
#                SSH_TIMEOUT           Per-connection timeout, seconds
#                                      (default: 30)
#
#                --- Vault authentication ---
#                VAULT_TOKEN           Required whenever Vault is used
#
#                --- VM selection filters ---
#                INCLUDE_LIST          Space-separated ERE patterns; a VM name
#                                      must match at least one to be tested
#                                      (default: "^vm-")
#                EXCLUDE_LIST          Space-separated ERE patterns; a VM name
#                                      matching any of these is skipped
#                                      (default: "vm-talos.* vm-windows.*
#                                       vm-citrix.*")
#
#                --- Execution control ---
#                MAX_JOBS              Max parallel SSH checks (default: 80)
#                GLOBAL_TIMEOUT        Hard wall-clock limit for the whole
#                                      run, seconds (default: 900)
#
#  SECURITY NOTE:
#                SSH passwords are never passed on any command line (which
#                would leak them via `ps`). They are piped to sshpass via
#                stdin (-p file descriptor /dev/stdin), and go through
#                xargs/bash -c only as positional parameters of a function
#                call, never interpolated into a shell string.
#
#       AUTHOR:  Philippe LEAL
#      VERSION: 3.0
#      CREATED: 2025-09-15
#    MODIFIED:  2025-11-19
#===============================================================================

set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRAPE_ERROR=0

############################################################################
### Pre-checks
############################################################################

if [[ "$(id -u)" -ne 0 ]]; then
    echo "$(basename "$0") must be run as root!" >&2
    exit 2
fi

for bin in sshpass ssh jq curl xargs timeout; do
    command -v "$bin" &>/dev/null || { echo "ERROR: required binary not found: $bin" >&2; exit 1; }
done

############################################################################
### Variables
############################################################################

VSPHERE_SECRET_PATH="${VSPHERE_SECRET_PATH:-machines/prod/apps/terraform/vsphere}"
SSH_SECRET_PATH="${SSH_SECRET_PATH:-machines/prod/apps/terraform/ssh}"

MAX_JOBS="${MAX_JOBS:-80}"
SSH_TIMEOUT="${SSH_TIMEOUT:-30}"
GLOBAL_TIMEOUT="${GLOBAL_TIMEOUT:-900}"

VSPHERE_SESSION_ID=""
VSPHERE_URL=""

# shellcheck disable=SC2206
SSH_OPTS=(
    -o NumberOfPasswordPrompts=1
    -o PasswordAuthentication=yes
    -o PubkeyAuthentication=no
    -o KbdInteractiveAuthentication=no
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o ConnectTimeout="$SSH_TIMEOUT"
    -o BatchMode=no
)

############################################################################
### Fatal (emits scrape_error metric before exiting)
############################################################################

fatal() {
    echo "ERROR: $*" >&2
    echo "# HELP ssh_connectivity_scrape_error 1 if a fatal error occurred"
    echo "# TYPE ssh_connectivity_scrape_error gauge"
    echo "ssh_connectivity_scrape_error 1"
    exit 1
}

############################################################################
### Cleanup (closes the vSphere session if one was opened)
############################################################################

cleanup() {
    if [[ -n "$VSPHERE_SESSION_ID" && -n "$VSPHERE_URL" ]]; then
        curl --noproxy '*' -s -k -X DELETE \
            -H "vmware-api-session-id: ${VSPHERE_SESSION_ID}" \
            "${VSPHERE_URL}/rest/com/vmware/cis/session" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

############################################################################
### SSH users
############################################################################

declare -A SSH_USERS

read -ra SSH_KEYS_TO_USE <<< "${SSH_KEYS_TO_USE:-}"

if [[ "${#SSH_KEYS_TO_USE[@]}" -ne 0 ]]; then

    [[ -n "${VAULT_TOKEN:-}" ]] || fatal "VAULT_TOKEN is not set"

    SSH_DATA="$(vault kv get -mount=kv -format=json "$SSH_SECRET_PATH" 2>/dev/null)" \
        || fatal "Vault path not found: $SSH_SECRET_PATH"

    for key in "${SSH_KEYS_TO_USE[@]}"; do
        value="$(jq -r ".data.data.\"${key}_password\" // empty" <<< "$SSH_DATA")"
        [[ -n "$value" ]] && SSH_USERS["$key"]="$value"
    done

else
    # Alternative to Vault: SSH_USERS_<login>=<password>
    while IFS='=' read -r env_name env_value; do
        if [[ "$env_name" == SSH_USERS_* ]]; then
            user="${env_name#SSH_USERS_}"
            [[ -n "$user" && -n "$env_value" ]] && SSH_USERS["$user"]="$env_value"
        fi
    done < <(env)
fi

[[ "${#SSH_USERS[@]}" -gt 0 ]] || fatal "No SSH users configured"

############################################################################
### vSphere credentials
############################################################################

if [[ -z "${VSPHERE_SERVER:-}" || -z "${VSPHERE_USER:-}" || -z "${VSPHERE_PASS:-}" ]]; then

    [[ -n "${VAULT_TOKEN:-}" ]] || fatal "VAULT_TOKEN is not set"

    VSPHERE_DATA="$(vault kv get -mount=kv -format=json "$VSPHERE_SECRET_PATH")" \
        || fatal "Vault path not found: $VSPHERE_SECRET_PATH"

    VSPHERE_SERVER="${VSPHERE_SERVER:-$(jq -r '.data.data.vsphere_server' <<< "$VSPHERE_DATA")}"
    VSPHERE_USER="${VSPHERE_USER:-$(jq -r '.data.data.vsphere_username' <<< "$VSPHERE_DATA")}"
    VSPHERE_PASS="${VSPHERE_PASS:-$(jq -r '.data.data.vsphere_password' <<< "$VSPHERE_DATA")}"
fi

VSPHERE_URL="https://${VSPHERE_SERVER}"

############################################################################
### VM filters
############################################################################

read -ra INCLUDE_LIST <<< "${INCLUDE_LIST:-^vm-}"
read -ra EXCLUDE_LIST <<< "${EXCLUDE_LIST:-vm-talos.* vm-windows.* vm-citrix.*}"

EXCLUDE_REGEX=$(IFS='|'; echo "${EXCLUDE_LIST[*]}")
INCLUDE_REGEX=$(IFS='|'; echo "${INCLUDE_LIST[*]}")
[[ -n "$INCLUDE_REGEX" ]] || INCLUDE_REGEX='^$a'   # matches nothing
[[ -n "$EXCLUDE_REGEX" ]] || EXCLUDE_REGEX='^$a'   # matches nothing

############################################################################
### Step 1: Authenticate to vSphere API
############################################################################

# Credentials via a curl config file (-K): never on the command line,
# so they never leak through `ps`.
VSPHERE_CURL_CONFIG="$(mktemp)"
chmod 600 "$VSPHERE_CURL_CONFIG"
printf 'user = "%s:%s"\n' "$VSPHERE_USER" "$VSPHERE_PASS" > "$VSPHERE_CURL_CONFIG"

SESSION_RESPONSE="$(
    curl --noproxy '*' -s -k -X POST -K "$VSPHERE_CURL_CONFIG" \
        "${VSPHERE_URL}/rest/com/vmware/cis/session"
)"
rm -f "$VSPHERE_CURL_CONFIG"

VSPHERE_SESSION_ID="$(jq -r '.value // empty' <<< "$SESSION_RESPONSE")"
[[ -n "$VSPHERE_SESSION_ID" ]] || fatal "Failed to authenticate to vSphere API"

############################################################################
### Step 2: Get powered-on VM list
############################################################################

VM_RESPONSE="$(
    curl --noproxy '*' -s -k -X GET \
        -H "vmware-api-session-id: ${VSPHERE_SESSION_ID}" \
        "${VSPHERE_URL}/rest/vcenter/vm"
)"

[[ -n "$VM_RESPONSE" ]] || fatal "Empty response when listing VMs"

mapfile -t VM_LIST < <(
    jq -r \
        --arg exclude_regex "$EXCLUDE_REGEX" \
        --arg include_regex "$INCLUDE_REGEX" '
            .value[]
            | select(.power_state == "POWERED_ON")
            | select(.name | test($include_regex))
            | select(.name | test($exclude_regex) | not)
            | .name
        ' <<< "$VM_RESPONSE"
) || fatal "Failed to parse VM list"

VM_COUNT="${#VM_LIST[@]}"
USER_COUNT="${#SSH_USERS[@]}"
EXPECTED_CHECKS=$((VM_COUNT * USER_COUNT))

if [[ "$VM_COUNT" -eq 0 ]]; then
    echo "WARNING: No VMs matched INCLUDE_LIST/EXCLUDE_LIST" >&2
    SCRAPE_ERROR=1
fi

############################################################################
### Prometheus headers
############################################################################

echo "# HELP ssh_connection_up SSH connectivity status (1=up, 0=failed, see ssh_error)"
echo "# TYPE ssh_connection_up gauge"

echo "# HELP ssh_connection_latency_seconds SSH connection latency in seconds (success only)"
echo "# TYPE ssh_connection_latency_seconds gauge"

############################################################################
### SSH check
############################################################################

# Classifies ssh's stderr into a short, stable label so dashboards can
# distinguish "VM down" from "wrong password" from "DNS broken" etc.
classify_ssh_error() {
    local err="$1"

    if   [[ "$err" == *"Could not resolve hostname"* ]]; then echo "dns_resolution"
    elif [[ "$err" == *"Connection timed out"* ]];         then echo "net_timeout"
    elif [[ "$err" == *"Operation timed out"* ]];          then echo "timeout"
    elif [[ "$err" == *"No route to host"* ]];             then echo "no_route"
    elif [[ "$err" == *"Connection refused"* ]];           then echo "refused"
    elif [[ "$err" == *"Permission denied"* ]];            then echo "auth_failed"
    elif [[ "$err" == *"Host key verification failed"* ]]; then echo "host_key"
    elif [[ "$err" == *"Connection closed"* ]];             then echo "conn_closed"
    else echo "other"
    fi
}

ssh_test() {

    local vm_name="$1"
    local user="$2"
    local pass="$3"

    local start_us end_us delta_us latency ssh_err status err_file

    err_file="$(mktemp)"
    start_us=${EPOCHREALTIME/./}

    # Password passed via file descriptor 3 (sshpass -d3): never on the
    # command line, never in an env var dump — only this process can read it.
    if sshpass -d3 ssh \
        "${SSH_OPTS[@]}" \
        "${user}@${vm_name}" \
        "exit" \
        >/dev/null 2>"$err_file" 3<<< "$pass"
    then
        end_us=${EPOCHREALTIME/./}
        delta_us=$((10#$end_us - 10#$start_us))
        latency=$(printf '%d.%06d' "$((delta_us / 1000000))" "$((delta_us % 1000000))")

        printf 'ssh_connection_up{vm="%s",user="%s",ssh_error="ok"} 1\n' "$vm_name" "$user"
        printf 'ssh_connection_latency_seconds{vm="%s",user="%s"} %s\n' "$vm_name" "$user" "$latency"
    else
        ssh_err="$(classify_ssh_error "$(cat "$err_file")")"
        printf 'ssh_connection_up{vm="%s",user="%s",ssh_error="%s"} 0\n' "$vm_name" "$user" "$ssh_err"
    fi

    rm -f "$err_file"
    return 0
}

export -f ssh_test classify_ssh_error
export SSH_OPTS

############################################################################
### Step 3: Build and run the SSH job queue
############################################################################

JOB_QUEUE="$(mktemp)"

# Appended to the existing trap: removes the job queue on top of closing
# the vSphere session.
trap 'cleanup; rm -f "$JOB_QUEUE"' EXIT

for VM_NAME in "${VM_LIST[@]}"; do
    for USER in "${!SSH_USERS[@]}"; do
        printf '%s\0%s\0%s\0' "$VM_NAME" "$USER" "${SSH_USERS[$USER]}" >> "$JOB_QUEUE"
    done
done

timeout --signal=KILL "$GLOBAL_TIMEOUT" \
    xargs -0 -r -n 3 -P "$MAX_JOBS" \
        bash -c 'ssh_test "$1" "$2" "$3"' _ \
        < "$JOB_QUEUE"

if [[ $? -eq 137 ]]; then
    echo "WARNING: GLOBAL_TIMEOUT=${GLOBAL_TIMEOUT}s exceeded, results may be incomplete" >&2
    SCRAPE_ERROR=1
fi

############################################################################
### Scrape error
############################################################################

echo "# HELP ssh_connectivity_scrape_error 1 if an error occurred during the run"
echo "# TYPE ssh_connectivity_scrape_error gauge"
echo "ssh_connectivity_scrape_error $SCRAPE_ERROR"

exit 0