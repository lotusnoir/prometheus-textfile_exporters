#!/bin/bash

REBOOT=0
if [ "$USER" != "root" ] ; then
    echo "$(basename $0) must be run as root!"
    exit 2
fi

if [ -f /var/run/reboot-required ]; then
  REBOOT=1
fi

if [ -f /bin/needs-restarting ]; then
  if [ "$(needs-restarting -r | grep 'Reboot is required' | wc -l)" == 1 ]; then REBOOT=1; fi
fi

echo "# HELP node_pending_reboot Check if pending reboot is activated"
echo "# TYPE node_pending_reboot gauge"
echo node_pending_reboot $REBOOT
