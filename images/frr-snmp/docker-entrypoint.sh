#!/bin/bash
set -e

cleanup() {
    echo "[entrypoint] stopping FRR daemons..."
    /usr/lib/frr/frrinit.sh stop || true
    exit 0
}
trap cleanup TERM INT

mkdir -p /var/agentx
chmod 777 /var/agentx
mkdir -p /var/log/frr
chown frr:frr /var/log/frr

# snmpd must be up first: it is the AgentX master that FRR's zebra/bgpd/ospfd
# modules and lldpd's SNMP subagent both connect to over /var/agentx/master.
echo "[entrypoint] starting snmpd (SNMP / AgentX master agent)..."
snmpd -Lf /var/log/snmpd.log -p /var/run/snmpd.pid

echo "[entrypoint] starting lldpd (LLDP + SNMP AgentX subagent)..."
lldpd -x

echo "[entrypoint] starting FRR daemons (zebra, ospfd, bgpd, staticd)..."
/usr/lib/frr/frrinit.sh start

echo "[entrypoint] node ready: OSPF, BGP, LLDP and SNMP are running."
touch /var/log/frr/frr.log /var/log/snmpd.log
tail -F /var/log/frr/frr.log /var/log/snmpd.log &
wait $!
