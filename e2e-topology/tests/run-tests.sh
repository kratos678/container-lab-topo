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
RETRY_MAX=18      # ~90s of polling for control-plane convergence
RETRY_SLEEP=5

PASS=0
FAIL=0
FAILED_CHECKS=()

c_green() { printf '\033[32m%s\033[0m\n' "$1"; }
c_red()   { printf '\033[31m%s\033[0m\n' "$1"; }
c_blue()  { printf '\033[34m%s\033[0m\n' "$1"; }

vty() { docker exec "${PREFIX}$1" vtysh -c "$2" 2>/dev/null; }

# check <label> <node> <vtysh-cmd> <expected-substring> [expected-count]
# Retries until the command's output contains <expected-count> occurrences
# (default 1) of <expected-substring>, or RETRY_MAX attempts are exhausted.
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

# ping_check <label> <exec-container> <target-ip> [vrf-name]
ping_check() {
    local label="$1" n="$2" target="$3" vrf="${4:-}"
    local i cmd out
    for ((i = 0; i < RETRY_MAX; i++)); do
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
        sleep "$RETRY_SLEEP"
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
check "pe1 CE session established (br-core1)" pe1 "show bgp vrf CUST-A summary" "100.64.1.1" 1
check "pe3 CE session established (br-core1)" pe3 "show bgp vrf CUST-A summary" "100.64.1.5" 1
check "pe2 CE session established (border1)"  pe2 "show bgp vrf CUST-A summary" "100.64.2.2" 1
check "pe4 CE session established (border1)"  pe4 "show bgp vrf CUST-A summary" "100.64.2.6" 1
check "rr1 reflects 4 VPNv4 peers"             rr1 "show bgp ipv4 vpn summary" "10.0.0."  4
check "pe1 receives remote VPNv4 prefixes"     pe1 "show bgp ipv4 vpn summary" "10.0.0.2" 1

echo
c_blue "== control plane: DC underlay eBGP + EVPN =="
check "border1 underlay to spine1/spine2" border1 "show bgp summary" "10.2.12." 2
check "spine1 underlay sessions"          spine1  "show bgp summary" "10.2.12." 3
check "spine2 underlay sessions"          spine2  "show bgp summary" "10.2.12." 3
check "leaf1 underlay to both spines"     leaf1   "show bgp summary" "10.2.12." 2
check "leaf2 underlay to both spines"     leaf2   "show bgp summary" "10.2.12." 2
check "leaf1 EVPN session established"    leaf1   "show bgp l2vpn evpn summary" "10.2.12." 2
check "leaf2 EVPN session established"    leaf2   "show bgp l2vpn evpn summary" "10.2.12." 2
check "border1 EVPN session established" border1 "show bgp l2vpn evpn summary" "10.2.12." 2
check "leaf1 learns leaf2 host route (Type-2)" leaf1 "show bgp l2vpn evpn route" "10.2.120.11" 1
check "border1 vrf TENANT-A sees branch route"  border1 "show bgp vrf TENANT-A ipv4 unicast" "10.1.10.0" 1

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
