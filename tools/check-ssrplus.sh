#!/bin/sh
# Run as root on a Linux test host with nft, ip, unshare, nsenter and Python 3.
# The test creates two anonymous namespaces and sends synthetic packets only.
set -eu

if [ "${1:-}" != "--isolated" ]; then
	exec unshare -n sh "$0" --isolated
fi

src="$(cd "$(dirname "$0")/../luci-app-uugamebooster/root/usr/libexec/uuplugin" && pwd)"
work="$(mktemp -d)"
sync_pid="" client=""
cleanup() {
	if [ -n "$sync_pid" ]; then kill "$sync_pid" 2>/dev/null || :; wait "$sync_pid" || :; fi
	if [ -n "$client" ]; then kill "$client" 2>/dev/null || :; wait "$client" || :; fi
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

mkdir "$work/bin"
sed -e "s|/usr/libexec/uuplugin|$work|g" -e "s|/var/run/uu-|$work/uu-|g" \
	-e "s|/tmp/\.uu-|$work/.uu-|g" "$src/uu-sync" > "$work/uu-sync"
sed "s|/usr/libexec/uuplugin|$work|g" "$src/uu-lib.sh" > "$work/uu-lib.sh"
cp -R "$src/uu-sync.d" "$work/"
cat > "$work/uu-detect" <<EOF
#!/bin/sh
printf 'boosted=%s\n' "\$(cat '$work/boosted')"
EOF
cat > "$work/bin/uci" <<'EOF'
#!/bin/sh
case "$3" in *.oc_interval) echo 1 ;; esac
EOF
cat > "$work/bin/logger" <<'EOF'
#!/bin/sh
shift 4
printf '%s\n' "$*" >&2
EOF
chmod +x "$work/uu-detect" "$work/bin/uci" "$work/bin/logger"
export PATH="$work/bin:$PATH"

wait_for() {
	local retries=12
	until "$@"; do
		[ "$retries" -gt 0 ] || { echo "Timed out: $*" >&2; nft list ruleset >&2; exit 1; }
		retries=$((retries - 1))
		sleep 1
	done
}

start_sync() {
	sh "$work/uu-sync" "$1" "$2" &
	sync_pid=$!
}

stop_sync() {
	kill "$sync_pid"
	wait "$sync_pid"
	sync_pid=""
}

unshare -n sleep 120 &
client=$!
client_ready() { [ "$(readlink "/proc/$client/ns/net")" != "$(readlink /proc/self/ns/net)" ]; }
wait_for client_ready
ip link add lan type veth peer name client
ip link set client netns "$client"
ip addr add 192.0.2.1/24 dev lan
ip link set lan up
ip link set lo up
nsenter -t "$client" -n ip link set client up
for ip in 10 20 30; do
	nsenter -t "$client" -n ip addr add "192.0.2.$ip/24" dev client
done
nsenter -t "$client" -n ip route add default via 192.0.2.1
sysctl -qw net.ipv4.ip_forward=1
for entry in '10 163 198.51.100.0/24' '20 164 203.0.113.0/24'; do
	set -- $entry
	ip link add "tun$2" type dummy
	ip link set "tun$2" up
	ip route add "$3" dev "tun$2" table "$1"
	ip route add default dev "tun$2" table "$2"
	ip rule add priority "$1" from "192.0.2.$1" lookup "$1"
	ip rule add priority "$(($1 + 1))" from "192.0.2.$1" fwmark "0x$2" lookup "$2"
done
printf '%s\n' '192.0.2.10 192.0.2.20' > "$work/boosted"

nft -f - <<'RULES'
table ip uu_test {
	chain prerouting {
		type filter hook prerouting priority -199; policy accept;
		ip saddr 192.0.2.10 udp dport 53 meta mark set 0x163
		ip saddr 192.0.2.10 ip daddr 198.18.0.1 udp dport 443 meta mark set 0x163
		ip saddr 192.0.2.10 ip daddr 198.18.0.2 udp dport 443 meta mark set 0x164
	}
}
RULES
cat > "$work/tcp.nft" <<'RULES'
table inet ss_spec {
	chain ss_spec_prerouting {
		type nat hook prerouting priority 0; policy accept;
		tcp dport 8443 counter redirect to :1234 comment "ssr-tcp"
		udp dport 443 counter drop comment "ssr-quic"
	}
}
RULES
cat > "$work/udp.nft" <<'RULES'
table ip ss_spec_mangle {
	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;
		udp dport { 53, 80, 443 } counter drop comment "ssr-udp"
	}
}
RULES
nft -f "$work/tcp.nft"
nft -f "$work/udp.nft"

send() {
	nsenter -t "$client" -n python3 - "$@" <<'PY'
import socket
import sys

kind, source, destination, port = sys.argv[1:]
with socket.socket(socket.AF_INET, socket.SOCK_STREAM if kind == "tcp" else socket.SOCK_DGRAM) as sock:
    sock.bind(("192.0.2." + source, 0))
    sock.settimeout(0.2)
    if kind == "tcp":
        sock.connect_ex((destination, int(port)))
    else:
        sock.sendto(b"test", (destination, int(port)))
PY
}

packets() {
	nft list chain "$1" "$2" "$3" | awk -v comment="\"$4\"" '
		index($0, "comment " comment) {
			for (i = 1; i < NF; i++) if ($i == "packets") print $(i + 1)
		}'
}

hit() {
	local family="$1" table="$2" chain="$3" tag="$4" before after
	shift 4
	before="$(packets "$family" "$table" "$chain" "$tag")"
	send "$@"
	after="$(packets "$family" "$table" "$chain" "$tag")"
	[ -n "$before" ] && [ "$after" -gt "$before" ] || {
		echo "No hit on $table/$chain $tag for $*" >&2
		exit 1
	}
}

has_rule() {
	nft list chain "$1" "$2" "$3" | grep -Fq "comment \"uu-sync-${4:-dest}\""
}

hit inet ss_spec ss_spec_prerouting ssr-tcp tcp 10 198.51.100.1 8443
hit ip ss_spec_mangle prerouting ssr-udp udp 10 198.51.100.1 443
start_sync ssrplus cooperative
wait_for has_rule inet ss_spec ss_spec_prerouting
wait_for has_rule ip ss_spec_mangle prerouting
wait_for nft get element ip ss_spec_mangle uu_sync_lease "{ $(date +%s) }"

hit inet ss_spec ss_spec_prerouting uu-sync-dest tcp 10 198.51.100.1 8443
hit inet ss_spec ss_spec_prerouting uu-sync-dest tcp 20 203.0.113.1 8443
hit inet ss_spec ss_spec_prerouting ssr-tcp tcp 10 203.0.113.1 8443
hit inet ss_spec ss_spec_prerouting ssr-tcp tcp 30 198.51.100.1 8443
hit ip ss_spec_mangle prerouting uu-sync-dest udp 10 198.51.100.1 443
hit ip ss_spec_mangle prerouting uu-sync-dest udp 10 198.18.0.1 443
hit ip ss_spec_mangle prerouting uu-sync-dest udp 10 198.18.0.1 53
hit ip ss_spec_mangle prerouting ssr-udp udp 10 198.18.0.2 443
hit ip ss_spec_mangle prerouting ssr-udp udp 30 198.51.100.1 443

# Restore priority if a proxy rule gets inserted ahead of the exemption.
nft insert rule ip ss_spec_mangle prerouting udp dport 443 counter drop comment '"ssr-new-drop"'
exemption_first() {
	nft -a list chain ip ss_spec_mangle prerouting |
		awk '/ # handle [0-9]+$/ && !index($0, "{ # handle") {
			found = 1
			result = ($0 !~ /uu-sync-dest/)
			exit
		}
		END { exit (!found || result) }'
}
wait_for exemption_first
hit ip ss_spec_mangle prerouting uu-sync-dest udp 10 198.51.100.1 443
drop_handle="$(nft -a list chain ip ss_spec_mangle prerouting |
	awk '/comment "ssr-new-drop"/ { print $NF }')"
nft delete rule ip ss_spec_mangle prerouting handle "$drop_handle"

# Preserve an SSR+ snapshot with both devices and a valid lease.
nft list table inet ss_spec > "$work/snapshot.nft"
nft list table ip ss_spec_mangle >> "$work/snapshot.nft"
nft delete table ip ss_spec_mangle
hit inet ss_spec ss_spec_prerouting uu-sync-dest udp 10 198.51.100.1 443
nft -f "$work/udp.nft"
wait_for has_rule ip ss_spec_mangle prerouting
wait_for nft get element ip ss_spec_mangle uu_sync_lease "{ $(date +%s) }"

# The engine must rebuild restored sets even if all rule tags are present.
printf '%s\n' 192.0.2.10 > "$work/boosted"
only_first_device() {
	nft get element ip ss_spec_mangle uu_boosted '{ 192.0.2.10 }' >/dev/null 2>&1 &&
		! nft get element ip ss_spec_mangle uu_boosted '{ 192.0.2.20 }' >/dev/null 2>&1
}
wait_for only_first_device
nft delete table inet ss_spec
nft delete table ip ss_spec_mangle
nft -f "$work/snapshot.nft"
wait_for only_first_device
# An old set can also be restored while the lease itself is still current.
nft add element ip ss_spec_mangle uu_boosted '{ 192.0.2.20 }'
wait_for only_first_device
hit inet ss_spec ss_spec_prerouting ssr-tcp tcp 20 203.0.113.1 8443

: > "$work/boosted"
no_exemptions() {
	! has_rule inet ss_spec ss_spec_prerouting && ! has_rule ip ss_spec_mangle prerouting
}
wait_for no_exemptions
stop_sync

# With a saved, unexpired lease, removing the live route still restores SSR+.
printf '%s\n' 192.0.2.10 > "$work/boosted"
start_sync ssrplus cooperative
wait_for has_rule inet ss_spec ss_spec_prerouting
wait_for nft get element inet ss_spec uu_sync_lease "{ $(date +%s) }"
nft list table inet ss_spec > "$work/snapshot.nft"
stop_sync
no_exemptions
nft delete table inet ss_spec
nft -f "$work/snapshot.nft"
ip route del 198.51.100.0/24 dev tun163 table 10
hit inet ss_spec ss_spec_prerouting ssr-tcp tcp 10 198.51.100.1 8443
ip route add 198.51.100.0/24 dev tun163 table 10
sleep 9
hit inet ss_spec ss_spec_prerouting ssr-tcp tcp 10 198.51.100.1 8443

# Whole-device bypass uses the same source set in both SSR+ chains, even for
# destinations outside that device's UU routes.
start_sync ssrplus bypass
wait_for has_rule inet ss_spec ss_spec_prerouting bypass
wait_for has_rule ip ss_spec_mangle prerouting bypass
wait_for nft get element ip ss_spec_mangle uu_sync_bypass_lease "{ $(date +%s) }"
hit inet ss_spec ss_spec_prerouting uu-sync-bypass tcp 10 203.0.113.1 8443
hit ip ss_spec_mangle prerouting uu-sync-bypass udp 10 203.0.113.1 443
hit inet ss_spec ss_spec_prerouting ssr-tcp tcp 20 203.0.113.1 8443
hit ip ss_spec_mangle prerouting ssr-udp udp 20 203.0.113.1 443
nft list table ip ss_spec_mangle > "$work/bypass-snapshot.nft"
stop_sync
! has_rule inet ss_spec ss_spec_prerouting bypass
! has_rule ip ss_spec_mangle prerouting bypass
hit ip ss_spec_mangle prerouting ssr-udp udp 10 203.0.113.1 443
sleep 9
nft delete table ip ss_spec_mangle
nft -f "$work/bypass-snapshot.nft"
hit ip ss_spec_mangle prerouting ssr-udp udp 10 203.0.113.1 443

# Existing single-table backends still install and remove their rules.
nft delete table inet ss_spec
nft delete table ip ss_spec_mangle
nft add table inet fw4
if ! nft add set inet fw4 prefix_probe '{ type ipv4_addr . ipv4_addr; flags interval; }' 2>/dev/null; then
	echo 'SSR+ coexistence checks passed. Kernel lacks the concatenated interval set used by OpenClash.'
	exit 0
fi
nft delete set inet fw4 prefix_probe
nft add chain inet fw4 openclash '{ type nat hook prerouting priority dstnat; policy accept; }'
start_sync openclash cooperative
wait_for has_rule inet fw4 openclash
hit inet fw4 openclash uu-sync-dest tcp 10 198.51.100.1 8443
stop_sync
! has_rule inet fw4 openclash
echo 'SSR+ and OpenClash coexistence checks passed'
