#!/usr/bin/env bash
#===============================================================================
#         FILE:  vsphere_vm_attributes.sh
#
#        USAGE:  ./vsphere_vm_attributes.sh
#
#  DESCRIPTION:
#                Extracts vSphere tags attached to powered-on VMs and emits
#                Prometheus textfile metrics reporting, for each mandatory
#                tag category, whether the VM is correctly tagged:
#
#                  vsphere_vm_attributes{vmid,hostname,key,value,ansible_tag}
#                      0 = mandatory key missing on this VM (value="empty")
#                      1 = tag found for this key on this VM
#                      2 = VM has NO tag at all (any category)
#
#                  vsphere_vm_attributes_scrape_error
#                      0 = scrape completed without error
#                      1 = at least one API call failed (metrics may be
#                          partial/stale, do not trust this scrape blindly)
#
#  REQUIREMENTS: bash 4+, curl, jq, mktemp, base64
#                (optionally: Vault CLI if USE_VAULT=true)
#
#    ARGUMENTS:  None (all configuration is via environment variables below).
#
#  ENVIRONMENT:
#                --- vCenter connection ---
#                USE_VAULT             true/false - fetch credentials from
#                                      Vault instead of VSPHERE_* env vars
#                                      (default: false)
#                VSPHERE_SECRET_PATH   Vault KV path for vCenter creds
#                                      (default: machines/prod/apps/terraform/vsphere)
#                VSPHERE_KEY_SERVER    Key name for server in Vault payload
#                                      (default: vsphere_server)
#                VSPHERE_KEY_USER      Key name for user in Vault payload
#                                      (default: vsphere_username)
#                VSPHERE_KEY_PASS      Key name for password in Vault payload
#                                      (default: vsphere_password)
#                VSPHERE_SERVER        vCenter FQDN/IP (required if USE_VAULT=false)
#                VSPHERE_USER          vCenter username (required if USE_VAULT=false)
#                VSPHERE_PASS          vCenter password (required if USE_VAULT=false)
#
#                --- VM selection filters ---
#                INCLUDE_LIST          Space-separated ERE patterns; a VM name
#                                      must match at least one to be processed
#                                      (default: "^vm-")
#                EXCLUDE_LIST          Space-separated ERE patterns; a VM name
#                                      matching any of these is skipped
#                                      (default: "vm-talos.*")
#                MANDATORY_KEYS        Space-separated list of tag category
#                                      names that every VM must carry
#                                      (default: "site os env vlan scope")
#
#                --- Network / proxy ---
#                USE_PROXY             true/false - route curl through PROXY_URL
#                                      (default: false)
#                PROXY_URL             Proxy URL, required if USE_PROXY=true
#                CURL_MAX_TIME         Per-request curl timeout, seconds
#                                      (default: 30)
#
#                --- Execution control ---
#                MAX_JOBS              Max parallel vSphere API requests
#                                      (default: 20)
#                GLOBAL_TIMEOUT        Hard wall-clock limit for the whole
#                                      script, seconds (default: 900)
#
#                --- Output ---
#                METRIC_NAME           Prometheus metric name prefix
#                                      (default: vsphere_vm_attributes)
#
#  SECURITY NOTE:
#                vCenter credentials are never passed on the curl command
#                line (which would leak them via `ps`). They are written to
#                a chmod 600 curl config file (`-K`), removed on exit.
#
#       AUTHOR:  Philippe LEAL
#      VERSION: 4.0
#      CREATED: 2025-10-02
#    MODIFIED:  2025-11-19
#===============================================================================

set -uo pipefail

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
VSPHERE_SESSION_ID=""
VSPHERE_CURL_CONFIG=""
VSPHERE_TEMPFILE_COOKIE=""

# Arrays cannot be exported in bash: env vars are plain space-separated
# strings and are split here into real arrays.
read -ra INCLUDE_LIST <<< "${INCLUDE_LIST:-^vm-}"
read -ra EXCLUDE_LIST <<< "${EXCLUDE_LIST:-vm-talos.*}"
read -ra MANDATORY_KEYS <<< "${MANDATORY_KEYS:-site os env vlan scope}"

MAX_JOBS="${MAX_JOBS:-20}"
GLOBAL_TIMEOUT="${GLOBAL_TIMEOUT:-900}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"

# ------------------------------------------------------------------------------
# Proxy configuration
# ------------------------------------------------------------------------------

USE_PROXY="${USE_PROXY:-false}"
PROXY_URL="${PROXY_URL:-}"

CURL_ARGS=(-k -s --max-time "$CURL_MAX_TIME")

if [[ "$USE_PROXY" == "true" ]]; then
    [[ -n "$PROXY_URL" ]] || { echo "ERROR: USE_PROXY=true but PROXY_URL is empty" >&2; exit 1; }
    CURL_ARGS+=(--proxy "$PROXY_URL")
else
    CURL_ARGS+=(--noproxy "*")
fi

# ------------------------------------------------------------------------------
# Dependencies check
# ------------------------------------------------------------------------------

for bin in curl jq mktemp base64; do
    command -v "$bin" &>/dev/null || { echo "ERROR: required binary not found: $bin" >&2; exit 1; }
done

# ------------------------------------------------------------------------------
# Cleanup (also closes the vSphere session if one was opened)
# ------------------------------------------------------------------------------

cleanup() {
    if [[ -n "$VSPHERE_SESSION_ID" && -n "$VSPHERE_CURL_CONFIG" ]]; then
        curl "${CURL_ARGS[@]}" \
            -K "$VSPHERE_CURL_CONFIG" \
            -b "$VSPHERE_TEMPFILE_COOKIE" \
            -X DELETE \
            "${VSPHERE_URL}/rest/com/vmware/cis/session" \
            >/dev/null 2>&1 || true
    fi
    rm -f "${VSPHERE_TEMPFILE_COOKIE:-}" "${VSPHERE_CURL_CONFIG:-}"
}

trap cleanup EXIT

# ------------------------------------------------------------------------------
# Fatal: emit a valid (minimal) Prometheus output before exiting, so a
# scrape failure is itself visible as a metric instead of an empty file.
# ------------------------------------------------------------------------------

fatal() {
    echo "ERROR: $*" >&2
    echo "# HELP ${METRIC_NAME}_scrape_error 1 if an error occurred during parsing"
    echo "# TYPE ${METRIC_NAME}_scrape_error gauge"
    echo "${METRIC_NAME}_scrape_error 1"
    exit 1
}

# ------------------------------------------------------------------------------
# Load vSphere credentials
# ------------------------------------------------------------------------------

load_vsphere_credentials() {

    if [[ "$USE_VAULT" == "true" ]]; then

        command -v vault &>/dev/null || fatal "Vault CLI is not installed but USE_VAULT=true"

        local vsphere_data
        vsphere_data="$(
            vault kv get -mount=kv -format=json "$VSPHERE_SECRET_PATH"
        )" || fatal "Vault path not found: $VSPHERE_SECRET_PATH"

        local vsphere_credentials
        readarray -t vsphere_credentials < <(
            jq -er \
                --arg server "$VSPHERE_KEY_SERVER" \
                --arg user "$VSPHERE_KEY_USER" \
                --arg pass "$VSPHERE_KEY_PASS" \
                '.data.data[$server], .data.data[$user], .data.data[$pass]' \
                <<< "$vsphere_data"
        ) || fatal "Missing vSphere credentials in Vault"

        VSPHERE_SERVER="${vsphere_credentials[0]}"
        VSPHERE_USER="${vsphere_credentials[1]}"
        VSPHERE_PASS="${vsphere_credentials[2]}"

    else
        [[ -n "$VSPHERE_SERVER" ]] || fatal "VSPHERE_SERVER missing and USE_VAULT=false"
        [[ -n "$VSPHERE_USER" ]]   || fatal "VSPHERE_USER missing and USE_VAULT=false"
        [[ -n "$VSPHERE_PASS" ]]   || fatal "VSPHERE_PASS missing and USE_VAULT=false"
    fi

    VSPHERE_URL="https://${VSPHERE_SERVER}"

    # Credentials go into a chmod 600 curl config file: never on the
    # command line, so they never appear in `ps`.
    VSPHERE_CURL_CONFIG="$(mktemp)"
    chmod 600 "$VSPHERE_CURL_CONFIG"
    printf 'user = "%s:%s"\n' "$VSPHERE_USER" "$VSPHERE_PASS" > "$VSPHERE_CURL_CONFIG"
}

# ------------------------------------------------------------------------------
# Get vSphere session
# ------------------------------------------------------------------------------

vsphere_get_ticket() {

    VSPHERE_TEMPFILE_COOKIE="$(mktemp)"

    local response
    response="$(
        curl "${CURL_ARGS[@]}" \
            -K "$VSPHERE_CURL_CONFIG" \
            -X POST \
            -c "$VSPHERE_TEMPFILE_COOKIE" \
            "${VSPHERE_URL}/rest/com/vmware/cis/session"
    )" || fatal "Unable to reach vCenter at $VSPHERE_URL"

    VSPHERE_SESSION_ID="$(jq -r '.value // empty' <<< "$response")"
    [[ -n "$VSPHERE_SESSION_ID" ]] || fatal "vSphere authentication failed (check VSPHERE_USER/VSPHERE_PASS)"
}

# ------------------------------------------------------------------------------
# curl wrapper: on failure, flags SCRAPE_ERROR instead of letting an empty/
# broken response silently propagate into the metrics.
# ------------------------------------------------------------------------------

api_get() {
    local url="$1" response

    response="$(
        curl "${CURL_ARGS[@]}" -b "$VSPHERE_TEMPFILE_COOKIE" "$url"
    )"

    if [[ -z "$response" ]] || ! jq -e . >/dev/null 2>&1 <<< "$response"; then
        echo "WARNING: empty/invalid response from $url" >&2
        SCRAPE_ERROR=1
        echo "{}"
        return
    fi

    echo "$response"
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
    api_get "${VSPHERE_URL}/api/cis/tagging/category" |
        jq -r 'if type=="object" and has("value") then .value else . end | .[]'
}

# ------------------------------------------------------------------------------
# Get category information
# Output: category_id<TAB>category_name
# ------------------------------------------------------------------------------

get_category_info() {
    local category_id="$1"
    api_get "${VSPHERE_URL}/api/cis/tagging/category/${category_id}" |
        jq -r --arg id "$category_id" '[$id, (.name // "")] | @tsv'
}

# ------------------------------------------------------------------------------
# List tags
# ------------------------------------------------------------------------------

vsphere_list_tags() {
    api_get "${VSPHERE_URL}/api/cis/tagging/tag" |
        jq -r 'if type=="object" and has("value") then .value else . end | .[]'
}

# ------------------------------------------------------------------------------
# Get tag information
# Output: tag_id<TAB>category_id<TAB>tag_name
# ------------------------------------------------------------------------------

get_tag_info() {
    local tag_id="$1"
    api_get "${VSPHERE_URL}/api/cis/tagging/tag/${tag_id}" |
        jq -r --arg id "$tag_id" '[$id, (.category_id // ""), (.name // "")] | @tsv'
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

vsphere_generate_prometheus_metrics() {

    load_vsphere_credentials
    vsphere_get_ticket

    echo "# HELP $METRIC_NAME vSphere tag attributes per VM. 0=mandatory key missing, 1=tag found, 2=no tag at all"
    echo "# TYPE $METRIC_NAME gauge"

    # An empty ERE matches every string: guard explicitly so an unset/empty
    # EXCLUDE_LIST never excludes all VMs, and an empty INCLUDE_LIST never
    # matches everything by accident either.
    local exclude_regex include_regex
    exclude_regex=$(IFS="|"; echo "${EXCLUDE_LIST[*]}")
    include_regex=$(IFS="|"; echo "${INCLUDE_LIST[*]}")
    [[ -n "$include_regex" ]] || include_regex='^$a'   # matches nothing
    [[ -n "$exclude_regex" ]] || exclude_regex='^$a'   # matches nothing

    # ==========================================================================
    # Get VMs
    # ==========================================================================

    declare -A vm_names

    while IFS=$'\t' read -r vm_id hostname; do
        [[ -n "$vm_id" ]] || continue
        vm_names["$vm_id"]="$hostname"
    done < <(
        api_get "${VSPHERE_URL}/rest/vcenter/vm" |
        jq -r \
            --arg exclude_regex "$exclude_regex" \
            --arg include_regex "$include_regex" '
                if type=="object" and has("value") then .value else . end
                | .[]
                | select(.power_state=="POWERED_ON")
                | select(.name | test($include_regex))
                | select(.name | test($exclude_regex) | not)
                | [.vm, .name]
                | @tsv
            '
    )

    if (( ${#vm_names[@]} == 0 )); then
        echo "WARNING: no VM matched INCLUDE_LIST/EXCLUDE_LIST, check filters" >&2
        SCRAPE_ERROR=1
    fi

    # ==========================================================================
    # Get tag categories
    # ==========================================================================

    mapfile -t tag_cat_ids < <(vsphere_list_tags_category)

    declare -A tag_categories
    category_tmpdir="$(mktemp -d)"

    for cat_id in "${tag_cat_ids[@]}"; do
        wait_for_slot
        ( get_category_info "$cat_id" > "${category_tmpdir}/${cat_id}" ) &
    done
    wait

    while IFS=$'\t' read -r cat_id cat_name; do
        [[ -n "$cat_id" ]] || continue
        tag_categories["$cat_id"]="$cat_name"
    done < <(cat "${category_tmpdir}"/* 2>/dev/null || true)

    rm -rf "$category_tmpdir"

    # ==========================================================================
    # Get tags
    # ==========================================================================

    mapfile -t tag_ids < <(vsphere_list_tags)

    declare -A tag_category_name  # tag_id -> category NAME (not id)
    declare -A base_tag_names     # tag_id -> tag name

    tag_tmpdir="$(mktemp -d)"

    for tag_id in "${tag_ids[@]}"; do
        wait_for_slot
        ( get_tag_info "$tag_id" > "${tag_tmpdir}/${tag_id}" ) &
    done
    wait

    while IFS=$'\t' read -r tag_id cat_id tag_name; do
        [[ -n "$tag_id" ]] || continue
        tag_category_name["$tag_id"]="${tag_categories[$cat_id]:-}"
        base_tag_names["$tag_id"]="$tag_name"
    done < <(cat "${tag_tmpdir}"/* 2>/dev/null || true)

    rm -rf "$tag_tmpdir"

    # ==========================================================================
    # Get all VM/tag associations (parsed once for every VM)
    # ==========================================================================

    declare -A vm_tag_ids

    while IFS=$'\t' read -r vm_id tag_id; do
        [[ -n "$vm_id" && -n "$tag_id" ]] || continue
        if [[ -n "${vm_tag_ids[$vm_id]:-}" ]]; then
            vm_tag_ids["$vm_id"]+=$'\n'"$tag_id"
        else
            vm_tag_ids["$vm_id"]="$tag_id"
        fi
    done < <(
        api_get "${VSPHERE_URL}/api/vcenter/tagging/associations" |
        jq -r '.associations[]? | [.object.id, .tag] | @tsv'
    )

    # ==========================================================================
    # Generate Prometheus metrics
    # ==========================================================================

    for vm_id in "${!vm_names[@]}"; do

        hostname="${vm_names[$vm_id]}"
        declare -A vm_tag_map=()

        tag_list="${vm_tag_ids[$vm_id]:-}"

        if [[ -z "$tag_list" ]]; then
            echo "$METRIC_NAME{vmid=\"$vm_id\",hostname=\"$hostname\"} 2"
            continue
        fi

        while IFS= read -r tag_id; do
            [[ -n "$tag_id" ]] || continue

            key="${tag_category_name[$tag_id]:-}"
            value="${base_tag_names[$tag_id]:-}"

            [[ -n "$key" ]] || continue

            vm_tag_map["$key"]="$value"
            echo "$METRIC_NAME{vmid=\"$vm_id\",hostname=\"$hostname\",key=\"$key\",value=\"$value\",ansible_tag=\"${key}_${value}\"} 1"
        done <<< "$tag_list"

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
# Start (background job in the SAME shell so it keeps every variable/array
# as-is; a watcher kills it if GLOBAL_TIMEOUT is exceeded)
# ------------------------------------------------------------------------------

vsphere_generate_prometheus_metrics &
main_pid=$!

(
    sleep "$GLOBAL_TIMEOUT"
    kill -9 "$main_pid" 2>/dev/null
) >/dev/null 2>&1 &
watcher_pid=$!

if wait "$main_pid"; then
    kill "$watcher_pid" 2>/dev/null
    wait "$watcher_pid" 2>/dev/null
    exit 0
else
    kill "$watcher_pid" 2>/dev/null
    wait "$watcher_pid" 2>/dev/null
    echo "ERROR: script exceeded GLOBAL_TIMEOUT=${GLOBAL_TIMEOUT}s or failed" >&2
    echo "# HELP ${METRIC_NAME}_scrape_error 1 if an error occurred during parsing"
    echo "# TYPE ${METRIC_NAME}_scrape_error gauge"
    echo "${METRIC_NAME}_scrape_error 1"
    exit 1
fi