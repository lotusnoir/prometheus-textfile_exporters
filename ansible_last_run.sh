#!/usr/bin/env bash
#===============================================================================
#         FILE:  ansible_last_run.sh
#
#        USAGE:  ./ansible_last_run.sh
#
#  DESCRIPTION:  Extract role success run flag info into prometheus metrics
#
#  REQUIREMENTS: bash 4+
#       AUTHOR:  Philippe
#      VERSION: 0.1
#      CREATED: 2025-11-25
#===============================================================================

set -euo pipefail
CACHE_DIR="/var/cache/ansible"
METRIC_NAME="ansible_last_run"

echo "# HELP $METRIC_NAME Extract date from role success_run_flag"
echo "# TYPE $METRIC_NAME gauge"

# Loop through every file in cache
for f in "$CACHE_DIR"/*; do
    [ -f "$f" ] || continue
    role=$(basename "$f")

    # Read timestamp from file
    timestamp=$(cat "$f")

    # Convert ISO8601 → UNIX epoch (Prometheus needs numbers)
    epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo "")

    # Skip invalid timestamps
    [ -n "$epoch" ] || continue

    echo "${METRIC_NAME}{role=\"${role}\"} ${epoch}"
done
