#!/bin/sh
# OpenClash backend for uu-sync. Sourced by the engine, never run.
#
# OpenClash intercepts LAN traffic from chains it plants inside fw4: a nat
# "openclash" chain when it redirects, "openclash_mangle" when it uses TPROXY.
# Both are acted on, so either mode works with no configuration.

NAME=openclash
LABEL="OpenClash"
CONFIG=/etc/config/openclash

sync_family() { echo inet; }
sync_table()  { echo fw4; }

sync_chains() {
	local c
	for c in openclash_mangle openclash; do
		nft list chain inet fw4 "$c" >/dev/null 2>&1 && echo "$c"
	done
}

# What UU claims from a device is read back from the rules UU itself installs,
# not assumed, because the slice differs by build: the generic build marks the
# whole ephemeral UDP range, the OEM build only DNS and leaves the rest to its
# destination-prefix route. Assuming the wide range pushed a boosted PC's UDP
# out of the proxy while UU was not accelerating any of it.
sync_extra_rules() {
	local ips="$1" udp mark d p m

	udp="$UU_UDP_PORTS"
	mark="$UU_MARK_CFG"
	for d in $ips; do
		if [ -z "$UU_UDP_PORTS" ]; then
			for p in $(uu_marked_udp_ports "$d"); do
				case ",$udp," in
					*",$p,"*) ;;
					*) udp="${udp:+$udp,}$p" ;;
				esac
			done
		fi
		# Each boosted device gets its own mark (0x163, 0x164, ...).
		if [ -z "$UU_MARK_CFG" ]; then
			m="$(uu_marked_fwmark "$d")"
			case ",$mark," in
				*",$m,"*) ;;
				*) [ -n "$m" ] && mark="${mark:+$mark,}$m" ;;
			esac
		fi
	done

	# Exempt exactly the UDP slice UU marks, and nothing when it marks none: a
	# blanket range would return the device's other UDP from the proxy without
	# UU accelerating it, which on a boosted PC is a lot of traffic quietly
	# leaving the proxy.
	[ -n "$udp" ] &&
		echo "${TAG_PREFIX}udp|ip saddr @$SET_SRC meta l4proto udp udp dport { $udp }"
	# UU's prerouting hook runs before this chain, so by the time traffic gets
	# here UU's own mark already identifies it exactly, whatever the ports.
	[ -n "$mark" ] &&
		echo "${TAG_PREFIX}mark|ip saddr @$SET_SRC meta mark { $mark }"
	return 0
}

# ------------------------------------------------------------- lan_ac handling

# A boosted device sitting in lan_ac_black_ips returns from OpenClash's chain
# before any finer exemption can apply, so cooperative mode would be a no-op for
# it. Take those entries out while we manage the device, remembering them so
# cleanup can put them back exactly as they were.
LANAC_STATE="/var/run/uu-openclash.lanac"
LANAC_WARN="/var/run/uu-openclash.lanwarn"

sync_before_apply() {
	local ips="$1" ip changed=0

	# Off by default: this edits and commits the user's OpenClash config, which
	# is not ours to churn - especially since this runs on a poll loop. Without
	# it a device listed there simply keeps bypassing OpenClash wholesale, so
	# say so once instead of silently doing nothing.
	if [ "$(uci_get oc_manage_lan_ac)" != "1" ]; then
		[ -f "$LANAC_WARN" ] && return 0
		for ip in $ips; do
			if uci -q get openclash.config.lan_ac_black_ips | grep -qw "$ip"; then
				: > "$LANAC_WARN"
				log "$ip is in OpenClash's lan_ac_black_ips, so it bypasses the" \
				    "proxy entirely and cooperative mode cannot refine it." \
				    "Remove it there, or enable 'Move devices off OpenClash's own" \
				    "bypass list'."
				return 0
			fi
		done
		return 0
	fi

	for ip in $ips; do
		uci -q get openclash.config.lan_ac_black_ips | grep -qw "$ip" || continue
		uci -q del_list openclash.config.lan_ac_black_ips="$ip" && {
			grep -qx "$ip" "$LANAC_STATE" 2>/dev/null || echo "$ip" >> "$LANAC_STATE"
			changed=1
			log "Removed $ip from lan_ac_black_ips so its non-game traffic can use the proxy."
		}
	done
	if [ "$changed" = "1" ]; then
		uci commit openclash
		nft delete element inet fw4 lan_ac_black_ips \
			"{ $(echo $ips | tr ' ' ',') }" 2>/dev/null
	fi
	return 0
}

sync_on_cleanup() {
	local ip changed=0
	rm -f "$LANAC_WARN"
	[ -f "$LANAC_STATE" ] || return 0
	while read -r ip; do
		[ -n "$ip" ] || continue
		uci -q get openclash.config.lan_ac_black_ips | grep -qw "$ip" && continue
		uci -q add_list openclash.config.lan_ac_black_ips="$ip" && changed=1
	done < "$LANAC_STATE"
	if [ "$changed" = "1" ]; then
		uci commit openclash
		log "Restored previously bypassed devices to lan_ac_black_ips."
	fi
	rm -f "$LANAC_STATE"
}

# There is no bypass code here any more. Excluding a device outright used to
# mean writing lan_ac_black_ips and reloading OpenClash; the engine now does it
# with one nftables rule in this same chain, so the proxy's configuration is
# never touched and nothing has to be restarted to undo it.
