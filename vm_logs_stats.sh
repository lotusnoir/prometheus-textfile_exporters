#!/usr/bin/env bash
#===============================================================================
#         FILE:  vm_logs_stats.sh
#
#        USAGE:  ./vm_logs_stats.sh
#
#  DESCRIPTION:  Export log file metrics (size in KB, last modification age in days,
#                and error/warning line counts) for Prometheus node_exporter textfile collector.
#
#  REQUIREMENTS: find, du, stat, date, awk, timeout
#       AUTHOR:  Philippe LEAL (lotus.noir@gmail.com)
#      VERSION:  1.8
#      CREATED:  2025-10-01
#===============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#--- Functions -----------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "$(basename "$0") must be run as root!" >&2
        exit 2
    fi
}

#--- Main ----------------------------------------------------------------------
require_root

LOG_DIR="${LOG_DIR:-/var/log}"

# Default error patterns (override with env var)
ERROR_PATTERN="${LOG_ERROR_PATTERNS:-error:|warning:|fail|invalid|denied|forbidden|timeout|not found|critical}"

# Default excluded dirs (override with env var)
LOG_EXCLUDE_DIRS="${LOG_EXCLUDE_DIRS:-}"

# Timeout for per-file parsing (default 5s)
LOG_FILE_TIMEOUT="${LOG_FILE_TIMEOUT:-5}"

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
echo "# HELP vm_log_files_stats_error_lines Number of error/warning lines detected in log files"
echo "# TYPE vm_log_files_stats_error_lines counter"

# Current epoch
now_epoch=$(date +%s)

# Build find command dynamically with exclusions
FIND_CMD=(find "$LOG_DIR" -type f)
for excl in $LOG_EXCLUDE_DIRS; do
    FIND_CMD+=( -path "$excl" -prune -o )
done
FIND_CMD+=( \( -name "*.log" -o -name "syslog" -o -name "btmp" -o -name "wtmp" -o -name "lastlog" \) )
FIND_CMD+=( ! -regex '.*\.[0-9]+\.log$' -print0 )

# Read log files
mapfile -d '' LOG_FILES < <("${FIND_CMD[@]}" | sort -z)

file_count=${#LOG_FILES[@]}
echo "vm_log_files_stats_count $file_count"

if [ "$file_count" -eq 0 ]; then
    SCRAPE_ERROR=1
fi

for file in "${LOG_FILES[@]}"; do
    FOUND_FILES=1

    # Size
    if ! size=$(du -k --apparent-size --block-size=1K "$file" 2>/dev/null | cut -f1); then
        SCRAPE_ERROR=1
        continue
    fi

    # Last modification epoch
    if ! mod_epoch=$(stat -c "%Y" "$file" 2>/dev/null); then
        SCRAPE_ERROR=1
        continue
    fi

    mod_days=$(( (now_epoch - mod_epoch) / 86400 ))
    mod_date=$(stat -c "%y" "$file" 2>/dev/null | cut -d ' ' -f1 || echo "unknown")
    owner=$(stat -c "%U" "$file" 2>/dev/null || echo "unknown")
    mode=$(stat -c "%a" "$file" 2>/dev/null || echo "unknown")

    parent_dir=$(dirname "$file")
    if [ "$parent_dir" != "$LOG_DIR" ]; then
        dir_label=",directory=\"$(basename "$parent_dir")\""
    else
        dir_label=""
    fi

    # Count error/warning lines with awk + timeout
    if ! errors=$(timeout "$LOG_FILE_TIMEOUT"s awk -v IGNORECASE=1 -v pat="$ERROR_PATTERN" '
        $0 ~ pat {count++}
        END {print count+0}
    ' "$file" 2>/dev/null); then
        errors=0
        SCRAPE_ERROR=1
    fi

    # Prometheus metrics
    echo "vm_log_files_stats_size_kb{file=\"$file\",last_mod_date=\"$mod_date\",owner=\"$owner\",mode=\"$mode\"$dir_label} $size"
    echo "vm_log_files_stats_last_modification_days{file=\"$file\",last_mod_date=\"$mod_date\",owner=\"$owner\",mode=\"$mode\"$dir_label} $mod_days"
    echo "vm_log_files_stats_error_lines{file=\"$file\",last_mod_date=\"$mod_date\",owner=\"$owner\",mode=\"$mode\"$dir_label} $errors"
done

if [ "$FOUND_FILES" -eq 0 ]; then
    SCRAPE_ERROR=1
fi

echo "vm_log_files_stats_scrape_error $SCRAPE_ERROR"

exit 0
