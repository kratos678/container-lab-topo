#!/bin/bash
# border1 is the DC's gateway leaf: it stitches the EVPN-VXLAN L3VNI 5000
# (VRF TENANT-A) to the ISP's MPLS L3VPN (VRF CUST-A on pe2/pe4) so branch
# and DC subnets can reach each other end to end.
#
# Builds:
#   - VRF TENANT-A (Linux vrf device) — the L3VNI's routing table.
#   - vxlan5000 — this node's L3VNI VTEP, sourced from its own loopback.
#   - eth1/eth2 (the WAN circuits to pe2/pe4) enslaved into VRF TENANT-A,
#     so the eBGP PE-CE sessions run inside the tenant's routing context.
set -e
. /etc/frr-lab/lib.sh

wait_for_iface eth1
wait_for_iface eth2

ip link add TENANT-A type vrf table 5000
ip link set TENANT-A up

# The L3VNI's VTEP must sit inside a bridge, not be enslaved to the VRF
# directly: zebra derives the L3VNI's Router-MAC (needed to originate EVPN
# Type-5 routes) from the bridge's own MAC. Enslaving vxlan5000 straight to
# TENANT-A leaves "show vrf vni" stuck at L3-SVI: None / State: Down / Rmac:
# None, and bgpd never counts it as a real L3 VNI (confirmed live).
ip link add br-l3vni type bridge
ip link set br-l3vni master TENANT-A

ip link add vxlan5000 type vxlan id 5000 dstport 4789 local 10.2.0.1 nolearning
ip link set vxlan5000 master br-l3vni
ip link set vxlan5000 up
ip link set br-l3vni up

ip link set eth1 master TENANT-A
ip link set eth1 up
ip link set eth2 master TENANT-A
ip link set eth2 up
