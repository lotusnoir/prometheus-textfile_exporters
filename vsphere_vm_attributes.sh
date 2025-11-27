#!/usr/bin/env bash
#===============================================================================
#         FILE:  vsphere_vm_attributes.sh
#
#        USAGE:  ./vsphere_vm_attributes.sh
#
#  DESCRIPTION:  Extract VM attributes and tags from vSphere and emit Prometheus metrics
#                to stdout for node_exporter textfile collector.
#
#  REQUIREMENTS: bash 4+, curl, jq, (optionally Vault if USE_VAULT=true)
#       AUTHOR:  Philippe
#      VERSION: 2.10
#      CREATED: 2025-10-02
#===============================================================================

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRAPE_ERROR=0

# --- Configurable Variables ---------------------------------------------------
METRIC_NAME="${METRIC_NAME:-vsphere_vm_attributes}"

# Vault mode: if true, force loading from Vault only
USE_VAULT="${USE_VAULT:-false}"

VSPHERE_SECRET_PATH="${VSPHERE_SECRET_PATH:-machines/prod/apps/terraform/vsphere}"
VSPHERE_KEY_SERVER="${VSPHERE_KEY_SERVER:-vsphere_server}"
VSPHERE_KEY_USER="${VSPHERE_KEY_USER:-vsphere_username}"
VSPHERE_KEY_PASS="${VSPHERE_KEY_PASS:-vsphere_password}"

# Optional manual override (only used if USE_VAULT=false)
VSPHERE_SERVER="${VSPHERE_SERVER:-}"
VSPHERE_USER="${VSPHERE_USER:-}"
VSPHERE_PASS="${VSPHERE_PASS:-}"

VSPHERE_URL=""
VSPHERE_TEMPFILE_COOKIE="${VSPHERE_TEMPFILE_COOKIE:-/tmp/cookie}"

INCLUDE_LIST=(${INCLUDE_LIST[@]:-("^vm-")})
EXCLUDE_LIST=(${EXCLUDE_LIST[@]:-("vm-talos.*")})
MANDATORY_KEYS=(${MANDATORY_KEYS[@]:-"site" "os" "env" "vlan" "scope"})

# --- Proxy configuration ---
USE_PROXY="${USE_PROXY:-false}"
PROXY_URL="${PROXY_URL:-}"
CURL_ARGS=(-k -s)
if [[ "$USE_PROXY" == "true" ]]; then
    if [[ -z "$PROXY_URL" ]]; then
        echo "ERROR: USE_PROXY=true but PROXY_URL is empty" >&2
        exit 1
    fi
    CURL_ARGS+=(--proxy "$PROXY_URL")
else
  CURL_ARGS+=(--noproxy "*")
fi

### Functions ------------------------------------------------------------------
cleanup() { rm -f "${VSPHERE_TEMPFILE_COOKIE:-}"; }
trap cleanup EXIT

fatal() {
    echo "ERROR: $*" >&2
    SCRAPE_ERROR=1
    exit 1
}

load_vsphere_credentials() {
    if [[ "$USE_VAULT" == "true" ]]; then
        if ! command -v vault &>/dev/null; then
            fatal "Vault CLI is not installed but USE_VAULT=true"
        fi

        VSPHERE_DATA=$(vault kv get -mount=kv -format=json "$VSPHERE_SECRET_PATH") \
            || fatal "Vault path not found: $VSPHERE_SECRET_PATH"

        VSPHERE_SERVER="$(echo "$VSPHERE_DATA" | jq -er ".data.data.${VSPHERE_KEY_SERVER}")" \
            || fatal "Missing key '$VSPHERE_KEY_SERVER' in Vault secret"
        VSPHERE_USER="$(echo "$VSPHERE_DATA" | jq -er ".data.data.${VSPHERE_KEY_USER}")" \
            || fatal "Missing key '$VSPHERE_KEY_USER' in Vault secret"
        VSPHERE_PASS="$(echo "$VSPHERE_DATA" | jq -er ".data.data.${VSPHERE_KEY_PASS}")" \
            || fatal "Missing key '$VSPHERE_KEY_PASS' in Vault secret"

    else
        [[ -n "$VSPHERE_SERVER" ]] || fatal "VSPHERE_SERVER missing and USE_VAULT=false"
        [[ -n "$VSPHERE_USER" ]] || fatal "VSPHERE_USER missing and USE_VAULT=false"
        [[ -n "$VSPHERE_PASS" ]] || fatal "VSPHERE_PASS missing and USE_VAULT=false"
    fi

    VSPHERE_URL="https://${VSPHERE_SERVER}"
}

vsphere_get_ticket() {
    VSPHERE_TEMPFILE_COOKIE=$(mktemp)
    curl "${CURL_ARGS[@]}" -u "${VSPHERE_USER}:${VSPHERE_PASS}" -X POST -c "$VSPHERE_TEMPFILE_COOKIE" \
         "${VSPHERE_URL}/rest/com/vmware/cis/session" >/dev/null
}

vsphere_list_tags_category() {
    curl "${CURL_ARGS[@]}" -b "$VSPHERE_TEMPFILE_COOKIE" \
         "${VSPHERE_URL}/api/cis/tagging/category" \
         | jq -r 'if type=="object" and has("value") then .value else . end | .[]'
}

vsphere_list_tags() {
    curl "${CURL_ARGS[@]}" -b "$VSPHERE_TEMPFILE_COOKIE" \
         "${VSPHERE_URL}/api/cis/tagging/tag" \
         | jq -r 'if type=="object" and has("value") then .value else . end | .[]'
}

vsphere_get_tagcategoryname_from_id() {
    local TAG_CAT_ID=$1
    curl "${CURL_ARGS[@]}" -b "$VSPHERE_TEMPFILE_COOKIE" \
         "${VSPHERE_URL}/api/cis/tagging/category/$TAG_CAT_ID" \
         | jq -r '.name'
}

vsphere_generate_prometheus_metrics() {
    load_vsphere_credentials
    vsphere_get_ticket

    {
        echo "# HELP $METRIC_NAME Extract attributes from vSphere 0=empty mandatory, 1=found_attribute, 2=no tags at all"
        echo "# TYPE $METRIC_NAME gauge"
    }

    EXCLUDE_REGEX=$(IFS="|"; echo "${EXCLUDE_LIST[*]}")
    INCLUDE_REGEX=$(IFS="|"; echo "${INCLUDE_LIST[*]}")

    declare -A vm_names
    mapfile -t vm_lines < <(
        curl "${CURL_ARGS[@]}" -b "$VSPHERE_TEMPFILE_COOKIE" "${VSPHERE_URL}/rest/vcenter/vm" \
        | jq -c --arg exclude_regex "$EXCLUDE_REGEX" --arg include_regex "$INCLUDE_REGEX" '
            if type=="object" and has("value") then .value else . end
            | .[]
            | select(.power_state=="POWERED_ON")
            | select(.name | test($include_regex))
            | select(.name | test($exclude_regex) | not)
            | [.vm, .name]
        '
    )
    for line in "${vm_lines[@]}"; do
        vm_id=$(echo "$line" | jq -r '.[0]')
        hostname=$(echo "$line" | jq -r '.[1]')
        vm_names["$vm_id"]="$hostname"
    done

    declare -A tag_categories tags tag_category_map base_tag_names
    mapfile -t tag_cat_ids < <(vsphere_list_tags_category)
    for cat_id in "${tag_cat_ids[@]}"; do
        tag_categories["$cat_id"]="$(vsphere_get_tagcategoryname_from_id "$cat_id")"
    done

    mapfile -t tag_ids < <(vsphere_list_tags)
    for tag_id in "${tag_ids[@]}"; do
        tag_info=$(curl "${CURL_ARGS[@]}" -b "$VSPHERE_TEMPFILE_COOKIE" "${VSPHERE_URL}/api/cis/tagging/tag/$tag_id")
        tag_name=$(echo "$tag_info" | jq -r '.name')
        cat_id=$(echo "$tag_info" | jq -r '.category_id')
        cat_name="${tag_categories[$cat_id]}"
        tag_category_map["$tag_id"]="$cat_name"
        base_tag_names["$tag_id"]="$tag_name"
        if [[ "$cat_name" == "site" ]]; then
            tags["$tag_id"]="$tag_name"
        else
            tags["$tag_id"]="${cat_name}_${tag_name}"
        fi
    done

    all_vm_tags=$(curl "${CURL_ARGS[@]}" -b "$VSPHERE_TEMPFILE_COOKIE" \
                   --url "${VSPHERE_URL}/api/vcenter/tagging/associations" | jq -c '.associations[]')

    for vm_id in "${!vm_names[@]}"; do
        hostname="${vm_names[$vm_id]}"
        declare -A vm_tag_map=()

        mapfile -t vm_tag_ids < <(echo "$all_vm_tags" | jq -r --arg ID "$vm_id" 'select(.object.id==$ID) | .tag')

        if [ ${#vm_tag_ids[@]} -eq 0 ]; then
            echo "$METRIC_NAME{vmid=\"$vm_id\",hostname=\"$hostname\"} 2"
            continue
        fi

        for tag_id in "${vm_tag_ids[@]}"; do
            key="${tag_category_map[$tag_id]}"
            value="${base_tag_names[$tag_id]}"
            vm_tag_map["$key"]="$value"
            echo "$METRIC_NAME{vmid=\"$vm_id\",hostname=\"$hostname\",key=\"$key\",value=\"$value\",ansible_tag=\"${key}_${value}\"} 1"
        done

        for k in "${MANDATORY_KEYS[@]}"; do
            if [ -z "${vm_tag_map[$k]:-}" ]; then
                echo "$METRIC_NAME{vmid=\"$vm_id\",hostname=\"$hostname\",key=\"$k\",value=\"empty\",ansible_tag=\"empty\"} 0"
            fi
        done
    done

    echo "# HELP ${METRIC_NAME}_scrape_error 1 if an error occurred during parsing"
    echo "# TYPE ${METRIC_NAME}_scrape_error gauge"
    echo "${METRIC_NAME}_scrape_error $SCRAPE_ERROR"
}

### START ###
vsphere_generate_prometheus_metrics

