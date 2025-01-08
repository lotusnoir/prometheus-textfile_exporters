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
NODE_VERSION_LATEST=0
if [ -f /usr/local/bin/node_exporter ]; then
	NODE_VERSION=$(/usr/local/bin/node_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	NODE_VERSION_LATEST=$(/usr/bin/curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
fi
echo "# HELP node_exporter_version Check node_exporter binary version"
echo "# TYPE node_exporter_version gauge"
echo node_exporter_version $NODE_VERSION
echo "# HELP node_exporter_version_latest Check node_exporter binary latest version on repo project"
echo "# TYPE node_exporter_version_latest gauge"
echo node_exporter_version_latest $NODE_VERSION_LATEST

### chrony_exporter
CHRONY_VERSION=0
CHRONY_VERSION_LATEST=0
if [ -f /usr/local/bin/node_exporter ]; then
	CHRONY_VERSION=$(/usr/local/bin/chrony_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CHRONY_VERSION_LATEST=$(/usr/bin/curl -s https://api.github.com/repos/SuperQ/chrony_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
fi
echo "# HELP chrony_exporter_version Check chrony_exporter binary version"
echo "# TYPE chrony_exporter_version gauge"
echo chrony_exporter_version $CHRONY_VERSION
echo "# HELP chrony_exporter_version_latest Check chrony_exporter binary latest version on repo project"
echo "# TYPE chrony_exporter_version_latest gauge"
echo chrony_exporter_version_latest $CHRONY_VERSION_LATEST

### conntrack_exporter
CONNTRACK_VERSION=0
CONNTRACK_VERSION_LATEST=0
if [ -f /usr/local/bin/conntrack_exporter ]; then
	#CONNTRACK_VERSION=$(/usr/local/bin/conntrack_exporter --version | head -1| awk '{print $3}')
        #if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CONNTRACK_VERSION_LATEST=$(/usr/bin/curl -s https://api.github.com/repos/hiveco/conntrack_exporter/releases/latest | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
fi
echo "# HELP conntrack_exporter_version Check conntrack_exporter binary version"
echo "# TYPE conntrack_exporter_version gauge"
echo conntrack_exporter_version $CONNTRACK_VERSION
echo "# HELP conntrack_exporter_version_latest Check conntrack_exporter binary latest version on repo project"
echo "# TYPE conntrack_exporter_version_latest gauge"
echo conntrack_exporter_version_latest $CONNTRACK_VERSION_LATEST

### blackbox_exporter
BLACKBOX_VERSION=0
BLACKBOX_VERSION_LATEST=0
if [ -f /usr/local/bin/blackbox_exporter ]; then
	BLACKBOX_VERSION=$(/usr/local/bin/blackbox_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	BLACKBOX_VERSION_LATEST=$(/usr/bin/curl -s https://api.github.com/repos/prometheus/blackbox_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
fi
echo "# HELP blackbox_exporter_version Check blackbox_exporter binary version"
echo "# TYPE blackbox_exporter_version gauge"
echo blackbox_exporter_version $BLACKBOX_VERSION
echo "# HELP blackbox_exporter_version_latest Check blackbox_exporter binary latest version on repo project"
echo "# TYPE blackbox_exporter_version_latest gauge"
echo blackbox_exporter_version_latest $BLACKBOX_VERSION_LATEST



### end
if [ "$PROBLEM_COUNT" -ne "0" ] ; then
    exit 1
fi
exit 0
