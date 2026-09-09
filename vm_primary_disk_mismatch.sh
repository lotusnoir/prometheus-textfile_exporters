#!/usr/bin/env bash
#===============================================================================
#         FILE:  vm_primary_disk_mismatch.sh
#
#        USAGE:  ./vm_primary_disk_mismatch.sh
#
#  DESCRIPTION:  Check if the system boot/root disk has the expected device name.
#                Exposes results in Prometheus node_exporter textfile format.
#
#  REQUIREMENTS: df, blkid
#       AUTHOR:  Philippe LEAL
#      VERSION: 1.3
#      CREATED: 2025-10-01
#===============================================================================

set -euo pipefail

SCRIPT_NAME="${0##*/}"

#--- Functions -----------------------------------------------------------------

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "${SCRIPT_NAME} must be run as root!" >&2
        exit 2
    fi
}

find_primary_disk() {
    # Look for root (/) and /boot partitions.
    # Use the last df column because it contains the mountpoint.
    df -P 2>/dev/null |
        awk '$NF == "/" || $NF == "/boot" { print $1 }' |
        grep -m1 -E 'da[0-9]' || true
}

get_disk_uuid() {
    local device="$1"

    [ -n "$device" ] || return 0

    /usr/sbin/blkid -s UUID -o value "$device" 2>/dev/null || true
}

find_grub_cfg() {
    # Prefer grub2 configuration.
    if [ -f /boot/grub2/grub.cfg ]; then
        printf '%s\n' "/boot/grub2/grub.cfg"
    elif [ -f /boot/grub/grub.cfg ]; then
        printf '%s\n' "/boot/grub/grub.cfg"
    fi
}

uuid_in_file() {
    local uuid="$1"
    local file="$2"

    [ -n "$uuid" ] || return 1
    [ -n "$file" ] || return 1
    [ -f "$file" ] || return 1

    grep -qF -- "$uuid" "$file"
}

#--- Main ----------------------------------------------------------------------

require_root

PROBLEM_COUNT=0

# ------------------------------------------------------------------------------
# Primary disk check
# ------------------------------------------------------------------------------

PRIMARY_DISK_CODE=0
PRIMARY_DISK_NAME=$(find_primary_disk)

if [ -z "$PRIMARY_DISK_NAME" ]; then
    PRIMARY_DISK_CODE=1
    PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
fi

# Historical naming convention: daX
if [ -n "$PRIMARY_DISK_NAME" ]; then
    case "$PRIMARY_DISK_NAME" in
        *da[0-9]*)
            ;;
        *)
            PRIMARY_DISK_CODE=1
            PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
            ;;
    esac
fi

# ------------------------------------------------------------------------------
# UUID check
# ------------------------------------------------------------------------------

SDA1_UUID=$(get_disk_uuid "$PRIMARY_DISK_NAME")
GRUB_CFG=$(find_grub_cfg)

UUID_FSTAB_CODE=0
UUID_GRUB_CODE=0

if ! uuid_in_file "$SDA1_UUID" "/etc/fstab"; then
    UUID_FSTAB_CODE=1
    PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
fi

if ! uuid_in_file "$SDA1_UUID" "$GRUB_CFG"; then
    UUID_GRUB_CODE=1
    PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
fi

# ------------------------------------------------------------------------------
# Prometheus metrics
# ------------------------------------------------------------------------------

echo "# HELP node_disk_mismatch_on_boot Check if the primary boot/root disk matches the expected disk naming convention"
echo "# TYPE node_disk_mismatch_on_boot gauge"

if [ -n "$PRIMARY_DISK_NAME" ]; then
    echo "node_disk_mismatch_on_boot{primary_disk=\"$PRIMARY_DISK_NAME\"} $PRIMARY_DISK_CODE"
else
    echo "node_disk_mismatch_on_boot $PRIMARY_DISK_CODE"
fi

echo "# HELP node_disk_uuid_missing Check if the primary disk UUID is referenced in boot configuration files (0=found, 1=missing/error)"
echo "# TYPE node_disk_uuid_missing gauge"

if [ -n "$SDA1_UUID" ]; then
    echo "node_disk_uuid_missing{file=\"/etc/fstab\",uuid=\"$SDA1_UUID\"} $UUID_FSTAB_CODE"
    echo "node_disk_uuid_missing{file=\"$GRUB_CFG\",uuid=\"$SDA1_UUID\"} $UUID_GRUB_CODE"
else
    echo "node_disk_uuid_missing{file=\"/etc/fstab\",uuid=\"unknown\"} $UUID_FSTAB_CODE"
    echo "node_disk_uuid_missing{file=\"$GRUB_CFG\",uuid=\"unknown\"} $UUID_GRUB_CODE"
fi

# ------------------------------------------------------------------------------
# Exit code
# ------------------------------------------------------------------------------

if [ "$PROBLEM_COUNT" -ne 0 ]; then
    exit 1
fi

exit 0
