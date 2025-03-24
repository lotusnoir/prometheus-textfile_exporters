#!/bin/bash

LOG_DIR="/var/log"
LOG_FILES=$(find "$LOG_DIR" -type f \( -name "*.log" -o -name "syslog" -o -name "btmp" -o -name "wtmp" -o -name "lastlog" \) | grep -v ".[0-9].log" | sort -u)

# Check if any log files were found
if ! [ -z "$LOG_FILES" ]; then
    # Loop through each log file and display its details
    for file in $LOG_FILES; do
        # Get file size in KB
        size=$(du -k "$file" | cut -f1)
        # Get last access date (YYYY-MM-DD)
        access_date=$(stat -c "%x" "$file" | cut -d ' ' -f1)
        # Print the file path, size, and last access date
        echo "log_files_present{file=\"$file\", access_date=\"$access_date\"} $size"
    done
fi
