#!/usr/bin/env bash
#
# dns_mismatch.sh
#
# Ensure that vm_name inside vcenter == dns name == vm hostname == ip PTR
# Ensure that dns_name_ip == vm_ip
#
# Get secrets from vault, support include / exclude regex to filter vcenter objects
# Crontab exemple:
# */5 * * * * . /opt/secrets.sh; MAX_JOBS=20 DNS_DOMAIN="infra.toto.fr" DNS_SERVER="10.1.2.3" /opt/prometheus_textfile_exporters/dns_mismatch.sh | sponge /var/lib/node_exporter/dns_mismatch.prom
#
### How it works
# GET vm name inside vcenter
# GET IP from dns and name from reverse
# GET hostname and ip by ssh 
# COMPARE VM_NAME with Hostname
# COMPARE IP from dns with ip inside vm
# COMPARE reverse dns ip with hostname

############################################################################
### Defaults
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

### Env variable with default values
MAX_JOBS=${MAX_JOBS:-20}   # default parallelism
DNS_SERVER=${DNS_SERVER:-}

DIG_CMD="dig +short"
if [ -n "$DNS_SERVER" ]; then
    DIG_CMD="dig +short @${DNS_SERVER}"
fi

############################################################################
### Pre-checks
if [ -z "$USER" ] ; then USER=$(whoami); fi
if [ "$USER" != "root" ] ; then echo "$(basename "$0") must be run as root!"; exit 2; fi
if [ -z "$VAULT_TOKEN" ]; then echo "ERROR: VAULT_TOKEN is not set, exiting."; exit 1; fi

############################################################################
### VARIABLES
#export HTTP_PROXY=http://proxy.query.consul:80
#export HTTPS_PROXY=http://proxy.query.consul:80
#
#VSPHERE_SECRET_PATH="machines/prod/apps/terraform/vsphere"
#VSPHERE_DATA=$(vault kv get -mount=kv -format=json "$VSPHERE_SECRET_PATH")
#VSPHERE_USER=$(echo "$VSPHERE_DATA" | jq -r '.data.data.vsphere_username')
#VSPHERE_PASS=$(echo "$VSPHERE_DATA" | jq -r '.data.data.vsphere_password')
#VSPHERE_SERVER=$(echo "$VSPHERE_DATA" | jq -r '.data.data.vsphere_server')
#
#SSH_SECRET_PATH="machines/prod/apps/terraform/ssh"
#SSH_DATA=$(vault kv get -mount=kv -format=json "$SSH_SECRET_PATH")
#SSH_USER="app-ansible"
#SSH_USER_PASSWORD=$(echo "$SSH_DATA" | jq -r '.data.data.ssh_password')
#
#DNS_DOMAIN=${DNS_DOMAIN:-}
#SSH_OPTS="-o BatchMode=no -o ConnectTimeout=60 -o StrictHostKeyChecking=no"
#INCLUDE_LIST=('^vm-')
#EXCLUDE_LIST=('vm-talos.*') 

############################################################################
### Step 1: Authenticate to vSphere API
SESSION=$(curl --noproxy '*' -s -k -X POST \
  -u "${VSPHERE_USER}:${VSPHERE_PASS}" \
  "https://${VSPHERE_SERVER}/rest/com/vmware/cis/session" \
  | jq -r '.value')

if [[ -z "$SESSION" || "$SESSION" == "null" ]]; then
  echo "Failed to authenticate to vSphere API" >&2
  exit 1
fi

############################################################################
### Step 2: Get list of VMs
EXCLUDE_REGEX=$(IFS="|"; echo "${EXCLUDE_LIST[*]}")
INCLUDE_REGEX=$(IFS="|"; echo "${INCLUDE_LIST[*]}")

VM_LIST=$(curl --noproxy '*' -s -k -X GET \
  -H "vmware-api-session-id: ${SESSION}" \
  "https://${VSPHERE_SERVER}/rest/vcenter/vm" \
  | jq -c --arg exclude_regex "$EXCLUDE_REGEX" --arg include_regex "$INCLUDE_REGEX" '
      .value[]
      | select(.power_state=="POWERED_ON")
      | select(.name | test($include_regex))
      | select(.name | test($exclude_regex) | not)
  ')

if [ -z "$VM_LIST" ]; then
    echo "No vm returned" >&2
    exit 1
fi

############################################################################
### Step 3: Test SSH connections in parallel
echo "# HELP vm_dns_mismatch_hostname compare dns with Hostname inside VM: 0=ok, 1=mismatch, 2=missing dns, 3=no ssh"
echo "# TYPE vm_dns_mismatch_hostname gauge"
echo "# HELP vm_dns_mismatch_reverse Reverse DNS check: 0=ok, 1=missing, 2=mismatch"
echo "# TYPE vm_dns_mismatch_reverse gauge"
echo "# HELP vm_dns_mismatch_ip compare ip dns with IP inside VM: 0=ok, 1=mismatch, 3=no ssh"
echo "# TYPE vm_dns_mismatch_ip gauge"

check_vm() {
    local vm_json="$1"
    local VM_NAME VM_IP HOST_INSIDE IPS_INSIDE PTR TMPFILE

    VM_NAME=$(echo "$vm_json" | jq -r '.name // empty')
    TMPFILE=$(mktemp -t dnsmismatch.XXXXXXXX) || TMPFILE="/tmp/dnsmismatch.$$.$RANDOM"

    if [ -z "$VM_NAME" ]; then
        echo" Missing vm_name value" >&2
        return
    fi

    VM_IP=$($DIG_CMD A "${VM_NAME}.${DNS_DOMAIN}" | head -n1 || echo "")

    ### no ip = vm_name doesnt have a dns+domain resolution
    if [ -z "$VM_IP" ]; then
        echo "vm_dns_mismatch_hostname{vm=\"$VM_NAME\"} 2" > "$TMPFILE"
        cat "$TMPFILE"; rm -f "$TMPFILE"
        return
    fi

    # Reverse DNS
    PTR=$($DIG_CMD -x "$VM_IP" | sed 's/\.$//')
    if [ -z "$PTR" ]; then
        echo "vm_dns_mismatch_reverse{vm=\"$VM_NAME\"} 1" >> "$TMPFILE"
    elif [ "$PTR" = "${VM_NAME}.${DNS_DOMAIN}" ]; then
        echo "vm_dns_mismatch_reverse{vm=\"$VM_NAME\"} 0" >> "$TMPFILE"
    else
        echo "vm_dns_mismatch_reverse{vm=\"$VM_NAME\"} 2" >> "$TMPFILE"
    fi

    # SSH-dependent metrics
    if ! timeout 60 sshpass -p "$SSH_USER_PASSWORD" ssh $SSH_OPTS -n "$SSH_USER@$VM_NAME" "exit" 2>/dev/null; then
        echo "vm_dns_mismatch_hostname{vm=\"$VM_NAME\"} 3" >> "$TMPFILE"
        echo "vm_dns_mismatch_ip{vm=\"$VM_NAME\"} 3" >> "$TMPFILE"
        cat "$TMPFILE"; rm -f "$TMPFILE"
        return
    fi

    HOST_INSIDE=$(timeout 30 sshpass -p "$SSH_USER_PASSWORD" ssh $SSH_OPTS -n "$SSH_USER@$VM_NAME" "hostname -s" 2>/dev/null || echo "unknown")
    IPS_INSIDE=$(timeout 30 sshpass -p "$SSH_USER_PASSWORD" ssh $SSH_OPTS -n "$SSH_USER@$VM_NAME" "hostname -I" 2>/dev/null | tr ' ' '\n' | grep -v '^172\.' | xargs)

    if [ "$HOST_INSIDE" = "$VM_NAME" ]; then
        echo "vm_dns_mismatch_hostname{vm=\"$VM_NAME\"} 0" >> "$TMPFILE"
    else
        echo "vm_dns_mismatch_hostname{vm=\"$VM_NAME\"} 1" >> "$TMPFILE"
    fi

    if echo "$IPS_INSIDE" | grep -qw "$VM_IP"; then
        echo "vm_dns_mismatch_ip{vm=\"$VM_NAME\"} 0" >> "$TMPFILE"
    else
        echo "vm_dns_mismatch_ip{vm=\"$VM_NAME\"} 1" >> "$TMPFILE"
    fi

    cat "$TMPFILE"
    rm -f "$TMPFILE"
}

limit_jobs() {
    local current_jobs
    while :; do
        current_jobs=$(jobs -rp | wc -l)
        (( current_jobs < MAX_JOBS )) && break
        sleep 0.1
    done
}

# Launch checks
readarray -t VM_ARRAY <<<"$VM_LIST"
for vm in "${VM_ARRAY[@]}"; do
    local_vm_name=$(echo "$vm" | jq -r '.name // empty')
    limit_jobs
    check_vm "$vm" &
done
wait

