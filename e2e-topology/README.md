# E2E Topology: Branch &harr; ISP &harr; Data Centre

A 21-node [containerlab](https://containerlab.dev/) lab built entirely on FRR
(plus two lightweight host containers) modelling a realistic multi-domain
network: a dual-homed branch site, an MPLS L3VPN ISP core, and an
EVPN-VXLAN data-centre fabric, stitched together end to end and monitored
over SNMP.

- **18 FRR nodes** (17 routers + 1 L2 access switch) + **3 end hosts**
- **33 links**, OOB management on `10.255.0.0/24`
- One shared Docker image for every FRR/switch node (`images/frr-snmp`)

## Repository layout

```
e2e-lab.clab.yml               containerlab topology: 21 nodes, 33 links
images/frr-snmp/                shared node image (Dockerfile + entrypoint)
configs/branch/                 br-core1, br-dist1, br-dist2, br-acc1
configs/isp/                    pe1-4, p1-4, rr1
configs/dc/                     border1, spine1, spine2, leaf1, leaf2
tests/run-tests.sh              control-plane + data-plane test suite
```

Each router directory holds `daemons`, `frr.conf`, `vtysh.conf`,
`snmpd.conf`, and — where Linux networking must exist before FRR starts
(VLAN trunks, VXLAN/bridge/VRF devices) — a `prestart.sh`, all bind-mounted
by `e2e-lab.clab.yml`.

## Topology

```
                                          ISP — AS 65000
                                OSPF + LDP/MPLS core, iBGP VPNv4 via rr1
                    rr1 (RR, VPNv4 only)
                   /                \
      pe1---p1---p2---pe2        (full core mesh: pe1-4, p1-4)
       |    | \ / |    |
      (CE)  |  X  |   (CE)
       |    | / \ |    |
      pe3---p3---p4---pe4
       |                  |
   circuit A/B        circuit A/B
   100.64.1.0/30      100.64.2.0/30
       |                  |
  BRANCH — AS 65100   DATA CENTRE — eBGP fabric + EVPN-VXLAN
  br-core1            border1 (AS 65513, L3VNI 5000 / VRF TENANT-A)
   /      \             /        \
 br-dist1 br-dist2   spine1      spine2
  (VRRP master/backup  (AS65501)  (AS65502)
   VLAN10 <-> VLAN20)     \        /   (full cross-mesh to both leafs)
      \    /                leaf1  leaf2
     br-acc1 (L2 trunk)   (AS65511)(AS65512)
        |                  VNI10110 VNI10120
       br-h1                  |        |
    10.1.10.11              dc-h1    dc-h2
                          10.2.110.11 10.2.120.11
```

## Addressing plan

### Loopbacks (router IDs / VTEPs)

| Node      | Loopback     | Node    | Loopback     | Node    | Loopback     |
|-----------|--------------|---------|--------------|---------|--------------|
| br-core1  | 10.1.0.1/32  | pe1     | 10.0.0.1/32  | border1 | 10.2.0.1/32  |
| br-dist1  | 10.1.0.2/32  | rr1     | 10.0.0.2/32  | spine1  | 10.2.0.2/32  |
| br-dist2  | 10.1.0.3/32  | pe2     | 10.0.0.3/32  | spine2  | 10.2.0.3/32  |
|           |              | pe3     | 10.0.0.4/32  | leaf1   | 10.2.0.4/32  |
|           |              | pe4     | 10.0.0.5/32  | leaf2   | 10.2.0.5/32  |
|           |              | p1      | 10.0.0.11/32 |         |              |
|           |              | p2      | 10.0.0.12/32 |         |              |
|           |              | p3      | 10.0.0.13/32 |         |              |
|           |              | p4      | 10.0.0.14/32 |         |              |

### Domain protocols

| Domain      | Protocols                                              | Key identifiers |
|-------------|---------------------------------------------------------|-----------------|
| Branch      | OSPF area 0, VRRPv3, eBGP (dual-homed PE-CE)             | AS 65100 &middot; VLAN 10 `10.1.10.0/24` &middot; VLAN 20 `10.1.20.0/24` |
| ISP         | Core: OSPF + LDP/MPLS (P/PE routers). Service: iBGP VPNv4 reflected by `rr1` | AS 65000 &middot; VRF `CUST-A` &middot; RT `65000:100`, per-PE RD `<loopback>:100` |
| Data centre | eBGP underlay (per-device AS) + eBGP EVPN-VXLAN overlay, symmetric IRB | VRF `TENANT-A` &middot; L3VNI `5000` (RT `65000:5000`) &middot; L2VNI `10110`/`10120` |
| WAN         | eBGP PE-CE, both sides dual-homed                        | `100.64.1.0/30` circuits (branch) &middot; `100.64.2.0/30` circuits (DC) |
| Management  | OOB on `eth0`, SNMPv2c bound to the mgmt address          | `10.255.0.0/24`, `.101`&ndash;`.121` |

### Branch

| Link                        | Subnet        | Notes |
|------------------------------|--------------|-------|
| br-dist1 &harr; br-dist2      | 10.1.1.0/30  | direct peer link, OSPF |
| br-dist1 &harr; br-core1      | 10.1.2.0/30  | OSPF |
| br-dist2 &harr; br-core1      | 10.1.3.0/30  | OSPF |
| VLAN 10 (br-dist1/2 &harr; br-h1) | 10.1.10.0/24 | VRRP VIP `.1`, br-dist1 master (110) / br-dist2 backup (90) |
| VLAN 20 (br-dist1/2)          | 10.1.20.0/24 | VRRP VIP `.1`, br-dist2 master (110) / br-dist1 backup (90) |
| br-core1 &harr; pe1 (circuit A) | 100.64.1.0/30 | eBGP AS65100 &harr; AS65000 |
| br-core1 &harr; pe3 (circuit B) | 100.64.1.4/30 | eBGP AS65100 &harr; AS65000 |

`br-acc1` is a VLAN-aware Linux bridge (no FRR routing daemons): trunk
ports to br-dist1/br-dist2 carry VLAN 10+20, the access port to br-h1 is
untagged VLAN 10.

### ISP core

All P/PE/RR interfaces live in `10.0.12.0/24`, OSPF area 0. LDP runs on
every P/PE-to-P/PE link (not on rr1's uplinks — the route reflector isn't
in the MPLS data path). Full addressing is in each node's `frr.conf`; the
mesh follows the diagram exactly (pe1/pe3 dual-homed to the left square of
p1&ndash;p3, pe2/pe4 to the right square of p2/p4, plus cross-links
p1&ndash;p4 and rr1&ndash;{p1,p2}).

VRF `CUST-A` (RT `65000:100`) runs on all four PEs, each with its own RD
(`<pe-loopback>:100`), leaking routes via `rd/rt vpn` + `import/export vpn`
under `address-family ipv4 unicast` of `router bgp 65000 vrf CUST-A`.

### Data centre

| Link                    | Subnet         |
|--------------------------|---------------|
| border1 &harr; spine1     | 10.2.12.0/30  |
| border1 &harr; spine2     | 10.2.12.4/30  |
| spine1 &harr; leaf1       | 10.2.12.8/30  |
| spine2 &harr; leaf2       | 10.2.12.12/30 |
| leaf1 &harr; spine2 (cross) | 10.2.12.16/30 |
| leaf2 &harr; spine1 (cross) | 10.2.12.20/30 |
| pe2 &harr; border1 (circuit A) | 100.64.2.0/30 |
| pe4 &harr; border1 (circuit B) | 100.64.2.4/30 |

Each DC device is its own AS (border1=65513, spine1=65501, spine2=65502,
leaf1=65511, leaf2=65512) — a genuine eBGP fabric, not iBGP. Spines relay
EVPN routes between border1/leaf1/leaf2 with `set ip next-hop unchanged`
so VXLAN traffic still terminates on the originating VTEP's loopback, not
the spine's.

- **leaf1**: L2VNI 10110, subnet `10.2.110.0/24`, host `dc-h1 = .11`
- **leaf2**: L2VNI 10120, subnet `10.2.120.0/24`, host `dc-h2 = .11`
- **L3VNI 5000 / VRF TENANT-A**: instantiated on border1, leaf1 *and*
  leaf2 for symmetric-IRB routing between the two subnets, and on border1
  to stitch the EVPN fabric to VRF CUST-A on pe2/pe4 (branch&harr;DC
  reachability). RT `65000:5000` shared across all three.

## Prerequisites

- Docker
- [containerlab](https://containerlab.dev/install/)
- Two kernel modules loaded **on the containerlab host** (not inside the
  containers — these are namespaced per-container but the modules
  themselves are host-wide):
  ```bash
  sudo modprobe mpls_router mpls_iptunnel   # ISP core: LDP/MPLS forwarding
  sudo modprobe 8021q                       # branch: VLAN sub-interfaces
  ```
  This is now a hard requirement, not just a warning: `net.mpls.platform_labels`
  is set via containerlab's `sysctls:` block (applied at container
  creation, alongside `net.ipv4.ip_forward`) rather than from inside the
  entrypoint after the fact — that was silently failing to take effect on
  some nodes, leaving `net.mpls.platform_labels` at its kernel default of
  `0` and every LDP-bound label rejected with `Label >= configured maximum
  in platform_labels`, even though LDP sessions themselves looked
  perfectly healthy. If `mpls_router` isn't loaded before you deploy,
  every node fails to start at all rather than starting without MPLS.

## Build the node image

```bash
docker build -t clab-frr-snmp:e2e -f images/frr-snmp/Dockerfile images/frr-snmp
```

## Deploy

```bash
sudo containerlab deploy -t e2e-lab.clab.yml
```

Destroy with:

```bash
sudo containerlab destroy -t e2e-lab.clab.yml
```

## Run the tests

```bash
./tests/run-tests.sh e2e-topology
```

This polls (up to ~50s per check) for OSPF/LDP/VRRP convergence on the
branch and ISP core, BGP VRF/VPNv4 sessions on the PEs and route
reflector, the DC's underlay eBGP + EVPN sessions and a learned EVPN host
route, then runs a ping matrix: branch LAN gateway, PE-CE circuits,
intra-DC (leaf1&harr;leaf2 symmetric IRB), and full branch&harr;DC
end-to-end. Kernel-level checks (the MPLS FIB) and pings use a shorter
~12s budget of their own, since that state either shows up fast or needs
an actual fix, not more polling. Each check prints a "." for every retry
attempt while it's still waiting, so a slow run reads as "still
checking", not as hung. It prints PASS/FAIL per check and exits non-zero
if anything failed.

Useful manual checks while debugging a specific layer:

```bash
docker exec -it clab-e2e-topology-pe1 vtysh -c "show ip ospf neighbor"
docker exec -it clab-e2e-topology-pe1 vtysh -c "show mpls ldp neighbor"
docker exec -it clab-e2e-topology-pe1 vtysh -c "show bgp vrf CUST-A summary"
docker exec -it clab-e2e-topology-rr1 vtysh -c "show bgp ipv4 vpn summary"
docker exec -it clab-e2e-topology-leaf1 vtysh -c "show bgp l2vpn evpn summary"
docker exec -it clab-e2e-topology-leaf1 vtysh -c "show bgp l2vpn evpn route"
docker exec -it clab-e2e-topology-border1 vtysh -c "show bgp vrf TENANT-A ipv4 unicast"
docker exec -it clab-e2e-topology-br-dist1 vtysh -c "show vrrp"
```

## SNMP

Every FRR/switch node runs the same SNMP setup as the earlier 2-node lab:
`snmpd` as the AgentX master (SNMPv2c, community `public`, read-only,
reachable from anywhere on the mgmt network — lab-only, see the security
note below), with FRR's `frr-snmp` module (BGP4-MIB, OSPF-MIB) and
`lldpd -x` (LLDP-MIB) attached as AgentX subagents, plus native
IF-MIB/HOST-RESOURCES-MIB/UCD-SNMP-MIB coverage for interfaces, CPU, and
memory.

```bash
snmpwalk -v2c -c public 10.255.0.106 1.3.6.1.2.1.1        # pe1 system
snmpwalk -v2c -c public 10.255.0.106 1.3.6.1.2.1.14        # pe1 OSPF-MIB
snmpwalk -v2c -c public 10.255.0.106 1.3.6.1.2.1.15        # pe1 BGP4-MIB
snmpwalk -v2c -c public 10.255.0.118 1.0.8802.1.1.2        # leaf1 LLDP-MIB
```

**Security note**: SNMPv2c with the community `public` is unauthenticated
and sent in cleartext — appropriate only on this lab's isolated management
network. Do not reuse this configuration on anything reachable outside an
isolated lab; see the earlier 2-node lab's README for the SNMPv3
alternative pattern.

## SNMP traps and syslog

Every FRR/switch node (all 18, not the 3 test hosts) also sends:

- **SNMP traps** (`trap2sink 10.167.0.9 public` in `snmpd.conf`,
  `authtrapenable 1`, `linkUpDownNotifications yes`) — linkUp/linkDown,
  coldStart, and authentication-failure traps go to `10.167.0.9`.
- **Syslog** — every node runs `rsyslogd`, configured
  (`configs/shared/rsyslog.conf`, bind-mounted identically everywhere) to
  forward everything it receives on the local `/dev/log` socket to
  `10.167.0.9:514/udp`, while also keeping a local copy at
  `/var/log/syslog` for on-box troubleshooting.
- **Config-change audit logging** — every router's `frr.conf` has `log
  syslog informational` (so FRR's log output reaches rsyslog, not just its
  own log file) plus `log commands`, which makes every daemon log each
  configuration command it receives — including ones typed by hand via
  `vtysh` — to that same log stream. Combined with the syslog forwarding
  above, a manual `docker exec ... vtysh -c "conf t" -c "..."` on any node
  shows up centrally at `10.167.0.9`, not just in the container's own log
  file. `br-acc1` is the one exception — it runs no FRR routing daemons at
  all (pure L2 switch), so there's nothing there to audit.

`tests/run-tests.sh` verifies all three are actually configured and
running on every node (see its "management" section) — this only checks
that the *lab side* is correctly pointed at `10.167.0.9`; it does not
stand up a receiver there. Point an actual syslog/trap collector at that
address on your monitoring host to receive them.

## Known limitations / not yet verified

This sandbox has no running Docker daemon and no `containerlab` binary, so
this lab is authored and fixed against real deployment feedback from the
user's own environment, not validated end to end from this sandbox itself.

**Fixed from a real test run:**

- `border1`, `leaf1`, and `leaf2`'s *default* (underlay) BGP instances were
  missing `no bgp ebgp-requires-policy`. FRR enforces RFC 8212 by default:
  an eBGP session without an explicit route-map/policy on an
  address-family silently exchanges *nothing* in that AF, even though the
  session itself shows Established. This was present on spine1/spine2 and
  on border1's `vrf TENANT-A` instance, but missing on the three default
  instances that actually carry the `l2vpn evpn` AF between the spines and
  the DC devices — so EVPN sessions came up but no routes crossed them.
  Fixed by adding the knob to all three.
- The three end hosts' (`br-h1`, `dc-h1`, `dc-h2`) `exec:` blocks only ran
  `ip addr add` / `ip route add`, never `ip link set eth1 up`. If
  containerlab doesn't bring the veth up for you on a plain `linux`-kind
  node, the host never gets a working interface at all — symptomatic of a
  host that can't even ping its own directly-connected VRRP gateway.
  Fixed by bringing the interface up explicitly first.
- The test script itself had a real bug: several checks tested for a
  neighbor's IP address appearing in `show bgp ... summary` output, which
  is true whether or not the session is actually Established (the IP is
  in the table regardless of state). Replaced those with a `bgp_estab`
  helper that checks the neighbor's row isn't in a down/pending state.
  Also fixed a check that expected leaf1 to receive leaf2's Type-2 host
  route directly — L2VNIs stay import-isolated by route-target design;
  what should actually cross between leaf1 and leaf2 is each other's
  subnet as an EVPN Type-5 route via the shared L3VNI 5000 route-target.
- Ping retries were on the same ~90s-per-attempt budget as control-plane
  convergence checks, which made a genuinely broken data-plane check look
  like a hang. Data-plane pings now use a separate, shorter retry budget
  (~12s) since convergence is already checked earlier in the script.
- All four PEs' `vrf CUST-A` config had `label vpn export allocation-mode
  per-vrf`, which is not valid FRR syntax (the real command is `label vpn
  export auto`). Integrated config skips unrecognized lines instead of
  erroring, so every PE silently had no export label configured at all —
  confirmed on a live pe1 by `show bgp summary` showing the VPNv4 session
  to rr1 Established but `PfxSnt 0`: nothing was ever reaching the VPNv4
  table to reflect, which is also why border1 saw nothing downstream.
  Fixed on all four PEs.
- All four PEs' `eth1` and border1's `eth1`/`eth2` (the VRF-bound CE-facing
  interfaces) were declared as `interface eth1` followed by a nested `vrf
  CUST-A` sub-statement, instead of the compound `interface eth1 vrf
  CUST-A` form. FRR resolves `interface eth1` (no VRF suffix) as the
  default-VRF's `eth1` — a different object from the kernel's actual
  `eth1`, which `prestart.sh` already enslaved into the VRF before FRR
  started — so the configured address was silently withdrawn and the
  PE-CE eBGP session sat in `Active` with 0 messages sent/received
  forever (a pure TCP-level failure, not a BGP one). Fixed by using the
  single-line `interface eth1 vrf CUST-A` / `interface eth1 vrf TENANT-A`
  form everywhere a data interface lives inside a VRF.
- Added an MPLS/next-hop data-plane validation section to
  `tests/run-tests.sh`: LDP label bindings and a populated kernel MPLS
  FIB on every P/PE router, that the P routers run no `bgpd` and the
  route reflector runs no `ldpd` (proving transport and service stay
  architecturally separate), and that the VPNv4 next-hop for a
  reflected route is the originating far-PE's loopback — never `rr1`'s.
- Added SNMP trap (`trap2sink`), syslog forwarding (`rsyslogd` +
  `configs/shared/rsyslog.conf`), and config-change audit logging (`log
  syslog` + `log commands` in every `frr.conf`) — all pointed at
  `10.167.0.9` — plus a "management" test section that verifies each is
  actually configured and running on every node. See "SNMP traps and
  syslog" above.

**Still worth double-checking on your next run:**

- Re-run `show bgp summary` on pe1 — `PfxSnt` toward rr1 should now be
  non-zero, and `rr1 <-> peN VPNv4 session` / `border1 vrf TENANT-A sees
  branch route` in `tests/run-tests.sh` should start passing. If `PfxSnt`
  is still 0, check `show bgp vrf CUST-A ipv4 unicast` on pe1 first — if
  that's empty too, the break is further upstream (the CE-facing session
  to br-core1, or OSPF redistribution on br-core1), not the VPNv4 export.
- FRR's `daemons` file format and VRF/EVPN CLI have shifted across major
  versions; if a daemon won't start or a command is rejected, check
  `docker exec -it <node> cat /var/log/frr/frr.log` and compare against
  the FRR version actually pulled from `deb.frrouting.org` at build time
  (`FRR_COMPONENT` in the Dockerfile defaults to `frr-stable`; pin it to
  e.g. `frr-9` for a reproducible build).
- The `ghcr.io/srl-labs/network-multitool` image (used for the three end
  hosts) needs outbound registry access from the containerlab host.
