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

	echo "# HELP version_comparison_node_exporter Check node_exporter binary version and latest version on repo project"
	echo "# TYPE version_comparison_node_exporter gauge"
	if [ "$(echo "$NODE_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$NODE_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "version_comparison_node_exporter{installed=\"$NODE_VERSION\", latest=\"$NODE_VERSION_LATEST\"} 2"
		else
			echo "version_comparison_node_exporter{installed=\"$NODE_VERSION\"} 1"
		fi
	else
		echo "version_comparison_node_exporter 0"
	fi
fi

### chrony_exporter
if [ -f  /usr/local/bin/chrony_exporter ]; then
	CHRONY_VERSION=$(/usr/local/bin/chrony_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CHRONY_VERSION_LATEST=$(curl -s https://api.github.com/repos/SuperQ/chrony_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP version_comparison_chrony_exporter Check chrony_exporter binary version and latest version on repo project"
	echo "# TYPE version_comparison_chrony_exporter gauge"
	if [ "$(echo "$CHRONY_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$CHRONY_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "version_comparison_chrony_exporter{installed=\"$CHRONY_VERSION\", latest=\"$CHRONY_VERSION_LATEST\"} 2"
		else
			echo "version_comparison_chrony_exporter{installed=\"$CHRONY_VERSION\"} 1"
		fi
	else
		echo "version_comparison_chrony_exporter 0"
	fi
fi

### conntrack_exporter
if [ -f /usr/local/bin/conntrack_exporter ]; then
	CONNTRACK_VERSION="0.3.1"
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CONNTRACK_VERSION_LATEST=$(curl -s https://api.github.com/repos/hiveco/conntrack_exporter/releases/latest | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP version_comparison_conntrack_exporter Check conntrack_exporter binary version and latest version on repo project"
	echo "# TYPE version_comparison_conntrack_exporter gauge"
	if [ "$(echo "$CONNTRACK_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$CONNTRACK_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "version_comparison_conntrack_exporter{installed=\"$CONNTRACK_VERSION\", latest=\"$CONNTRACK_VERSION_LATEST\"} 2"
		else
			echo "version_comparison_conntrack_exporter{installed=\"$CONNTRACK_VERSION\"} 1"
		fi
	else
		echo "version_comparison_conntrack_exporter 0"
	fi

fi

### blackbox_exporter
if [ -f /usr/local/bin/blackbox_exporter ]; then
	BLACKBOX_VERSION=$(/usr/local/bin/blackbox_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	BLACKBOX_VERSION_LATEST=$(curl -s https://api.github.com/repos/prometheus/blackbox_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP version_comparison_blackbox_exporter Check blackbox_exporter binary version and latest version on repo project"
	echo "# TYPE version_comparison_blackbox_exporter gauge"
	if [ "$(echo "$BLACKBOX_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$BLACKBOX_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "version_comparison_blackbox_exporter{installed=\"$BLACKBOX_VERSION\", latest=\"$BLACKBOX_VERSION_LATEST\"} 2"
		else
			echo "version_comparison_blackbox_exporter{installed=\"$BLACKBOX_VERSION\"} 1"
		fi
	else
		echo "version_comparison_blackbox_exporter 0"
	fi
fi

### fluentbit
if [ -f /opt/fluent-bit/bin/fluent-bit ]; then
	FLUENTBIT_VERSION=$(/opt/fluent-bit/bin/fluent-bit --version | head -1| awk '{print $3}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	FLUENTBIT_VERSION_LATEST=$(curl -s https://api.github.com/repos/fluent/fluent-bit/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP version_comparison_fluentbit_exporter Check fluentbit_exporter binary version and latest version on repo project"
	echo "# TYPE version_comparison_fluentbit_exporter gauge"
	if [ "$(echo "$FLUENTBIT_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$FLUENTBIT_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "version_comparison_fluentbit_exporter{installed=\"$FLUENTBIT_VERSION\", latest=\"$FLUENTBIT_VERSION_LATEST\"} 2"
		else
			echo "version_comparison_fluentbit_exporter{installed=\"$FLUENTBIT_VERSION\"} 1"
		fi
	else
		echo "version_comparison_fluentbit_exporter 0"
	fi

fi

### cadvisor
if [ -f /opt/cadvisor/cadvisor ]; then
	CADVISOR_VERSION=$(/opt/cadvisor/cadvisor --version | head -1| awk '{print $3}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CADVISOR_VERSION_LATEST=$(curl -s https://api.github.com/repos/google/cadvisor/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP version_comparison_cadvisor Check cadvisor_exporter binary version and latest version on repo project"
	echo "# TYPE version_comparison_cadvisor gauge"
	if [ "$(echo "$CADVISOR_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$CADVISOR_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "version_comparison_cadvisor{installed=\"$CADVISOR_VERSION\", latest=\"$CADVISOR_VERSION_LATEST\"} 2"
		else
			echo "version_comparison_cadvisor{installed=\"$CADVISOR_VERSION\"} 1"
		fi
	else
		echo "version_comparison_cadvisor 0"
	fi

fi

### consul
if [ -f /usr/bin/consul ]; then
	CONSUL_VERSION=$(/usr/bin/consul --version | head -1| awk '{print $2}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CONSUL_VERSION_LATEST=$(curl -s https://api.github.com/repos/hashicorp/consul/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP version_comparison_consul Check consul binary version and latest version on repo project"
	echo "# TYPE version_comparison_consul gauge"
	if [ "$(echo "$CONSUL_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$CONSUL_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "version_comparison_consul{installed=\"$CONSUL_VERSION\", latest=\"$CONSUL_VERSION_LATEST\"} 2"
		else
			echo "version_comparison_consul{installed=\"$CONSUL_VERSION\"} 1"
		fi
	else
		echo "version_comparison_consul 0"
	fi
fi

### snoopy
if [ -f /usr/sbin/snoopyctl ]; then
	SNOOPY_VERSION=$(/usr/sbin/snoopyctl version | head -1| awk '{print $NF}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	SNOOPY_VERSION_LATEST=$(curl -s https://api.github.com/repos/a2o/snoopy/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -e 's/[-,]//gi' -e 's/snoopy//')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP version_comparison_snoopy Check consul binary version and latest version on repo project"
	echo "# TYPE version_comparison_snoopy gauge"
	if [ "$(echo "$SNOOPY_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$SNOOPY_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "version_comparison_snoopy{installed=\"$SNOOPY_VERSION\", latest=\"$SNOOPY_VERSION_LATEST\"} 2"
		else
			echo "version_comparison_snoopy{installed=\"$SNOOPY_VERSION\"} 1"
		fi
	else
		echo "version_comparison_snoopy 0"
	fi
fi

### /usr/bin/keepalived_exporter
if [ -f /usr/bin/keepalived_exporter ]; then
	KEEPALIVED_VERSION=$(/usr/bin/keepalived_exporter -version  |& awk '{print $2}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	KEEPALIVED_VERSION_LATEST=$(curl -s https://api.github.com/repos/mehdy/keepalived-exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	echo "# HELP version_comparison_keepalived Check consul binary version and latest version on repo project"
	echo "# TYPE version_comparison_keepalived gauge"
	if [ "$(echo "$KEEPALIVED_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		if [ "$(echo "$KEEPALIVED_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			echo "version_comparison_keepalived{installed=\"$KEEPALIVED_VERSION\", latest=\"$KEEPALIVED_VERSION_LATEST\"} 2"
		else
			echo "version_comparison_keepalived{installed=\"$KEEPALIVED_VERSION\"} 1"
		fi
	else
		echo "version_comparison_keepalived 0"
	fi
fi

### traefikee in docker
if [ -f /usr/bin/docker ]; then
	if [ "$(docker ps -a | grep -c traefik_proxy)" -eq "1" ]; then
		TRAEFIKEE_VERSION=$(docker exec -it traefik_proxy sh -c "traefikee version" | head -1| awk '{print $2}' | sed 's/v//')
	        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
		TRAEFIKEE_VERSION_LATEST=$(curl -s https://doc.traefik.io/traefik-enterprise/kb/release-notes/ | grep '<h2 id="v.*">v' | grep -oP '>v\K[^ ]+' | head -1)
		if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

		echo "# HELP version_comparison_traefikee Check consul binary version and latest version on repo project"
		echo "# TYPE version_comparison_traefikee gauge"
		if [ "$(echo "$TRAEFIKEE_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			if [ "$(echo "$TRAEFIKEE_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
				echo "version_comparison_traefikee{installed=\"$TRAEFIKEE_VERSION\", latest=\"$TRAEFIKEE_VERSION_LATEST\"} 2"
			else
				echo "version_comparison_traefikee{installed=\"$TRAEFIKEE_VERSION\"} 1"
			fi
		else
			echo "version_comparison_traefikee 0"
		fi
	fi
fi


### end
if [ "$PROBLEM_COUNT" -ne "0" ] ; then
    exit 1
fi
exit 0
