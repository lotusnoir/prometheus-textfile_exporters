#!/usr/bin/env bash
#===============================================================================
#         FILE:  vm_pending_reboot.sh
#
#        USAGE:  ./vm_pending_reboot.sh
#
#  DESCRIPTION: Export reboot requirement status for Prometheus node_exporter.
#               Detects:
#                 - pending reboot
#                 - running kernel
#                 - latest installed kernel
#                 - latest available kernel
#                 - kernel mismatch
#
#  REQUIREMENTS:
#               Debian/Ubuntu:
#                 dpkg-query, dpkg, apt-cache
#
#               RHEL/CentOS/Rocky/Oracle:
#                 rpm, dnf/yum, needs-restarting (optional)
#
#       AUTHOR:  Philippe LEAL (lotus.noir@gmail.com)
#      VERSION: 2.0
#      CREATED: 2025-10-02
#===============================================================================

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------

DNF_TIMEOUT="${DNF_TIMEOUT:-30}"

#-------------------------------------------------------------------------------
# Functions
#-------------------------------------------------------------------------------

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        printf '%s must be run as root!\n' "${0##*/}" >&2
        exit 2
    fi
}

#-------------------------------------------------------------------------------
# Debian / Ubuntu
#-------------------------------------------------------------------------------

detect_debian_kernel() {

    local running_release
    local running_package
    local installed
    local available

    running_release=$(uname -r)

    #---------------------------------------------------------------------------
    # Kernel package corresponding to the running kernel
    #
    # linux-image-<release>
    #---------------------------------------------------------------------------

    running_package="linux-image-${running_release}"

    if dpkg-query -W -f='${Status}\n${Version}\n' "$running_package" 2>/dev/null |
        grep -q '^install ok installed$'
    then
        RUNNING_KERNEL="$running_release"
    else
        RUNNING_KERNEL="$running_release"
        SCRAPE_ERROR=1
    fi

    #---------------------------------------------------------------------------
    # Latest installed real kernel package
    #
    # dpkg-query is significantly cheaper than parsing dpkg --list.
    #---------------------------------------------------------------------------

    installed=$(
        dpkg-query \
            -W \
            -f='${binary:Package} ${Version}\n' \
            'linux-image-[0-9]*' 2>/dev/null |
        awk '
            $1 !~ /:amd64$/ {
                print $2
            }
            $1 ~ /:amd64$/ {
                print $2
            }
        ' |
        sort -V |
        tail -n1
    ) || true

    if [[ -n "$installed" ]]; then
        # Remove Debian revision if present.
        LATEST_INSTALLED_KERNEL="${installed%%-*}"
    else
        LATEST_INSTALLED_KERNEL="unknown"
        SCRAPE_ERROR=1
    fi

    #---------------------------------------------------------------------------
    # Latest available kernel
    #---------------------------------------------------------------------------

    available=$(
        apt-cache policy linux-image-amd64 2>/dev/null |
        awk '$1 == "Candidate:" { print $2; exit }'
    ) || true

    if [[ -n "$available" && "$available" != "(none)" ]]; then
        LATEST_AVAILABLE_KERNEL="${available%%-*}"
    else
        LATEST_AVAILABLE_KERNEL="unknown"
        SCRAPE_ERROR=1
    fi
}

#-------------------------------------------------------------------------------
# RPM based systems
#-------------------------------------------------------------------------------

detect_rpm_kernel() {

    local running_release
    local latest_installed
    local latest_available

    running_release=$(uname -r)

    #---------------------------------------------------------------------------
    # Running kernel
    #
    # Keep the release exactly as reported by uname, but remove the distribution
    # suffix to make comparison with the installed/available kernel consistent.
    #---------------------------------------------------------------------------

    RUNNING_KERNEL="$running_release"
    RUNNING_KERNEL="${RUNNING_KERNEL%%.el[0-9]*}"
    RUNNING_KERNEL="${RUNNING_KERNEL%%.el[0-9]*.*}"

    #---------------------------------------------------------------------------
    # Latest installed kernel
    #
    # rpm -q --last is already sorted by installation date.
    # We only need the first kernel package.
    #---------------------------------------------------------------------------

    latest_installed=$(
        rpm -q --last kernel 2>/dev/null |
        head -n1
    ) || true

    if [[ -n "$latest_installed" ]]; then

        # First field is:
        # kernel-6.12.0-211.51.1.el10_0.x86_64
        latest_installed="${latest_installed%% *}"

        # Remove kernel-
        latest_installed="${latest_installed#kernel-}"

        # Remove architecture
        latest_installed="${latest_installed%.*}"

        # Remove EL suffix
        latest_installed="${latest_installed%%.el[0-9]*}"

        LATEST_INSTALLED_KERNEL="$latest_installed"

    else

        LATEST_INSTALLED_KERNEL="unknown"
        SCRAPE_ERROR=1

    fi

    #---------------------------------------------------------------------------
    # Latest available kernel
    #
    # dnf list available is the expensive operation.
    # Use repoquery when available because it avoids formatting the complete
    # package list.
    #---------------------------------------------------------------------------

    latest_available=""

    if command -v dnf >/dev/null 2>&1; then

        if command -v dnf5 >/dev/null 2>&1; then

            latest_available=$(
                timeout "$DNF_TIMEOUT" \
                    dnf5 repoquery \
                    --available \
                    --latest-limit=1 \
                    --qf '%{version}-%{release}' \
                    kernel 2>/dev/null |
                head -n1
            ) || true

        else

            latest_available=$(
                timeout "$DNF_TIMEOUT" \
                    dnf repoquery \
                    --available \
                    --latest-limit=1 \
                    --qf '%{version}-%{release}' \
                    kernel 2>/dev/null |
                head -n1
            ) || true

        fi

    elif command -v yum >/dev/null 2>&1; then

        latest_available=$(
            timeout "$DNF_TIMEOUT" \
                yum --quiet list available kernel 2>/dev/null |
            awk '
                /^kernel\./ {
                    print $2
                    exit
                }
            '
        ) || true

    fi

    if [[ -n "$latest_available" ]]; then

        # Remove architecture if repoquery returned it.
        latest_available="${latest_available%%.*.x86_64}"
        latest_available="${latest_available%%.el[0-9]*}"

        LATEST_AVAILABLE_KERNEL="$latest_available"

    else

        # If repositories cannot be queried, use the installed kernel.
        # This avoids reporting an artificial mismatch.
        LATEST_AVAILABLE_KERNEL="$LATEST_INSTALLED_KERNEL"

    fi
}

#-------------------------------------------------------------------------------
# Detect reboot requirement
#-------------------------------------------------------------------------------

detect_reboot_required() {

    # Debian / Ubuntu
    if [[ -f /var/run/reboot-required ]]; then
        REBOOT=1
        REASON="needs_restarting"
    fi

    # RHEL / CentOS / Rocky / Oracle
    if [[ -x /bin/needs-restarting ]]; then

        if /bin/needs-restarting -r >/dev/null 2>&1; then
            :
        else
            needs_restarting_rc=$?

            # needs-restarting -r returns non-zero when a reboot is required.
            # A normal reboot-required result is not a scrape error.
            if [[ "$needs_restarting_rc" -eq 1 ]]; then
                REBOOT=1
                REASON="needs_restarting"
            else
                SCRAPE_ERROR=1
            fi
        fi
    fi
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------

require_root

REBOOT=0
KERNEL_MISMATCH="false"
REASON="none"
SCRAPE_ERROR=0

RUNNING_KERNEL="unknown"
LATEST_INSTALLED_KERNEL="unknown"
LATEST_AVAILABLE_KERNEL="unknown"

#-------------------------------------------------------------------------------
# Detect distribution
#-------------------------------------------------------------------------------

if command -v dpkg-query >/dev/null 2>&1; then

    detect_debian_kernel

elif command -v rpm >/dev/null 2>&1; then

    detect_rpm_kernel

else

    SCRAPE_ERROR=1

fi

#-------------------------------------------------------------------------------
# Detect reboot requirement
#-------------------------------------------------------------------------------

detect_reboot_required

#-------------------------------------------------------------------------------
# Kernel mismatch
#-------------------------------------------------------------------------------

if [[ "$LATEST_AVAILABLE_KERNEL" != "unknown" &&
      "$RUNNING_KERNEL" != "unknown" &&
      "$RUNNING_KERNEL" != "$LATEST_AVAILABLE_KERNEL" ]]
then
    KERNEL_MISMATCH="true"
fi

if [[ "$LATEST_INSTALLED_KERNEL" != "unknown" &&
      "$RUNNING_KERNEL" != "unknown" &&
      "$RUNNING_KERNEL" != "$LATEST_INSTALLED_KERNEL" ]]
then
    KERNEL_MISMATCH="true"
fi

# If a reboot is already required and the kernel is different,
# expose the more precise reason.
if [[ "$KERNEL_MISMATCH" == "true" &&
      "$REASON" == "needs_restarting" ]]
then
    REASON="kernel_mismatch"
fi

#-------------------------------------------------------------------------------
# Metric values
#-------------------------------------------------------------------------------

if [[ "$KERNEL_MISMATCH" == "true" ]]; then
    MISMATCH_VALUE=1
else
    MISMATCH_VALUE=0
fi

INSTALLED_VALUE=0

if [[ "$LATEST_INSTALLED_KERNEL" != "unknown" &&
      "$LATEST_AVAILABLE_KERNEL" != "unknown" &&
      "$LATEST_AVAILABLE_KERNEL" != "$LATEST_INSTALLED_KERNEL" ]]
then
    INSTALLED_VALUE=1
fi

#-------------------------------------------------------------------------------
# Prometheus metrics
#-------------------------------------------------------------------------------

printf '%s\n' \
    '# HELP vm_pending_reboot Check if a pending reboot is required' \
    '# TYPE vm_pending_reboot gauge'

printf 'vm_pending_reboot{reason="%s"} %d\n' \
    "$REASON" \
    "$REBOOT"

printf '%s\n' \
    '# HELP vm_pending_reboot_scrape_error 1 if an error occurred during detection' \
    '# TYPE vm_pending_reboot_scrape_error gauge'

printf 'vm_pending_reboot_scrape_error %d\n' \
    "$SCRAPE_ERROR"

printf '%s\n' \
    '# HELP vm_pending_kernel Check if a new kernel is available' \
    '# TYPE vm_pending_kernel gauge'

printf 'vm_pending_kernel{running_kernel="%s",latest_installed_kernel="%s",latest_available_kernel="%s"} %d\n' \
    "$RUNNING_KERNEL" \
    "$LATEST_INSTALLED_KERNEL" \
    "$LATEST_AVAILABLE_KERNEL" \
    "$MISMATCH_VALUE"

printf '%s\n' \
    '# HELP node_kernel_expected Check available version' \
    '# TYPE node_kernel_expected gauge'

printf 'node_kernel_expected{latest_available_kernel="%s"} %d\n' \
    "$LATEST_AVAILABLE_KERNEL" \
    "$MISMATCH_VALUE"

printf '%s\n' \
    '# HELP node_kernel_installed Check available version' \
    '# TYPE node_kernel_installed gauge'

printf 'node_kernel_installed{latest_installed_kernel="%s"} %d\n' \
    "$LATEST_INSTALLED_KERNEL" \
    "$INSTALLED_VALUE"

exit 0
