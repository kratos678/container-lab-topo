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

# Enable MPLS forwarding on every interface present at boot. Harmless on
# nodes that don't run LDP/MPLS; required on the ISP core (P/PE routers)
# for label-switched forwarding to actually work. Needs the mpls_router
# kernel module loaded on the clab host first (modprobe mpls_router
# mpls_iptunnel) — these sysctls are namespaced per-container but the
# kernel module itself is host-wide.
if [ -d /proc/sys/net/mpls ]; then
    sysctl -w net.mpls.platform_labels=100000 >/dev/null 2>&1 || true
    sysctl -w net.mpls.conf.default.input=1 >/dev/null 2>&1 || true
    for ifc in /sys/class/net/*; do
        i=$(basename "$ifc")
        [ "$i" = "lo" ] && continue
        sysctl -w "net.mpls.conf.${i}.input=1" >/dev/null 2>&1 || true
    done
else
    echo "[entrypoint] WARNING: /proc/sys/net/mpls not present — load the" \
         "mpls_router kernel module on the clab host if this node needs LDP/MPLS."
fi

# Node-specific Linux networking that must exist before FRR starts:
# VLAN trunking on the branch access switch, or VXLAN/bridge/VRF
# netdevices for the DC EVPN-VXLAN fabric.
if [ -x /etc/frr-lab/prestart.sh ]; then
    echo "[entrypoint] running /etc/frr-lab/prestart.sh..."
    /etc/frr-lab/prestart.sh
fi

# snmpd must be up first: it is the AgentX master that FRR's zebra/bgpd/ospfd
# modules and lldpd's SNMP subagent both connect to over /var/agentx/master.
echo "[entrypoint] starting snmpd (SNMP / AgentX master agent)..."
snmpd -Lf /var/log/snmpd.log -p /var/run/snmpd.pid

echo "[entrypoint] starting lldpd (LLDP + SNMP AgentX subagent)..."
lldpd -x

echo "[entrypoint] starting FRR daemons enabled in /etc/frr/daemons..."
/usr/lib/frr/frrinit.sh start

echo "[entrypoint] node ready."
touch /var/log/frr/frr.log /var/log/snmpd.log
tail -F /var/log/frr/frr.log /var/log/snmpd.log &
wait $!
