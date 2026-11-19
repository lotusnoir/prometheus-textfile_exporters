#===============================================================================
#         FILE:  vsphere_vms_dns_mismatch.sh
#
#        USAGE:  ./vsphere_vms_dns_mismatch.sh
#
#  DESCRIPTION:
#                Cross-checks vCenter VM inventory against DNS (A/PTR) and
#                guest OS state over SSH, exposing results in Prometheus
#                textfile format:
#
#                  vm_dns_mismatch_hostname{vm,ip,ssh_error}
#                      0 = hostname inside VM matches DNS name
#                      1 = hostname inside VM differs from DNS name
#                      2 = no DNS (A) record found for this VM
#                      3 = SSH unreachable (see ssh_error label for reason)
#                      4 = VM excluded from SSH checks (SSH_EXCLUDE_LIST)
#
#                  vm_dns_mismatch_reverse{vm,ip,ptr}
#                      0 = PTR record matches the expected FQDN
#                      1 = no PTR record found for this IP
#                      2 = PTR record points to a different name
#
#                  vm_dns_mismatch_ip{vm,dns_ip,guest_ip,ssh_error}
#                      0 = IP resolved by DNS matches an IP inside the VM
#                      1 = none of the VM's IPs match the DNS-resolved IP
#                      3 = SSH unreachable (see ssh_error label for reason)
#                      4 = VM excluded from SSH checks (SSH_EXCLUDE_LIST)
#
#                Labels:
#                  ssh_error : ok | no_dns | timeout | auth_failed | refused |
#                              dns_resolution | no_route | host_key |
#                              net_timeout | conn_closed | other | excluded
#
#  REQUIREMENTS: bash 5.1+, curl, jq, dig, sshpass, ssh, xargs, awk, timeout,
#                vault (Vault CLI, only if secrets are not provided via env)
#
#    ARGUMENTS:  None (all configuration is via environment variables below).
#
#  ENVIRONMENT:
#                --- vCenter connection ---
#                VSPHERE_SERVER        vCenter FQDN/IP (from Vault if unset)
#                VSPHERE_USER          vCenter username (from Vault if unset)
#                VSPHERE_PASS          vCenter password (from Vault if unset)
#                VSPHERE_SECRET_PATH   Vault KV path for vCenter creds
#                                      (default: machines/prod/apps/terraform/vsphere)
#
#                --- SSH connection to guest OS ---
#                SSH_USER              SSH username used to connect to VMs
#                                      (default: app-ansible)
#                SSH_USER_PASSWORD     SSH password (from Vault if unset)
#                SSH_SECRET_PATH       Vault KV path for SSH creds
#                                      (default: machines/prod/apps/terraform/ssh)
#                SSH_TIMEOUT           Per-connection timeout, seconds
#                                      (default: 30)
#                SSH_OPTS              Extra ssh options
#                                      (default: "-o StrictHostKeyChecking=no
#                                       -o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=no")
#                SSH_RETRIES           Retries on transient SSH errors
#                                      (timeout / connection closed / no route)
#                                      (default: 2)
#                SSH_RETRY_DELAY       Delay between SSH retries, seconds
#                                      (default: 3)
#
#                --- Vault authentication ---
#                VAULT_TOKEN           Required if VSPHERE_*/SSH_USER_PASSWORD
#                                      are not already set directly
#
#                --- DNS resolution ---
#                DNS_SERVER            DNS server to query (default: system resolver)
#                DNS_DOMAIN            Domain suffix appended to VM names
#                                      for A/PTR lookups (required)
#
#                --- VM selection filters ---
#                INCLUDE_LIST          Space-separated ERE patterns; a VM name
#                                      must match at least one to be checked
#                                      (default: "^vm-")
#                EXCLUDE_LIST          Space-separated ERE patterns; a VM name
#                                      matching any of these is fully skipped
#                                      (default: list of known appliances/
#                                       infra VMs, see script)
#                SSH_EXCLUDE_LIST      Space-separated ERE patterns; matching
#                                      VMs are still DNS/PTR-checked but SKIPPED
#                                      for SSH/hostname/IP checks (status=4)
#                                      (default: empty)
#
#                --- Execution control ---
#                MAX_JOBS              Max parallel VM checks (default: 80)
#                GLOBAL_TIMEOUT        Hard wall-clock limit for the whole
#                                      parallel run, seconds (default: 1800)
#
#       AUTHOR: Philippe LEAL
#      VERSION: 1.6
#      CREATED: 2025-11-19
#===============================================================================
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

############################################################################
### Defaults
############################################################################

DNS_SERVER="${DNS_SERVER:-}"
DNS_DOMAIN="${DNS_DOMAIN:-}"

DIG_BASE=(dig)
[[ -n "$DNS_SERVER" ]] && DIG_BASE+=("@${DNS_SERVER}")

SSH_RETRIES="${SSH_RETRIES:-2}"
SSH_RETRY_DELAY="${SSH_RETRY_DELAY:-3}"

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
    # Ne jamais laisser le mot de passe SSH traîner en variable d'environnement
    unset SSHPASS SSH_USER_PASSWORD 2>/dev/null || true
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

require_commands() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: missing required commands: ${missing[*]}" >&2
        exit 1
    fi
}

require_commands dig curl jq sshpass ssh xargs awk timeout

############################################################################
### DNS server health check (avoid false "no_dns" mass diagnosis)
############################################################################

if [[ -z "$DNS_DOMAIN" ]]; then
    echo "ERROR: DNS_DOMAIN is not set, exiting." >&2
    exit 1
fi

if ! timeout 10 "${DIG_BASE[@]}" +short +time=5 +tries=1 "$DNS_DOMAIN" SOA >/dev/null 2>&1; then
    echo "ERROR: DNS server unreachable or not answering for domain '$DNS_DOMAIN' (checked via SOA query). Aborting to avoid false mass mismatch." >&2
    exit 1
fi

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

    unset VSPHERE_DATA
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

    unset SSH_DATA
fi

# sshpass -e lit le mot de passe depuis la variable d'environnement SSHPASS,
# ce qui évite de l'exposer en clair dans `ps aux` / /proc/<pid>/cmdline
# (contrairement à `sshpass -p`).
export SSHPASS="$SSH_USER_PASSWORD"

############################################################################
### Filters / parallelism
############################################################################

IFS=' ' read -r -a INCLUDE_LIST <<< "${INCLUDE_LIST:-^vm-}"

IFS=' ' read -r -a EXCLUDE_LIST <<< "${EXCLUDE_LIST:-vm-talos.* vm-wec.* vm-citrix.* vm-ad-dc.* vm-board.* vm-elipse.* vm-gatewaydwh.* vm-gitrunr.* vm-ndsvc.* vm-protectsys.* vm-provtool.* vm-sig.* vm-syno.* vm-testad.* vm-veeam.* vm-wsus.* vm-windows.* vm-vdi.* vm-openvpn.* vm-ciscossm.*}"

# VMs matching this list are still DNS/PTR-checked but SKIPPED for SSH
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

# SSH exclude regex: géré proprement via un flag plutôt qu'un pattern factice
# "qui ne matche rien" (ERE bash ne supporte pas les lookaheads type (?!)).
SSH_EXCLUDE_ENABLED=0
if [[ "${#SSH_EXCLUDE_LIST[@]}" -gt 0 && -n "${SSH_EXCLUDE_LIST[0]}" ]]; then
    SSH_EXCLUDE_ENABLED=1
    SSH_EXCLUDE_REGEX=$(IFS="|"; echo "${SSH_EXCLUDE_LIST[*]}")
else
    SSH_EXCLUDE_REGEX=""
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

# On ne garde que les enregistrements de type A : un CNAME intermédiaire
# renverrait un nom d'hôte dans $rdata (pas une IP), ce qui corromprait
# toute la suite (zone inverse, comparaison SSH).
while read -r name _ttl _class rtype rdata; do
    [[ -z "${name:-}" || -z "${rdata:-}" ]] && continue
    [[ "$rtype" != "A" ]] && continue
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

    while read -r name _ttl _class rtype rdata; do
        [[ -z "${name:-}" || -z "${rdata:-}" ]] && continue
        [[ "$rtype" != "PTR" ]] && continue
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

ssh_is_excluded() {
    local vm="$1"
    [[ "$SSH_EXCLUDE_ENABLED" -eq 0 ]] && return 1
    [[ "$vm" =~ $SSH_EXCLUDE_REGEX ]]
}

# Une seule connexion SSH par tentative, avec retry sur erreurs transitoires
# (timeout, connexion fermée, pas de route) ; pas de retry sur les erreurs
# définitives (auth refusée, host key, DNS) pour ne pas perdre de temps.
ssh_collect_info() {
    local vm_name="$1"
    local attempt=0
    local rc=0
    local err=""
    local out=""
    local err_file

    while :; do
        attempt=$((attempt + 1))
        err_file="$(mktemp "$TMP_DIR/err.XXXXXX")"

        if out=$(
            timeout 60 \
                sshpass -e \
                ssh \
                    $SSH_OPTS \
                    -n \
                    "$SSH_USER@$vm_name" \
                    'printf "%s\n" "$(hostname -s)"; hostname -I' \
                    2>"$err_file"
        ); then
            rc=0
        else
            rc=$?
        fi

        err="$(cat "$err_file" 2>/dev/null)"
        rm -f "$err_file"

        if [[ "$rc" -eq 0 ]]; then
            SSH_RESULT_OUT="$out"
            SSH_RESULT_RC=0
            SSH_RESULT_ERR=""
            return 0
        fi

        # Erreurs transitoires -> retry ; erreurs définitives -> sortie immédiate
        if [[ "$rc" -eq 124 || "$err" == *"Connection timed out"* || "$err" == *"Connection closed"* || "$err" == *"No route to host"* ]]; then
            if [[ "$attempt" -le "$SSH_RETRIES" ]]; then
                sleep "$SSH_RETRY_DELAY"
                continue
            fi
        fi

        SSH_RESULT_OUT=""
        SSH_RESULT_RC="$rc"
        SSH_RESULT_ERR="$err"
        return 1
    done
}

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
    ### SSH exclusion check
    ########################################################################

    if ssh_is_excluded "$VM_NAME"; then

        printf 'vm_dns_mismatch_hostname{vm="%s",ip="%s",ssh_error="excluded"} 4\n' \
            "$VM_NAME" "$VM_IP"

        printf 'vm_dns_mismatch_reverse{vm="%s",ip="%s",ptr="%s"} %d\n' \
            "$VM_NAME" "$VM_IP" "${PTR:-none}" "$REVERSE_STATUS"

        printf 'vm_dns_mismatch_ip{vm="%s",dns_ip="%s",guest_ip="unknown",ssh_error="excluded"} 4\n' \
            "$VM_NAME" "$VM_IP"

        return 0
    fi

    ########################################################################
    ### SSH: single connection -> hostname + IPs, with retry + error classification
    ########################################################################

    if ssh_collect_info "$VM_NAME"; then

        SSH_OUTPUT="$SSH_RESULT_OUT"
        HOST_INSIDE="${SSH_OUTPUT%%$'\n'*}"
        IPS_INSIDE="${SSH_OUTPUT#*$'\n'}"

        if [[ "$HOST_INSIDE" == "$VM_NAME" ]]; then
            HOSTNAME_STATUS=0
        else
            HOSTNAME_STATUS=1
        fi

        IP_STATUS=1

        for IP in $IPS_INSIDE; do

            # Filtre les plages internes/non routables connues et l'IPv6
            # (hostname -I peut renvoyer les deux, on ne compare qu'en IPv4 publique/privée pertinente)
            [[ "$IP" == 172.* ]] && continue
            [[ "$IP" == *:* ]] && continue

            if [[ "$IP" == "$VM_IP" ]]; then
                IP_STATUS=0
                MATCHED_IP="$IP"
                break
            fi

        done

        if [[ -z "$MATCHED_IP" ]]; then
            MATCHED_IP="$(awk '{for (i=1;i<=NF;i++) if ($i !~ /:/) {print $i; exit}}' <<< "$IPS_INSIDE")"
        fi
        SSH_REASON="ok"

    else

        HOSTNAME_STATUS=3
        IP_STATUS=3
        SSH_RC="$SSH_RESULT_RC"
        SSH_ERR="$SSH_RESULT_ERR"

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
export SSHPASS
export SSH_OPTS
export SSH_TIMEOUT
export SSH_RETRIES
export SSH_RETRY_DELAY
export DNS_DOMAIN
export DNS_MAP_FILE
export TMP_DIR
export SSH_EXCLUDE_REGEX
export SSH_EXCLUDE_ENABLED
export MAX_JOBS

export -f check_vm
export -f ssh_is_excluded
export -f ssh_collect_info

############################################################################
### Step 6: Continuous parallel execution (with global safety timeout)
############################################################################

GLOBAL_TIMEOUT="${GLOBAL_TIMEOUT:-1800}"  # 30 min par défaut, garde-fou anti-script qui traîne

set +e
timeout "$GLOBAL_TIMEOUT" xargs \
    -0 \
    -r \
    -n 1 \
    -P "$MAX_JOBS" \
    bash -c '
        source "$DNS_MAP_FILE"
        check_vm "$1"
    ' _ < <(printf '%s\0' "${VM_ARRAY[@]}")
RC=$?
set -e

if [[ "$RC" -eq 124 ]]; then
    echo "ERROR: script exceeded GLOBAL_TIMEOUT (${GLOBAL_TIMEOUT}s), some VMs may not have been checked" >&2
    exit 1
fi

exit 0