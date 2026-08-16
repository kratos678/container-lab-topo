# customer_inventory.csv

Inventory rows for the 18 network devices in `e2e-lab.clab.yml` (the
branch/ISP/DC routers and the access switch), in the same column format
used by Selector Analytics' `customer_inventory` table. The 3 end hosts
(`br-h1`, `dc-h1`, `dc-h2`) are excluded — they're test endpoints, not
SNMP-monitored infrastructure.

Naming convention: `{STATE}-{DOMAIN}-{ROLE}-{TYPE}{NUM}`, where `DOMAIN` is
`BR` (branch) / `ISP` / `DC`, `ROLE` is the device's function, and
`TYPE`+`NUM` is `R##` for a router or `SW##` for a switch. `##` is the
device's mgmt IP last octet minus 100, so it's directly traceable back to
`e2e-lab.clab.yml`.

Location assignments: branch devices sit in Chicago, IL; the DC (border,
spine, leaf) sits in Los Angeles, CA; the ISP's P-only core routers and
route reflector sit in Denver, CO (a separate backbone location, not
co-located with either edge); each PE is placed in whichever city its CE
faces — pe1/pe3 (branch-facing) in Chicago, pe2/pe4 (DC-facing) in Los
Angeles.

| Device row        | mgmt IP       | containerlab node |
|-------------------|---------------|--------------------|
| IL-BR-CORE-R01    | 10.255.0.101  | br-core1 |
| IL-BR-AGG-R02     | 10.255.0.102  | br-dist1 |
| IL-BR-AGG-R03     | 10.255.0.103  | br-dist2 |
| IL-BR-ACC-SW04    | 10.255.0.104  | br-acc1 |
| IL-ISP-PE-R06     | 10.255.0.106  | pe1 |
| CA-ISP-PE-R07     | 10.255.0.107  | pe2 |
| IL-ISP-PE-R08     | 10.255.0.108  | pe3 |
| CA-ISP-PE-R09     | 10.255.0.109  | pe4 |
| CO-ISP-P-R10      | 10.255.0.110  | p1 |
| CO-ISP-P-R11      | 10.255.0.111  | p2 |
| CO-ISP-P-R12      | 10.255.0.112  | p3 |
| CO-ISP-P-R13      | 10.255.0.113  | p4 |
| CO-ISP-RR-R14     | 10.255.0.114  | rr1 |
| CA-DC-BORDER-R15  | 10.255.0.115  | border1 |
| CA-DC-SPINE-R16   | 10.255.0.116  | spine1 |
| CA-DC-SPINE-R17   | 10.255.0.117  | spine2 |
| CA-DC-LEAF-R18    | 10.255.0.118  | leaf1 |
| CA-DC-LEAF-R19    | 10.255.0.119  | leaf2 |

`namespace`/`pingprofile` = `FRR`, `profile` = `linux_router_v2`,
`vendor`/`platform` = `frr` across every row, matching the example and
reflecting that every device in this lab runs the same FRR-based image
polled over the same SNMPv2c profile (see `../README.md` for the SNMP
setup and community string).
