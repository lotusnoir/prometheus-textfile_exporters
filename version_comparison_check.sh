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
PRINT=0

#######################################
### Checks

### node_exporter
if [ -f /usr/local/bin/node_exporter ]; then
	PRINT=1

        ### Get versions
	NODE_EXPORTER_VERSION=$(/usr/local/bin/node_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	NODE_EXPORTER_VERSION_LATEST=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

        ### Checks and print versions
        if [ "$(echo "$NODE_EXPORTER_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$NODE_EXPORTER_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                NODE_EXPORTER_VERSION_SCRAPE=1
                if [ "$NODE_EXPORTER_VERSION"  == "$NODE_EXPORTER_VERSION_LATEST" ]; then
			NODE_EXPORTER_VERSION_MATCH=1
                else
			NODE_EXPORTER_VERSION_MATCH=0
                fi
        else
                NODE_EXPORTER_VERSION_SCRAPE=0
        fi
fi

### chrony_exporter
if [ -f  /usr/local/bin/chrony_exporter ]; then
	PRINT=1

	### Get versions
	CHRONY_EXPORTER_VERSION=$(/usr/local/bin/chrony_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CHRONY_EXPORTER_VERSION_LATEST=$(curl -s https://api.github.com/repos/SuperQ/chrony_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

        ### Checks and print versions
        if [ "$(echo "$CHRONY_EXPORTER_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$CHRONY_EXPORTER_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                CHRONY_EXPORTER_VERSION_SCRAPE=1
                if [ "$CHRONY_EXPORTER_VERSION"  == "$CHRONY_EXPORTER_VERSION_LATEST" ]; then
                        CHRONY_EXPORTER_VERSION_MATCH=1
                else
                        CHRONY_EXPORTER_VERSION_MATCH=0
                fi
        else
                CHRONY_EXPORTER_VERSION_SCRAPE=0
        fi
fi

### conntrack_exporter
if [ -f /usr/local/bin/conntrack_exporter ]; then
	PRINT=1

        ### Get versions
	CONNTRACK_EXPORTER_VERSION="0.3.1"
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CONNTRACK_EXPORTER_VERSION_LATEST=$(curl -s https://api.github.com/repos/hiveco/conntrack_exporter/releases/latest | grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
        ### Checks and print versions
        if [ "$(echo "$CONNTRACK_EXPORTER_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$CONNTRACK_EXPORTER_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                CONNTRACK_EXPORTER_VERSION_SCRAPE=1
                if [ "$CONNTRACK_EXPORTER_VERSION"  == "$CONNTRACK_EXPORTER_VERSION_LATEST" ]; then
                        CONNTRACK_EXPORTER_VERSION_MATCH=1
                else
                        CONNTRACK_EXPORTER_VERSION_MATCH=0
                fi
        else
                CONNTRACK_EXPORTER_VERSION_SCRAPE=0
        fi
fi

### blackbox_exporter
if [ -f /usr/local/bin/blackbox_exporter ]; then
	PRINT=1

        ### Get versions
	BLACKBOX_EXPORTER_VERSION=$(/usr/local/bin/blackbox_exporter --version | head -1| awk '{print $3}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	BLACKBOX_EXPORTER_VERSION_LATEST=$(curl -s https://api.github.com/repos/prometheus/blackbox_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

        ### Checks and print versions
        if [ "$(echo "$BLACKBOX_EXPORTER_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$BLACKBOX_EXPORTER_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                BLACKBOX_EXPORTER_VERSION_SCRAPE=1
                if [ "$BLACKBOX_EXPORTER_VERSION"  == "$BLACKBOX_EXPORTER_VERSION_LATEST" ]; then
                        BLACKBOX_EXPORTER_VERSION_MATCH=1
                else
                        BLACKBOX_EXPORTER_VERSION_MATCH=0
                fi
        else
                BLACKBOX_EXPORTER_VERSION_SCRAPE=0
        fi
fi

### keepalived_exporter
if [ -f /usr/bin/keepalived_exporter ]; then
	PRINT=1

        ### Get versions
	KEEPALIVED_EXPORTER_VERSION=$(/usr/bin/keepalived_exporter -version  |& awk '{print $2}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	KEEPALIVED_EXPORTER_VERSION_LATEST=$(curl -s https://api.github.com/repos/gen2brain/keepalived_exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	#KEEPALIVED_EXPORTER_VERSION_LATEST=$(curl -s https://api.github.com/repos/mehdy/keepalived-exporter/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

        ### Checks and print versions
        if [ "$(echo "$KEEPALIVED_EXPORTER_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$KEEPALIVED_EXPORTER_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                KEEPALIVED_EXPORTER_VERSION_SCRAPE=1
                if [ "$KEEPALIVED_EXPORTER_VERSION"  == "$KEEPALIVED_EXPORTER_VERSION_LATEST" ]; then
                        KEEPALIVED_EXPORTER_VERSION_MATCH=1
                else
                        KEEPALIVED_EXPORTER_VERSION_MATCH=0
                fi
        else
                KEEPALIVED_EXPORTER_VERSION_SCRAPE=0
        fi
fi

### fluentbit
if [ -f /opt/fluent-bit/bin/fluent-bit ]; then
	PRINT=1

        ### Get versions
	FLUENTBIT_VERSION=$(/opt/fluent-bit/bin/fluent-bit --version | head -1| awk '{print $3}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	FLUENTBIT_VERSION_LATEST=$(curl -s https://api.github.com/repos/fluent/fluent-bit/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

        ### Checks and print versions
        if [ "$(echo "$FLUENTBIT_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$FLUENTBIT_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                FLUENTBIT_VERSION_SCRAPE=1
                if [ "$FLUENTBIT_VERSION"  == "$FLUENTBIT_VERSION_LATEST" ]; then
                        FLUENTBIT_VERSION_MATCH=1
                else
                        FLUENTBIT_VERSION_MATCH=0
                fi
        else
                FLUENTBIT_VERSION_SCRAPE=0
        fi
fi

### cadvisor
if [ -f /opt/cadvisor/cadvisor ]; then
	PRINT=1

        ### Get versions
	CADVISOR_VERSION=$(/opt/cadvisor/cadvisor --version | head -1| awk '{print $3}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CADVISOR_VERSION_LATEST=$(curl -s https://api.github.com/repos/google/cadvisor/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

	        ### Checks and print versions
        if [ "$(echo "$CADVISOR_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$CADVISOR_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                CADVISOR_VERSION_SCRAPE=1
                if [ "$CADVISOR_VERSION"  == "$CADVISOR_VERSION_LATEST" ]; then
                        CADVISOR_VERSION_MATCH=1
                else
                        CADVISOR_VERSION_MATCH=0
                fi
        else
                CADVISOR_VERSION_SCRAPE=0
        fi
fi

### consul
if [ -f /usr/bin/consul ]; then
	PRINT=1

        ### Get versions
	CONSUL_VERSION=$(/usr/bin/consul --version | head -1| awk '{print $2}' | sed 's/v//')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	CONSUL_VERSION_LATEST=$(curl -s https://api.github.com/repos/hashicorp/consul/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -r 's/[v,]//gi')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

        ### Checks and print versions
        if [ "$(echo "$CONSUL_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$CONSUL_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                CONSUL_VERSION_SCRAPE=1
                if [ "$CONSUL_VERSION"  == "$CONSUL_VERSION_LATEST" ]; then
                        CONSUL_VERSION_MATCH=1
                else
                        CONSUL_VERSION_MATCH=0
                fi
        else
                CONSUL_VERSION_SCRAPE=0
        fi
fi

### snoopy
if [ -f /usr/sbin/snoopyctl ]; then
	PRINT=1

        ### Get versions
	SNOOPY_VERSION=$(/usr/sbin/snoopyctl version | head -1| awk '{print $NF}')
        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
	SNOOPY_VERSION_LATEST=$(curl -s https://api.github.com/repos/a2o/snoopy/releases/latest| grep '"tag_name"' | tr -d '"' | awk '{print $NF}' | sed -e 's/[-,]//gi' -e 's/snoopy//')
	if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

        ### Checks and print versions
        if [ "$(echo "$SNOOPY_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$SNOOPY_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
                SNOOPY_VERSION_SCRAPE=1
                if [ "$SNOOPY_VERSION"  == "$SNOOPY_VERSION_LATEST" ]; then
                        SNOOPY_VERSION_MATCH=1
                else
                        SNOOPY_VERSION_MATCH=0
                fi
        else
                SNOOPY_VERSION_SCRAPE=0
        fi
fi

### traefikee in docker
if [ -f /usr/bin/docker ]; then
	if [ "$(docker ps -a | grep -c traefik_proxy)" -eq "1" ]; then
		PRINT=1

		### Get versions
		TRAEFIKEE_VERSION=$(docker exec -it traefik_proxy sh -c "traefikee version" | head -1| awk '{print $2}' | sed 's/v//')
	        if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi
		TRAEFIKEE_VERSION_LATEST=$(curl -s https://doc.traefik.io/traefik-enterprise/kb/release-notes/ | grep '<h2 id="v.*">v' | grep -oP '>v\K[^ ]+' | head -1)
		if [ "$?" -ne "0" ] ; then PROBLEM_COUNT=$((PROBLEM_COUNT + 1)); fi

		### Checks and print versions
	        if [ "$(echo "$TRAEFIKEE_VERSION" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] && [ "$(echo "$TRAEFIKEE_VERSION_LATEST" | grep -c -E '[0-9]{1,4}\.[0-9]{1,4}\.{1,4}')" -eq "1" ] ; then
	                TRAEFIKEE_VERSION_SCRAPE=1
	                if [ "$TRAEFIKEE_VERSION"  == "$TRAEFIKEE_VERSION_LATEST" ]; then
	                        TRAEFIKEE_VERSION_MATCH=1
	                else
	                        TRAEFIKEE_VERSION_MATCH=0
	                fi
	        else
	                TRAEFIKEE_VERSION_SCRAPE=0
	        fi
	fi
fi

if [ "$PRINT" -eq "1" ]; then
  echo "# HELP version_comparison Check binary version and latest version on repo project, 1 equals, 0 not equals"
  echo "# TYPE version_comparison gauge"
  if [ -n "$NODE_EXPORTER_VERSION_MATCH" ]; then echo "version_comparison{application=\"node_exporter\",installed=\"$NODE_EXPORTER_VERSION\",latest=\"$NODE_EXPORTER_VERSION_LATEST\"} $NODE_EXPORTER_VERSION_MATCH"; fi
  if [ -n "$CHRONY_EXPORTER_VERSION_MATCH" ]; then echo "version_comparison{application=\"chrony_exporter\",installed=\"$CHRONY_EXPORTER_VERSION\",latest=\"$CHRONY_EXPORTER_VERSION_LATEST\"} $CHRONY_EXPORTER_VERSION_MATCH"; fi
  if [ -n "$CONNTRACK_EXPORTER_VERSION_MATCH" ]; then echo "version_comparison{application=\"conntrack_exporter\",installed=\"$CONNTRACK_EXPORTER_VERSION\",latest=\"$CONNTRACK_EXPORTER_VERSION_LATEST\"} $CONNTRACK_EXPORTER_VERSION_MATCH"; fi
  if [ -n "$BLACKBOX_EXPORTER_VERSION_MATCH" ]; then echo "version_comparison{application=\"blackbox_exporter\",installed=\"$BLACKBOX_EXPORTER_VERSION\",latest=\"$BLACKBOX_EXPORTER_VERSION_LATEST\"} $BLACKBOX_EXPORTER_VERSION_MATCH"; fi
  if [ -n "$KEEPALIVED_EXPORTER_VERSION_MATCH" ]; then echo "version_comparison{application=\"keepalived_exporter\",installed=\"$KEEPALIVED_EXPORTER_VERSION\",latest=\"$KEEPALIVED_EXPORTER_VERSION_LATEST\"} $KEEPALIVED_EXPORTER_VERSION_MATCH"; fi
  if [ -n "$FLUENTBIT_VERSION_MATCH" ]; then echo "version_comparison{application=\"fluentbit\",installed=\"$FLUENTBIT_VERSION\",latest=\"$FLUENTBIT_VERSION_LATEST\"} $FLUENTBIT_VERSION_MATCH"; fi
  if [ -n "$CADVISOR_VERSION_MATCH" ]; then echo "version_comparison{application=\"cadvisor\",installed=\"$CADVISOR_VERSION\",latest=\"$CADVISOR_VERSION_LATEST\"} $CADVISOR_VERSION_MATCH"; fi
  if [ -n "$CONSUL_VERSION_MATCH" ]; then echo "version_comparison{application=\"consul\",installed=\"$CONSUL_VERSION\",latest=\"$CONSUL_VERSION_LATEST\"} $CONSUL_VERSION_MATCH"; fi
  if [ -n "$SNOOPY_VERSION_MATCH" ]; then echo "version_comparison{application=\"snoopy\",installed=\"$SNOOPY_VERSION\",latest=\"$SNOOPY_VERSION_LATEST\"} $SNOOPY_VERSION_MATCH"; fi
  if [ -n "$TRAEFIKEE_VERSION_MATCH" ]; then echo "version_comparison{application=\"traefikee\",installed=\"$TRAEFIKEE_VERSION\",latest=\"$TRAEFIKEE_VERSION_LATEST\"} $TRAEFIKEE_VERSION_MATCH"; fi

  echo "# HELP version_comparison_scrape Check if versions were found 1 ok, 0 problem"
  echo "# TYPE version_comparison_scrape gauge"
  if [ -n "$NODE_EXPORTER_VERSION_SCRAPE" ]; then echo "version_comparison_scrape{application=\"node_exporter\"} $NODE_EXPORTER_VERSION_SCRAPE"; fi
  if [ -n "$CHRONY_EXPORTER_VERSION_SCRAPE" ]; then echo "version_comparison_scrape{application=\"chrony_exporter\"} $CHRONY_EXPORTER_VERSION_SCRAPE"; fi
  if [ -n "$CONNTRACK_EXPORTER_VERSION_SCRAPE" ]; then echo "version_comparison_scrape{application=\"conntrack_exporter\"} $CONNTRACK_EXPORTER_VERSION_SCRAPE"; fi
  if [ -n "$BLACKBOX_EXPORTER_VERSION_SCRAPE" ]; then echo "version_comparison_scrape{application=\"blackbox_exporter\"} $BLACKBOX_EXPORTER_VERSION_SCRAPE"; fi
  if [ -n "$KEEPALIVED_EXPORTER_VERSION_SCRAPE" ]; then echo "version_comparison_scrape{application=\"keepalived_exporter\"} $KEEPALIVED_EXPORTER_VERSION_SCRAPE"; fi
  if [ -n "$FLUENTBIT_VERSION_SCRAPE" ]; then echo "version_comparison_scrape{application=\"fluentbit\"} $FLUENTBIT_VERSION_SCRAPE"; fi
  if [ -n "$CADVISOR_VERSION_SCRAPE" ]; then echo "version_comparison_scrape{application=\"cadvisor\"} $CADVISOR_VERSION_SCRAPE"; fi
  if [ -n "$CONSUL_VERSION_SCRAPE" ]; then echo "version_comparison_scrape{application=\"consul\"} $CONSUL_VERSION_SCRAPE"; fi
  if [ -n "$SNOOPY_VERSION_SCRAPE" ]; then echo "version_comparison_scrape{application=\"snoopy\"} $SNOOPY_VERSION_SCRAPE"; fi
  if [ -n "$TRAEFIKEE_VERSION_SCRAPE" ]; then echo "version_comparison_scrape{application=\"traefikee\"} $TRAEFIKEE_VERSION_SCRAPE"; fi
fi


### end
if [ "$PROBLEM_COUNT" -ne "0" ] ; then
    exit 1
fi
exit 0
