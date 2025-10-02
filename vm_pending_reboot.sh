#!/usr/bin/env bash
#===============================================================================
#         FILE:  vm_pending_reboot.sh
#
#        USAGE:  ./vm_pending_reboot.sh
#
#  DESCRIPTION:  Export reboot requirement status for Prometheus node_exporter.
#                Adds labels for kernel mismatch, running/latest kernel versions,
#                reason why a reboot is required, and a scrape error metric.
#
#  REQUIREMENTS: needs-restarting (optional, RHEL/CentOS) or /var/run/reboot-required (Debian/Ubuntu)
#       AUTHOR:  Philippe LEAL (lotus.noir@gmail.com)
#      VERSION:  1.4
#      CREATED:  2025-10-02
#===============================================================================

set -euo pipefail

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "$(basename "$0") must be run as root!" >&2
        exit 2
    fi
}

require_root

REBOOT=0
KERNEL_MISMATCH="false"
REASON="none"
SCRAPE_ERROR=0

# Detect current running kernel
RUNNING_KERNEL=$(uname -r || { SCRAPE_ERROR=1; echo "unknown"; })

# Detect latest installed kernel
if command -v dpkg >/dev/null 2>&1; then
    LATEST_KERNEL=$(dpkg --list 2>/dev/null | awk '/linux-image-[0-9]/{print $2}' | sed 's/linux-image-//' | sort -V | tail -n1) || true
    if [ -z "$LATEST_KERNEL" ]; then LATEST_KERNEL="unknown"; SCRAPE_ERROR=1; fi
elif command -v rpm >/dev/null 2>&1; then
    LATEST_KERNEL=$(rpm -q kernel 2>/dev/null | sed 's/kernel-//' | sort -V | tail -n1) || true
    if [ -z "$LATEST_KERNEL" ]; then LATEST_KERNEL="unknown"; SCRAPE_ERROR=1; fi
else
    LATEST_KERNEL="unknown"
    SCRAPE_ERROR=1
fi

# Debian/Ubuntu reboot-required file
if [ -f /var/run/reboot-required ]; then
    REBOOT=1
    REASON="debian_reboot_file"
fi

# RHEL/CentOS reboot check
if [ -x /bin/needs-restarting ]; then
    if needs-restarting -r 2>/dev/null | grep -q 'Reboot is required'; then
        REBOOT=1
        REASON="needs_restarting"
    elif [ $? -ne 0 ]; then
        SCRAPE_ERROR=1
    fi
fi

# Kernel mismatch
if [ "$LATEST_KERNEL" != "unknown" ] && [ "$RUNNING_KERNEL" != "$LATEST_KERNEL" ]; then
    REBOOT=1
    KERNEL_MISMATCH="true"
    REASON="kernel_mismatch"
fi

# Prometheus metrics
echo "# HELP vm_pending_reboot Check if a pending reboot is required"
echo "# TYPE vm_pending_reboot gauge"
echo "vm_pending_reboot{kernel_mismatch=\"$KERNEL_MISMATCH\",running_kernel=\"$RUNNING_KERNEL\",latest_kernel=\"$LATEST_KERNEL\",reason=\"$REASON\"} $REBOOT"

echo "# HELP vm_pending_reboot_scrape_error 1 if an error occurred during detection"
echo "# TYPE vm_pending_reboot_scrape_error gauge"
echo "vm_pending_reboot_scrape_error $SCRAPE_ERROR"

exit 0
