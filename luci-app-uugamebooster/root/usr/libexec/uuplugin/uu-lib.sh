#!/bin/sh
# uu-lib.sh - discovery and plumbing shared by uu-sync and its backends.
# Sourced, not run: set LOG_TAG first.
#
# Two halves, and the split matters:
#
#   - what UU itself is doing (boosted devices, its TUNs, the prefixes it
#     routes, the UDP ports and fwmark it claims) is read from the live system,
#     never assumed, because it differs between NetEase's builds;
#   - which proxies exist is a directory listing. Every backend is one file in
#     uu-sync.d/, so a new proxy integration is a new file rather than another
#     near-identical daemon to keep in step with the others.

DETECT="/usr/libexec/uuplugin/uu-detect"
SYNC_DIR="/usr/libexec/uuplugin/uu-sync.d"

# syslog gets the message with its real level. The copy for a human goes to
# stderr, and only when there is a human: procd also forwards stderr to syslog,
# so echoing unconditionally logged everything twice and relabelled every
# informational line as an error. Never stdout - several helpers below are read
# through command substitution, which would capture it as their return value.
log() { logger -t "$LOG_TAG" -p daemon.info "$@"; [ -t 2 ] && echo "[$LOG_TAG] $@" >&2; return 0; }
err() { logger -t "$LOG_TAG" -p daemon.err  "$@"; [ -t 2 ] && echo "[$LOG_TAG] $@" >&2; return 0; }

uci_get() { uci -q get "uuplugin.@uuplugin[0].$1"; }

# A bare "sleep" defers signal handling until it returns, so procd gives up
# waiting and escalates to SIGKILL. Backgrounding it and waiting lets the
# cleanup trap run immediately.
nap() { sleep "$1" & wait $!; }

INTERVAL="$(uci_get oc_interval)"; [ -z "$INTERVAL" ] && INTERVAL=5
MINPFX="$(uci_get oc_min_prefix)";  [ -z "$MINPFX" ] && MINPFX=8
TUNIF="$(uci_get oc_tun_iface)"

# The UDP ports and fwmark UU claims, when a build does something new and the
# read-back below gets it wrong. Empty means "read it from UU's own rules".
UU_UDP_PORTS="$(uci_get oc_uu_udp_ports)"
UU_MARK_CFG="$(uci_get oc_uu_mark)"

# ------------------------------------------------------------------ backends

# Every proxy integration is a descriptor file, so the list is the directory.
backends() {
	local f
	for f in "$SYNC_DIR"/*.sh; do
		[ -f "$f" ] || continue
		basename "$f" .sh
	done
}

# One descriptor variable, read without inheriting the descriptor's functions
# into the caller: backend_var nikki CONFIG
backend_var() {
	( . "$SYNC_DIR/$1.sh" >/dev/null 2>&1; eval "printf '%s' \"\$$2\"" )
}

# Installed, as opposed to merely supported. A backend whose proxy is not on
# this router is not started and not reported.
backend_installed() {
	[ -f "$(backend_var "$1" CONFIG)" ]
}

# The uci option holding a backend's mode, so the wiring needs no per-proxy
# knowledge: openclash_mode, nikki_mode, ua3f_mode, homeproxy_mode.
backend_mode() {
	local m
	m="$(uci_get "${1}_mode")"
	[ -z "$m" ] && m=cooperative
	echo "$m"
}

# ------------------------------------------------------------------ discovery

# Devices UU is currently boosting. UU creates a per-device nftables table for
# each one, which names the device's IP - a more direct signal than guessing
# from routes or leases.
#
# UU adds a policy routing rule per boosted device ("from <ip> lookup <table>")
# pointing at a table that routes into its tunnel, and usually also an
# XU_ACC_DEVICE_<ip> nftables table. The OEM build under emulation only manages
# the first of those - it boosts correctly while creating no nft tables at all -
# so the ip rule is the signal to trust, with the nft table as a supplement.
boosted_ips() {
	# Delegated to uu-detect so the status page and this daemon can never
	# disagree about what counts as boosted - including the device
	# black/whitelist, which is applied there.
	"$DETECT" 2>/dev/null | sed -n 's/^boosted=//p' | tr ' ' '\n' | grep -v '^$'
}

# Anything named utun belongs to OpenClash, so it is never a candidate.
#
# UU creates one TUN per boosted device - tun163 for the first, tun164 for the
# second, and so on - so every tun16* has to be read, not just the first.
find_tuns() {
	local d devs found="" fallback=""
	[ -n "$TUNIF" ] && { echo "$TUNIF"; return; }

	devs=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1)
	for d in $devs; do
		case "$d" in
			tun16*) found="$found $d" ;;
		esac
	done
	[ -n "$found" ] && { echo $found; return; }

	for d in $devs; do
		case "$d" in
			utun*) continue ;;
			tun*)  fallback="$d"; break ;;
		esac
	done
	[ -n "$fallback" ] && { echo "$fallback"; return; }
	echo ""
}

# Destination prefixes UU routes into its tunnel, across every one of its TUNs.
collect_prefixes() {
	local dev p mask
	for dev in "$@"; do
		ip route show table all dev "$dev" 2>/dev/null | awk '{print $1}'
	done | \
	while read -r p; do
		case "$p" in
			default|0.0.0.0/0|"") continue ;;
			*:*) continue ;;                 # IPv6 handled separately
			*[!0-9./]*) continue ;;          # not a bare v4 prefix
		esac
		case "$p" in
			*/*) mask="${p##*/}" ;;
			*)   mask=32; p="$p/32" ;;
		esac
		# Guard: never exempt a route broad enough to pull the whole internet
		# out of the proxy.
		[ "$mask" -lt "$MINPFX" ] && continue
		echo "$p"
	done | sort -u
}

# The UDP ports UU is actually marking for a device, read off the rules it just
# installed. Two shapes exist in the wild, and both are matched here:
#
#   ip saddr <ip> udp dport 53             ... xt target "MARK"   (OEM, emulated)
#   ip saddr <ip> udp dport 1025-65535     ... meta mark set 0x163 (generic)
#
# The OEM build uses its own bundled iptables-nft, so its rules land in the
# legacy "ip mangle" table rather than in an XU_ACC_DEVICE_<ip> table. Read both.
uu_marked_udp_ports() {
	local ip="$1" t
	{
		nft list table ip mangle 2>/dev/null
		for t in $(nft list tables 2>/dev/null |
		           sed -n 's/^table ip \(XU_ACC_DEVICE_.*\)$/\1/p'); do
			nft list table ip "$t" 2>/dev/null
		done
	} | awk -v ip="$ip" '
		index($0, "ip saddr " ip) == 0 { next }
		!/udp dport/                   { next }
		!/mark set|xt target "MARK"/   { next }
		{
			sub(/.*udp dport /, "")
			sub(/ (counter|meta|xt|comment|accept|return|jump|goto|drop).*/, "")
			gsub(/[{}]/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			# "{ 53, 1025-65535 }" is one rule but two ports; emit them
			# separately so the caller can merge across devices.
			n = split($0, part, /[ \t]*,[ \t]*/)
			for (j = 1; j <= n; j++)
				if (length(part[j])) print part[j]
		}'
}

# The fwmark UU routes a device's traffic with, taken from its own ip rule
# ("from <ip> fwmark 0x163/0x163 lookup 163"). Scoped to the device so a proxy's
# own mark, which sits in the same rule range, is never picked up.
uu_marked_fwmark() {
	local ip="$1"
	ip rule show 2>/dev/null | awk -v ip="$ip" '
		index($0, "from " ip) && /fwmark/ {
			for (i = 1; i <= NF; i++)
				if ($i == "fwmark") { split($(i + 1), a, "/"); print a[1]; exit }
		}'
}
