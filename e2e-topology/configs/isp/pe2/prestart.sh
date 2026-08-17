#!/bin/bash
# Creates the Linux VRF device for VRF CUST-A and enslaves the CE-facing
# WAN interface into it before FRR starts. FRR's "vrf CUST-A" / "interface
# eth1 / vrf CUST-A" config expects this device to already exist.
set -e
. /etc/frr-lab/lib.sh

wait_for_iface eth1
ip link add CUST-A type vrf table 100
ip link set CUST-A up
ip link set eth1 master CUST-A
ip link set eth1 up
