#!/bin/sh
# Push the plugin's runtime files straight to a router, without building an .ipk.
#
# mkipk.py needs payload/preload/*.so, which only tools/build-preload.sh on a
# Linux host can produce. When that is not available - or when iterating on a
# live router - this does the same file placement by hand.
#
# Usage: tools/deploy.sh [user@]host [--dry-run]
#
# Everything the package installs is copied, so the result is identical to an
# .ipk install of the same tree. Run it from Git Bash on Windows or any POSIX
# shell; it only needs ssh, scp and python3 (for po2lmo).
set -e

HOST="${1:-}"
if [ -z "$HOST" ]; then
	echo "usage: tools/deploy.sh user@host [--dry-run]" >&2
	exit 1
fi
DRY=0
[ "$2" = "--dry-run" ] && DRY=1

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/luci-app-uugamebooster"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- compilation
# The .lmo LuCI actually loads is never in the tree: it is compiled from
# po/<lang>/ at install time. Do the same here so a translated string that was
# added but not compiled cannot silently ship as English.
say "compiling translation catalogues"
for po in "$SRC"/po/*/uugamebooster.po; do
	[ -f "$po" ] || continue
	lang=$(basename "$(dirname "$po")")
	case "$lang" in
		zh_Hans) suffix=zh-cn ;;
		zh_Hant) suffix=zh-tw ;;
		*)       suffix=$(echo "$lang" | tr '_' '-') ;;
	esac
	python3 "$ROOT/tools/po2lmo.py" "$po" "$TMP/uugamebooster.$suffix.lmo"
	echo "    $lang -> uugamebooster.$suffix.lmo"
done

# ------------------------------------------------------------------- staging
# Mirror the package layout under $TMP/stage so a single scp can push it.
say "staging files"
mkdir -p "$TMP/stage"
cp -a "$SRC/root/." "$TMP/stage/"
# The router's settings are the user's; a package upgrade keeps them too.
rm -f "$TMP/stage/etc/config/uuplugin"
mkdir -p "$TMP/stage/usr/lib/lua/luci/controller" \
         "$TMP/stage/usr/lib/lua/luci/model/cbi" \
         "$TMP/stage/usr/lib/lua/luci/view/uuplugin" \
         "$TMP/stage/usr/lib/lua/luci/i18n"
cp "$SRC/luasrc/controller/uuplugin.lua"  "$TMP/stage/usr/lib/lua/luci/controller/"
cp "$SRC/luasrc/model/cbi/uuplugin.lua"   "$TMP/stage/usr/lib/lua/luci/model/cbi/"
cp "$SRC"/luasrc/view/uuplugin/*.htm      "$TMP/stage/usr/lib/lua/luci/view/uuplugin/"
cp "$TMP"/*.lmo                           "$TMP/stage/usr/lib/lua/luci/i18n/"

# CRLF would break every shell script and Lua chunk on the router, and the
# Windows editor that writes this tree has produced them before.
say "normalising line endings"
find "$TMP/stage" -type f \( -name '*.sh' -o -name 'uu-sync' -o -name 'uu-*' \
	-o -name 'uuplugin' -o -name '*.lua' -o -name '*.htm' -o -name '*.conf' \
	-o -name '*.uc' \) -exec sed -i 's/\r$//' {} +

if [ "$DRY" = "1" ]; then
	say "dry run - would push:"
	(cd "$TMP/stage" && find . -type f | sort | sed 's/^/    /')
	exit 0
fi

# ------------------------------------------------------------------- install
say "uploading to $HOST"
# -O: OpenWrt ships no sftp-server, which newer scp needs by default.
scp -O -q -r "$TMP/stage/." "$HOST:/"

say "setting permissions"
ssh "$HOST" '
	chmod 755 /etc/init.d/uuplugin \
	          /usr/libexec/uuplugin/uu-sync \
	          /usr/libexec/uuplugin/uu-* \
	          /usr/libexec/uuplugin/uu-sync.d/*.sh 2>/dev/null
	# A stale index cache would serve the old menu and the old form.
	rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
	true
'

# ------------------------------------------------------------------ validate
# A file that is present but unparseable is worse than one that is missing,
# because the service fails at run time rather than here.
say "validating on the router"
ssh "$HOST" '
	fail=0
	for f in /etc/init.d/uuplugin /usr/libexec/uuplugin/uu-sync \
	         /usr/libexec/uuplugin/uu-sync.d/*.sh /usr/libexec/uuplugin/uu-lib.sh \
	         /usr/libexec/uuplugin/uu-detect; do
		sh -n "$f" || { echo "  SYNTAX: $f"; fail=1; }
	done
	for f in /usr/lib/lua/luci/controller/uuplugin.lua \
	         /usr/lib/lua/luci/model/cbi/uuplugin.lua; do
		lua -e "assert(loadfile(\"$f\"))" 2>/dev/null \
			|| { echo "  SYNTAX: $f"; fail=1; }
	done
	[ "$fail" = "0" ] && echo "  all files parse"
	exit $fail
'

# Never a full restart: that re-registers with NetEase. reload only restarts
# instances whose command changed, so the sync daemons are also sent TERM and
# procd respawns them on the new code; the UU core keeps running.
say "reloading"
ssh "$HOST" '
	/etc/init.d/uuplugin reload >/dev/null 2>&1
	for i in $(ubus call service list "{\"name\":\"uuplugin\"}" |
	           jsonfilter -e "@.uuplugin.instances" | grep -o "\"uu_sync_[a-z0-9]*\"" | tr -d "\""); do
		p=$(ubus call service list "{\"name\":\"uuplugin\"}" | jsonfilter -e "@.uuplugin.instances.$i.pid")
		[ -n "$p" ] && kill "$p"
	done
	sleep 3; /etc/init.d/uuplugin status 2>&1 | head -2'

say "done"
