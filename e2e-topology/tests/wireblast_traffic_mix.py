#!/usr/bin/env python3
"""
Generates a mixed traffic profile from a source node (br-h1 by default) to
the DC hosts (dc-h1/dc-h2) using wireblast (https://github.com/atoonk/
wireblast), split by percentage across four traffic "types":

  voice - small fixed-size UDP flows on a voice-like port. Approximates a
          G.711 20ms RTP stream (218-byte frames: 14 Eth + 20 IP + 8 UDP +
          12 RTP + 160 payload + 4 FCS), not a real RTP/SIP session.
  web   - stateless TCP SYNs to port 443. Wireblast has no TCP handshake or
          payload support (see its --mode tcp-syn docs) - this is SYN-rate
          traffic shaped like a wave of HTTPS connection attempts, not real
          TLS/HTTP payloads.
  udp   - plain UDP to a port you choose, for anything else.
  imix  - wireblast's native --mode imix: UDP framing with the classic
          Internet Mix size distribution (64B x7, 594B x4, 1518B x1, mean
          362B). No --packet-size is passed for it - the distribution is
          built in and wireblast ignores --packet-size in this mode.

All four run CONCURRENTLY for the same --duration, not as sequential
slices of it - wireblast explicitly supports reusing an already-attached
XDP program on one interface (internal/dataplane/runner.go's "Reused"
handling), so multiple wireblast processes sharing eth1 at once is by
design, not a hack. --mix percentages split the aggregate --total-pps
budget across the four types, then split evenly again across however
many --dst-nodes you target.

--src-node picks where traffic originates. br-h1/dc-h1/dc-h2 resolve
automatically (short name -> container/interface/IP below); any other
node needs --src-iface and --src-ip given explicitly, since a router's
data-plane interface and address aren't a single obvious default the way
a single-homed end host's are.

Requires the wireblast binary (not included) available locally for
--deploy, or already present in the source node at REMOTE_BINARY.
"""
import argparse
import subprocess
import sys

# Known end hosts: short name -> (container name suffix, iface, IP). Routers
# and switches aren't listed here on purpose - use --src-iface/--src-ip for
# anything not in this table.
NODES = {
    "br-h1": {"iface": "eth1", "ip": "10.1.10.11"},
    "dc-h1": {"iface": "eth1", "ip": "10.2.110.11"},
    "dc-h2": {"iface": "eth1", "ip": "10.2.120.11"},
}

LOCAL_BINARY = "/root/wireblast"
REMOTE_BINARY = "/usr/local/bin/wireblast"

TRAFFIC_TYPES = ["voice", "web", "udp", "imix"]


def normalize_node_name(name):
    if not name.startswith("clab-e2e-topology-"):
        return f"clab-e2e-topology-{name}"
    return name


def resolve_src(args):
    """Returns (container_name, iface, ip) for --src-node, using the NODES
    table for known hosts and requiring explicit overrides otherwise."""
    short = args.src_node
    if short in NODES:
        iface = args.src_iface or NODES[short]["iface"]
        ip = args.src_ip or NODES[short]["ip"]
        return normalize_node_name(short), iface, ip
    if not args.src_iface or not args.src_ip:
        raise ValueError(
            f"'{short}' isn't one of {list(NODES)} - give --src-iface and "
            f"--src-ip explicitly for any other node"
        )
    return normalize_node_name(short), args.src_iface, args.src_ip


def parse_mix(spec):
    """Parses 'voice=20,web=50,udp=30' into {'voice': 20.0, ...}. Unlisted
    types default to 0. Must sum to 100 (within floating-point tolerance)."""
    mix = {t: 0.0 for t in TRAFFIC_TYPES}
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "=" not in part:
            raise ValueError(f"'{part}' is not in type=percent form")
        name, pct = part.split("=", 1)
        name = name.strip().lower()
        if name not in TRAFFIC_TYPES:
            raise ValueError(f"unknown traffic type '{name}' - must be one of {TRAFFIC_TYPES}")
        mix[name] = float(pct.strip())
    total = sum(mix.values())
    if abs(total - 100.0) > 0.01:
        raise ValueError(f"--mix percentages must sum to 100, got {total}")
    return mix


def parse_pps(s):
    """Parses '1M'/'500k'/plain numbers the same way wireblast's own --pps
    does, just enough to compute per-type/per-destination shares before
    handing wireblast each share as a plain integer."""
    s = s.strip().lower()
    mult = 1
    if s.endswith("m"):
        mult, s = 1_000_000, s[:-1]
    elif s.endswith("k"):
        mult, s = 1_000, s[:-1]
    return int(float(s) * mult)


def check_running(node):
    res = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", node],
                          capture_output=True, text=True)
    return res.stdout.strip() == "true"


def deploy_binary(src_node):
    print(f"\033[1;34m[SYSTEM]\033[0m Deploying wireblast binary to {src_node}...")
    if not check_running(src_node):
        print(f" [\033[91mOFFLINE\033[0m] {src_node} is not running.")
        return False
    cp = subprocess.run(["docker", "cp", LOCAL_BINARY, f"{src_node}:{REMOTE_BINARY}"],
                         capture_output=True, text=True)
    if cp.returncode != 0:
        print(f" [\033[91mFAILED\033[0m] copy to {src_node}: {cp.stderr.strip()}")
        return False
    subprocess.run(["docker", "exec", "-u", "0", src_node, "chmod", "+x", REMOTE_BINARY],
                    capture_output=True, text=True)
    print(f" [\033[92mOK\033[0m] Deployed to {src_node}.")
    return True


def stop_all(src_node, dry_run=False):
    cmd = ["docker", "exec", "-u", "0", src_node, "pkill", "-f", "wireblast"]
    if dry_run:
        print(f"[DRY-RUN] {' '.join(cmd)}")
        return
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode == 0:
        print(f" [\033[92mSTOPPED\033[0m] Terminated running wireblast processes on {src_node}.")
    else:
        print(f" [\033[90mIDLE\033[0m] No running wireblast processes found on {src_node}.")


def build_command(binary, src_node, src_iface, src_ip, ttype, pps, duration, dst_ip, flows, args):
    cmd = [
        "docker", "exec", "-u", "0", "-d", src_node,
        binary, "--no-tui", "--start",
        "-i", src_iface,
        "--src-ip", src_ip, "--dst-ip", dst_ip,
        "--pps", str(pps), "--duration", duration,
        "--flows", str(flows),
    ]
    if ttype == "voice":
        cmd += ["--mode", "udp", "--dst-port", str(args.voice_port),
                "--packet-size", str(args.voice_packet_size)]
    elif ttype == "web":
        cmd += ["--mode", "tcp-syn", "--dst-port", str(args.web_port)]
        if args.web_packet_size:
            cmd += ["--packet-size", str(args.web_packet_size)]
    elif ttype == "udp":
        cmd += ["--mode", "udp", "--dst-port", str(args.udp_port),
                "--packet-size", str(args.udp_packet_size)]
    elif ttype == "imix":
        cmd += ["--mode", "imix", "--dst-port", str(args.imix_port)]
    return cmd


def main():
    p = argparse.ArgumentParser(
        description="Mixed voice/web/UDP/imix traffic generator to the DC hosts, using wireblast.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--src-node", default="br-h1",
                   help="node to originate traffic from (default: br-h1). "
                        "br-h1/dc-h1/dc-h2 resolve automatically; anything else "
                        "needs --src-iface and --src-ip too")
    p.add_argument("--src-iface", help="source interface (required for a --src-node not in the known table)")
    p.add_argument("--src-ip", help="source IP (required for a --src-node not in the known table)")
    p.add_argument("--dst-nodes", nargs="+", default=["dc-h1", "dc-h2"], choices=list(NODES),
                   help="destination hosts by short name (default: dc-h1 dc-h2)")
    p.add_argument("--mix", default="voice=20,web=40,udp=20,imix=20",
                   help="traffic-type percentages, e.g. 'voice=30,web=40,udp=10,imix=20' (must sum to 100)")
    p.add_argument("--total-pps", default="50000",
                   help="aggregate packet-rate budget across all types and destinations (e.g. 1M, 500k)")
    p.add_argument("--duration", default="60s", help="how long to run (wireblast -d syntax, e.g. 60s, 5m)")
    p.add_argument("--flows", type=int, default=4, help="flows per type per destination (default: 4)")
    p.add_argument("--udp-port", type=int,
                   help="destination port for the 'udp' traffic type (required if its mix %% > 0)")
    p.add_argument("--voice-port", type=int, default=5004,
                   help="destination port for voice/RTP-like traffic (default: 5004)")
    p.add_argument("--voice-packet-size", type=int, default=218,
                   help="frame size for voice traffic (default: 218, a G.711 20ms RTP frame)")
    p.add_argument("--web-port", type=int, default=443,
                   help="destination port for web/HTTPS traffic (default: 443)")
    p.add_argument("--web-packet-size", type=int, default=None,
                   help="frame size override for web SYN traffic (default: wireblast's own default)")
    p.add_argument("--udp-packet-size", type=int, default=512,
                   help="frame size for the udp traffic type (default: 512)")
    p.add_argument("--imix-port", type=int, default=8080,
                   help="destination port for imix traffic (default: 8080; frame sizes are "
                        "wireblast's built-in IMIX distribution, not configurable here)")
    p.add_argument("--binary", default=REMOTE_BINARY, help="path to wireblast inside the source node")
    p.add_argument("--deploy", action="store_true", help="copy the wireblast binary into the source node first")
    p.add_argument("--stop", action="store_true", help="kill all running wireblast processes on the source node and exit")
    p.add_argument("--dry-run", action="store_true", help="print the commands without running them")
    args = p.parse_args()

    try:
        src_node, src_iface, src_ip = resolve_src(args)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    if args.stop:
        print(f"\033[1;34m[SYSTEM]\033[0m Stopping all wireblast processes on {src_node}...")
        stop_all(src_node, dry_run=args.dry_run)
        sys.exit(0)

    if args.src_node in args.dst_nodes:
        print(f"error: --src-node '{args.src_node}' is also in --dst-nodes - can't generate traffic to itself",
              file=sys.stderr)
        sys.exit(1)

    try:
        mix = parse_mix(args.mix)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    if mix["udp"] > 0 and args.udp_port is None:
        print("error: --udp-port is required when the 'udp' mix percentage is > 0", file=sys.stderr)
        sys.exit(1)

    total_pps = parse_pps(args.total_pps)
    dst_ips = [NODES[n]["ip"] for n in args.dst_nodes]

    print("=" * 78)
    print(f"       WIREBLAST TRAFFIC MIX: {args.src_node} -> " + ", ".join(args.dst_nodes))
    print("=" * 78)
    print(f"Source: {src_node} ({src_iface}, {src_ip})")
    print(f"Total PPS budget: {total_pps:,}   Duration: {args.duration}   "
          f"Destinations: {len(dst_ips)}")
    print("-" * 78)

    if args.deploy:
        if not deploy_binary(src_node):
            sys.exit(1)

    plan = []
    for ttype in TRAFFIC_TYPES:
        pct = mix[ttype]
        if pct <= 0:
            continue
        type_pps = round(total_pps * pct / 100)
        per_dst_pps = max(1, round(type_pps / len(dst_ips)))
        for dst_name, dst_ip in zip(args.dst_nodes, dst_ips):
            plan.append((ttype, pct, dst_name, dst_ip, per_dst_pps))

    for ttype, pct, dst_name, dst_ip, per_dst_pps in plan:
        print(f"  {ttype:6s} {pct:5.1f}%  -> {dst_name:6s} ({dst_ip})  "
              f"{per_dst_pps:>8,} pps")
    print("-" * 78)

    launched = 0
    for ttype, _pct, dst_name, dst_ip, per_dst_pps in plan:
        cmd = build_command(args.binary, src_node, src_iface, src_ip,
                             ttype, per_dst_pps, args.duration, dst_ip, args.flows, args)
        if args.dry_run:
            print(f"[DRY-RUN] {' '.join(cmd)}")
            launched += 1
            continue
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode == 0:
            print(f" [\033[92mLAUNCHED\033[0m] {ttype} -> {dst_name} @ {per_dst_pps:,} pps")
            launched += 1
        else:
            print(f" [\033[91mFAILED\033[0m] {ttype} -> {dst_name}: {res.stderr.strip()}")

    print("=" * 78)
    print(f"{launched}/{len(plan)} flows launched. "
          f"Use --stop to kill them early, or ./tests/link_utilization.py to watch them.")
    print("=" * 78)


if __name__ == "__main__":
    main()
