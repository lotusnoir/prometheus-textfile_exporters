#!/bin/bash


if [ -e "/usr/sbin/tune2fs" ]; then 
  disk=$(df | awk '$NF == "/" || $NF == "/boot" { print $1}' | grep a1)
  if [ "$disk" == "" ]; then exit 1; fi
  date_string=$(sudo tune2fs -l $disk | grep 'Filesystem created' | sed 's/Filesystem created: //' | sed 's/^[[:space:]]*//')
  timestamp=$(date -d "$date_string" +%s)

  echo "# HELP vm_creation_time_seconds Return timestamp since vm was created"
  echo "# TYPE vm_creation_time_seconds time"
  echo "vm_creation_time_seconds{date=\"$date_string\"} $timestamp"
fi
