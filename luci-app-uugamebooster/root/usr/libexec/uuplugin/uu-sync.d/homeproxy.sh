#!/bin/sh
# HomeProxy backend for uu-sync. Sourced by the engine, never run.
#
# Only HomeProxy builds that run sing-box's TUN inbound with auto_redirect are
# handled. sing-box then owns table inet sing-box, and its prerouting chain does
# "tcp redirect to :<port>" in nat, before any route lookup, so UU's "from
# <device> lookup <table>" rule never sees a boosted device's TCP. UDP already
# reaches UU's tunnel: the policy rule wins over sing-box's marks. Official
# HomeProxy's redirect and TPROXY modes hook fw4 instead; nothing here acts on
# those.
#
# Both chains are needed - the filter one decides what gets queued, the nat one
# is where the redirect sits - but whichever this version has is acted on, so a
# renamed chain in a future sing-box degrades to a partial exemption rather than
# a silent no-op.
#
# sing-box rebuilds its whole table on start and on subscription updates, taking
# our sets and rules with it, so the engine re-checks both on every pass.

NAME=homeproxy
LABEL="HomeProxy"
CONFIG=/etc/config/homeproxy

sync_family() { echo inet; }
sync_table()  { echo sing-box; }

sync_chains() {
	local c
	for c in prerouting_prematch prerouting; do
		nft list chain inet sing-box "$c" >/dev/null 2>&1 && echo "$c"
	done
}

# DNS is exempted for the boosted device whatever the destination: sing-box
# would answer it through the proxy exit, with addresses UU does not route.
sync_extra_rules() {
	echo "${TAG_PREFIX}dns|ip saddr @$SET_SRC meta l4proto { tcp, udp } th dport 53"
}
