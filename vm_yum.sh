#!/usr/bin/env bash
#===============================================================================
#         FILE:  yum.sh
#
#        USAGE:  ./yum.sh
#
#  DESCRIPTION: Exposes pending YUM/DNF updates and reboot requirement
#               in Prometheus textfile format.
#
#  REQUIREMENTS: yum, awk
#       AUTHOR:  Philippe LEAL
#      VERSION: 2.0
#      CREATED: 2025-10-02
#===============================================================================

set -u -o pipefail

YUM="/usr/bin/yum"
NEEDS_RESTARTING="/bin/needs-restarting"

#-------------------------------------------------------------------------------
# Check pending upgrades
#
# yum check-update returns:
#   0   = no updates
#   100 = updates available
#   >1  = error
#
# Output format:
#   package.arch    version    repository
#
# We count packages directly by repository/origin with awk.
#-------------------------------------------------------------------------------

check_upgrades() {
    local output rc

    output=$(
        "$YUM" -q \
            --setopt=autocheck_running_kernel=0 \
            check-update 2>/dev/null
    )
    rc=$?

    # 100 is the normal return code when updates are available.
    # Any other non-zero status is an actual yum error.
    if ((rc != 0 && rc != 100)); then
        return "$rc"
    fi

    awk '
        BEGIN {
            found=0
        }

        # Stop before the "Obsoleting Packages" section.
        /^Obsoleting Packages/ {
            exit
        }

        # Match normal package update lines.
        #
        # Example:
        # containerd.io.x86_64    2.1.4-1.el10    docker-ce-stable
        #
        /^[[:alnum:]][^[:space:]]*\.[[:alnum:]_+-]+[[:space:]]+/ {
            repo=$3

            if (repo != "") {
                count[repo]++
                found=1
            }
        }

        END {
            for (repo in count) {
                printf "yum_upgrades_pending{origin=\"%s\"} %d\n", repo, count[repo]
            }

            if (!found) {
                exit 1
            }
        }
    ' <<< "$output"
}

#-------------------------------------------------------------------------------
# Metrics
#-------------------------------------------------------------------------------

echo '# HELP yum_upgrades_pending Yum package pending updates by origin.'
echo '# TYPE yum_upgrades_pending gauge'

if upgrades=$(check_upgrades); then
    printf '%s\n' "$upgrades"
else
    echo 'yum_upgrades_pending{origin=""} 0'
fi

#-------------------------------------------------------------------------------
# Reboot required
#-------------------------------------------------------------------------------

if [[ -x "$NEEDS_RESTARTING" ]]; then
    echo '# HELP node_reboot_required Node reboot is required for software updates.'
    echo '# TYPE node_reboot_required gauge'

    if "$NEEDS_RESTARTING" -r >/dev/null 2>&1; then
        echo 'node_reboot_required 0'
    else
        echo 'node_reboot_required 1'
    fi
fi
