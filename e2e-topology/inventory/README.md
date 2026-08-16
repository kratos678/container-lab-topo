# customer_inventory.csv

Inventory rows for the 18 network devices in `e2e-lab.clab.yml` (the
branch/ISP/DC routers and the access switch), in the same column format
used by Selector Analytics' `customer_inventory` table. The 3 end hosts
(`br-h1`, `dc-h1`, `dc-h2`) are excluded — they're test endpoints, not
SNMP-monitored infrastructure.

`device` is the containerlab node name as-is (`pe1`, `border1`, `leaf2`,
...) — no separate naming scheme. This also matches each node's FRR
`hostname` (set in `configs/*/*/frr.conf`), so SNMP's `sysName` and LLDP's
advertised system name agree with this column directly; no mapping table
needed.

Location assignments: branch devices sit in Chicago, IL; the DC (border,
spine, leaf) sits in Los Angeles, CA; the ISP's P-only core routers and
route reflector sit in Denver, CO (a separate backbone location, not
co-located with either edge); each PE is placed in whichever city its CE
faces — pe1/pe3 (branch-facing) in Chicago, pe2/pe4 (DC-facing) in Los
Angeles.

`namespace`/`pingprofile` = `FRR`, `profile` = `linux_router_v2`,
`vendor`/`platform` = `frr` across every row, reflecting that every
device in this lab runs the same FRR-based image polled over the same
SNMPv2c profile (see `../README.md` for the SNMP setup and community
string, and the "SNMP traps and syslog" section for the trap/syslog
receiver configuration).
