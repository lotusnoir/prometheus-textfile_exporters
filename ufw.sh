#!/bin/bash

if [ "$USER" != "root" ] ; then
    echo "$(basename $0) must be run as root!"
    exit 2
fi

UFW_STATE=0
UFW_EXIST=0

if [ -f /sbin/ufw ]; then
	UFW_EXIST=1
	UFW_STATE=$(ufw status | grep "Status: active" | wc -l)
fi

echo "# HELP ufw_exist Check if ufw is installed"
echo "# TYPE ufw_exist gauge"
echo ufw_exist $UFW_EXIST

echo "# HELP ufw_up Check if ufw is running"
echo "# TYPE ufw_up gauge"
echo ufw_up $UFW_STATE
