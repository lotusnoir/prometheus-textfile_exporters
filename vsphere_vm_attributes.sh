#!/usr/bin/env bash
#===============================================================================
#         FILE:  vsphere_vm_attributes.sh
#
#        USAGE:  ./vsphere_vm_attributes.sh
#
#  DESCRIPTION: Extract VM attributes and tags from vSphere and emit Prometheus
#               metrics to stdout for node_exporter textfile collector.
#
#  REQUIREMENTS: bash 4+, curl, jq, (optionally Vault if USE_VAULT=true)
#       AUTHOR: Philippe
#      VERSION: 3.1
#===============================================================================

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRAPE_ERROR=0

# ------------------------------------------------------------------------------
# Configurable variables
# ------------------------------------------------------------------------------

METRIC_NAME="${METRIC_NAME:-vsphere_vm_attributes}"

USE_VAULT="${USE_VAULT:-false}"

VSPHERE_SECRET_PATH="${VSPHERE_SECRET_PATH:-machines/prod/apps/terraform/vsphere}"
VSPHERE_KEY_SERVER="${VSPHERE_KEY_SERVER:-vsphere_server}"
VSPHERE_KEY_USER="${VSPHERE_KEY_USER:-vsphere_username}"
VSPHERE_KEY_PASS="${VSPHERE_KEY_PASS:-vsphere_password}"

VSPHERE_SERVER="${VSPHERE_SERVER:-}"
VSPHERE_USER="${VSPHERE_USER:-}"
VSPHERE_PASS="${VSPHERE_PASS:-}"

VSPHERE_URL=""
VSPHERE_TEMPFILE_COOKIE="${VSPHERE_TEMPFILE_COOKIE:-/tmp/vsphere_vm_attributes.cookie}"

INCLUDE_LIST=(${INCLUDE_LIST[@]:-("^vm-")})
EXCLUDE_LIST=(${EXCLUDE_LIST[@]:-("vm-talos.*")})
MANDATORY_KEYS=(${MANDATORY_KEYS[@]:-"site" "os" "env" "vlan" "scope"})

# Number of parallel vSphere API requests
MAX_JOBS="${MAX_JOBS:-20}"

# ------------------------------------------------------------------------------
# Proxy configuration
# ------------------------------------------------------------------------------

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

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------

cleanup() {
    rm -f "${VSPHERE_TEMPFILE_COOKIE:-}"
}

trap cleanup EXIT

# ------------------------------------------------------------------------------
# Fatal
# ------------------------------------------------------------------------------

fatal() {
    echo "ERROR: $*" >&2
    SCRAPE_ERROR=1
    exit 1
}

# ------------------------------------------------------------------------------
# Load vSphere credentials
# ------------------------------------------------------------------------------

load_vsphere_credentials() {

    if [[ "$USE_VAULT" == "true" ]]; then

        if ! command -v vault &>/dev/null; then
            fatal "Vault CLI is not installed but USE_VAULT=true"
        fi

        VSPHERE_DATA="$(
            vault kv get \
                -mount=kv \
                -format=json \
                "$VSPHERE_SECRET_PATH"
        )" || fatal "Vault path not found: $VSPHERE_SECRET_PATH"

        readarray -t VSPHERE_CREDENTIALS < <(
            jq -er \
                --arg server "$VSPHERE_KEY_SERVER" \
                --arg user "$VSPHERE_KEY_USER" \
                --arg pass "$VSPHERE_KEY_PASS" \
                '.data.data[$server],
                 .data.data[$user],
                 .data.data[$pass]' <<< "$VSPHERE_DATA"
        ) || fatal "Missing vSphere credentials in Vault"

        VSPHERE_SERVER="${VSPHERE_CREDENTIALS[0]}"
        VSPHERE_USER="${VSPHERE_CREDENTIALS[1]}"
        VSPHERE_PASS="${VSPHERE_CREDENTIALS[2]}"

    else

        [[ -n "$VSPHERE_SERVER" ]] ||
            fatal "VSPHERE_SERVER missing and USE_VAULT=false"

        [[ -n "$VSPHERE_USER" ]] ||
            fatal "VSPHERE_USER missing and USE_VAULT=false"

        [[ -n "$VSPHERE_PASS" ]] ||
            fatal "VSPHERE_PASS missing and USE_VAULT=false"

    fi

    VSPHERE_URL="https://${VSPHERE_SERVER}"
}

# ------------------------------------------------------------------------------
# Get vSphere session
# ------------------------------------------------------------------------------

vsphere_get_ticket() {

    VSPHERE_TEMPFILE_COOKIE="$(mktemp)"

    curl "${CURL_ARGS[@]}" \
        -u "${VSPHERE_USER}:${VSPHERE_PASS}" \
        -X POST \
        -c "$VSPHERE_TEMPFILE_COOKIE" \
        "${VSPHERE_URL}/rest/com/vmware/cis/session" \
        >/dev/null
}

# ------------------------------------------------------------------------------
# Limit parallel jobs
# ------------------------------------------------------------------------------

wait_for_slot() {

    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do
        sleep 0.02
    done
}

# ------------------------------------------------------------------------------
# List tag categories
# ------------------------------------------------------------------------------

vsphere_list_tags_category() {

    curl "${CURL_ARGS[@]}" \
        -b "$VSPHERE_TEMPFILE_COOKIE" \
        "${VSPHERE_URL}/api/cis/tagging/category" |
        jq -r '
            if type=="object" and has("value")
            then .value
            else .
            end
            | .[]
        '
}

# ------------------------------------------------------------------------------
# Get category information
#
# Output:
# category_id<TAB>category_name
# ------------------------------------------------------------------------------

get_category_info() {

    local category_id="$1"
    local response

    response="$(
        curl "${CURL_ARGS[@]}" \
            -b "$VSPHERE_TEMPFILE_COOKIE" \
            "${VSPHERE_URL}/api/cis/tagging/category/${category_id}"
    )"

    jq -r --arg id "$category_id" \
        '[$id, .name] | @tsv' <<< "$response"
}

# ------------------------------------------------------------------------------
# List tags
# ------------------------------------------------------------------------------

vsphere_list_tags() {

    curl "${CURL_ARGS[@]}" \
        -b "$VSPHERE_TEMPFILE_COOKIE" \
        "${VSPHERE_URL}/api/cis/tagging/tag" |
        jq -r '
            if type=="object" and has("value")
            then .value
            else .
            end
            | .[]
        '
}

# ------------------------------------------------------------------------------
# Get tag information
#
# Output:
# tag_id<TAB>category_id<TAB>tag_name
# ------------------------------------------------------------------------------

get_tag_info() {

    local tag_id="$1"
    local response

    response="$(
        curl "${CURL_ARGS[@]}" \
            -b "$VSPHERE_TEMPFILE_COOKIE" \
            "${VSPHERE_URL}/api/cis/tagging/tag/${tag_id}"
    )"

    jq -r --arg id "$tag_id" '
        [$id, .category_id, .name] | @tsv
    ' <<< "$response"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

vsphere_generate_prometheus_metrics() {

    load_vsphere_credentials
    vsphere_get_ticket

    echo "# HELP $METRIC_NAME Extract attributes from vSphere 0=empty mandatory, 1=found_attribute, 2=no tags at all"
    echo "# TYPE $METRIC_NAME gauge"

    EXCLUDE_REGEX=$(IFS="|"; echo "${EXCLUDE_LIST[*]}")
    INCLUDE_REGEX=$(IFS="|"; echo "${INCLUDE_LIST[*]}")

    # ==========================================================================
    # Get VMs
    # ==========================================================================

    declare -A vm_names

    while IFS=$'\t' read -r vm_id hostname; do

        [[ -n "$vm_id" ]] || continue

        vm_names["$vm_id"]="$hostname"

    done < <(
        curl "${CURL_ARGS[@]}" \
            -b "$VSPHERE_TEMPFILE_COOKIE" \
            "${VSPHERE_URL}/rest/vcenter/vm" |
        jq -r \
            --arg exclude_regex "$EXCLUDE_REGEX" \
            --arg include_regex "$INCLUDE_REGEX" '
                if type=="object" and has("value")
                then .value
                else .
                end
                | .[]
                | select(.power_state=="POWERED_ON")
                | select(.name | test($include_regex))
                | select(.name | test($exclude_regex) | not)
                | [.vm, .name]
                | @tsv
            '
    )

    # ==========================================================================
    # Get tag categories
    # ==========================================================================

    mapfile -t tag_cat_ids < <(
        vsphere_list_tags_category
    )

    declare -A tag_categories

    category_tmpdir="$(mktemp -d)"

    for cat_id in "${tag_cat_ids[@]}"; do

        wait_for_slot

        (
            get_category_info "$cat_id" \
                > "${category_tmpdir}/${cat_id}"
        ) &

    done

    wait

    while IFS=$'\t' read -r cat_id cat_name; do

        [[ -n "$cat_id" ]] || continue

        tag_categories["$cat_id"]="$cat_name"

    done < <(
        cat "${category_tmpdir}"/* 2>/dev/null || true
    )

    rm -rf "$category_tmpdir"

    # ==========================================================================
    # Get tags
    # ==========================================================================

    mapfile -t tag_ids < <(
        vsphere_list_tags
    )

    declare -A tag_category_map
    declare -A base_tag_names

    tag_tmpdir="$(mktemp -d)"

    for tag_id in "${tag_ids[@]}"; do

        wait_for_slot

        (
            get_tag_info "$tag_id" \
                > "${tag_tmpdir}/${tag_id}"
        ) &

    done

    wait

    while IFS=$'\t' read -r tag_id cat_id tag_name; do

        [[ -n "$tag_id" ]] || continue

        cat_name="${tag_categories[$cat_id]:-}"

        # IMPORTANT:
        # Keep the original script semantics:
        # key = category name
        # value = tag name
        tag_category_map["$tag_id"]="$cat_name"
        base_tag_names["$tag_id"]="$tag_name"

    done < <(
        cat "${tag_tmpdir}"/* 2>/dev/null || true
    )

    rm -rf "$tag_tmpdir"

    # ==========================================================================
    # Get all VM/tag associations
    #
    # Parse the complete association list ONCE.
    # The original script reparsed it once per VM.
    # ==========================================================================

    declare -A vm_tag_ids

    while IFS=$'\t' read -r vm_id tag_id; do

        [[ -n "$vm_id" ]] || continue
        [[ -n "$tag_id" ]] || continue

        if [[ -n "${vm_tag_ids[$vm_id]:-}" ]]; then
            vm_tag_ids["$vm_id"]+=$'\n'"$tag_id"
        else
            vm_tag_ids["$vm_id"]="$tag_id"
        fi

    done < <(
        curl "${CURL_ARGS[@]}" \
            -b "$VSPHERE_TEMPFILE_COOKIE" \
            "${VSPHERE_URL}/api/vcenter/tagging/associations" |
        jq -r '
            .associations[]
            | [.object.id, .tag]
            | @tsv
        '
    )

    # ==========================================================================
    # Generate Prometheus metrics
    # ==========================================================================

    for vm_id in "${!vm_names[@]}"; do

        hostname="${vm_names[$vm_id]}"
        declare -A vm_tag_map=()

        tag_list="${vm_tag_ids[$vm_id]:-}"

        # ----------------------------------------------------------------------
        # No tags
        # ----------------------------------------------------------------------

        if [[ -z "$tag_list" ]]; then

            echo "$METRIC_NAME{vmid=\"$vm_id\",hostname=\"$hostname\"} 2"

            continue
        fi

        # ----------------------------------------------------------------------
        # Tags
        # ----------------------------------------------------------------------

        while IFS= read -r tag_id; do

            [[ -n "$tag_id" ]] || continue

            key="${tag_category_map[$tag_id]:-}"
            value="${base_tag_names[$tag_id]:-}"

            [[ -n "$key" ]] || continue

            vm_tag_map["$key"]="$value"

            echo "$METRIC_NAME{vmid=\"$vm_id\",hostname=\"$hostname\",key=\"$key\",value=\"$value\",ansible_tag=\"${key}_${value}\"} 1"

        done <<< "$tag_list"

        # ----------------------------------------------------------------------
        # Mandatory keys
        # ----------------------------------------------------------------------

        for k in "${MANDATORY_KEYS[@]}"; do

            if [[ -z "${vm_tag_map[$k]:-}" ]]; then

                echo "$METRIC_NAME{vmid=\"$vm_id\",hostname=\"$hostname\",key=\"$k\",value=\"empty\",ansible_tag=\"empty\"} 0"

            fi

        done
    done

    # ==========================================================================
    # Scrape error
    # ==========================================================================

    echo "# HELP ${METRIC_NAME}_scrape_error 1 if an error occurred during parsing"
    echo "# TYPE ${METRIC_NAME}_scrape_error gauge"
    echo "${METRIC_NAME}_scrape_error $SCRAPE_ERROR"
}

# ------------------------------------------------------------------------------
# Start
# ------------------------------------------------------------------------------

vsphere_generate_prometheus_metrics
