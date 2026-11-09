#!/bin/sh
# Nikki backend for uu-sync. Sourced by the engine, never run.
#
# Nikki (nikkinikki-org/OpenWrt-nikki) drives mihomo and generates its whole
# netfilter layout from /etc/config/nikki through ucode/hijack.ut, into a table
# of its own: inet nikki. Not fw4 - which is why this cannot reuse the OpenClash
# backend, and why the sets have to be created inside nikki's table rather than
# somewhere central.
#
# WHERE NIKKI ACTUALLY INTERCEPTS
# ------------------------------
# Two chains, and which one matters depends on the mode:
#
#   dstnat                 nat, prerouting, priority dstnat+1
#                          DNS hijack, and the redirect itself in tcp_mode
#                          "redirect": iifname @lan_inbound_device jump
#                          lan_redirect, which rewrites the destination to
#                          mihomo's redir port. A redirect happens before any
#                          route lookup, so UU's "from <device> lookup <table>"
#                          rule never runs for a boosted device's TCP.
#
#   mangle_prerouting_lan  filter, prerouting, priority mangle
#                          Where tproxy and tun modes take the traffic: the vmap
#                          sends tcp/udp into lan_tproxy or lan_tun, which set a
#                          mark and accept. The mark then wins the routing
#                          decision against UU's policy rule, whichever mode.
#
# So both chains get the exemption, whichever of them this configuration
# actually has: with tcp_mode=redirect and udp_mode=tproxy - the combination
# that leaves room for UA3F in front - a boosted device's TCP is grabbed in
# dstnat and its UDP in mangle_prerouting_lan.
#
# DNS is exempted in both as well. With the OEM build, UU marks a boosted
# device's port 53 and routes it into its own tunnel; nikki answering it through
# the proxy exit instead would hand the device addresses UU does not route, and
# the boost would resolve to nothing. This is also the reason fake-ip does not
# work here at all: the plugin never sees the real server IPs it routes on.
#
# Nikki rebuilds the table from scratch on every start and on every subscription
# update, taking our sets and rules with it, so the engine re-checks both on each
# pass and rebuilds what is missing.
#
# TWO NIKKI DEFAULTS THAT BREAK COEXISTENCE
# ----------------------------------------
# nikki.mixin.socks_port defaults to 1080, which is the port UA3F listens on.
# Whoever binds second loses, and if that is UA3F it ends up running with no
# listener - no error anywhere but its own log. Give nikki another port.
#
# nikki.proxy.bypass_china_mainland_ip defaults to 0, which leaves the china_ip
# set empty: every LAN destination is then pulled into the proxy and there is
# nothing left for anything that runs behind it. Turn it on.

NAME=nikki
LABEL="Nikki"
CONFIG=/etc/config/nikki

sync_family() { echo inet; }
sync_table()  { echo nikki; }

sync_chains() {
	local c found=""

	for c in dstnat mangle_prerouting_lan; do
		nft list chain inet nikki "$c" >/dev/null 2>&1 && { echo "$c"; found=1; }
	done
	[ -n "$found" ] && return 0

	# No hook chains: nikki is installed but its proxy is off or core-only, so
	# there is nothing to exempt. The lan_* chains only exist while it is
	# intercepting anyway, and going one level in keeps a future layout that
	# hides the hooks working rather than silently doing nothing.
	for c in lan_redirect lan_tproxy lan_tun lan_dns_hijack; do
		nft list chain inet nikki "$c" >/dev/null 2>&1 && echo "$c"
	done
}

sync_extra_rules() {
	echo "${TAG_PREFIX}dns|ip saddr @$SET_SRC meta l4proto { tcp, udp } th dport 53"
}
