#!/usr/bin/env bash
#===============================================================================
#         FILE:  vm_apt.sh
#
#        USAGE:  ./vm_apt.sh
#
#  DESCRIPTION: 
#
#  REQUIREMENTS: bash 4+, curl, jq
#       AUTHOR:  Philippe LEAL
#      VERSION: 1.4
#      CREATED: 2025-10-02
#===============================================================================

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

arch=$(dpkg --print-architecture)

declare -A upgrades_pending
declare -A upgrades_held
declare -A held_lookup
declare -A pkg_origin_cache

# -----------------------------
# Held packages lookup
# -----------------------------
while IFS= read -r pkg; do
    held_lookup["$pkg"]=1
done < <(apt-mark showhold 2>/dev/null)

# -----------------------------
# All upgradable packages
# -----------------------------
upgradable_list=()
while IFS= read -r line; do
    pkg_name=$(echo "$line" | cut -d/ -f1)
    upgradable_list+=("$pkg_name")
    if [[ -n "${held_lookup[$pkg_name]:-}" ]]; then
        upgrades_held["$pkg_name"]=1
    else
        upgrades_pending["$pkg_name"]=1
    fi
done < <(apt list --upgradable 2>/dev/null | tail -n +2)

# -----------------------------
# Build package origin cache (one apt-cache policy call)
# -----------------------------
policy_output=$(apt-cache policy "${upgradable_list[@]}" 2>/dev/null)
current_pkg=""
cand=""
arch=$(dpkg --print-architecture 2>/dev/null || echo "unknown")

while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"  # trim leading space
    if [[ "$line" =~ ^([a-zA-Z0-9.+-]+):$ ]]; then
        current_pkg="${BASH_REMATCH[1]}"
    elif [[ "$line" == Candidate:* ]]; then
        cand=$(awk '{print ($2 ? $2 : "")}' <<< "${line:-}")
    elif [[ "$line" == *https://* && "$line" == *"${cand:-}"* ]]; then
        url=$(awk '{print $2}' <<< "$line")
        distro=$(awk '{print $3}' <<< "$line")
        if [[ -n "${current_pkg:-}" ]]; then
            pkg_origin_cache["$current_pkg"]="${url}:${distro}/${arch}"
        fi
    fi
done <<< "$policy_output"

# -----------------------------
# Print pending upgrades
# -----------------------------
echo "# HELP apt_upgrades_pending Apt packages pending updates by origin/arch/package"
echo "# TYPE apt_upgrades_pending gauge"
for pkg_name in "${!upgrades_pending[@]}"; do
    origin="${pkg_origin_cache[$pkg_name]:-unknown}"
    echo "apt_upgrades_pending{origin=\"$origin\",arch=\"$arch\",package=\"$pkg_name\"} 1"
done

# -----------------------------
# Print held upgrades
# -----------------------------
echo "# HELP apt_upgrades_held Apt packages pending updates but held back."
echo "# TYPE apt_upgrades_held gauge"
for pkg_name in "${!upgrades_held[@]}"; do
    origin="${pkg_origin_cache[$pkg_name]:-unknown}"
    echo "apt_upgrades_held{origin=\"$origin\",arch=\"$arch\",package=\"$pkg_name\"} 1"
done

# -----------------------------
# Autoremove
# -----------------------------
autoremove_count=0
if output=$(apt-get -s autoremove 2>/dev/null); then
    autoremove_count=$(awk '/^Remv /{count++} END{print count+0}' <<< "$output")
fi

echo "# HELP apt_autoremove_pending Apt packages pending autoremoval."
echo "# TYPE apt_autoremove_pending gauge"
echo "apt_autoremove_pending $autoremove_count"

# -----------------------------
# Cache timestamp
# -----------------------------
stamp_file="/var/lib/apt/periodic/update-success-stamp"
[[ ! -f "$stamp_file" ]] && stamp_file="/var/lib/apt/lists/partial"
ts=0
[[ -f "$stamp_file" ]] && ts=$(stat -c %Y "$stamp_file")
echo "# HELP apt_package_cache_timestamp_seconds Apt update last run time."
echo "# TYPE apt_package_cache_timestamp_seconds gauge"
echo "apt_package_cache_timestamp_seconds $ts"
