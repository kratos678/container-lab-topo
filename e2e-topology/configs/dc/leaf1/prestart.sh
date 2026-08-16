#!/bin/bash
# leaf1 owns L2VNI 10110 (subnet 10.2.110.0/24, host dc-h1 on eth3) and
# participates in L3VNI 5000 (VRF TENANT-A) for symmetric-IRB routing to
# leaf2's subnet and, via border1, to the branch over the ISP's L3VPN.
set -e

# VRF for the tenant's L3VNI (created first so the SVI and L3VNI VTEP can
# join it below).
ip link add TENANT-A type vrf table 5000
ip link set TENANT-A up

# L3VNI 5000: this node's VTEP for inter-subnet / inter-domain routing.
ip link add vxlan5000 type vxlan id 5000 dstport 4789 local 10.2.0.4 nolearning
ip link set vxlan5000 master TENANT-A
ip link set vxlan5000 up

# L2VNI 10110: bridges the host-facing port (eth3) into the VXLAN overlay.
ip link add vxlan10110 type vxlan id 10110 dstport 4789 local 10.2.0.4 nolearning
ip link add br10110 type bridge
ip link set vxlan10110 master br10110
ip link set eth3 master br10110
ip link set vxlan10110 up
ip link set eth3 up
ip link set br10110 up

# SVI (anycast gateway for 10.2.110.0/24), routed via VRF TENANT-A.
ip link set br10110 master TENANT-A
ip addr add 10.2.110.1/24 dev br10110
sysctl -w net.ipv4.conf.br10110.proxy_arp=1 >/dev/null 2>&1 || true
