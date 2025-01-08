#!/bin/bash

if [ -z "$USER" ] ; then
    USER=$(whoami)
fi
if [ "$USER" != "root" ] ; then
    echo "$(basename $0) must be run as root!"
    exit 2
fi

PROBLEM_COUNT=0

### Check

### node_exporter
NODE_VERSION=0
if [ -f /usr/local/bin/node_exporter ]; then
	NODE_VERSION=$(node_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
fi
### chrony_exporter
CHRONY_VERSION=0
if [ -f /usr/local/bin/node_exporter ]; then
	CHRONY_VERSION=$(chrony_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
fi

echo "# HELP node_exporter_version Check node_exporter binary version"
echo "# TYPE node_exporter_version gauge"
echo node_exporter_version $NODE_VERSION

echo "# HELP chrony_exporter_version Check chrony_exporter binary version"
echo "# TYPE chrony_exporter_version gauge"
echo chrony_exporter_version $CHRONY_VERSION

### end
if [ "$PROBLEM_COUNT" -ne "0" ] ; then
    exit 1
fi
exit 0
