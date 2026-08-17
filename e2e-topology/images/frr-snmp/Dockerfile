# Shared node image for the Branch / ISP / Data-Centre E2E lab.
#
# One image is reused for every router, the L2 access switch, and the DC
# VTEPs; behaviour is driven entirely by what's bind-mounted per node:
#   - /etc/frr/daemons     which FRR daemons run on this node (zebra, bgpd,
#                          ospfd, staticd, ldpd, vrrpd — all built with the
#                          frr-snmp AgentX module where FRR supports it)
#   - /etc/frr/frr.conf    the node's routing configuration
#   - /etc/snmp/snmpd.conf the node's SNMP master-agent configuration
#   - /etc/frr-lab/prestart.sh (optional) node-specific Linux networking
#                          setup that must run before FRR starts: VLAN
#                          trunking on the access switch, or VXLAN/bridge/
#                          VRF netdevices for the DC EVPN fabric.
#   - /etc/rsyslog.conf    forwards local syslog (FRR's "log syslog", incl.
#                          "log commands" config-change audit records) to
#                          the monitoring host's syslog receiver.
#
# Build:
#   docker build -t clab-frr-snmp:e2e -f images/frr-snmp/Dockerfile images/frr-snmp

FROM debian:bookworm-slim

# Tracks the latest FRR stable release line. Pin to e.g. "frr-9" if you need
# a specific major version instead.
ARG FRR_COMPONENT=frr-stable

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
        iproute2 iputils-ping bridge-utils vlan procps \
        snmpd snmp \
        lldpd \
        rsyslog \
        openssh-server \
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
    && mkdir -p /var/log/frr && chown frr:frr /var/log/frr \
    && mkdir -p /etc/frr-lab

# SSH access for manual troubleshooting on the mgmt network. Lab-only
# credential (root/clab123) - see the README security note; do not reuse
# this image's sshd config anywhere reachable outside an isolated lab.
RUN mkdir -p /run/sshd \
    && ssh-keygen -A \
    && echo 'root:clab123' | chpasswd \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
