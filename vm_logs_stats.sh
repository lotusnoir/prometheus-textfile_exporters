#!/usr/bin/env bash
#===============================================================================
#         FILE:  vm_logs_stats.sh
#
#        USAGE:  ./vm_logs_stats.sh
#
#  DESCRIPTION:  Export log file metrics (size in KB, last modification age in days)
#                for Prometheus node_exporter textfile collector.
#
#  REQUIREMENTS: find, du, stat, date
#       AUTHOR:  Philippe LEAL (lotus.noir@gmail.com)
#      VERSION:  1.3
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

# Default log directory, override with environment variable if set
LOG_DIR="${LOG_DIR:-/var/log}"

SCRAPE_ERROR=0
FOUND_FILES=0

# Prometheus metric headers
echo "# HELP vm_log_files_stats_size_kb Size of log files in KB"
echo "# TYPE vm_log_files_stats_size_kb gauge"
echo "# HELP vm_log_files_stats_last_modification_days Number of days since last modification of log files"
echo "# TYPE vm_log_files_stats_last_modification_days gauge"
echo "# HELP vm_log_files_stats_count Number of log files found"
echo "# TYPE vm_log_files_stats_count gauge"
echo "# HELP vm_log_files_stats_scrape_error 1 if an error occurred or no files found, 0 otherwise"
echo "# TYPE vm_log_files_stats_scrape_error gauge"

# Current epoch (for calculating staleness)
now_epoch=$(date +%s)

# Read log files into an array safely using null-delimited mapfile and sort
mapfile -d '' LOG_FILES < <(find "$LOG_DIR" -type f \
    \( -name "*.log" -o -name "syslog" -o -name "btmp" -o -name "wtmp" -o -name "lastlog" \) \
    ! -regex '.*\.[0-9]+\.log$' -print0 | sort -z)

# Number of files found
file_count=${#LOG_FILES[@]}
echo "vm_log_files_stats_count $file_count"

# If no files found, mark scrape error
if [ "$file_count" -eq 0 ]; then
    SCRAPE_ERROR=1
fi

# Loop over log files
for file in "${LOG_FILES[@]}"; do
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

    # Get file owner and permissions
    owner=$(stat -c "%U" "$file" 2>/dev/null || echo "unknown")
    mode=$(stat -c "%a" "$file" 2>/dev/null || echo "unknown")

    # Determine immediate parent directory relative to LOG_DIR
    parent_dir=$(dirname "$file")
    if [ "$parent_dir" != "$LOG_DIR" ]; then
        dir_label=",directory=\"$(basename "$parent_dir")\""
    else
        dir_label=""
    fi

    # Prometheus metrics with optional directory label
    echo "vm_log_files_stats_size_kb{file=\"$file\",last_mod_date=\"$mod_date\",owner=\"$owner\",mode=\"$mode\"$dir_label} $size"
    echo "vm_log_files_stats_last_modification_days{file=\"$file\",last_mod_date=\"$mod_date\",owner=\"$owner\",mode=\"$mode\"$dir_label} $mod_days"
done

# If no files processed (just in case)
if [ "$FOUND_FILES" -eq 0 ]; then
    SCRAPE_ERROR=1
fi

# Final scrape error metric
echo "vm_log_files_stats_scrape_error $SCRAPE_ERROR"

# Always exit 0 for Prometheus
exit 0
