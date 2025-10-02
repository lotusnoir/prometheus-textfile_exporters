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
#      VERSION: 2.0
#      CREATED: 2025-10-02
#===============================================================================

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/opt/consul.d/consul.hcl}"

SCRAPE_ERROR=0

# Function to sanitize a string for Prometheus label
sanitize() {
    local s="$1"
    echo "$s" | sed -E 's#[^a-zA-Z0-9]+#_#g'
}

# Prometheus headers
{
    echo "# HELP vm_consul_node_meta Consul node_meta exposed as vm_consul_node_meta"
    echo "# TYPE vm_consul_node_meta gauge"
} 

# If file missing, mark scrape error and exit clean
if [ ! -f "$CONFIG_FILE" ]; then
    echo 'vm_consul_node_meta_scrape_error 1'
    exit 0
fi

# Extract node_meta block
mapfile -t NODE_META < <(awk '/node_meta \{/,/^\}/' "$CONFIG_FILE")

declare -A found=( ["scope"]=0 ["vlan"]=0 ["severity"]=0 ["os"]=0 ["env"]=0 ["site"]=0 ["groups"]=0 ["apps"]=0 )

metrics=()

for line in "${NODE_META[@]}"; do
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*\}[[:space:]]*$ ]] && continue

    if [[ "$line" =~ ([[:alnum:]_]+)[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        found[$key]=1

        sanitized_value=$(sanitize "$value")
        sanitized_tag=$(sanitize "${key}_${value}")

        case "$key" in
            vlan|scope|severity|os|env|site)
                metrics+=("vm_consul_node_meta{key=\"$key\",value=\"$sanitized_value\",ansible_tag=\"$sanitized_tag\"} 1")
                ;;
            groups)
                if [[ -n "$value" ]]; then
                    IFS=',' read -ra groups_arr <<< "$value"
                    for g in "${groups_arr[@]}"; do
                        g_trimmed=$(echo "$g" | xargs)
                        [[ -n "$g_trimmed" ]] && metrics+=("vm_consul_node_meta{key=\"groups\",value=\"$(sanitize "$g_trimmed")\",ansible_tag=\"$(sanitize groups_$g_trimmed)\"} 1")
                    done
                fi
                ;;
            apps)
                if [[ -n "$value" ]]; then
                    IFS=',' read -ra apps_arr <<< "$value"
                    for a in "${apps_arr[@]}"; do
                        a_trimmed=$(echo "$a" | xargs)
                        [[ -n "$a_trimmed" ]] && metrics+=("vm_consul_node_meta{key=\"apps\",value=\"$(sanitize "$a_trimmed")\",ansible_tag=\"$(sanitize apps_$a_trimmed)\"} 1")
                    done
                fi
                ;;
            *)
                ;;
        esac
    fi
done

# Add empty metrics for mandatory types
for k in scope vlan severity os env site; do
    if [ "${found[$k]}" -eq 0 ]; then
        metrics+=("vm_consul_node_meta{key=\"$k\",value=\"empty\",ansible_tag=\"empty\"} 0")
    fi
done

# Sort metrics alphabetically by key and ansible_tag and print
printf "%s\n" "${metrics[@]}" | sort

# Always emit scrape error metric at the end
echo "# HELP vm_consul_node_meta_scrape_error 1 if an error occurred during parsing"
echo "# TYPE vm_consul_node_meta_scrape_error gauge"
echo "vm_consul_node_meta_scrape_error $SCRAPE_ERROR"

exit 0
