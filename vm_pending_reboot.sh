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
#      VERSION:  1.5
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

# Get the kernel package version that matches the running kernel


# Detect latest installed kernel
if command -v dpkg >/dev/null 2>&1; then
    RUNNING_KERNEL_RELEASE=$(uname -r)
    RUNNING_KERNEL=$(dpkg-query -W -f='${Version}\n' "linux-image-${RUNNING_KERNEL_RELEASE}" 2>/dev/null || echo "unknown")

    # Get installed kernels (actual packages, not metapackages)
    LATEST_INSTALLED_KERNEL=$(dpkg --list 2>/dev/null | grep -E '^ii' | awk '/linux-image-[0-9]/{print $3}' | sed 's/linux-image-//' | sort -V | tail -n1) || true
    [ -z "$LATEST_INSTALLED_KERNEL" ] && LATEST_INSTALLED_KERNEL="unknown" && SCRAPE_ERROR=1
    # Get candidate kernel version from the metapackage
    LATEST_AVAILABLE_KERNEL=$(apt-cache policy linux-image-amd64 2>/dev/null | awk '/Candidate:/ {print $2}') || true
    [ -z "$LATEST_AVAILABLE_KERNEL" ] && LATEST_AVAILABLE_KERNEL="unknown" && SCRAPE_ERROR=1
elif command -v rpm >/dev/null 2>&1; then
    RUNNING_KERNEL=$(uname -r | sed -E 's/\.el[0-9].*//' || { SCRAPE_ERROR=1; echo "unknown"; })

    # Detect installed kernels
    LATEST_INSTALLED_KERNEL=$(rpm -q --last kernel 2>/dev/null | head -n1 | awk '{print $1}' | sed 's/kernel-\(.*\)\..*$/\1/' | sed -E 's/\.el[0-9].*//') || true
    # Detect available kernels (requires yum/dnf repo access)
    if command -v dnf >/dev/null 2>&1; then
        LATEST_AVAILABLE_KERNEL=$(timeout 60 dnf --nogpgcheck --quiet list available kernel 2>/dev/null | awk '/^kernel\./ {print $2}' | sed -E 's/\.el[0-9].*//' | sort -V | tail -n1) || true
    elif command -v yum >/dev/null 2>&1; then
        LATEST_AVAILABLE_KERNEL=$(timeout 60 yum list available kernel 2>/dev/null | \
            awk '/^kernel\./ {print $2}' | sort -V | tail -n1) || true
    else
        LATEST_AVAILABLE_KERNEL=$LATEST_INSTALLED_KERNEL
    fi

    [ -z "$LATEST_AVAILABLE_KERNEL" ] && LATEST_AVAILABLE_KERNEL="unknown" && SCRAPE_ERROR=1
    [ -z "$LATEST_INSTALLED_KERNEL" ] && LATEST_INSTALLED_KERNEL="unknown" && SCRAPE_ERROR=1
else
    LATEST_INSTALLED_KERNEL="unknown"
    LATEST_AVAILABLE_KERNEL="unknown"
    SCRAPE_ERROR=1
fi

# Debian/Ubuntu reboot-required file
if [ -f /var/run/reboot-required ]; then
    REBOOT=1
    REASON="needs_restarting"
fi

# RHEL/CentOS reboot check
if [ -x /bin/needs-restarting ]; then
    if grep -q 'Reboot is required' <(needs-restarting -r 2>&1); then
        REBOOT=1
        REASON="needs_restarting"
    fi
    # Check if needs-restarting command failed
    if [ $? -ne 0 ]; then
        SCRAPE_ERROR=1
    fi
fi

# Kernel mismatch
if [ "$LATEST_AVAILABLE_KERNEL" != "unknown" ] && [ "$RUNNING_KERNEL" != "$LATEST_AVAILABLE_KERNEL" ]; then
    KERNEL_MISMATCH="true"
    [ "$REASON" = "needs_restarting" ] && REASON="kernel_mismatch"
fi
if [ "$LATEST_INSTALLED_KERNEL" != "unknown" ] && [ "$RUNNING_KERNEL" != "$LATEST_INSTALLED_KERNEL" ]; then
    KERNEL_MISMATCH="true"
    [ "$REASON" = "needs_restarting" ] && REASON="kernel_mismatch"
fi

if [ "$KERNEL_MISMATCH" = "true" ]; then
    MISMATCH_VALUE=1
else
    MISMATCH_VALUE=0
fi

# Prometheus metrics
echo "# HELP vm_pending_reboot Check if a pending reboot is required"
echo "# TYPE vm_pending_reboot gauge"
echo "vm_pending_reboot{reason=\"$REASON\"} $REBOOT"
echo "# HELP vm_pending_kernel Check if a new kernel is available"
echo "# TYPE vm_pending_kernel gauge"
echo "vm_pending_kernel{running_kernel=\"$RUNNING_KERNEL\",latest_installed_kernel=\"$LATEST_INSTALLED_KERNEL\",latest_available_kernel=\"$LATEST_AVAILABLE_KERNEL\"} $MISMATCH_VALUE"
echo "# HELP vm_pending_reboot_scrape_error 1 if an error occurred during detection"
echo "# TYPE vm_pending_reboot_scrape_error gauge"
echo "vm_pending_reboot_scrape_error $SCRAPE_ERROR"

exit 0
