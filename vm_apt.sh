#!/usr/bin/env bash
#===============================================================================
#         FILE:  vm_apt.sh
#
#        USAGE:  ./vm_apt.sh
#
#  DESCRIPTION:
#                Exposes APT package status in Prometheus textfile format.
#
#  REQUIREMENTS: bash 4+, apt, apt-cache, apt-mark, apt-get, dpkg, stat
#       AUTHOR:  Philippe LEAL
#      VERSION: 1.6
#      CREATED: 2025-10-02
#===============================================================================

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#-------------------------------------------------------------------------------
# Architecture
#-------------------------------------------------------------------------------

arch=$(dpkg --print-architecture 2>/dev/null || echo "unknown")

#-------------------------------------------------------------------------------
# Associative arrays
#-------------------------------------------------------------------------------

declare -A upgrades_pending=()
declare -A upgrades_held=()
declare -A held_lookup=()
declare -A pkg_origin_cache=()

#-------------------------------------------------------------------------------
# Held packages
#-------------------------------------------------------------------------------

while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && held_lookup["$pkg"]=1
done < <(apt-mark showhold 2>/dev/null)

#-------------------------------------------------------------------------------
# Upgradable packages
#-------------------------------------------------------------------------------

upgradable_list=()

while IFS= read -r pkg_name; do
    [[ -z "$pkg_name" ]] && continue

    upgradable_list+=("$pkg_name")

    if [[ -n "${held_lookup[$pkg_name]:-}" ]]; then
        upgrades_held["$pkg_name"]=1
    else
        upgrades_pending["$pkg_name"]=1
    fi
done < <(
    apt list --upgradable 2>/dev/null |
        awk 'NR > 1 {
            sub(/\/.*/, "", $1)
            if ($1 != "") print $1
        }'
)

#-------------------------------------------------------------------------------
# Package origins
#
# Parse the complete apt-cache policy output with one awk process.
#-------------------------------------------------------------------------------

if ((${#upgradable_list[@]} > 0)); then

    policy_output=$(
        apt-cache policy "${upgradable_list[@]}" 2>/dev/null || true
    )

    while IFS=$'\t' read -r pkg origin; do
        [[ -n "$pkg" && -n "$origin" ]] &&
            pkg_origin_cache["$pkg"]="$origin"
    done < <(
        awk -v arch="$arch" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }

        /^[[:alnum:].+:-]+:$/ {
            pkg=$0
            sub(/:$/, "", pkg)
            candidate=""
            repo=""
            next
        }

        /^Candidate:/ {
            candidate=$0
            sub(/^Candidate:[[:space:]]*/, "", candidate)
            next
        }

        /https:\/\// && / Packages$/ {
            line=trim($0)

            # Expected:
            # 500 https://repo.example/debian bookworm/main amd64 Packages
            n=split(line, f, /[[:space:]]+/)

            if (n >= 4) {
                repo=f[2]
                distro=f[3]
            }

            next
        }

        candidate != "" && repo != "" {
            version=trim($0)

            if (version == candidate) {
                printf "%s\t%s:%s/%s\n", pkg, repo, distro, arch
                repo=""
            }
        }
        ' <<< "$policy_output"
    )
fi

#-------------------------------------------------------------------------------
# Pending upgrades
#-------------------------------------------------------------------------------

echo "# HELP apt_upgrades_pending Apt packages pending updates by origin/arch/package"
echo "# TYPE apt_upgrades_pending gauge"

for pkg_name in "${!upgrades_pending[@]}"; do
    origin="${pkg_origin_cache[$pkg_name]:-unknown}"

    echo "apt_upgrades_pending{origin=\"$origin\",arch=\"$arch\",package=\"$pkg_name\"} 1"
done

#-------------------------------------------------------------------------------
# Held upgrades
#-------------------------------------------------------------------------------

echo "# HELP apt_upgrades_held Apt packages pending updates but held back."
echo "# TYPE apt_upgrades_held gauge"

for pkg_name in "${!upgrades_held[@]}"; do
    origin="${pkg_origin_cache[$pkg_name]:-unknown}"

    echo "apt_upgrades_held{origin=\"$origin\",arch=\"$arch\",package=\"$pkg_name\"} 1"
done

#-------------------------------------------------------------------------------
# Autoremove
#-------------------------------------------------------------------------------

autoremove_count=0

if output=$(apt-get -s autoremove 2>/dev/null); then
    autoremove_count=$(awk '/^Remv / { count++ } END { print count+0 }' <<< "$output")
fi

echo "# HELP apt_autoremove_pending Apt packages pending autoremoval."
echo "# TYPE apt_autoremove_pending gauge"
echo "apt_autoremove_pending $autoremove_count"

#-------------------------------------------------------------------------------
# APT package cache timestamp
#-------------------------------------------------------------------------------

stamp_file="/var/lib/apt/periodic/update-success-stamp"

if [[ ! -f "$stamp_file" ]]; then
    stamp_file="/var/lib/apt/lists/partial"
fi

ts=0

if [[ -f "$stamp_file" ]]; then
    ts=$(stat -c %Y "$stamp_file" 2>/dev/null || echo 0)
fi

echo "# HELP apt_package_cache_timestamp_seconds Apt update last run time."
echo "# TYPE apt_package_cache_timestamp_seconds gauge"
echo "apt_package_cache_timestamp_seconds $ts"
