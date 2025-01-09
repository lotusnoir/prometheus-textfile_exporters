#!/bin/bash

# Add proxy variables 
if [ -f /etc/profile.d/proxy.sh ]; then
    source /etc/profile.d/proxy.sh
fi

#Check user is root
if [ -z "$USER" ] ; then USER=$(whoami); fi
if [ "$USER" != "root" ] ; then
    echo "$(basename $0) must be run as root!"
    exit 2
fi

# Set global variables
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PROBLEM_COUNT=0
LATEST_CHECK=1

#######################################
### Checks

### node_exporter
NODE_VERSION=0
NODE_VERSION_LATEST=0
if [ -f /usr/local/bin/node_exporter ]; then
	NODE_VERSION=$(/usr/local/bin/node_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	if [ "$LATEST_CHECK" -eq "1" ] ; then
		NODE_VERSION_LATEST=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
		if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	fi
fi
echo "# HELP node_exporter_version Check node_exporter binary version"
echo "# TYPE node_exporter_version gauge"
echo "node_exporter_version $NODE_VERSION"
echo "# HELP node_exporter_version_latest Check node_exporter binary latest version on repo project"
echo "# TYPE node_exporter_version_latest gauge"
echo "node_exporter_version_latest $NODE_VERSION_LATEST"

### chrony_exporter
CHRONY_VERSION=0
CHRONY_VERSION_LATEST=0
if [ -f /usr/local/bin/node_exporter ]; then
	CHRONY_VERSION=$(/usr/local/bin/chrony_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	if [ "$LATEST_CHECK" -eq "1" ] ; then
		CHRONY_VERSION_LATEST=$(curl -s https://api.github.com/repos/SuperQ/chrony_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
		if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	fi
fi
echo "# HELP chrony_exporter_version Check chrony_exporter binary version"
echo "# TYPE chrony_exporter_version gauge"
echo "chrony_exporter_version $CHRONY_VERSION"
echo "# HELP chrony_exporter_version_latest Check chrony_exporter binary latest version on repo project"
echo "# TYPE chrony_exporter_version_latest gauge"
echo "chrony_exporter_version_latest $CHRONY_VERSION_LATEST"

### conntrack_exporter
CONNTRACK_VERSION=0
CONNTRACK_VERSION_LATEST=0
if [ -f /usr/local/bin/conntrack_exporter ]; then
	#CONNTRACK_VERSION=$(/usr/local/bin/conntrack_exporter --version | head -1| awk '{print $3}')
	CONNTRACK_VERSION="0.3.1"
        #if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	if [ "$LATEST_CHECK" -eq "1" ] ; then
		CONNTRACK_VERSION_LATEST=$(curl -s https://api.github.com/repos/hiveco/conntrack_exporter/releases/latest | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
		if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	fi
fi
echo "# HELP conntrack_exporter_version Check conntrack_exporter binary version"
echo "# TYPE conntrack_exporter_version gauge"
echo "conntrack_exporter_version $CONNTRACK_VERSION"
echo "# HELP conntrack_exporter_version_latest Check conntrack_exporter binary latest version on repo project"
echo "# TYPE conntrack_exporter_version_latest gauge"
echo "conntrack_exporter_version_latest $CONNTRACK_VERSION_LATEST"

### blackbox_exporter
BLACKBOX_VERSION=0
BLACKBOX_VERSION_LATEST=0
if [ -f /usr/local/bin/blackbox_exporter ]; then
	BLACKBOX_VERSION=$(/usr/local/bin/blackbox_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	if [ "$LATEST_CHECK" -eq "1" ] ; then
		BLACKBOX_VERSION_LATEST=$(curl -s https://api.github.com/repos/prometheus/blackbox_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
		if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	fi
fi
echo "# HELP blackbox_exporter_version Check blackbox_exporter binary version"
echo "# TYPE blackbox_exporter_version gauge"
echo "blackbox_exporter_version $BLACKBOX_VERSION"
echo "# HELP blackbox_exporter_version_latest Check blackbox_exporter binary latest version on repo project"
echo "# TYPE blackbox_exporter_version_latest gauge"
echo "blackbox_exporter_version_latest $BLACKBOX_VERSION_LATEST"

### fluentbit
FLUENTBIT_VERSION=0
FLUENTBIT_VERSION_LATEST=0
if [ -f /opt/fluent-bit/bin/fluent-bit ]; then
	FLUENTBIT_VERSION=$(/opt/fluent-bit/bin/fluent-bit --version | head -1| awk '{print $3}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	if [ "$LATEST_CHECK" -eq "1" ] ; then
		FLUENTBIT_VERSION_LATEST=$(curl -s https://api.github.com/repos/fluent/fluent-bit/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
		if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	fi
fi
echo "# HELP fluentbit_exporter_version Check fluentbit_exporter binary version"
echo "# TYPE fluentbit_exporter_version gauge"
echo "fluentbit_exporter_version $FLUENTBIT_VERSION"
echo "# HELP fluentbit_exporter_version_latest Check fluentbit_exporter binary latest version on repo project"
echo "# TYPE fluentbit_exporter_version_latest gauge"
echo "fluentbit_exporter_version_latest $FLUENTBIT_VERSION_LATEST"

### cadvisor
CADVISOR_VERSION=0
CADVISOR_VERSION_LATEST=0
if [ -f /opt/cadvisor/cadvisor ]; then
	CADVISOR_VERSION=$(/opt/cadvisor/cadvisor --version | head -1| awk '{print $3}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	if [ "$LATEST_CHECK" -eq "1" ] ; then
		CADVISOR_VERSION_LATEST=$(curl -s https://api.github.com/repos/google/cadvisor/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
		if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	fi
fi
echo "# HELP cadvisor_exporter_version Check cadvisor_exporter binary version"
echo "# TYPE cadvisor_exporter_version gauge"
echo "cadvisor_exporter_version $CADVISOR_VERSION"
echo "# HELP cadvisor_exporter_version_latest Check cadvisor_exporter binary latest version on repo project"
echo "# TYPE cadvisor_exporter_version_latest gauge"
echo "cadvisor_exporter_version_latest $CADVISOR_VERSION_LATEST"

### consul
CONSUL_VERSION=0
CONSUL_VERSION_LATEST=0
if [ -f /usr/bin/consul ]; then
	CONSUL_VERSION=$(/usr/bin/consul --version | head -1| awk '{print $2}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	if [ "$LATEST_CHECK" -eq "1" ] ; then
		CONSUL_VERSION_LATEST=$(curl -s https://api.github.com/repos/hashicorp/consul/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
		if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	fi
fi
echo "# HELP consul_version Check consul binary version"
echo "# TYPE consul_version gauge"
echo "consul_version $CONSUL_VERSION"
echo "# HELP consul_version_latest Check consul binary latest version on repo project"
echo "# TYPE consul_version_latest gauge"
echo "consul_version_latest $CONSUL_VERSION_LATEST"



### end
if [ "$PROBLEM_COUNT" -ne "0" ] ; then
    exit 1
fi
exit 0
