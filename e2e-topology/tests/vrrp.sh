#!/bin/bash
# Read-only. Confirms exactly what's different about the currently-working
# vrrpd process on br-dist1/br-dist2 (root vs frr user, which pid file,
# started when) so the permanent prestart.sh/daemons fix matches reality.
set -x
docker exec clab-e2e-topology-br-dist1 bash -c 'PID=$(pgrep vrrpd); ps -o pid,user,lstart,args -p "$PID"; cat /proc/$PID/status | grep -i cap'
docker exec clab-e2e-topology-br-dist2 bash -c 'PID=$(pgrep vrrpd); ps -o pid,user,lstart,args -p "$PID"; cat /proc/$PID/status | grep -i cap'
docker exec clab-e2e-topology-br-dist1 vtysh -c "show vrrp"
docker exec clab-e2e-topology-br-dist2 vtysh -c "show vrrp"
set +x
