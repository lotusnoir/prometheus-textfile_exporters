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

# Keep the original DNS command semantics.
DIG_CMD="dig +short"

if [[ -n "$DNS_SERVER" ]]; then
    DIG_CMD="dig +short @${DNS_SERVER}"
fi

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

INCLUDE_LIST=(${INCLUDE_LIST:-"^vm-"})

EXCLUDE_LIST=(${EXCLUDE_LIST="vm-talos.* vm-wec.* vm-citrix.* vm-ad-dc.* vm-board.* vm-elipse.* vm-gatewaydwh.* vm-gitrunr.* vm-ndsvc.* vm-protectsys.* vm-provtool.* vm-sig.* vm-syno.* vm-testad.* vm-veeam.* vm-wsus.* vm-windows.* vm-vdi.* vm-openvpn.* vm-ciscossm.*"})

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

mapfile -t VM_ARRAY < <(
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

if [[ "${#VM_ARRAY[@]}" -eq 0 ]]; then
    echo "No vm returned" >&2
    exit 1
fi

#echo "VMs: ${#VM_ARRAY[@]}" >&2
#echo "MAX_JOBS: ${MAX_JOBS}" >&2

############################################################################
### Step 3: Prometheus metrics
############################################################################

echo "# HELP vm_dns_mismatch_hostname compare dns with Hostname inside VM: 0=ok, 1=mismatch, 2=missing dns, 3=no ssh"
echo "# TYPE vm_dns_mismatch_hostname gauge"

echo "# HELP vm_dns_mismatch_reverse Reverse DNS check: 0=ok, 1=missing, 2=mismatch"
echo "# TYPE vm_dns_mismatch_reverse gauge"

echo "# HELP vm_dns_mismatch_ip compare ip dns with IP inside VM: 0=ok, 1=mismatch, 3=no ssh"
echo "# TYPE vm_dns_mismatch_ip gauge"

############################################################################
### Step 4: Check one VM
############################################################################

check_vm() {

    local VM_NAME="$1"

    local VM_IP=""
    local PTR=""
    local HOST_INSIDE=""
    local IPS_INSIDE=""
    local SSH_OUTPUT=""

    local HOSTNAME_STATUS=3
    local REVERSE_STATUS=1
    local IP_STATUS=3

    ########################################################################
    ### DNS A record
    ########################################################################

    VM_IP=$(
        $DIG_CMD A "${VM_NAME}.${DNS_DOMAIN}" |
        head -n1 ||
        true
    )

    ########################################################################
    ### No DNS record
    ########################################################################

    if [[ -z "$VM_IP" ]]; then

        printf \
            'vm_dns_mismatch_hostname{vm="%s"} 2\n' \
            "$VM_NAME"

        return 0
    fi

    ########################################################################
    ### Reverse DNS
    ########################################################################

    PTR=$(
        $DIG_CMD -x "$VM_IP" |
        sed 's/\.$//' ||
        true
    )

    if [[ -z "$PTR" ]]; then

        REVERSE_STATUS=1

    elif [[ "$PTR" == "${VM_NAME}.${DNS_DOMAIN}" ]]; then

        REVERSE_STATUS=0

    else

        REVERSE_STATUS=2

    fi

    ########################################################################
    ### SSH
    #
    # Original:
    #   SSH #1 -> test connection
    #   SSH #2 -> hostname -s
    #   SSH #3 -> hostname -I
    #
    # Optimized:
    #   ONE SSH connection -> hostname + IP
    ########################################################################

    if SSH_OUTPUT=$(
        timeout 60 \
            sshpass -p "$SSH_USER_PASSWORD" \
            ssh \
                $SSH_OPTS \
                -n \
                "$SSH_USER@$VM_NAME" \
                'printf "%s\n" "$(hostname -s)"; hostname -I' \
                2>/dev/null
    ); then

        ####################################################################
        ### Parse hostname
        ####################################################################

        HOST_INSIDE="${SSH_OUTPUT%%$'\n'*}"

        ####################################################################
        ### Parse IPs
        ####################################################################

        IPS_INSIDE="${SSH_OUTPUT#*$'\n'}"

        ####################################################################
        ### Hostname check
        ####################################################################

        if [[ "$HOST_INSIDE" == "$VM_NAME" ]]; then
            HOSTNAME_STATUS=0
        else
            HOSTNAME_STATUS=1
        fi

        ####################################################################
        ### IP check
        #
        # Same behaviour as original:
        # ignore 172.x.x.x addresses.
        ####################################################################

        IP_STATUS=1

        for IP in $IPS_INSIDE; do

            if [[ "$IP" == 172.* ]]; then
                continue
            fi

            if [[ "$IP" == "$VM_IP" ]]; then
                IP_STATUS=0
                break
            fi

        done

    else

        ####################################################################
        ### SSH unavailable
        ####################################################################

        HOSTNAME_STATUS=3
        IP_STATUS=3

    fi

    ########################################################################
    ### Output metrics
    ########################################################################

    printf \
        'vm_dns_mismatch_hostname{vm="%s"} %d\n' \
        "$VM_NAME" \
        "$HOSTNAME_STATUS"

    printf \
        'vm_dns_mismatch_reverse{vm="%s"} %d\n' \
        "$VM_NAME" \
        "$REVERSE_STATUS"

    printf \
        'vm_dns_mismatch_ip{vm="%s"} %d\n' \
        "$VM_NAME" \
        "$IP_STATUS"

    return 0
}

############################################################################
### Export function/environment for xargs workers
############################################################################

export DNS_SERVER
export DNS_DOMAIN
export DIG_CMD
export SSH_USER
export SSH_USER_PASSWORD
export SSH_OPTS
export SSH_TIMEOUT

export -f check_vm

############################################################################
### Step 5: Continuous parallel execution
############################################################################

printf '%s\0' "${VM_ARRAY[@]}" |
    xargs \
        -0 \
        -r \
        -n 1 \
        -P "$MAX_JOBS" \
        bash -c '
            check_vm "$1"
        ' _


exit 0
