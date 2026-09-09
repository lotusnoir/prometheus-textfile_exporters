#!/usr/bin/env bash

#===============================================================================
#         FILE:  vm_creation_date.sh
#
#        USAGE:  ./vm_creation_date.sh
#
#  DESCRIPTION: Export filesystem creation date as Prometheus metric.
#                Uses /boot filesystem because root may be XFS.
#
#  REQUIREMENTS: bash, findmnt, tune2fs, date
#       AUTHOR:  Philippe
#      VERSION: 2.0
#===============================================================================

TUNE2FS="/usr/sbin/tune2fs"
METRIC_NAME="vm_creation_time_seconds"
MOUNTPOINT="/boot"

# tune2fs unavailable
if [[ ! -x "$TUNE2FS" ]]; then
    exit 0
fi

# Get /boot filesystem and type
read -r disk fstype < <(findmnt -n -o SOURCE,FSTYPE "$MOUNTPOINT")

if [[ -z "$disk" || -z "$fstype" ]]; then
    exit 1
fi

# tune2fs only supports ext2/ext3/ext4
case "$fstype" in
    ext2|ext3|ext4)
        ;;
    *)
        exit 0
        ;;
esac

# Get filesystem creation date
date_string=$(
    "$TUNE2FS" -l "$disk" |
    awk '/^Filesystem created:/ {
        sub(/^[^:]*:[[:space:]]*/, "")
        print
        exit
    }'
)

if [[ -z "$date_string" ]]; then
    exit 1
fi

timestamp=$(date -d "$date_string" +%s)

echo "# HELP ${METRIC_NAME} Return timestamp since vm was created"
echo "# TYPE ${METRIC_NAME} gauge"
echo "${METRIC_NAME}{date=\"$date_string\"} $timestamp"

exit 0
