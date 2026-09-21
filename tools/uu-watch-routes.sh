#!/bin/sh
# Watch what UU adds to its route table as you launch and play a game.
#
# UU decides what to accelerate per session: it recognises the running game and
# installs routes for that game's servers. So the only way to know whether a
# given title is accelerated at all is to watch the table while you play it.
#
# This matters most for anything on Steam Datagram Relay - CS2 official
# matchmaking, Dota 2 - because the client talks to a Valve relay rather than to
# the game server. If UU never installs Valve's ranges, that traffic never
# reaches its tunnel however well the accelerator is working otherwise.
#
# Run it on the router, with a device boosted, then launch the game:
#
#     tools/uu-watch-routes.sh [seconds between checks]

INTERVAL=${1:-5}

# Valve's own address space, which is where SDR relays live.
VALVE='^(155\.133|162\.254|185\.25|192\.69|146\.66|103\.10|103\.28|205\.196|208\.78|45\.121|153\.254)'

uu_table() {
	ip rule show 2>/dev/null | awk '
		{ t = ""
		  for (i = 1; i <= NF; i++) if ($i == "lookup") t = $(i + 1)
		  if (t ~ /^[0-9]+$/) print t }' |
	while read -r t; do
		ip route show table "$t" 2>/dev/null | grep -q "dev tun16" && { echo "$t"; break; }
	done
}

snapshot() {
	local t
	t=$(uu_table)
	[ -n "$t" ] && ip route show table "$t" 2>/dev/null | awk '{print $1}' | sort -u
}

prev=$(snapshot)
echo "watching UU's route table every ${INTERVAL}s. Ctrl-C to stop."
echo "starting with $(printf '%s\n' "$prev" | grep -c . 2>/dev/null || echo 0) prefixes."
echo

while :; do
	sleep "$INTERVAL"
	now=$(snapshot)

	if [ -z "$now" ]; then
		[ -n "$prev" ] && echo "$(date +%H:%M:%S)  tunnel gone - nothing is boosted now"
		prev=""
		continue
	fi

	added=$(printf '%s\n' "$now" | grep -vxF "$(printf '%s\n' "$prev")" 2>/dev/null | grep .)
	gone=$(printf '%s\n' "$prev" | grep -vxF "$(printf '%s\n' "$now")" 2>/dev/null | grep .)

	if [ -n "$added" ] || [ -n "$gone" ]; then
		echo "$(date +%H:%M:%S)  +$(printf '%s\n' "$added" | grep -c .) -$(printf '%s\n' "$gone" | grep -c .)  (total $(printf '%s\n' "$now" | grep -c .))"
		if [ -n "$added" ]; then
			printf '%s\n' "$added" | sed 's/^/    + /' | head -12
			valve=$(printf '%s\n' "$added" | grep -E "$VALVE")
			if [ -n "$valve" ]; then
				echo "    >>> Valve address space appeared - SDR traffic IS being accelerated:"
				printf '%s\n' "$valve" | sed 's/^/        /'
			fi
		fi
		prev="$now"
	fi
done
