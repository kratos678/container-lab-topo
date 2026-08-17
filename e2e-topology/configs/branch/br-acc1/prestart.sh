#!/bin/bash
# VLAN-aware Linux bridge acting as the branch access switch.
#   eth1 -> br-dist1  (trunk: VLAN 10 + 20)
#   eth2 -> br-dist2  (trunk: VLAN 10 + 20)
#   eth3 -> br-h1     (access: VLAN 10, untagged)
set -e
. /etc/frr-lab/lib.sh

for i in eth1 eth2 eth3; do
    wait_for_iface "$i"
done

ip link add name br0 type bridge vlan_filtering 1
ip link set br0 up

for i in eth1 eth2 eth3; do
    ip link set "$i" master br0
    ip link set "$i" up
done

# Trunk ports: tagged VLAN 10 and 20, no default VLAN 1 membership.
for i in eth1 eth2; do
    bridge vlan del dev "$i" vid 1
    bridge vlan add dev "$i" vid 10
    bridge vlan add dev "$i" vid 20
done

# Access port toward the host: untagged VLAN 10.
bridge vlan del dev eth3 vid 1
bridge vlan add dev eth3 vid 10 pvid untagged
