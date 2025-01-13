#!/bin/bash

if [ -z "$USER" ] ; then
    USER=$(whoami)
fi
if [ "$USER" != "root" ] ; then
    echo "$(basename "$0") must be run as root!"
    exit 2
fi

REBOOT=0
PROBLEM_COUNT=0
if [ -f /var/run/reboot-required ]; then
  REBOOT=1
fi

if [ -f /bin/needs-restarting ]; then
	if [ "$(needs-restarting -r | grep -c 'Reboot is required')" == 1 ]; then REBOOT=1; fi
        if [ "$?" -ne "0" ] ; then
            PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
        fi

fi

echo "# HELP node_pending_reboot Check if pending reboot is activated"
echo "# TYPE node_pending_reboot gauge"
echo node_pending_reboot $REBOOT

if [ "$PROBLEM_COUNT" -ne "0" ] ; then
    exit 1
fi
exit 0
