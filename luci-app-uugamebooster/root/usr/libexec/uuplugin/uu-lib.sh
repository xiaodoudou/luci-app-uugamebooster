#!/bin/sh
# uu-lib.sh - discovery shared by the coexistence daemons (uu-openclash-sync,
# uu-ua3f-sync). Sourced, not run: set LOG_TAG first.

DETECT="/usr/libexec/uuplugin/uu-detect"

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
	local dev
	for dev in "$@"; do
		ip route show table all dev "$dev" 2>/dev/null | awk '{print $1}'
	done | filter_prefixes
}

# Routing tables a device's own "from <ip> lookup <table>" rules point at.
device_tables() {
	ip rule show 2>/dev/null | awk -v ip="$1" '
		{ hit = 0
		  for (i = 1; i < NF; i++)
			if ($i == "from" && ($(i + 1) == ip || $(i + 1) == ip "/32")) hit = 1 }
		hit { for (i = 1; i < NF; i++) if ($i == "lookup") print $(i + 1) }' | sort -u
}

# What UU routes into its TUNs for this one device: only the tables its own
# rules use, so one device is never exempted for another's game prefixes.
# Falls back to every TUN's routes when the device's rules lead nowhere, so an
# unexpected UU layout costs precision rather than the whole exemption.
device_prefixes() {
	local ip="$1" t dev out
	shift
	out="$(for t in $(device_tables "$ip"); do
		for dev in "$@"; do
			ip route show table "$t" dev "$dev" 2>/dev/null | awk '{print $1}'
		done
	done | filter_prefixes)"
	if [ -n "$out" ]; then echo "$out"; else collect_prefixes "$@"; fi
}

# "<device> . <prefix>" for every boosted device, the element format of a
# concatenated interval set. Such a set has no auto-merge and rejects a prefix
# nested inside another, so nested ones are dropped first: CIDR blocks either
# nest or are disjoint, never partly overlap.
device_pairs() {
	local ips="$1" ip
	shift
	for ip in $ips; do
		# Zero-padded and sorted as text: busybox sort ignores per-key "n".
		device_prefixes "$ip" "$@" | awk -F'[./]' '
			{ printf "%010.0f %02d %s\n", (($1 * 256 + $2) * 256 + $3) * 256 + $4, $5, $0 }' |
		sort | awk -v ip="$ip" '
			{ start = $1; size = 1
			  for (k = $2; k < 32; k++) size *= 2   # no "^": awk may lack libm
			  end = start + size - 1
			  if (n++ && start <= last) next
			  last = end; print ip " . " $3 }'
	done
}

# nft "add element" lines for <family table set> from device_pairs output,
# chunked: UU can route thousands of prefixes per device.
pair_batches() {
	printf '%s\n' "$2" | awk -v t="$1" '
		NF { l = l (n ? "," : "") $0
		     if (++n >= 2000) { print "add element " t " { " l " }"; l = ""; n = 0 } }
		END { if (n) print "add element " t " { " l " }" }'
}

# The distinct prefixes in device_pairs output, for the status page's count.
pair_prefixes() { printf '%s\n' "$1" | sed -n 's/.* \. //p' | sort -u; }

filter_prefixes() {
	local p mask
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
		# out of OpenClash.
		[ "$mask" -lt "$MINPFX" ] && continue
		echo "$p"
	done | sort -u
}
