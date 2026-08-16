#!/bin/bash
# E2E control-plane and data-plane test suite for the Branch/ISP/DC lab.
#
# Usage: ./tests/run-tests.sh [lab-name]
#   lab-name defaults to "e2e-topology" (the "name:" field in e2e-lab.clab.yml).
#
# Exits 0 if every check passes, 1 otherwise. Safe to re-run.

set -u

LAB="${1:-e2e-topology}"
PREFIX="clab-${LAB}-"
RETRY_MAX=18       # ~90s of polling for control-plane convergence
RETRY_SLEEP=5
PING_RETRY_MAX=6   # ~12s per ping check: convergence is checked separately
PING_RETRY_SLEEP=2 # above, so a failing ping shouldn't need a long timeout

PASS=0
FAIL=0
FAILED_CHECKS=()

c_green() { printf '\033[32m%s\033[0m\n' "$1"; }
c_red()   { printf '\033[31m%s\033[0m\n' "$1"; }
c_blue()  { printf '\033[34m%s\033[0m\n' "$1"; }

vty() { docker exec "${PREFIX}$1" vtysh -c "$2" 2>/dev/null; }

# check <label> <node> <vtysh-cmd> <expected-substring> [expected-count]
# For route-table output (OSPF/LDP neighbor state, VRRP state, BGP route
# tables): retries until <expected-count> occurrences of <expected-substring>
# appear, or RETRY_MAX attempts are exhausted. Do NOT use this against a
# "show bgp ... summary" table to test session state — the neighbor's IP
# address appears there whether or not the session is established; use
# bgp_estab for that instead.
check() {
    local label="$1" n="$2" cmd="$3" pattern="$4" count="${5:-1}"
    local i out got
    for ((i = 0; i < RETRY_MAX; i++)); do
        out="$(vty "$n" "$cmd")"
        got="$(grep -o -- "$pattern" <<<"$out" | wc -l)"
        if [ "$got" -ge "$count" ]; then
            c_green "  PASS  $label"
            PASS=$((PASS + 1))
            return 0
        fi
        sleep "$RETRY_SLEEP"
    done
    c_red "  FAIL  $label (wanted >= $count x '$pattern', got $got)"
    echo "        -- $n# vtysh -c \"$cmd\" --"
    sed 's/^/        /' <<<"$out"
    FAIL=$((FAIL + 1))
    FAILED_CHECKS+=("$label")
    return 1
}

# bgp_estab <label> <node> <summary-cmd> <neighbor-ip>
# Passes once <neighbor-ip>'s row in a "show bgp ... summary" table is
# Established (FRR prints a numeric PfxRcd there; a text state name means
# it is NOT up yet).
bgp_estab() {
    local label="$1" n="$2" cmd="$3" neighbor="$4"
    local i out line
    for ((i = 0; i < RETRY_MAX; i++)); do
        out="$(vty "$n" "$cmd")"
        line="$(grep -E "^${neighbor//./\\.}[[:space:]]" <<<"$out")"
        if [ -n "$line" ] && ! grep -qE 'Idle|Active|Connect|OpenSent|OpenConfirm|Never' <<<"$line"; then
            c_green "  PASS  $label"
            PASS=$((PASS + 1))
            return 0
        fi
        sleep "$RETRY_SLEEP"
    done
    c_red "  FAIL  $label (neighbor $neighbor not Established)"
    echo "        -- $n# vtysh -c \"$cmd\" --"
    sed 's/^/        /' <<<"$out"
    FAIL=$((FAIL + 1))
    FAILED_CHECKS+=("$label")
    return 1
}

# ping_check <label> <exec-container> <target-ip> [vrf-name]
ping_check() {
    local label="$1" n="$2" target="$3" vrf="${4:-}"
    local i cmd out
    for ((i = 0; i < PING_RETRY_MAX; i++)); do
        if [ -n "$vrf" ]; then
            cmd=(docker exec "${PREFIX}${n}" ip vrf exec "$vrf" ping -c 2 -W 1 "$target")
        else
            cmd=(docker exec "${PREFIX}${n}" ping -c 2 -W 1 "$target")
        fi
        out="$("${cmd[@]}" 2>&1)"
        if grep -q ' 0% packet loss' <<<"$out"; then
            c_green "  PASS  $label"
            PASS=$((PASS + 1))
            return 0
        fi
        sleep "$PING_RETRY_SLEEP"
    done
    c_red "  FAIL  $label"
    sed 's/^/        /' <<<"$out"
    FAIL=$((FAIL + 1))
    FAILED_CHECKS+=("$label")
    return 1
}

echo
c_blue "== control plane: branch OSPF + VRRP =="
check "br-core1 OSPF full to br-dist1"  br-core1 "show ip ospf neighbor" "Full" 2
check "br-dist1 OSPF full neighbors"    br-dist1 "show ip ospf neighbor" "Full" 2
check "br-dist2 OSPF full neighbors"    br-dist2 "show ip ospf neighbor" "Full" 2
check "br-dist1 VRRP vrid10 Master"     br-dist1 "show vrrp" "Master" 1
check "br-dist2 VRRP vrid20 Master"     br-dist2 "show vrrp" "Master" 1

echo
c_blue "== control plane: ISP core OSPF + LDP =="
for n in pe1 pe2 pe3 pe4 p1 p3; do
    check "$n OSPF neighbors Full" "$n" "show ip ospf neighbor" "Full" 2
done
check "p2 OSPF neighbors Full" p2 "show ip ospf neighbor" "Full" 3
check "p4 OSPF neighbors Full" p4 "show ip ospf neighbor" "Full" 3
for n in pe1 pe2 pe3 pe4 p1 p2 p3 p4; do
    check "$n LDP neighbors OPERATIONAL" "$n" "show mpls ldp neighbor" "OPERATIONAL" 1
done

echo
c_blue "== control plane: ISP L3VPN (VRF CUST-A) + iBGP VPNv4 =="
bgp_estab "pe1 CE session established (br-core1)" pe1 "show bgp vrf CUST-A summary" "100.64.1.1"
bgp_estab "pe3 CE session established (br-core1)" pe3 "show bgp vrf CUST-A summary" "100.64.1.5"
bgp_estab "pe2 CE session established (border1)"  pe2 "show bgp vrf CUST-A summary" "100.64.2.2"
bgp_estab "pe4 CE session established (border1)"  pe4 "show bgp vrf CUST-A summary" "100.64.2.6"
bgp_estab "rr1 <-> pe1 VPNv4 session" rr1 "show bgp ipv4 vpn summary" "10.0.0.1"
bgp_estab "rr1 <-> pe2 VPNv4 session" rr1 "show bgp ipv4 vpn summary" "10.0.0.3"
bgp_estab "rr1 <-> pe3 VPNv4 session" rr1 "show bgp ipv4 vpn summary" "10.0.0.4"
bgp_estab "rr1 <-> pe4 VPNv4 session" rr1 "show bgp ipv4 vpn summary" "10.0.0.5"
check "pe1 has VPNv4 route to pe2 loopback (10.0.0.3/32)" pe1 "show bgp ipv4 vpn" "10.0.0.3/32" 1

echo
c_blue "== control plane: DC underlay eBGP =="
bgp_estab "border1 <-> spine1 underlay" border1 "show bgp summary" "10.2.12.2"
bgp_estab "border1 <-> spine2 underlay" border1 "show bgp summary" "10.2.12.6"
bgp_estab "spine1 <-> border1 underlay" spine1  "show bgp summary" "10.2.12.1"
bgp_estab "spine1 <-> leaf1 underlay"   spine1  "show bgp summary" "10.2.12.10"
bgp_estab "spine1 <-> leaf2 underlay"   spine1  "show bgp summary" "10.2.12.21"
bgp_estab "spine2 <-> border1 underlay" spine2  "show bgp summary" "10.2.12.5"
bgp_estab "spine2 <-> leaf2 underlay"   spine2  "show bgp summary" "10.2.12.14"
bgp_estab "spine2 <-> leaf1 underlay"   spine2  "show bgp summary" "10.2.12.18"
bgp_estab "leaf1 <-> spine1 underlay"   leaf1   "show bgp summary" "10.2.12.9"
bgp_estab "leaf1 <-> spine2 underlay"   leaf1   "show bgp summary" "10.2.12.18"
bgp_estab "leaf2 <-> spine2 underlay"   leaf2   "show bgp summary" "10.2.12.13"
bgp_estab "leaf2 <-> spine1 underlay"   leaf2   "show bgp summary" "10.2.12.22"

echo
c_blue "== control plane: DC EVPN-VXLAN overlay =="
bgp_estab "leaf1 EVPN session to spine1"   leaf1   "show bgp l2vpn evpn summary" "10.2.12.9"
bgp_estab "leaf1 EVPN session to spine2"   leaf1   "show bgp l2vpn evpn summary" "10.2.12.18"
bgp_estab "leaf2 EVPN session to spine2"   leaf2   "show bgp l2vpn evpn summary" "10.2.12.13"
bgp_estab "leaf2 EVPN session to spine1"   leaf2   "show bgp l2vpn evpn summary" "10.2.12.22"
bgp_estab "border1 EVPN session to spine1" border1 "show bgp l2vpn evpn summary" "10.2.12.2"
bgp_estab "border1 EVPN session to spine2" border1 "show bgp l2vpn evpn summary" "10.2.12.6"
# leaf1 does NOT import leaf2's L2VNI-10120 Type-2 routes (different VNI,
# different route-target — L2 domains stay isolated by design). What
# should cross is leaf2's subnet as an EVPN Type-5 route via the shared
# L3VNI 5000 route-target, landing in leaf1's own vrf TENANT-A table.
check "leaf1 vrf TENANT-A sees leaf2 subnet (Type-5)" leaf1 "show bgp vrf TENANT-A ipv4 unicast" "10.2.120.0" 1
check "border1 vrf TENANT-A sees branch route"        border1 "show bgp vrf TENANT-A ipv4 unicast" "10.1.10.0" 1

echo
c_blue "== data plane: branch LAN =="
ping_check "br-h1 -> VRRP gateway 10.1.10.1" br-h1 10.1.10.1

echo
c_blue "== data plane: PE-CE reachability (WAN circuits) =="
ping_check "pe1 -> br-core1 CE (100.64.1.1)" pe1 100.64.1.1 CUST-A
ping_check "border1 -> pe2 CE (100.64.2.1)" border1 100.64.2.1 TENANT-A

echo
c_blue "== data plane: intra-DC (symmetric IRB across leaf1<->leaf2) =="
ping_check "dc-h1 -> dc-h2 (10.2.120.11)" dc-h1 10.2.120.11
ping_check "dc-h2 -> dc-h1 (10.2.110.11)" dc-h2 10.2.110.11

echo
c_blue "== data plane: end to end, branch <-> DC across ISP L3VPN + EVPN =="
ping_check "br-h1 -> dc-h1 (10.2.110.11)" br-h1 10.2.110.11
ping_check "br-h1 -> dc-h2 (10.2.120.11)" br-h1 10.2.120.11
ping_check "dc-h1 -> br-h1 (10.1.10.11)" dc-h1 10.1.10.11

echo
c_blue "== summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "  failing checks:"
    for f in "${FAILED_CHECKS[@]}"; do
        echo "    - $f"
    done
    exit 1
fi
c_green "All checks passed."
exit 0
