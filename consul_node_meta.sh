#!/bin/bash

# Input file (modify if needed)
CONFIG_FILE="/opt/consul.d/consul.hcl"

# Output file for node_exporter textfile collector
OUTPUT_FILE="/var/lib/node_exporter/consul_meta.prom"

# Clear previous output
> "$OUTPUT_FILE"

# Initialize scope_exists flag
scope_exists=0
vlan_exists=0
severity_exists=0
groups_exists=0
apps_exists=0

# First pass to check if scope exists
while read -r line; do
    if [[ "$line" =~ ^[[:space:]]*scope[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        scope_exists=1
    fi
    if [[ "$line" =~ ^[[:space:]]*vlan[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        vlan_exists=1
    fi
    if [[ "$line" =~ ^[[:space:]]*severity[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        severity_exists=1
    fi
    if [[ "$line" =~ ^[[:space:]]*groups[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        groups_exists=1
    fi
    if [[ "$line" =~ ^[[:space:]]*apps[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        apps_exists=1
    fi
done < <(awk '/node_meta \{/,/^\}/' "$CONFIG_FILE")
# Add empty scope metric if not found
if [ "$scope_exists" -eq 0 ]; then echo 'ansible_inventory_groups{type="scope", tag="empty"} 0' >> "$OUTPUT_FILE"; fi
if [ "$vlan_exists" -eq 0 ]; then echo 'ansible_inventory_groups{type="vlan", tag="empty"} 0' >> "$OUTPUT_FILE"; fi
if [ "$severity_exists" -eq 0 ]; then echo 'ansible_inventory_groups{type="severity", tag="empty"} 0' >> "$OUTPUT_FILE"; fi
if [ "$groups_exists" -eq 0 ]; then echo 'ansible_inventory_groups{type="groups", tag="empty"} 0' >> "$OUTPUT_FILE"; fi
if [ "$apps_exists" -eq 0 ]; then echo 'ansible_inventory_groups{type="apps", tag="empty"} 0' >> "$OUTPUT_FILE"; fi


# Extract and process node_meta block
awk '/node_meta \{/,/^\}/' "$CONFIG_FILE" | while read -r line; do
    # Skip empty lines and closing brace
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*\}[[:space:]]*$ ]] && continue
    
    # Parse key-value pairs
    if [[ "$line" =~ ([[:alnum:]_]+)[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        
        # Handle special cases
        case "$key" in
            vlan)
                echo "ansible_inventory_groups{type=\"vlan\", tag=\"vlan_${value}\"} 1" >> "$OUTPUT_FILE"
                ;;
            scope)
                echo "ansible_inventory_groups{type=\"scope\", tag=\"scope_${value}\"} 1" >> "$OUTPUT_FILE"
                ;;
            severity)
                echo "ansible_inventory_groups{type=\"severity\", tag=\"severity_${value}\"} 1" >> "$OUTPUT_FILE"
                ;;
            groups)
                # Split comma-separated groups
                IFS=',' read -ra groups <<< "$value"
                for group in "${groups[@]}"; do
                    group_trimmed=$(echo "$group" | xargs)  # Trim whitespace
                    echo "ansible_inventory_groups{type=\"groups\", group=\"${group_trimmed}\", tag=\"groups_${group_trimmed}\"} 1" >> "$OUTPUT_FILE"
                done
                ;;
            apps)
                # Split comma-separated apps
                IFS=',' read -ra apps <<< "$value"
                for app in "${apps[@]}"; do
                    app_trimmed=$(echo "$app" | xargs)  # Trim whitespace
                    echo "ansible_inventory_groups{type=\"apps\", app=\"${app_trimmed}\", tag=\"apps_${app_trimmed}\"} 1" >> "$OUTPUT_FILE"
                done
                ;;
            *)
                # Skip other keys (os, env)
                ;;
        esac
    fi
done

# Verify output
echo "# HELP ansible_inventory_groups Check consul meta associated with ansible groups 1 type exist, 0 it doesnt"
echo "# TYPE ansible_inventory_groups gauge"
cat "$OUTPUT_FILE"
