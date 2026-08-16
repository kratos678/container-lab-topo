#!/bin/bash
# leaf2 owns L2VNI 10120 (subnet 10.2.120.0/24, host dc-h2 on eth3) and
# participates in L3VNI 5000 (VRF TENANT-A) for symmetric-IRB routing to
# leaf1's subnet and, via border1, to the branch over the ISP's L3VPN.
set -e
. /etc/frr-lab/lib.sh

wait_for_iface eth3

ip link add TENANT-A type vrf table 5000
ip link set TENANT-A up

ip link add vxlan5000 type vxlan id 5000 dstport 4789 local 10.2.0.5 nolearning
ip link set vxlan5000 master TENANT-A
ip link set vxlan5000 up

ip link add vxlan10120 type vxlan id 10120 dstport 4789 local 10.2.0.5 nolearning
ip link add br10120 type bridge
ip link set vxlan10120 master br10120
ip link set eth3 master br10120
ip link set vxlan10120 up
ip link set eth3 up
ip link set br10120 up

ip link set br10120 master TENANT-A
ip addr add 10.2.120.1/24 dev br10120
sysctl -w net.ipv4.conf.br10120.proxy_arp=1 >/dev/null 2>&1 || true
