#!/usr/bin/env bash
#===============================================================================
#         FILE:  vm_consul_node_meta.sh
#
#        USAGE:  ./vm_consul_node_meta.sh
#
#  DESCRIPTION:  Export Consul node_meta config (scope, vlan, severity, os, env, site, groups, apps)
#                as Prometheus metrics for node_exporter textfile collector.
#                groups and apps are optional; others always emit a metric.
#                Output is sorted alphabetically by key and ansible_tag.
#                Labels: key, value, ansible_tag
#                Both value and ansible_tag are sanitized for Prometheus.
#
#  REQUIREMENTS: awk, bash 4+, consul config file, sort
#       AUTHOR:  Philippe
#      VERSION: 2.1
#      CREATED: 2025-10-02
#===============================================================================

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/opt/consul.d/consul.hcl}"

SCRAPE_ERROR=0
METRIC_NAME="vm_consul_node_meta"

#===============================================================================
# Functions
#===============================================================================
sanitize() {
    local s="$1"
    local result=""
    local i
    local c
    local previous_invalid=0

    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"

        if [[ "$c" =~ [a-zA-Z0-9] ]]; then
            result+="$c"
            previous_invalid=0
        elif (( previous_invalid == 0 )); then
            result+="_"
            previous_invalid=1
        fi
    done

    printf '%s' "$result"
}

trim() {
    local s="$1"

    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"

    printf '%s' "$s"
}

#===============================================================================
# Prometheus headers
#===============================================================================

echo "# HELP $METRIC_NAME Consul node_meta exposed as $METRIC_NAME"
echo "# TYPE $METRIC_NAME gauge"

#===============================================================================
# Check configuration file
#===============================================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "${METRIC_NAME}_scrape_error 1"
    exit 0
fi

#===============================================================================
# Extract node_meta block
#===============================================================================

mapfile -t NODE_META < <(
    awk '/node_meta \{/,/^\}/' "$CONFIG_FILE"
)

declare -A found=(
    ["scope"]=0
    ["vlan"]=0
    ["severity"]=0
    ["os"]=0
    ["env"]=0
    ["site"]=0
    ["groups"]=0
    ["apps"]=0
)

metrics=()

#===============================================================================
# Parse node_meta
#===============================================================================

for line in "${NODE_META[@]}"; do

    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*$ ]] && continue

    if [[ "$line" =~ ([[:alnum:]_]+)[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then

        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"

        found[$key]=1

        case "$key" in

            vlan|scope|severity|os|env|site)
                sanitized_value=$(sanitize "$value")
                sanitized_tag="${key}_${sanitized_value}"

                metrics+=(
                    "vm_consul_node_meta{key=\"$key\",value=\"$sanitized_value\",ansible_tag=\"$sanitized_tag\"} 1"
                )
                ;;

            groups)
                if [[ -n "$value" ]]; then
                    IFS=',' read -ra groups_arr <<< "$value"

                    for g in "${groups_arr[@]}"; do
                        g_trimmed=$(trim "$g")

                        [[ -n "$g_trimmed" ]] || continue

                        sanitized_value=$(sanitize "$g_trimmed")
                        sanitized_tag="groups_${sanitized_value}"

                        metrics+=(
                            "vm_consul_node_meta{key=\"groups\",value=\"$sanitized_value\",ansible_tag=\"$sanitized_tag\"} 1"
                        )
                    done
                fi
                ;;

            apps)
                if [[ -n "$value" ]]; then
                    IFS=',' read -ra apps_arr <<< "$value"

                    for a in "${apps_arr[@]}"; do
                        a_trimmed=$(trim "$a")

                        [[ -n "$a_trimmed" ]] || continue

                        sanitized_value=$(sanitize "$a_trimmed")
                        sanitized_tag="apps_${sanitized_value}"

                        metrics+=(
                            "vm_consul_node_meta{key=\"apps\",value=\"$sanitized_value\",ansible_tag=\"$sanitized_tag\"} 1"
                        )
                    done
                fi
                ;;

            *)
                ;;
        esac
    fi
done

#===============================================================================
# Add empty metrics for mandatory types
#===============================================================================

for k in scope vlan severity os env site; do
    if [[ "${found[$k]}" -eq 0 ]]; then
        metrics+=(
            "vm_consul_node_meta{key=\"$k\",value=\"empty\",ansible_tag=\"empty\"} 0"
        )
    fi
done

#===============================================================================
# Sort and output metrics
#===============================================================================

printf '%s\n' "${metrics[@]}" | sort

#===============================================================================
# Scrape error metric
#===============================================================================

echo "# HELP ${METRIC_NAME}_scrape_error 1 if an error occurred during parsing"
echo "# TYPE ${METRIC_NAME}_scrape_error gauge"
echo "${METRIC_NAME}_scrape_error $SCRAPE_ERROR"

exit 0
