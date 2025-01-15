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
        ### Get versions
	NODE_VERSION=$(/usr/local/bin/node_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	NODE_VERSION_LATEST=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

        ### Checks and print versions
        if [ "$(echo "$NODE_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$NODE_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                NODE_VERSION_SCRAPE=1
                echo "# HELP version_comparison_node_exporter Check node_exporter binary version and latest version on repo project, 1 equals, 0 not equals"
                echo "# TYPE version_comparison_node_exporter gauge"
                if [ "$NODE_VERSION"  == "$NODE_VERSION_LATEST" ]; then
                        echo "version_comparison_node_exporter{installed=\"$NODE_VERSION\",latest=\"$NODE_VERSION_LATEST\"} 1"
                else
                        echo "version_comparison_node_exporter{installed=\"$NODE_VERSION\",latest=\"$NODE_VERSION_LATEST\"} 0"
                fi
        else
                NODE_VERSION_SCRAPE=0
        fi

        ### Print scrape result
        echo "# HELP version_comparison_node_exporter_scrape Check if versions were found 1 ok, 0 problem"
        echo "# TYPE version_comparison_node_exporter_scrape gauge"
        echo "version_comparison_node_exporter_scrape $NODE_VERSION_SCRAPE"
fi

### chrony_exporter
if [ -f  /usr/local/bin/chrony_exporter ]; then
	### Get versions
	CHRONY_VERSION=$(/usr/local/bin/chrony_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CHRONY_VERSION_LATEST=$(curl -s https://api.github.com/repos/SuperQ/chrony_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	### Checks and print versions
	if [ "$(echo "$CHRONY_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$CHRONY_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
		CHRONY_VERSION_SCRAPE=1
		echo "# HELP version_comparison_chrony_exporter Check chrony_exporter binary version and latest version on repo project, 1 equals, 0 not equals"
		echo "# TYPE version_comparison_chrony_exporter gauge"
		if [ "$CHRONY_VERSION"  == "$CHRONY_VERSION_LATEST" ]; then
			echo "version_comparison_chrony_exporter{installed=\"$CHRONY_VERSION\",latest=\"$CHRONY_VERSION_LATEST\"} 1"
		else
			echo "version_comparison_chrony_exporter{installed=\"$CHRONY_VERSION\",latest=\"$CHRONY_VERSION_LATEST\"} 0"
		fi
	else
		CHRONY_VERSION_SCRAPE=0
	fi

	### Print scrape result
	echo "# HELP version_comparison_chrony_exporter_scrape Check if versions were found 1 ok, 0 problem"
	echo "# TYPE version_comparison_chrony_exporter_scrape gauge"
	echo "version_comparison_chrony_exporter_scrape $CHRONY_VERSION_SCRAPE"
fi

### conntrack_exporter
if [ -f /usr/local/bin/conntrack_exporter ]; then
        ### Get versions
	CONNTRACK_VERSION="0.3.1"
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CONNTRACK_VERSION_LATEST=$(curl -s https://api.github.com/repos/hiveco/conntrack_exporter/releases/latest | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

        ### Checks and print versions
        if [ "$(echo "$CONNTRACK_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$CONNTRACK_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                CONNTRACK_VERSION_SCRAPE=1
                echo "# HELP version_comparison_conntrack_exporter Check conntrack_exporter binary version and latest version on repo project, 1 equals, 0 not equals"
                echo "# TYPE version_comparison_conntrack_exporter gauge"
                if [ "$CONNTRACK_VERSION"  == "$CONNTRACK_VERSION_LATEST" ]; then
                        echo "version_comparison_conntrack_exporter{installed=\"$CONNTRACK_VERSION\",latest=\"$CONNTRACK_VERSION_LATEST\"} 1"
                else
                        echo "version_comparison_conntrack_exporter{installed=\"$CONNTRACK_VERSION\",latest=\"$CONNTRACK_VERSION_LATEST\"} 0"
                fi
        else
                CONNTRACK_VERSION_SCRAPE=0
        fi

        ### Print scrape result
        echo "# HELP version_comparison_conntrack_exporter_scrape Check if versions were found 1 ok, 0 problem"
        echo "# TYPE version_comparison_conntrack_exporter_scrape gauge"
        echo "version_comparison_conntrack_exporter_scrape $CONNTRACK_VERSION_SCRAPE"
fi

### blackbox_exporter
if [ -f /usr/local/bin/blackbox_exporter ]; then
        ### Get versions
	BLACKBOX_VERSION=$(/usr/local/bin/blackbox_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	BLACKBOX_VERSION_LATEST=$(curl -s https://api.github.com/repos/prometheus/blackbox_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	### Checks and print versions
        if [ "$(echo "$BLACKBOX_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$BLACKBOX_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                BLACKBOX_VERSION_SCRAPE=1
                echo "# HELP version_comparison_blackbox_exporter Check blackbox_exporter binary version and latest version on repo project, 1 equals, 0 not equals"
                echo "# TYPE version_comparison_blackbox_exporter gauge"
                if [ "$BLACKBOX_VERSION"  == "$BLACKBOX_VERSION_LATEST" ]; then
                        echo "version_comparison_blackbox_exporter{installed=\"$BLACKBOX_VERSION\",latest=\"$BLACKBOX_VERSION_LATEST\"} 1"
                else
                        echo "version_comparison_blackbox_exporter{installed=\"$BLACKBOX_VERSION\",latest=\"$BLACKBOX_VERSION_LATEST\"} 0"
                fi
        else
                BLACKBOX_VERSION_SCRAPE=0
        fi

        ### Print scrape result
        echo "# HELP version_comparison_blackbox_exporter_scrape Check if versions were found 1 ok, 0 problem"
        echo "# TYPE version_comparison_blackbox_exporter_scrape gauge"
        echo "version_comparison_blackbox_exporter_scrape $BLACKBOX_VERSION_SCRAPE"
fi

### keepalived_exporter
if [ -f /usr/bin/keepalived_exporter ]; then
        ### Get versions
	KEEPALIVED_VERSION=$(/usr/bin/keepalived_exporter -version  |& awk '{print $2}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	KEEPALIVED_VERSION_LATEST=$(curl -s https://api.github.com/repos/gen2brain/keepalived_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	#KEEPALIVED_VERSION_LATEST=$(curl -s https://api.github.com/repos/mehdy/keepalived-exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
        ### Checks and print versions
        if [ "$(echo "$KEEPALIVED_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$KEEPALIVED_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                KEEPALIVED_VERSION_SCRAPE=1
                echo "# HELP version_comparison_keepalived_exporter Check keepalived_exporter binary version and latest version on repo project, 1 equals, 0 not equals"
                echo "# TYPE version_comparison_keepalived_exporter gauge"
                if [ "$KEEPALIVED_VERSION"  == "$KEEPALIVED_VERSION_LATEST" ]; then
                        echo "version_comparison_keepalived_exporter{installed=\"$KEEPALIVED_VERSION\",latest=\"$KEEPALIVED_VERSION_LATEST\"} 1"
                else
                        echo "version_comparison_keepalived_exporter{installed=\"$KEEPALIVED_VERSION\",latest=\"$KEEPALIVED_VERSION_LATEST\"} 0"
                fi
        else
                KEEPALIVED_VERSION_SCRAPE=0
        fi

        ### Print scrape result
        echo "# HELP version_comparison_keepalived_exporter_scrape Check if versions were found 1 ok, 0 problem"
        echo "# TYPE version_comparison_keepalived_exporter_scrape gauge"
        echo "version_comparison_keepalived_exporter_scrape $KEEPALIVED_VERSION_SCRAPE"
fi


### fluentbit
if [ -f /opt/fluent-bit/bin/fluent-bit ]; then
        ### Get versions
	FLUENTBIT_VERSION=$(/opt/fluent-bit/bin/fluent-bit --version | head -1| awk '{print $3}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	FLUENTBIT_VERSION_LATEST=$(curl -s https://api.github.com/repos/fluent/fluent-bit/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	### Checks and print versions
        if [ "$(echo "$FLUENTBIT_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$FLUENTBIT_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                FLUENTBIT_VERSION_SCRAPE=1
                echo "# HELP version_comparison_fluentbit Check fluentbit binary version and latest version on repo project, 1 equals, 0 not equals"
                echo "# TYPE version_comparison_fluentbit gauge"
                if [ "$FLUENTBIT_VERSION"  == "$FLUENTBIT_VERSION_LATEST" ]; then
                        echo "version_comparison_fluentbit{installed=\"$FLUENTBIT_VERSION\",latest=\"$FLUENTBIT_VERSION_LATEST\"} 1"
                else
                        echo "version_comparison_fluentbit{installed=\"$FLUENTBIT_VERSION\",latest=\"$FLUENTBIT_VERSION_LATEST\"} 0"
                fi
        else
                FLUENTBIT_VERSION_SCRAPE=0
        fi

        ### Print scrape result
        echo "# HELP version_comparison_fluentbit_scrape Check if versions were found 1 ok, 0 problem"
        echo "# TYPE version_comparison_fluentbit_scrape gauge"
        echo "version_comparison_fluentbit_scrape $FLUENTBIT_VERSION_SCRAPE"
fi

### cadvisor
if [ -f /opt/cadvisor/cadvisor ]; then
        ### Get versions
	CADVISOR_VERSION=$(/opt/cadvisor/cadvisor --version | head -1| awk '{print $3}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CADVISOR_VERSION_LATEST=$(curl -s https://api.github.com/repos/google/cadvisor/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

        ### Checks and print versions
        if [ "$(echo "$CADVISOR_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$CADVISOR_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                CADVISOR_VERSION_SCRAPE=1
                echo "# HELP version_comparison_cadvisor Check cadvisor binary version and latest version on repo project, 1 equals, 0 not equals"
                echo "# TYPE version_comparison_cadvisor gauge"
                if [ "$CADVISOR_VERSION"  == "$CADVISOR_VERSION_LATEST" ]; then
                        echo "version_comparison_cadvisor{installed=\"$CADVISOR_VERSION\",latest=\"$CADVISOR_VERSION_LATEST\"} 1"
                else
                        echo "version_comparison_cadvisor{installed=\"$CADVISOR_VERSION\",latest=\"$CADVISOR_VERSION_LATEST\"} 0"
                fi
        else
                CADVISOR_VERSION_SCRAPE=0
        fi

        ### Print scrape result
        echo "# HELP version_comparison_cadvisor_scrape Check if versions were found 1 ok, 0 problem"
        echo "# TYPE version_comparison_cadvisor_scrape gauge"
        echo "version_comparison_cadvisor_scrape $CADVISOR_VERSION_SCRAPE"
fi

### consul
if [ -f /usr/bin/consul ]; then
        ### Get versions
	CONSUL_VERSION=$(/usr/bin/consul --version | head -1| awk '{print $2}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CONSUL_VERSION_LATEST=$(curl -s https://api.github.com/repos/hashicorp/consul/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

        ### Checks and print versions
        if [ "$(echo "$CONSUL_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$CONSUL_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                CONSUL_VERSION_SCRAPE=1
                echo "# HELP version_comparison_consul Check consul binary version and latest version on repo project, 1 equals, 0 not equals"
                echo "# TYPE version_comparison_consul gauge"
                if [ "$CONSUL_VERSION"  == "$CONSUL_VERSION_LATEST" ]; then
                        echo "version_comparison_consul{installed=\"$CONSUL_VERSION\",latest=\"$CONSUL_VERSION_LATEST\"} 1"
                else
                        echo "version_comparison_consul{installed=\"$CONSUL_VERSION\",latest=\"$CONSUL_VERSION_LATEST\"} 0"
                fi
        else
                CONSUL_VERSION_SCRAPE=0
        fi

        ### Print scrape result
        echo "# HELP version_comparison_consul_scrape Check if versions were found 1 ok, 0 problem"
        echo "# TYPE version_comparison_consul_scrape gauge"
        echo "version_comparison_consul_scrape $CONSUL_VERSION_SCRAPE"
fi

### snoopy
if [ -f /usr/sbin/snoopyctl ]; then
        ### Get versions
	SNOOPY_VERSION=$(/usr/sbin/snoopyctl version | head -1| awk '{print $NF}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	SNOOPY_VERSION_LATEST=$(curl -s https://api.github.com/repos/a2o/snoopy/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -e 's/[-,]//gi' -e 's/snoopy//')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

        ### Checks and print versions
        if [ "$(echo "$SNOOPY_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$SNOOPY_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                SNOOPY_VERSION_SCRAPE=1
                echo "# HELP version_comparison_snoopy Check snoopy binary version and latest version on repo project, 1 equals, 0 not equals"
                echo "# TYPE version_comparison_snoopy gauge"
                if [ "$SNOOPY_VERSION"  == "$SNOOPY_VERSION_LATEST" ]; then
                        echo "version_comparison_snoopy{installed=\"$SNOOPY_VERSION\",latest=\"$SNOOPY_VERSION_LATEST\"} 1"
                else
                        echo "version_comparison_snoopy{installed=\"$SNOOPY_VERSION\",latest=\"$SNOOPY_VERSION_LATEST\"} 0"
                fi
        else
                SNOOPY_VERSION_SCRAPE=0
        fi

        ### Print scrape result
        echo "# HELP version_comparison_snoopy_scrape Check if versions were found 1 ok, 0 problem"
        echo "# TYPE version_comparison_snoopy_scrape gauge"
        echo "version_comparison_snoopy_scrape $SNOOPY_VERSION_SCRAPE"
fi

### traefikee in docker
if [ -f /usr/bin/docker ]; then
	if [ "$(docker ps -a | grep -c traefik_proxy)" -eq "1" ]; then
		### Get versions
		TRAEFIKEE_VERSION=$(docker exec -it traefik_proxy sh -c "traefikee version" | head -1| awk '{print $2}' | sed 's/v//')
	        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
		TRAEFIKEE_VERSION_LATEST=$(curl -s https://doc.traefik.io/traefik-enterprise/kb/release-notes/ | grep '<h2 id="v.*">v' | grep -oP '>v\K[^ ]+' | head -1)
		if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

		### Checks and print versions
		if [ "$(echo "$TRAEFIKEE_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$TRAEFIKEE_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
			TRAEFIKEE_VERSION_SCRAPE=1
			echo "# HELP version_comparison_traefikee Check traefikee binary version and latest version on repo project, 1 equals, 0 not equals"
			echo "# TYPE version_comparison_traefikee gauge"
			if [ "$TRAEFIKEE_VERSION"  == "$TRAEFIKEE_VERSION_LATEST" ]; then
				echo "version_comparison_traefikee{installed=\"$TRAEFIKEE_VERSION\",latest=\"$TRAEFIKEE_VERSION_LATEST\"} 1"
			else
				echo "version_comparison_traefikee{installed=\"$TRAEFIKEE_VERSION\",latest=\"$TRAEFIKEE_VERSION_LATEST\"} 0"
			fi
		else
			TRAEFIKEE_VERSION_SCRAPE=0
		fi

		### Print scrape result
		echo "# HELP version_comparison_traefikee_scrape Check if versions were found 1 ok, 0 problem"
		echo "# TYPE version_comparison_traefikee_scrape gauge"
		echo "version_comparison_traefikee_scrape $TRAEFIKEE_VERSION_SCRAPE"
	fi
fi


### end
if [ "$PROBLEM_COUNT" -ne "0" ] ; then
    exit 1
fi
exit 0
