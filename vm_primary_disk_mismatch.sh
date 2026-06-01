#!/usr/bin/env bash
#===============================================================================
#         FILE:  check_primary_disk.sh
#
#        USAGE:  ./check_primary_disk.sh
#
#  DESCRIPTION:  Check if the system boot/root disk has the expected device name.
#                Exposes results in Prometheus node_exporter textfile format.
#
#  REQUIREMENTS: awk, df, grep, blkid
#       AUTHOR:  Philippe LEAL
#      VERSION:  1.2
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

get_sda1_uuid() {
    /usr/sbin/blkid $(find_primary_disk) 2>/dev/null | grep -oP ' UUID="\K[^"]+' || true
}

find_grub_cfg() {
    # Return the first grub.cfg path that exists, prefer grub2
    if [ -f "/boot/grub2/grub.cfg" ]; then
        echo "/boot/grub2/grub.cfg"
    elif [ -f "/boot/grub/grub.cfg" ]; then
        echo "/boot/grub/grub.cfg"
    else
        echo ""
    fi
}

check_uuid_in_file() {
    local uuid="$1"
    local file="$2"
    if [ -z "$uuid" ]; then
        echo "0"
        return
    fi
    if [ ! -f "$file" ]; then
        echo "0"
        return
    fi
    grep -qF "$uuid" "$file" && echo "1" || echo "0"
}

#--- Main ----------------------------------------------------------------------
require_root

PROBLEM_COUNT=0

# --- Primary disk check ---
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

# --- UUID check ---
SDA1_UUID=$(get_sda1_uuid)
GRUB_CFG=$(find_grub_cfg)

UUID_IN_FSTAB=$(check_uuid_in_file "$SDA1_UUID" "/etc/fstab")
UUID_IN_GRUB=$(check_uuid_in_file "$SDA1_UUID" "$GRUB_CFG")

# UUID check fails if uuid is missing OR not found in either file
UUID_FSTAB_CODE=0
UUID_GRUB_CODE=0

if [ -z "$SDA1_UUID" ] || [ "$UUID_IN_FSTAB" -eq 0 ]; then
    UUID_FSTAB_CODE=1
    PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
fi

if [ -z "$SDA1_UUID" ] || [ -z "$GRUB_CFG" ] || [ "$UUID_IN_GRUB" -eq 0 ]; then
    UUID_GRUB_CODE=1
    PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
fi

#--- Prometheus Metrics --------------------------------------------------------

# Metric 1: primary disk name check
echo "# HELP node_disk_mismatch_on_boot Check if the primary boot/root disk matches naming convention (daX)"
echo "# TYPE node_disk_mismatch_on_boot gauge"
if [ -z "$PRIMARY_DISK_NAME" ]; then
    echo "node_disk_mismatch_on_boot $PRIMARY_DISK_CODE"
else
    echo "node_disk_mismatch_on_boot{primary_disk=\"$PRIMARY_DISK_NAME\"} $PRIMARY_DISK_CODE"
fi

# Metric 2: UUID presence in /etc/fstab and /boot/grub/grub.cfg
echo "# HELP node_disk_uuid_missing Check if /dev/sda1 UUID is referenced in boot config files (0=found, 1=missing/error)"
echo "# TYPE node_disk_uuid_missing gauge"
if [ -z "$SDA1_UUID" ]; then
    echo "node_disk_uuid_missing{file=\"/etc/fstab\",uuid=\"unknown\"} $UUID_FSTAB_CODE"
    echo "node_disk_uuid_missing{file=\"$GRUB_CFG\",uuid=\"unknown\"} $UUID_GRUB_CODE"
else
    echo "node_disk_uuid_missing{file=\"/etc/fstab\",uuid=\"$SDA1_UUID\"} $UUID_FSTAB_CODE"
    echo "node_disk_uuid_missing{file=\"$GRUB_CFG\",uuid=\"$SDA1_UUID\"} $UUID_GRUB_CODE"
fi

#--- Exit Codes ----------------------------------------------------------------
if [ "$PROBLEM_COUNT" -ne 0 ]; then
    exit 1
fi
exit 0
