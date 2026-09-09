#!/usr/bin/env bash
#===============================================================================
#         FILE:  ansible_last_run.sh
#
#        USAGE:  ./ansible_last_run.sh
#
#  DESCRIPTION: Extract role success run flag info into prometheus metrics
#
#  REQUIREMENTS: bash 4+
#       AUTHOR:  Philippe
#      VERSION: 0.2
#      CREATED: 2025-11-25
#===============================================================================

set -euo pipefail

CACHE_DIR="/var/cache/ansible"
METRIC_NAME="ansible_last_run"

echo "# HELP $METRIC_NAME Extract date from role success_run_flag"
echo "# TYPE $METRIC_NAME gauge"

for f in "$CACHE_DIR"/*; do
    [ -f "$f" ] || continue

    role="${f##*/}"
    timestamp=$(<"$f")

    if [ -z "$timestamp" ]; then
        continue
    fi

    if epoch=$(date -d "$timestamp" +%s 2>/dev/null); then
        echo "${METRIC_NAME}{role=\"${role}\"} ${epoch}"
    fi
done

exit 0
