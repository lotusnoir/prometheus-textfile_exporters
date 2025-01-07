#!/bin/bash

if [ -z "$USER" ] ; then
    USER=$(whoami)
fi
if [ "$USER" != "root" ] ; then
    echo "$(basename $0) must be run as root!"
    exit 2
fi

UFW_STATE=0
UFW_EXIST=0
PROBLEM_COUNT=0

if [ -f /sbin/ufw ]; then
	UFW_EXIST=1
	UFW_STATE=$(ufw status | grep "Status: active" | wc -l)
        if [ "$?" -ne "0" ] ; then
            PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
        fi
fi

echo "# HELP ufw_check_problems Count problems encountered while checking ufw"
echo "# TYPE ufw_check_problems gauge"
echo ufw_check_problems $PROBLEM_COUNT

echo "# HELP ufw_exist Check if ufw is installed"
echo "# TYPE ufw_exist gauge"
echo ufw_exist $UFW_EXIST

echo "# HELP ufw_up Check if ufw is running"
echo "# TYPE ufw_up gauge"
echo ufw_up $UFW_STATE

if [ "$PROBLEM_COUNT" -ne "0" ] ; then
    exit 1
fi
exit 0
