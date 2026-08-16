#!/bin/bash
# Creates the 802.1q VLAN sub-interfaces for the trunk to br-acc1 before
# FRR starts (FRR configures existing netdevs, it does not create them).
set -e
. /etc/frr-lab/lib.sh

wait_for_iface eth1
ip link set eth1 up
ip link add link eth1 name eth1.10 type vlan id 10
ip link add link eth1 name eth1.20 type vlan id 20
ip link set eth1.10 up
ip link set eth1.20 up
