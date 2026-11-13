#!/bin/sh
# UA3F backend for uu-sync. Sourced by the engine, never run.
#
# UA3F diverts LAN TCP to its own listener from its own table, inet UA3F: in
# TPROXY mode chain PREROUTING marks it 0x1c9 and hands it to 127.0.0.1, in
# REDIRECT mode a nat chain of the same name rewrites the destination. Either
# way a boosted device's game connections never reach UU's tunnel. UDP is left
# alone by UA3F, so only TCP needs exempting - and that difference is the whole
# of this backend.
#
# UA3F's own skip list (UA3F_SKIP_IPSET) is destination-only and global, the
# same trap as OpenClash's wan_ac_black_ips: filling it with UU's prefixes would
# take those destinations out of UA3F for every device on the LAN. Hence the
# exemption is "boosted device AND a prefix UU routes", applied here.
#
# UA3F deletes and recreates its table on every start, taking our sets and rule
# with it, so the engine re-checks both on every pass and rebuilds what is
# missing.
#
# NOTE ON HOOK PRIORITY. The chain name is PREROUTING in both modes, but where
# it hooks differs, and that decides whether UA3F does anything at all while a
# transparent proxy is running:
#
#   REDIRECT  nat prerouting    dstnat - 20  = -120   runs before every proxy
#   TPROXY    filter prerouting filter + 20  =  +20   runs after all of them
#
# nikki's dstnat sits at -99 and its mangle chains at -150; OpenClash's at
# -150. Under TPROXY, UA3F therefore never sees a packet a proxy wanted, its
# tproxy statement finds no socket, and its counters climb while it rewrites
# nothing. REDIRECT is the mode to use alongside a proxy: UA3F takes the LAN
# TCP first, rewrites the User-Agent, and its own outbound connections are then
# picked up by the proxy on the output path.

NAME=ua3f
LABEL="UA3F"
CONFIG=/etc/config/ua3f

sync_family() { echo inet; }
sync_table()  { echo UA3F; }

sync_chains() {
	nft list chain inet UA3F PREROUTING >/dev/null 2>&1 && echo PREROUTING
}

sync_dest_match() {
	echo "meta l4proto tcp ip saddr . ip daddr @$SET_DST"
}
