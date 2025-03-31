#!/bin/bash

## Configuration
#VSPHERE_URL="ADD_VSPHERE_URL"
#VSPHERE_USER="ADD_VSPHERE_USER"
#VSPHERE_PWD="ADD_VSPHERE_PWD"
#VSPHERE_TEMPFILE_COOKIE="/tmp/cookie"
#METRIC_NAME="vsphere_vm_attributes"
#OUTPUT_FILE="/var/lib/node_exporter/vsphere_vm_attributes.prom"

function vsphere_get_ticket() {
    curl --noproxy '*' -s -k -u "${VSPHERE_USER}:${VSPHERE_PWD}" -X POST -c "${VSPHERE_TEMPFILE_COOKIE}" "${VSPHERE_URL}/rest/com/vmware/cis/session" > /dev/null
}

function vsphere_list_tags_category() {
    curl --noproxy '*' -k -s -b "${VSPHERE_TEMPFILE_COOKIE}" "${VSPHERE_URL}/api/cis/tagging/category" | \
    sed 's/[][]//g; s/"//g; s/,/ /g'
}

function vsphere_list_tags() {
    curl --noproxy '*' -k -s -b "${VSPHERE_TEMPFILE_COOKIE}" "${VSPHERE_URL}/api/cis/tagging/tag" | \
    sed 's/[][]//g; s/"//g; s/,/ /g'
}

function vsphere_get_tagcategoryname_from_id() {
    local TAG_CAT_ID=$1
    curl --noproxy '*' -k -s -b "${VSPHERE_TEMPFILE_COOKIE}" "${VSPHERE_URL}/api/cis/tagging/category/$TAG_CAT_ID" | \
    jq -r '.name'
}

function vsphere_list_vmid() {
    curl --noproxy '*' -s -k -b "${VSPHERE_TEMPFILE_COOKIE}" "${VSPHERE_URL}/rest/vcenter/vm" | \
    jq -r '.value[].vm'
}

# Main function
function vsphere_generate_prometheus_metrics() {
    # Initialize cookie file
    VSPHERE_TEMPFILE_COOKIE=$(mktemp)

    # Authenticate
    vsphere_get_ticket

    echo "# Starting VM information collection for Prometheus metrics..."
    echo "# HELP vmware_vm_attributes Extract attributes from vmware 1 = set 0 doesnt exist"  > "$OUTPUT_FILE"
    echo "# TYPE vmware_vm_attributes gauge" >> "$OUTPUT_FILE"

    # Step 1: Get all tag categories
    declare -A tag_categories
    echo "# Fetching tag categories..."
    local tag_cat_list=($(vsphere_list_tags_category))
    for cat_id in "${tag_cat_list[@]}"; do
        tag_categories["$cat_id"]=$(vsphere_get_tagcategoryname_from_id "$cat_id")
    done

    # Step 2: Get all tags with formatted names
    declare -A tags
    declare -A tag_category_map
    declare -A base_tag_names  # To store the original tag names without category prefixes
    echo "# Processing tags..."
    local tag_list=($(vsphere_list_tags))
    for tag_id in "${tag_list[@]}"; do
        local tag_info=$(curl --noproxy '*' -k -s -b "${VSPHERE_TEMPFILE_COOKIE}" "${VSPHERE_URL}/api/cis/tagging/tag/$tag_id")
        local tag_name=$(echo "$tag_info" | jq -r '.name')
        local cat_id=$(echo "$tag_info" | jq -r '.category_id')
        local cat_name="${tag_categories[$cat_id]}"

        # Store category for each tag
        tag_category_map["$tag_id"]="$cat_name"
        # Store the base tag name without category prefix
        base_tag_names["$tag_id"]="$tag_name"

        # Format combined tag name
        if [[ "$cat_name" == "site" ]]; then
            tags["$tag_id"]="$tag_name"
        else
            tags["$tag_id"]="${cat_name}_${tag_name}"
        fi
    done

    # Step 3: Get powered-on VMs
    declare -A vm_names
    echo "# Fetching VM list..."
    while IFS=$'\t' read -r vm_id vm_name; do
        vm_names["$vm_id"]="$vm_name"
    done < <(curl --noproxy '*' -s -k -b "${VSPHERE_TEMPFILE_COOKIE}" "${VSPHERE_URL}/rest/vcenter/vm" | \
             jq -r '.value[] | select(.vm != null) | select(.power_state == "POWERED_ON") | [.vm, .name] | @tsv' | sort)

    # Step 4: Get VM tags and generate Prometheus metrics
    echo "# Generating Prometheus metrics..."

    local vm_ids=($(vsphere_list_vmid))
    local all_vm_tags=$(curl -k -s --noproxy '*' -X GET -b "${VSPHERE_TEMPFILE_COOKIE}" --url "${VSPHERE_URL}/api/vcenter/tagging/associations" | jq -r '.associations[]')

    for vm_id in "${vm_ids[@]}"; do
        local vm_name="${vm_names[$vm_id]}"
        [ -z "$vm_name" ] && continue

        # Get tags for this VM
        local tag_ids=($(echo "$all_vm_tags" | jq -r --arg ID "$vm_id" 'select(.object.id == $ID) | .tag'))

        if [ ${#tag_ids[@]} -eq 0 ]; then
            # No tags found for this VM - output with value 0
            echo "${METRIC_NAME}{vmid=\"$vm_id\", vm_name=\"$vm_name\"} 0" >> "$OUTPUT_FILE"
        else
            has_valid_tags=false
            for tag_id in "${tag_ids[@]}"; do
                tag_name="${tags[$tag_id]}"
                cat_name="${tag_category_map[$tag_id]}"
                base_tag_name="${base_tag_names[$tag_id]}"
                if [ -z "$tag_name" ] || [ -z "$cat_name" ] || [ -z "$base_tag_name" ]; then
                    continue
                fi
                has_valid_tags=true

                # Write metric with corrected tag names
                echo "${METRIC_NAME}{vmid=\"$vm_id\", vm_name=\"$vm_name\", vm_tagcategory=\"$cat_name\", vm_tagname=\"$base_tag_name\", vm_tagcombined=\"${cat_name}_${base_tag_name}\"} 1" >> "$OUTPUT_FILE"
            done

            if [ "$has_valid_tags" = false ]; then
                # VM had tags but none were valid - output with value 0
                echo "${METRIC_NAME}{vmid=\"$vm_id\", vm_name=\"$vm_name\"} 0" >> "$OUTPUT_FILE"
            fi
        fi
    done

    # Cleanup
    rm -f "${VSPHERE_TEMPFILE_COOKIE}"

    echo "# Metrics generation complete"
}

### START ###
vsphere_generate_prometheus_metrics
