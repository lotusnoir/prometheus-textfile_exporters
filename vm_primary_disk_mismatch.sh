#!/usr/bin/env bash
#===============================================================================
#         FILE:  check_vm_log_files_stats.sh
#
#        USAGE:  ./check_vm_log_files_stats.sh
#
#  DESCRIPTION:  Export log file metrics (size in KB, last modification age in days)
#                for Prometheus node_exporter textfile collector.
#
#  REQUIREMENTS: find, du, stat, date
#       AUTHOR:  Philippe
#      VERSION:  1.6
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

#--- Main ----------------------------------------------------------------------
require_root

LOG_DIR="/var/log"
SCRAPE_ERROR=0
FOUND_FILES=0

echo "# HELP vm_log_files_stats_size_kb Size of log files in KB"
echo "# TYPE vm_log_files_stats_size_kb gauge"
echo "# HELP vm_log_files_stats_last_modification_days Number of days since last modification of log files"
echo "# TYPE vm_log_files_stats_last_modification_days gauge"
echo "# HELP vm_log_files_stats_scrape_error 1 if an error occurred or no files found, 0 otherwise"
echo "# TYPE vm_log_files_stats_scrape_error gauge"

# Current epoch (for calculating staleness)
now_epoch=$(date +%s)

# Use null-delimited find to avoid issues with spaces
if ! find "$LOG_DIR" -type f \
    \( -name "*.log" -o -name "syslog" -o -name "btmp" -o -name "wtmp" -o -name "lastlog" \) \
    ! -regex '.*\.[0-9]+\.log$' -print0 |
while IFS= read -r -d '' file; do
    FOUND_FILES=1
    # Get file size in KB
    if ! size=$(du -k --apparent-size --block-size=1K "$file" 2>/dev/null | cut -f1); then
        SCRAPE_ERROR=1
        continue
    fi

    # Get last modification epoch
    if ! mod_epoch=$(stat -c "%Y" "$file" 2>/dev/null); then
        SCRAPE_ERROR=1
        continue
    fi

    # Calculate age in days
    mod_days=$(( (now_epoch - mod_epoch) / 86400 ))

    # Get last modification date (YYYY-MM-DD) for label
    mod_date=$(stat -c "%y" "$file" 2>/dev/null | cut -d ' ' -f1 || echo "unknown")

    # Prometheus metrics
    echo "vm_log_files_stats_size_kb{file=\"$file\",last_mod_date=\"$mod_date\"} $size"
    echo "vm_log_files_stats_last_modification_days{file=\"$file\",last_mod_date=\"$mod_date\"} $mod_days"
done
then
    SCRAPE_ERROR=1
fi

# If no files were found, also mark scrape error
if [ "$FOUND_FILES" -eq 0 ]; then
    SCRAPE_ERROR=1
fi

# Final scrape error metric
echo "vm_log_files_stats_scrape_error $SCRAPE_ERROR"

# Always exit 0 for Prometheus
exit 0
