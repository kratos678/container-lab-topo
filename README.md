# FRR OSPF + BGP + LLDP + SNMP Container Lab

A two-node [containerlab](https://containerlab.dev/) topology built on FRR that demonstrates:

- An OSPF underlay that exchanges router loopback addresses.
- An eBGP session peered between those loopbacks (riding on the OSPF-learned route).
- LLDP enabled on the inter-node link.
- SNMP (via net-snmp + AgentX) exposing BGP, OSPF, LLDP, interface, CPU, and memory
  state for external monitoring (e.g. Selector Analytics).

## Topology

```
        eth1                         eth1
  +-----------+   10.0.12.0/30   +-----------+
  |    r1     |------------------|    r2     |
  | AS 65001  |                  | AS 65002  |
  | lo 10.0.0.1/32                | lo 10.0.0.2/32
  +-----------+                  +-----------+
   mgmt: 172.100.100.11           mgmt: 172.100.100.12
```

| Node | AS    | eth1 (p2p)      | Loopback     | Mgmt IP          |
|------|-------|-----------------|--------------|------------------|
| r1   | 65001 | 10.0.12.1/30    | 10.0.0.1/32  | 172.100.100.11   |
| r2   | 65002 | 10.0.12.2/30    | 10.0.0.2/32  | 172.100.100.12   |

OSPF area 0 runs on both the point-to-point link and the loopbacks (loopback
interfaces are passive). BGP is eBGP, sourced from and peered against the
loopback addresses, reachable only via the OSPF-installed route — so BGP
depends on OSPF converging first, mirroring a typical PE/route-reflector
design pattern at small scale.

## Repository layout

```
frr-lab.clab.yml            containerlab topology definition
images/frr-snmp/            Dockerfile + entrypoint for the node image
  Dockerfile                 Debian + FRR (official apt repo) + frr-snmp + lldpd + snmpd
  docker-entrypoint.sh        starts snmpd, then lldpd -x, then FRR daemons
configs/r1/, configs/r2/     per-node FRR + SNMP config, bind-mounted into each node
  daemons                     which FRR daemons to run, with `-M snmp` loaded
  frr.conf                    interfaces, OSPF, BGP, and the `agentx` directive
  vtysh.conf                  enables integrated config mode
  snmpd.conf                  SNMP master-agent config (SNMPv3 user, AgentX socket)
```

## How each requirement is met

| Requirement                        | Implementation |
|-------------------------------------|-----------------|
| 2 nodes connected to each other     | `r1:eth1 <-> r2:eth1` direct link in `frr-lab.clab.yml` |
| Loopback exchanged via OSPF         | `router ospf` advertises both the p2p subnet and each `lo` `/32` into area 0 |
| BGP peering between loopbacks       | eBGP (AS65001 <-> AS65002), `update-source lo`, `ebgp-multihop 2`, next hop reachable via OSPF |
| LLDP enabled                        | `lldpd` runs on each node and discovers the neighbor over `eth1` |
| SNMP monitoring (BGP/LLDP/OSPF/interface/CPU/memory) | `snmpd` as AgentX master; FRR's `frr-snmp` module (BGP4-MIB, OSPF-MIB, interface stats) and `lldpd -x` (LLDP-MIB) attach as AgentX subagents; IF-MIB/HOST-RESOURCES-MIB/UCD-SNMP-MIB cover interfaces, CPU, and memory natively |

## Prerequisites

- Docker
- [containerlab](https://containerlab.dev/install/) (`bash -c "$(curl -sL https://get.containerlab.dev)"`)

## Build the node image

```bash
docker build -t clab-frr-snmp:latest -f images/frr-snmp/Dockerfile images/frr-snmp
```

## Deploy the lab

```bash
sudo containerlab deploy -t frr-lab.clab.yml
```

Destroy it with:

```bash
sudo containerlab destroy -t frr-lab.clab.yml
```

## Verifying OSPF and BGP

```bash
docker exec -it clab-frr-ospf-bgp-snmp-r1 vtysh -c "show ip ospf neighbor"
docker exec -it clab-frr-ospf-bgp-snmp-r1 vtysh -c "show ip route ospf"
docker exec -it clab-frr-ospf-bgp-snmp-r1 vtysh -c "show bgp summary"
docker exec -it clab-frr-ospf-bgp-snmp-r1 vtysh -c "show bgp ipv4 unicast"
```

r1 should show an OSPF full neighbor at `10.0.12.2`, a `/32` OSPF route to
`10.0.0.2`, an established BGP session to `10.0.0.2`, and a learned BGP route
to `10.0.0.2/32`.

## Verifying LLDP

```bash
docker exec -it clab-frr-ospf-bgp-snmp-r1 lldpcli show neighbors
```

## Verifying SNMP

From the clab host (or any host that can reach the mgmt network), using the
SNMPv3 user configured in `configs/*/snmpd.conf`:

```bash
# System / sanity check
snmpwalk -v3 -u selector-mon -l authPriv -a SHA -A 'ChangeMe-Auth-Passphrase1' \
         -x AES -X 'ChangeMe-Priv-Passphrase1' 172.100.100.11 1.3.6.1.2.1.1

# Interfaces (IF-MIB)
snmpwalk -v3 -u selector-mon -l authPriv -a SHA -A 'ChangeMe-Auth-Passphrase1' \
         -x AES -X 'ChangeMe-Priv-Passphrase1' 172.100.100.11 1.3.6.1.2.1.2.2

# CPU / memory (HOST-RESOURCES-MIB, UCD-SNMP-MIB)
snmpwalk -v3 -u selector-mon -l authPriv -a SHA -A 'ChangeMe-Auth-Passphrase1' \
         -x AES -X 'ChangeMe-Priv-Passphrase1' 172.100.100.11 1.3.6.1.2.1.25
snmpwalk -v3 -u selector-mon -l authPriv -a SHA -A 'ChangeMe-Auth-Passphrase1' \
         -x AES -X 'ChangeMe-Priv-Passphrase1' 172.100.100.11 1.3.6.1.4.1.2021

# OSPF (OSPF-MIB, via FRR AgentX)
snmpwalk -v3 -u selector-mon -l authPriv -a SHA -A 'ChangeMe-Auth-Passphrase1' \
         -x AES -X 'ChangeMe-Priv-Passphrase1' 172.100.100.11 1.3.6.1.2.1.14

# BGP (BGP4-MIB, via FRR AgentX)
snmpwalk -v3 -u selector-mon -l authPriv -a SHA -A 'ChangeMe-Auth-Passphrase1' \
         -x AES -X 'ChangeMe-Priv-Passphrase1' 172.100.100.11 1.3.6.1.2.1.15

# LLDP (LLDP-MIB, via lldpd AgentX)
snmpwalk -v3 -u selector-mon -l authPriv -a SHA -A 'ChangeMe-Auth-Passphrase1' \
         -x AES -X 'ChangeMe-Priv-Passphrase1' 172.100.100.11 1.0.8802.1.1.2
```

If a walk against one of the AgentX-backed trees (OSPF/BGP/LLDP) comes back
empty, check `docker exec -it clab-frr-ospf-bgp-snmp-r1 tail -f /var/log/snmpd.log`
for AgentX subagent connection/registration errors — the most common cause
is the subagent starting before `snmpd` finished initializing (the entrypoint
starts them in order, but a very slow first boot could still race).

## Security notes

- `configs/*/snmpd.conf` ships with placeholder SNMPv3 auth/priv passphrases
  (`ChangeMe-Auth-Passphrase1` / `ChangeMe-Priv-Passphrase1`) and a single
  read-only view covering the whole MIB tree. **Change these before using
  the image outside an isolated lab.** For any shared or production-adjacent
  environment, narrow the `view all included .1` line to only the subtrees
  you actually poll, and check with your security team before exposing SNMP
  beyond the lab's management network.
- The commented-out `rocommunity` line is SNMPv2c (unauthenticated,
  cleartext community string) and is left disabled by default; only enable
  it if you specifically need v2c for a monitoring tool and understand the
  tradeoff.
- `agentXPerms 0777 0777` on `/var/agentx/master` is intentionally permissive
  so both FRR and lldpd (different users) can attach; this is reasonable for
  a single-purpose lab container but should be scoped down (shared group,
  0770) if you reuse this image pattern elsewhere.

## Known limitations / not yet verified

This was authored and reviewed against FRR's own SNMP/AgentX documentation
and the Debian `frr-snmp`/`lldpd` packaging, but **it has not been built or
deployed in this session** — the sandbox has no running Docker daemon and no
`containerlab` binary, so `docker build` / `containerlab deploy` could not be
exercised end-to-end here. Before relying on this in a real environment:

- Run the build and deploy steps above and confirm OSPF/BGP/LLDP/SNMP with
  the verification commands.
- FRR's `daemons` file format has evolved across major versions (e.g. the
  `mgmtd` daemon in newer releases); if a daemon fails to start after
  `containerlab deploy`, check `docker exec -it <node> cat /var/log/frr/frr.log`
  and adjust `configs/*/daemons` to match the FRR version actually pulled
  from `deb.frrouting.org` at build time.
- `FRR_COMPONENT` in the Dockerfile defaults to `frr-stable` (latest stable
  line); pin it to a specific major version (e.g. `frr-9`) if you need
  reproducible builds.
