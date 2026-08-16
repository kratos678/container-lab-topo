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

# rsyslogd first: FRR's "log syslog" (and the "log commands" config-change
# audit trail) only reaches a local /dev/log socket — without a listener
# there, those log lines go nowhere. rsyslogd forwards them on to the
# monitoring host per /etc/rsyslog.conf.
echo "[entrypoint] starting rsyslogd (local + remote log forwarding)..."
rsyslogd

# net.mpls.platform_labels is set at container creation via clab's
# "sysctls:" block (the same mechanism already used for the ipv4
# sysctls below) — that's the reliable path; writing it here via
# "sysctl -w" after the container is already running was silently
# failing to take effect on some nodes (kernel stayed at the default
# net.mpls.platform_labels=0, so zebra rejected every LDP-bound label
# with "Label >= configured maximum", and the kernel MPLS FIB never got
# programmed even though LDP itself looked fine).
#
# Per-interface MPLS input still has to be enabled here rather than in
# clab's static sysctls block: unlike net.ipv4.conf, net.mpls.conf has
# no "default"/"all" entry — /proc/sys/net/mpls/conf only ever contains
# real interface names, created dynamically as each interface appears —
# so there's no way to pre-set this ahead of the interfaces existing.
# Requires mpls_router/mpls_iptunnel loaded on the clab host first
# (modprobe mpls_router mpls_iptunnel).
if [ -d /proc/sys/net/mpls ]; then
    for ifc in /sys/class/net/*; do
        i=$(basename "$ifc")
        [ "$i" = "lo" ] && continue
        if ! sysctl -w "net.mpls.conf.${i}.input=1" >/tmp/mpls-sysctl.err 2>&1; then
            echo "[entrypoint] WARNING: failed to set net.mpls.conf.${i}.input=1:"
            cat /tmp/mpls-sysctl.err
        fi
    done
    echo "[entrypoint] net.mpls.platform_labels = $(sysctl -n net.mpls.platform_labels 2>/dev/null)"
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

# Node-specific vtysh commands that must run AFTER FRR (specifically
# bgpd) is up. Used to work around a known FRR startup-ordering issue
# where EVPN Type-5 route generation doesn't pick up a VRF's L3VNI
# mapping on the very first config load, needing a toggle-off/on of
# "advertise-all-vni" (or similar) once the daemon is confirmed running.
if [ -x /etc/frr-lab/poststart.sh ]; then
    echo "[entrypoint] waiting for vtysh to be ready..."
    for i in $(seq 1 30); do
        vtysh -c "show version" >/dev/null 2>&1 && break
        sleep 1
    done
    echo "[entrypoint] running /etc/frr-lab/poststart.sh..."
    /etc/frr-lab/poststart.sh
fi

echo "[entrypoint] node ready."
touch /var/log/frr/frr.log /var/log/snmpd.log
tail -F /var/log/frr/frr.log /var/log/snmpd.log &
wait $!
