# Sourced by every node's prestart.sh. containerlab starts a node's
# container and attaches its veth links as two separate steps — on a
# large topology under load, the entrypoint (and therefore prestart.sh)
# can start running before every link for that node has been attached
# yet. Without waiting, "ip link set eth1 ..." fails with "Cannot find
# device eth1", which is fatal under prestart.sh's "set -e" and crashes
# the container into a restart loop — which in turn can make
# containerlab's overall deploy time out and cancel every other node,
# even ones that were perfectly fine. wait_for_iface makes prestart.sh
# wait for its interfaces to actually exist instead of assuming they do.

wait_for_iface() {
    local iface="$1" timeout="${2:-90}" waited=0
    while ! ip link show "$iface" >/dev/null 2>&1; do
        if [ "$waited" -ge "$timeout" ]; then
            echo "[prestart] ERROR: interface $iface did not appear within ${timeout}s" >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}
