#!/bin/sh
# SSR+ uses independent prerouting hooks for TCP REDIRECT and UDP TPROXY.
# Its TCP table can also drop UDP 443 when TPROXY is disabled.

NAME=ssrplus
LABEL="SSR+"
CONFIG=/etc/config/shadowsocksr
SYNC_LEASE=1
SYNC_PREFIXES=0

sync_tables() {
	printf '%s\n' inet/ss_spec ip/ss_spec_mangle
}

sync_chains() {
	local chain
	case "$TBL" in
		ss_spec) chain=ss_spec_prerouting ;;
		ss_spec_mangle) chain=prerouting ;;
		*) return ;;
	esac
	nft -t list chain "$FAMILY" "$TBL" "$chain" >/dev/null 2>&1 && echo "$chain"
}

# The FIB lookup includes the source and the current packet mark, covering
# both explicit UU prefixes and the per-device marked UDP/DNS routes.
sync_dest_match() {
	local dev names=""
	for dev in $1; do
		case "$dev" in
			*[!a-zA-Z0-9_.-]*) continue ;;
			tun16*) ;;
			*) [ "$dev" = "$TUNIF" ] || continue ;;
		esac
		names="${names:+$names, }\"$dev\""
	done
	[ -n "$names" ] || return 1
	echo "ip saddr @$SET_SRC fib daddr . mark oifname { $names }"
}
