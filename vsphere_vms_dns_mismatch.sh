#!/usr/bin/env bash
#
# vsphere_vms_dns_mismatch.sh
#
# Ensure that vm_name inside vcenter == dns name == vm hostname == ip PTR
# Ensure that dns_name_ip == vm_ip
#
# Get secrets from vault, support include / exclude regex to filter vcenter objects
#
############################################################################

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

############################################################################
### Defaults
############################################################################

DNS_SERVER="${DNS_SERVER:-}"
DNS_DOMAIN="${DNS_DOMAIN:-}"

DIG_BASE=(dig)
[[ -n "$DNS_SERVER" ]] && DIG_BASE+=("@${DNS_SERVER}")

############################################################################
### Temp files / cleanup
############################################################################

TMP_DIR="$(mktemp -d /tmp/vm_dns_check.XXXXXX)"
SESSION=""

cleanup() {
    local rc=$?
    if [[ -n "$SESSION" ]]; then
        curl --noproxy '*' -s -k -X DELETE \
            -H "vmware-api-session-id: ${SESSION}" \
            "https://${VSPHERE_SERVER}/rest/com/vmware/cis/session" \
            >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
    exit "$rc"
}
trap cleanup EXIT

############################################################################
### Pre-checks
############################################################################

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "$(basename "$0") must be run as root!" >&2
        exit 2
    fi
}

require_root

############################################################################
### vSphere variables
############################################################################

VSPHERE_SECRET_PATH="${VSPHERE_SECRET_PATH:-machines/prod/apps/terraform/vsphere}"

if [[ -z "${VSPHERE_SERVER:-}" ||
      -z "${VSPHERE_USER:-}" ||
      -z "${VSPHERE_PASS:-}" ]]; then

    if [[ -z "${VAULT_TOKEN:-}" ]]; then
        echo "ERROR: VAULT_TOKEN is not set, exiting." >&2
        exit 1
    fi

    VSPHERE_DATA=$(
        vault kv get \
            -mount=kv \
            -format=json \
            "$VSPHERE_SECRET_PATH"
    )

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
### SSH variables
############################################################################

SSH_USER="${SSH_USER:-app-ansible}"

SSH_SECRET_PATH="${SSH_SECRET_PATH:-machines/prod/apps/terraform/ssh}"

if [[ -z "${SSH_USER_PASSWORD:-}" ]]; then

    if [[ -z "${VAULT_TOKEN:-}" ]]; then
        echo "ERROR: VAULT_TOKEN is not set, exiting." >&2
        exit 1
    fi

    SSH_DATA=$(
        vault kv get \
            -mount=kv \
            -format=json \
            "$SSH_SECRET_PATH"
    )

    SSH_USER_PASSWORD=$(
        jq -r '.data.data.ssh_password' <<< "$SSH_DATA"
    )

fi

############################################################################
### Filters / parallelism
############################################################################

IFS=' ' read -r -a INCLUDE_LIST <<< "${INCLUDE_LIST:-^vm-}"

IFS=' ' read -r -a EXCLUDE_LIST <<< "${EXCLUDE_LIST:-vm-talos.* vm-wec.* vm-citrix.* vm-ad-dc.* vm-board.* vm-elipse.* vm-gatewaydwh.* vm-gitrunr.* vm-ndsvc.* vm-protectsys.* vm-provtool.* vm-sig.* vm-syno.* vm-testad.* vm-veeam.* vm-wsus.* vm-windows.* vm-vdi.* vm-openvpn.* vm-ciscossm.*}"

# NEW: VMs matching this list are still DNS/PTR-checked but SKIPPED for SSH
# (hostname / IP checks). Useful for appliances, scanners, network devices,
# or any host known not to accept SSH from the app-ansible account.
IFS=' ' read -r -a SSH_EXCLUDE_LIST <<< "${SSH_EXCLUDE_LIST:-}"

MAX_JOBS="${MAX_JOBS:-80}"

SSH_TIMEOUT="${SSH_TIMEOUT:-30}"

SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=no}"

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
### Step 2: Get list of VMs
############################################################################

EXCLUDE_REGEX=$(IFS="|"; echo "${EXCLUDE_LIST[*]}")
INCLUDE_REGEX=$(IFS="|"; echo "${INCLUDE_LIST[*]}")

# NEW: SSH exclude regex (empty-safe — an empty regex would match everything
# with `test()`, so fall back to a pattern that can never match).
if [[ "${#SSH_EXCLUDE_LIST[@]}" -eq 0 || -z "${SSH_EXCLUDE_LIST[0]}" ]]; then
    SSH_EXCLUDE_REGEX='(?!)'
else
    SSH_EXCLUDE_REGEX=$(IFS="|"; echo "${SSH_EXCLUDE_LIST[*]}")
fi

VM_LIST_JSON=$(
    curl \
        --noproxy '*' \
        -s \
        -k \
        -X GET \
        -H "vmware-api-session-id: ${SESSION}" \
        "https://${VSPHERE_SERVER}/rest/vcenter/vm"
)

if ! jq -e '.value' <<< "$VM_LIST_JSON" >/dev/null 2>&1; then
    echo "ERROR: unexpected response from vCenter API" >&2
    echo "$VM_LIST_JSON" >&2
    exit 1
fi

mapfile -t VM_ARRAY < <(
    jq -r \
        --arg exclude_regex "$EXCLUDE_REGEX" \
        --arg include_regex "$INCLUDE_REGEX" '
            .value[]
            | select(.power_state == "POWERED_ON")
            | select(.name | test($include_regex))
            | select(.name | test($exclude_regex) | not)
            | .name
        ' <<< "$VM_LIST_JSON"
)

if [[ "${#VM_ARRAY[@]}" -eq 0 ]]; then
    echo "No vm returned" >&2
    exit 1
fi

############################################################################
### Step 3: Batched DNS resolution (A + PTR)
############################################################################

FQDN_FILE="$TMP_DIR/fqdns.txt"
A_ANSWERS_FILE="$TMP_DIR/a_answers.txt"
ARPA_FILE="$TMP_DIR/arpa.txt"
PTR_ANSWERS_FILE="$TMP_DIR/ptr_answers.txt"
DNS_MAP_FILE="$TMP_DIR/dns_maps.sh"

for VM in "${VM_ARRAY[@]}"; do
    printf '%s.%s\n' "$VM" "$DNS_DOMAIN"
done > "$FQDN_FILE"

timeout 60 "${DIG_BASE[@]}" -f "$FQDN_FILE" -t A \
    +noall +answer +time=5 +tries=2 > "$A_ANSWERS_FILE" || true

declare -A VM_IP_MAP=()

while read -r name _ttl _class _type rdata; do
    [[ -z "${name:-}" || -z "${rdata:-}" ]] && continue
    name="${name%.}"
    vm="${name%.$DNS_DOMAIN}"
    [[ -n "${VM_IP_MAP[$vm]:-}" ]] && continue
    VM_IP_MAP[$vm]="$rdata"
done < "$A_ANSWERS_FILE"

: > "$ARPA_FILE"
declare -A SEEN_IP=()
for VM in "${VM_ARRAY[@]}"; do
    IP="${VM_IP_MAP[$VM]:-}"
    [[ -z "$IP" ]] && continue
    [[ -n "${SEEN_IP[$IP]:-}" ]] && continue
    SEEN_IP[$IP]=1
    IFS='.' read -r o1 o2 o3 o4 <<< "$IP"
    printf '%s.%s.%s.%s.in-addr.arpa\n' "$o4" "$o3" "$o2" "$o1" >> "$ARPA_FILE"
done

declare -A IP_PTR_MAP=()

if [[ -s "$ARPA_FILE" ]]; then
    timeout 60 "${DIG_BASE[@]}" -f "$ARPA_FILE" -t PTR \
        +noall +answer +time=5 +tries=2 > "$PTR_ANSWERS_FILE" || true

    while read -r name _ttl _class _type rdata; do
        [[ -z "${name:-}" || -z "${rdata:-}" ]] && continue
        name="${name%.}"
        name="${name%.in-addr.arpa}"
        IFS='.' read -r o4 o3 o2 o1 <<< "$name"
        ip="${o1}.${o2}.${o3}.${o4}"
        rdata="${rdata%.}"
        [[ -n "${IP_PTR_MAP[$ip]:-}" ]] && continue
        IP_PTR_MAP[$ip]="$rdata"
    done < "$PTR_ANSWERS_FILE"
fi

{
    declare -p VM_IP_MAP
    declare -p IP_PTR_MAP
} > "$DNS_MAP_FILE"

############################################################################
### Step 4: Prometheus metrics
############################################################################

echo "# HELP vm_dns_mismatch_hostname compare dns with Hostname inside VM: 0=ok, 1=mismatch, 2=missing dns, 3=no ssh, 4=ssh excluded"
echo "# TYPE vm_dns_mismatch_hostname gauge"

echo "# HELP vm_dns_mismatch_reverse Reverse DNS check: 0=ok, 1=missing, 2=mismatch"
echo "# TYPE vm_dns_mismatch_reverse gauge"

echo "# HELP vm_dns_mismatch_ip compare ip dns with IP inside VM: 0=ok, 1=mismatch, 3=no ssh, 4=ssh excluded"
echo "# TYPE vm_dns_mismatch_ip gauge"

############################################################################
### Step 5: Check one VM
############################################################################

check_vm() {

    local VM_NAME="$1"

    local VM_IP="${VM_IP_MAP[$VM_NAME]:-}"
    local PTR=""
    local HOST_INSIDE=""
    local IPS_INSIDE=""
    local SSH_OUTPUT=""
    local MATCHED_IP=""
    local SSH_RC=0
    local SSH_ERR=""
    local SSH_REASON="ok"
    local ERR_FILE=""

    local HOSTNAME_STATUS=3
    local REVERSE_STATUS=1
    local IP_STATUS=3

    ########################################################################
    ### No DNS record
    ########################################################################

    if [[ -z "$VM_IP" ]]; then
        printf 'vm_dns_mismatch_hostname{vm="%s",ip="unknown",ssh_error="no_dns"} 2\n' "$VM_NAME"
        return 0
    fi

    ########################################################################
    ### Reverse DNS (from pre-computed batch map, no per-VM dig call)
    ########################################################################

    PTR="${IP_PTR_MAP[$VM_IP]:-}"

    if [[ -z "$PTR" ]]; then
        REVERSE_STATUS=1
    elif [[ "$PTR" == "${VM_NAME}.${DNS_DOMAIN}" ]]; then
        REVERSE_STATUS=0
    else
        REVERSE_STATUS=2
    fi

    ########################################################################
    ### NEW: SSH exclusion check
    ########################################################################

    if [[ "$VM_NAME" =~ $SSH_EXCLUDE_REGEX ]]; then

        printf 'vm_dns_mismatch_hostname{vm="%s",ip="%s",ssh_error="excluded"} 4\n' \
            "$VM_NAME" "$VM_IP"

        printf 'vm_dns_mismatch_reverse{vm="%s",ip="%s",ptr="%s"} %d\n' \
            "$VM_NAME" "$VM_IP" "${PTR:-none}" "$REVERSE_STATUS"

        printf 'vm_dns_mismatch_ip{vm="%s",dns_ip="%s",guest_ip="unknown",ssh_error="excluded"} 4\n' \
            "$VM_NAME" "$VM_IP"

        return 0
    fi

    ########################################################################
    ### SSH: single connection -> hostname + IPs, with error classification
    ########################################################################

    ERR_FILE="$(mktemp "$TMP_DIR/err.XXXXXX")"

    if SSH_OUTPUT=$(
        timeout 60 \
            sshpass -p "$SSH_USER_PASSWORD" \
            ssh \
                $SSH_OPTS \
                -n \
                "$SSH_USER@$VM_NAME" \
                'printf "%s\n" "$(hostname -s)"; hostname -I' \
                2>"$ERR_FILE"
    ); then
        SSH_RC=0
    else
        SSH_RC=$?
    fi

    SSH_ERR="$(cat "$ERR_FILE" 2>/dev/null)"
    rm -f "$ERR_FILE"

    if [[ "$SSH_RC" -eq 0 ]]; then

        HOST_INSIDE="${SSH_OUTPUT%%$'\n'*}"
        IPS_INSIDE="${SSH_OUTPUT#*$'\n'}"

        if [[ "$HOST_INSIDE" == "$VM_NAME" ]]; then
            HOSTNAME_STATUS=0
        else
            HOSTNAME_STATUS=1
        fi

        IP_STATUS=1

        for IP in $IPS_INSIDE; do

            if [[ "$IP" == 172.* ]]; then
                continue
            fi

            if [[ "$IP" == "$VM_IP" ]]; then
                IP_STATUS=0
                MATCHED_IP="$IP"
                break
            fi

        done

        [[ -z "$MATCHED_IP" ]] && MATCHED_IP="$(awk '{print $1}' <<< "$IPS_INSIDE")"
        SSH_REASON="ok"

    else

        HOSTNAME_STATUS=3
        IP_STATUS=3

        if   [[ "$SSH_RC" -eq 124 ]];                               then SSH_REASON="timeout"
        elif [[ "$SSH_ERR" == *"Permission denied"* ]];              then SSH_REASON="auth_failed"
        elif [[ "$SSH_ERR" == *"Connection refused"* ]];             then SSH_REASON="refused"
        elif [[ "$SSH_ERR" == *"Could not resolve hostname"* ]];     then SSH_REASON="dns_resolution"
        elif [[ "$SSH_ERR" == *"No route to host"* ]];               then SSH_REASON="no_route"
        elif [[ "$SSH_ERR" == *"Host key verification failed"* ]];   then SSH_REASON="host_key"
        elif [[ "$SSH_ERR" == *"Connection timed out"* ]];            then SSH_REASON="net_timeout"
        elif [[ "$SSH_ERR" == *"Connection closed"* ]];               then SSH_REASON="conn_closed"
        else                                                          SSH_REASON="other"
        fi

    fi

    ########################################################################
    ### Output metrics
    ########################################################################

    printf \
        'vm_dns_mismatch_hostname{vm="%s",ip="%s",ssh_error="%s"} %d\n' \
        "$VM_NAME" "$VM_IP" "$SSH_REASON" "$HOSTNAME_STATUS"

    printf \
        'vm_dns_mismatch_reverse{vm="%s",ip="%s",ptr="%s"} %d\n' \
        "$VM_NAME" "$VM_IP" "${PTR:-none}" "$REVERSE_STATUS"

    printf \
        'vm_dns_mismatch_ip{vm="%s",dns_ip="%s",guest_ip="%s",ssh_error="%s"} %d\n' \
        "$VM_NAME" "$VM_IP" "${MATCHED_IP:-unknown}" "$SSH_REASON" "$IP_STATUS"

    return 0
}

############################################################################
### Export function/environment for xargs workers
############################################################################

export SSH_USER
export SSH_USER_PASSWORD
export SSH_OPTS
export SSH_TIMEOUT
export DNS_DOMAIN
export DNS_MAP_FILE
export TMP_DIR
export SSH_EXCLUDE_REGEX

export -f check_vm

############################################################################
### Step 6: Continuous parallel execution
############################################################################

printf '%s\0' "${VM_ARRAY[@]}" |
    xargs \
        -0 \
        -r \
        -n 1 \
        -P "$MAX_JOBS" \
        bash -c '
            source "$DNS_MAP_FILE"
            check_vm "$1"
        ' _

exit 0
