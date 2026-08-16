# FRR node image for the OSPF + BGP + LLDP + SNMP container lab.
#
# Adds to a plain Debian base:
#   - FRR (zebra, bgpd, ospfd, staticd) from the official FRR apt repo,
#     including the frr-snmp package that builds the AgentX SNMP module
#     into zebra/bgpd/ospfd (BGP4-MIB, OSPF-MIB, plus interface/IP stats).
#   - net-snmp (snmpd) acting as the local SNMP master/AgentX agent.
#   - lldpd for 802.1AB LLDP, started with its own SNMP AgentX subagent.
#
# Build:
#   docker build -t clab-frr-snmp:latest -f images/frr-snmp/Dockerfile images/frr-snmp

FROM debian:bookworm-slim

# Tracks the latest FRR stable release line. Pin to e.g. "frr-9" if you need
# a specific major version instead.
ARG FRR_COMPONENT=frr-stable

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
        iproute2 iputils-ping \
        snmpd snmp \
        lldpd \
        tini \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.frrouting.org/frr/keys.asc -o /etc/apt/keyrings/frrouting.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/frrouting.asc] https://deb.frrouting.org/frr $(lsb_release -s -c) ${FRR_COMPONENT}" \
        > /etc/apt/sources.list.d/frr.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends frr frr-pythontools frr-snmp \
    && rm -rf /var/lib/apt/lists/*

# AgentX master socket directory: FRR daemons (user "frr") and lldpd both
# need to connect here. Permissive perms are acceptable inside an isolated
# lab container; tighten with a shared group in any shared environment.
RUN mkdir -p /var/agentx && chmod 777 /var/agentx \
    && mkdir -p /var/log/frr && chown frr:frr /var/log/frr

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
