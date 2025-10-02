#!/usr/bin/env bash
#===============================================================================
#         FILE:  check_primary_disk.sh
#
#        USAGE:  ./check_primary_disk.sh
#
#  DESCRIPTION:  Check if the system boot/root disk has the expected device name.
#                Exposes results in Prometheus node_exporter textfile format.
#
#  REQUIREMENTS: awk, df, grep
#       AUTHOR:  Philippe (Axione)
#      VERSION:  1.1
#      CREATED:  2025-10-01
#===============================================================================

set -euo pipefail

#--- Functions -----------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "$(basename "$0") must be run as root!" >&2
        exit 2
    fi
}

find_primary_disk() {
    # Look for root (/) and /boot partitions
    df | awk '$NF == "/" || $NF == "/boot" { print $1 }' | grep -E "da[0-9]" || true
}

#--- Main ----------------------------------------------------------------------
require_root

PROBLEM_COUNT=0
PRIMARY_DISK_CODE=0

PRIMARY_DISK_NAME=$(find_primary_disk)
if [ -z "$PRIMARY_DISK_NAME" ]; then
    PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
fi

PRIMARY_DISK=$(echo "$PRIMARY_DISK_NAME" | grep -c -E "da[0-9]" || true)
if [ "$PRIMARY_DISK" -eq 0 ]; then
    PRIMARY_DISK_CODE=1
    PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
fi

#--- Prometheus Metrics --------------------------------------------------------
echo "# HELP node_wrong_disk_on_boot Check if the primary boot/root disk matches naming convention (daX)"
echo "# TYPE node_wrong_disk_on_boot gauge"
if [ -z "$PRIMARY_DISK_NAME" ]; then
    echo "vm_primary_disk_mismatch $PRIMARY_DISK_CODE"
else
    echo "vm_primary_disk_mismatch{primary_disk=\"$PRIMARY_DISK_NAME\"} $PRIMARY_DISK_CODE"
fi

#--- Exit Codes ----------------------------------------------------------------
if [ "$PROBLEM_COUNT" -ne 0 ]; then
    exit 1
fi
exit 0
