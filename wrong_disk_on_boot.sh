#!/bin/bash

if [ -z "$USER" ] ; then
    USER=$(whoami)
fi
if [ "$USER" != "root" ] ; then
    echo "$(basename "$0") must be run as root!"
    exit 2
fi

PROBLEM_COUNT=0
PRIMARY_DISK_CODE=0
PRIMARY_DISK_NAME=$(df | awk '$NF == "/" || $NF == "/boot" { print $1}' | grep -E "da[0-9]")
if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
PRIMARY_DISK=$(echo "$PRIMARY_DISK_NAME" | grep -c -E "da[0-9]")
if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

if [ "$PRIMARY_DISK" -eq 0 ]; then
    PRIMARY_DISK_CODE=1
fi

echo "# HELP node_wrong_disk_on_boot Check if a letter on boot disk"
echo "# TYPE node_wrong_disk_on_boot gauge"
if [ -z "$PRIMARY_DISK_NAME"]; then
	echo node_wrong_disk_on_boot $PRIMARY_DISK_CODE
else
	echo "node_wrong_disk_on_boot{primary_disk=\"$PRIMARY_DISK_NAME\"} $PRIMARY_DISK_CODE"
fi

if [ "$PROBLEM_COUNT" -ne "0" ] ; then
    exit 1
fi
exit 0
