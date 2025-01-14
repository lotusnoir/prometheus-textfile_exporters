#!/bin/bash

# Add proxy variables 
if [ -f /etc/profile.d/proxy.sh ]; then
    source /etc/profile.d/proxy.sh
fi

#Check user is root
if [ -z "$USER" ] ; then USER=$(whoami); fi
if [ "$USER" != "root" ] ; then
    echo "$(basename "$0") must be run as root!"
    exit 2
fi

# Set global variables
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PROBLEM_COUNT=0

#######################################
### Checks
# 0 = no check passed
# 1 = latest check did not passed
# 2 = both check passed
### node_exporter
if [ -f /usr/local/bin/node_exporter ]; then
	NODE_VERSION=$(/usr/local/bin/node_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	NODE_VERSION_LATEST=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP node_exporter_version_comparison Check node_exporter binary version and latest version on repo project"
	echo "# TYPE node_exporter_version_comparison gauge"
	if [ "$(echo "$NODE_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$NODE_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "node_exporter_version_comparison{installed=\"$NODE_VERSION\", latest=\"$NODE_VERSION_LATEST\"} 2"
		else
			echo "node_exporter_version_comparison{installed=\"$NODE_VERSION\"} 1"
		fi
	else
		echo "node_exporter_version_comparison 0"
	fi
fi

### chrony_exporter
if [ -f  /usr/local/bin/chrony_exporter ]; then
	CHRONY_VERSION=$(/usr/local/bin/chrony_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CHRONY_VERSION_LATEST=$(curl -s https://api.github.com/repos/SuperQ/chrony_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP chrony_exporter_version_comparison Check chrony_exporter binary version and latest version on repo project"
	echo "# TYPE chrony_exporter_version_comparison gauge"
	if [ "$(echo "$CHRONY_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$CHRONY_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "chrony_exporter_version_comparison{installed=\"$CHRONY_VERSION\", latest=\"$CHRONY_VERSION_LATEST\"} 2"
		else
			echo "chrony_exporter_version_comparison{installed=\"$CHRONY_VERSION\"} 1"
		fi
	else
		echo "chrony_exporter_version_comparison 0"
	fi
fi

### conntrack_exporter
if [ -f /usr/local/bin/conntrack_exporter ]; then
	CONNTRACK_VERSION="0.3.1"
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CONNTRACK_VERSION_LATEST=$(curl -s https://api.github.com/repos/hiveco/conntrack_exporter/releases/latest | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP conntrack_exporter_version_comparison Check conntrack_exporter binary version and latest version on repo project"
	echo "# TYPE conntrack_exporter_version_comparison gauge"
	if [ "$(echo "$CONNTRACK_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$CONNTRACK_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "conntrack_exporter_version_comparison{installed=\"$CONNTRACK_VERSION\", latest=\"$CONNTRACK_VERSION_LATEST\"} 2"
		else
			echo "conntrack_exporter_version_comparison{installed=\"$CONNTRACK_VERSION\"} 1"
		fi
	else
		echo "conntrack_exporter_version_comparison 0"
	fi

fi

### blackbox_exporter
if [ -f /usr/local/bin/blackbox_exporter ]; then
	BLACKBOX_VERSION=$(/usr/local/bin/blackbox_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	BLACKBOX_VERSION_LATEST=$(curl -s https://api.github.com/repos/prometheus/blackbox_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP blackbox_exporter_version_comparison Check blackbox_exporter binary version and latest version on repo project"
	echo "# TYPE blackbox_exporter_version_comparison gauge"
	if [ "$(echo "$BLACKBOX_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$BLACKBOX_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "blackbox_exporter_version_comparison{installed=\"$BLACKBOX_VERSION\", latest=\"$BLACKBOX_VERSION_LATEST\"} 2"
		else
			echo "blackbox_exporter_version_comparison{installed=\"$BLACKBOX_VERSION\"} 1"
		fi
	else
		echo "blackbox_exporter_version_comparison 0"
	fi
fi

### fluentbit
if [ -f /opt/fluent-bit/bin/fluent-bit ]; then
	FLUENTBIT_VERSION=$(/opt/fluent-bit/bin/fluent-bit --version | head -1| awk '{print $3}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	FLUENTBIT_VERSION_LATEST=$(curl -s https://api.github.com/repos/fluent/fluent-bit/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP fluentbit_exporter_version_comparison Check fluentbit_exporter binary version and latest version on repo project"
	echo "# TYPE fluentbit_exporter_version_comparison gauge"
	if [ "$(echo "$FLUENTBIT_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$FLUENTBIT_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "fluentbit_exporter_version_comparison{installed=\"$FLUENTBIT_VERSION\", latest=\"$FLUENTBIT_VERSION_LATEST\"} 2"
		else
			echo "fluentbit_exporter_version_comparison{installed=\"$FLUENTBIT_VERSION\"} 1"
		fi
	else
		echo "fluentbit_exporter_version_comparison 0"
	fi

fi

### cadvisor
if [ -f /opt/cadvisor/cadvisor ]; then
	CADVISOR_VERSION=$(/opt/cadvisor/cadvisor --version | head -1| awk '{print $3}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CADVISOR_VERSION_LATEST=$(curl -s https://api.github.com/repos/google/cadvisor/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP cadvisor_exporter_version_comparison Check cadvisor_exporter binary version and latest version on repo project"
	echo "# TYPE cadvisor_exporter_version_comparison gauge"
	if [ "$(echo "$CADVISOR_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$CADVISOR_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "cadvisor_exporter_version_comparison{installed=\"$CADVISOR_VERSION\", latest=\"$CADVISOR_VERSION_LATEST\"} 2"
		else
			echo "cadvisor_exporter_version_comparison{installed=\"$CADVISOR_VERSION\"} 1"
		fi
	else
		echo "cadvisor_exporter_version_comparison 0"
	fi

fi

### consul
if [ -f /usr/bin/consul ]; then
	CONSUL_VERSION=$(/usr/bin/consul --version | head -1| awk '{print $2}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CONSUL_VERSION_LATEST=$(curl -s https://api.github.com/repos/hashicorp/consul/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP consul_exporter_version_comparison Check consul_exporter binary version and latest version on repo project"
	echo "# TYPE consul_exporter_version_comparison gauge"
	if [ "$(echo "$CONSUL_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$CONSUL_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "consul_exporter_version_comparison{installed=\"$CONSUL_VERSION\", latest=\"$CONSUL_VERSION_LATEST\"} 2"
		else
			echo "consul_exporter_version_comparison{installed=\"$CONSUL_VERSION\"} 1"
		fi
	else
		echo "consul_exporter_version_comparison 0"
	fi
fi

### end
if [ "$PROBLEM_COUNT" -ne "0" ] ; then
    exit 1
fi
exit 0
