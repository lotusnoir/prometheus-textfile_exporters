#!/usr/bin/env bash
#===============================================================================
#         FILE:  vm_logs_stats.sh
#
#        USAGE:  ./vm_logs_stats.sh
#
#  DESCRIPTION:  Export log file metrics (size in KB, last modification age in
#                days, and error/warning line counts) for Prometheus
#                node_exporter textfile collector.
#
#  REQUIREMENTS: find, grep, timeout, date
#       AUTHOR:  Philippe LEAL (philippe.leal@gmail.com)
#      VERSION: 2.2
#      CREATED: 2025-10-01
#===============================================================================

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------

LOG_DIR="${LOG_DIR:-/var/log}"

ERROR_PATTERN="${LOG_ERROR_PATTERNS:-[eE]rror|[wW]arn|[fF]ail|[iI]nvalid|[dD]enied|[fF]orbidden|[tT]imeout|not found|[cC]ritical}"

LOG_EXCLUDE_DIRS="${LOG_EXCLUDE_DIRS:-}"

LOG_FILE_TIMEOUT="${LOG_FILE_TIMEOUT:-5}"

# Number of files processed simultaneously.
# Keep this relatively low because log scanning is I/O intensive.
MAX_JOBS="${MAX_JOBS:-10}"

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
# Main
#-------------------------------------------------------------------------------

require_root

SCRAPE_ERROR=0

#-------------------------------------------------------------------------------
# Prometheus headers
#-------------------------------------------------------------------------------

printf '%s\n' \
    '# HELP vm_log_files_stats_size_kb Size of log files in KB' \
    '# TYPE vm_log_files_stats_size_kb gauge' \
    '# HELP vm_log_files_stats_last_modification_days Number of days since last modification of log files' \
    '# TYPE vm_log_files_stats_last_modification_days gauge' \
    '# HELP vm_log_files_stats_count Number of log files found' \
    '# TYPE vm_log_files_stats_count gauge' \
    '# HELP vm_log_files_stats_scrape_error 1 if an error occurred or no files found, 0 otherwise' \
    '# TYPE vm_log_files_stats_scrape_error gauge' \
    '# HELP vm_log_files_stats_error_lines Number of error/warning lines detected in log files' \
    '# TYPE vm_log_files_stats_error_lines counter'

#-------------------------------------------------------------------------------
# Current epoch
#-------------------------------------------------------------------------------

now_epoch=$(date +%s)

#-------------------------------------------------------------------------------
# Validate MAX_JOBS
#-------------------------------------------------------------------------------

if ! [[ "$MAX_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    MAX_JOBS=10
fi

#-------------------------------------------------------------------------------
# Temporary directory
#-------------------------------------------------------------------------------

TMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

#-------------------------------------------------------------------------------
# Build find command
#
# Metadata is retrieved directly by find:
#
#   %s       apparent size in bytes
#   %T@      modification epoch
#   %TY...   modification date
#   %u       owner
#   %m       permissions
#   %p       pathname
#
# NUL terminates each complete record.
#-------------------------------------------------------------------------------

FIND_CMD=(find "$LOG_DIR")

for excl in $LOG_EXCLUDE_DIRS; do
    FIND_CMD+=(
        -path "$excl"
        -prune
        -o
    )
done

FIND_CMD+=(
    -type f
    \(
        -name "*.log"
        -o -name "syslog"
        -o -name "btmp"
        -o -name "wtmp"
        -o -name "lastlog"
    \)
    ! -regex '.*\.[0-9]+\.log$'
    -printf '%s|%T@|%TY-%Tm-%Td|%u|%m|%p\0'
)

#-------------------------------------------------------------------------------
# Find files
#-------------------------------------------------------------------------------

mapfile -d '' LOG_FILES < <(
    "${FIND_CMD[@]}" |
    sort -z -t '|' -k6,6
)

file_count=${#LOG_FILES[@]}

printf 'vm_log_files_stats_count %d\n' "$file_count"

if (( file_count == 0 )); then
    printf 'vm_log_files_stats_scrape_error 1\n'
    exit 0
fi

#-------------------------------------------------------------------------------
# Process one file
#
# Result is written into result_<index>.
# Error status is written into error_<index>.
#
# This avoids stdout synchronization problems between background processes.
#-------------------------------------------------------------------------------

process_file() {
    local index="$1"
    local data="$2"

    local size_bytes
    local mod_epoch
    local mod_date
    local owner
    local mode
    local file

    local size_kb
    local mod_days
    local parent_dir
    local dir_label
    local errors

    local result_file
    local error_file

    result_file="$TMP_DIR/result_${index}"
    error_file="$TMP_DIR/error_${index}"

    #---------------------------------------------------------------------------
    # Parse metadata
    #---------------------------------------------------------------------------

    IFS='|' read -r size_bytes mod_epoch mod_date owner mode file <<< "$data"

    # %T@ returns fractional seconds.
    mod_epoch="${mod_epoch%%.*}"

    # Same rounding behavior as:
    # du -k --apparent-size --block-size=1K
    size_kb=$(( (size_bytes + 1023) / 1024 ))

    # Days since modification
    mod_days=$(( (now_epoch - mod_epoch) / 86400 ))

    #---------------------------------------------------------------------------
    # Directory label
    #---------------------------------------------------------------------------

    parent_dir="${file%/*}"

    if [[ "$parent_dir" != "$LOG_DIR" ]]; then
        dir_label=",directory=\"${parent_dir##*/}\""
    else
        dir_label=""
    fi

    #---------------------------------------------------------------------------
    # Count error/warning lines
    #
    # grep -Eic:
    #   -E = extended regexp
    #   -i = case insensitive
    #   -c = count matching lines
    #
    # grep returns:
    #   0 = matches found
    #   1 = no matches
    #   2 = error
    #
    # Both 0 and 1 are valid results, so handle them explicitly.
    #---------------------------------------------------------------------------

    errors=0

    if timeout "${LOG_FILE_TIMEOUT}s" \
        grep -Eic "$ERROR_PATTERN" "$file" > "$TMP_DIR/count_${index}" 2>/dev/null
    then
        errors=$(<"$TMP_DIR/count_${index}")
    else
        grep_status=$?

        if [[ "$grep_status" -eq 1 ]]; then
            # No matching lines.
            errors=0
        else
            # Timeout or actual read/grep error.
            errors=0
            printf '1\n' > "$error_file"
        fi
    fi

    rm -f "$TMP_DIR/count_${index}"

    #---------------------------------------------------------------------------
    # Generate metrics
    #---------------------------------------------------------------------------

    {
        printf 'vm_log_files_stats_size_kb{file="%s",last_mod_date="%s",owner="%s",mode="%s"%s} %s\n' \
            "$file" \
            "$mod_date" \
            "$owner" \
            "$mode" \
            "$dir_label" \
            "$size_kb"

        printf 'vm_log_files_stats_last_modification_days{file="%s",last_mod_date="%s",owner="%s",mode="%s"%s} %s\n' \
            "$file" \
            "$mod_date" \
            "$owner" \
            "$mode" \
            "$dir_label" \
            "$mod_days"

        printf 'vm_log_files_stats_error_lines{file="%s",last_mod_date="%s",owner="%s",mode="%s"%s} %s\n' \
            "$file" \
            "$mod_date" \
            "$owner" \
            "$mode" \
            "$dir_label" \
            "$errors"
    } > "$result_file"
}

#-------------------------------------------------------------------------------
# Parallel worker pool
#
# Unlike the previous version, this does NOT wait for a whole batch.
# As soon as a worker finishes, another file can be started.
#-------------------------------------------------------------------------------

declare -a PIDS=()
declare -a PID_INDEX=()

next_file=1
running=0

while (( next_file <= file_count || running > 0 )); do

    #---------------------------------------------------------------------------
    # Fill available worker slots
    #---------------------------------------------------------------------------

    while (( next_file <= file_count && running < MAX_JOBS )); do

        process_file \
            "$next_file" \
            "${LOG_FILES[$((next_file - 1))]}" &

        pid=$!

        PIDS+=("$pid")
        PID_INDEX+=("$next_file")

        running=$((running + 1))
        next_file=$((next_file + 1))
    done

    #---------------------------------------------------------------------------
    # Wait for one worker
    #
    # wait -n is available on modern Bash versions.
    #---------------------------------------------------------------------------

    if (( running > 0 )); then

        if wait -n 2>/dev/null; then
            :
        else
            # A worker can return non-zero because of an error.
            # We don't stop processing other files.
            SCRAPE_ERROR=1
        fi

        running=$((running - 1))
    fi
done

#-------------------------------------------------------------------------------
# Check worker errors
#-------------------------------------------------------------------------------

if compgen -G "$TMP_DIR/error_*" > /dev/null; then
    SCRAPE_ERROR=1
fi

#-------------------------------------------------------------------------------
# Output results in original sorted file order
#-------------------------------------------------------------------------------

for ((i = 1; i <= file_count; i++)); do

    result_file="$TMP_DIR/result_${i}"

    if [[ -f "$result_file" ]]; then
        cat "$result_file"
    else
        SCRAPE_ERROR=1
    fi

done

#-------------------------------------------------------------------------------
# Scrape error
#-------------------------------------------------------------------------------

printf 'vm_log_files_stats_scrape_error %d\n' "$SCRAPE_ERROR"

exit 0
