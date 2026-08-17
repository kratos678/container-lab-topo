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

<<<<<<< HEAD
<<<<<<< HEAD
# FRR's vrrpd never creates the macvlan device that carries the VRRP
# virtual MAC - it only discovers one by scanning zebra's interface list
# for a MAC match, and refuses to start the virtual router at all if none
# exists ("no interface found w/ MAC ..."). Confirmed live: without this,
# vrrpd sits in Status: Initialize forever with 0 advertisements sent.
ip link add vrrp-vrid10 link eth1.10 type macvlan mode bridge
ip link set dev vrrp-vrid10 address 00:00:5e:00:01:0a
ip link set dev vrrp-vrid10 up

ip link add vrrp-vrid20 link eth1.20 type macvlan mode bridge
ip link set dev vrrp-vrid20 address 00:00:5e:00:01:14
ip link set dev vrrp-vrid20 up
=======
# Pre-create the macvlan interfaces for VRRP (vrrpd discovers them by MAC)
ip link add link eth1.10 name vrrp-vrid10 type macvlan mode bridge
ip link set dev vrrp-vrid10 address 00:00:5e:00:01:0a
ip addr add 10.1.10.1/24 dev vrrp-vrid10
ip link set vrrp-vrid10 up

ip link add link eth1.20 name vrrp-vrid20 type macvlan mode bridge
ip link set dev vrrp-vrid20 address 00:00:5e:00:01:14
ip addr add 10.1.20.1/24 dev vrrp-vrid20
ip link set vrrp-vrid20 up

# Grant capabilities to vrrpd so it can bind raw sockets and manage interfaces after dropping privileges
setcap cap_net_raw,cap_net_admin+ep /usr/lib/frr/vrrpd

>>>>>>> ceda713 (vrrp fix)
=======
>>>>>>> c35d144 (Remove FRR VRRP configuration)
