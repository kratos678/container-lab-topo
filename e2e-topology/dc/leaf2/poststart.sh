#!/bin/bash
# Works around a known FRR startup-ordering issue: EVPN Type-5 route
# generation for a VRF's L3VNI can fail to pick up the mapping on the
# very first config load, even though the config is entirely correct.
# Toggling the relevant commands off/on after bgpd is confirmed up
# forces FRR to re-scan and generate the routes correctly.
set -e

vtysh \
    -c "configure terminal" \
    -c "router bgp 65512" \
    -c "address-family l2vpn evpn" \
    -c "no advertise-all-vni" \
    -c "advertise-all-vni" \
    -c "exit-address-family" \
    -c "exit" \
    -c "router bgp 65512 vrf TENANT-A" \
    -c "address-family l2vpn evpn" \
    -c "no advertise ipv4 unicast" \
    -c "advertise ipv4 unicast" \
    -c "exit-address-family" \
    -c "exit" \
    -c "end"
