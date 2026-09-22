#!/bin/sh
# Build the uu-view LD_PRELOAD shims.
#
# One per architecture a UU plugin can run as. The shim has to match the plugin,
# not the router: a generic build runs as the router's own architecture, an OEM
# build runs as aarch64 whether natively or under emulation.
#
# The OpenWrt SDK cannot help here - an x86_64 SDK has no aarch64 compiler - so
# the shims are built out of tree with zig, which ships cross toolchains for all
# of them, and the results are carried in payload/ alongside qemu.
#
# arm and mips use the soft-float ABI deliberately: the shim passes no floating
# point arguments anywhere, so one build works on hard-float targets too.
#
# Usage: tools/build-preload.sh [outdir]      (default: payload/preload)
set -e

SRC_DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$SRC_DIR/src/uu-view-preload.c"
OUT=${1:-$SRC_DIR/payload/preload}

ZIG=$(command -v zig || true)
[ -n "$ZIG" ] || ZIG="$HOME/zig/zig"
[ -x "$ZIG" ] || {
	echo "zig not found. Install it, or put it at ~/zig/zig:" >&2
	echo "  curl -sSLO https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz" >&2
	echo "  mkdir -p ~/zig && tar xf zig-linux-x86_64-0.13.0.tar.xz -C ~/zig --strip-components=1" >&2
	exit 1
}

mkdir -p "$OUT"

# <name we ship it under>:<zig target>
for spec in \
	x86_64:x86_64-linux-musl \
	aarch64:aarch64-linux-musl \
	arm:arm-linux-musleabi \
	mipsel:mipsel-linux-musl \
	mips:mips-linux-musl
do
	name="${spec%%:*}"
	target="${spec#*:}"
	# -g0 because zig emits debug info by default, and on arm that came to
	# ~590 KB of .debug_* sections on an object that is 17 KB everywhere else.
	# Interposition only reads .dynsym, which this does not touch.
	"$ZIG" cc -target "$target" -shared -fPIC -O2 -Wall -g0 \
		-o "$OUT/uu-view-preload-$name.so" "$SRC"
	# -g0 only silences our own translation unit. On arm, zig links compiler-rt
	# builtins that carry their own debug info, which took the object from 10 KB
	# to 800 KB, so strip after linking as well.
	#
	# Best effort, for two reasons. Writing over the input makes zig objcopy fail
	# with TRUNCATED_ELF, hence the temporary; and it refuses big-endian objects
	# outright ("ELF to ELF copying only supports native endian"), so mips cannot
	# be stripped on an x86_64 host. That one is 8 KB unstripped, so a failure
	# here is not worth aborting the build for.
	if "$ZIG" objcopy --strip-debug \
			"$OUT/uu-view-preload-$name.so" "$OUT/uu-view-preload-$name.so.tmp" \
			2>/dev/null &&
	   [ -s "$OUT/uu-view-preload-$name.so.tmp" ]; then
		mv -f "$OUT/uu-view-preload-$name.so.tmp" "$OUT/uu-view-preload-$name.so"
	else
		rm -f "$OUT/uu-view-preload-$name.so.tmp"
	fi
	echo "built $OUT/uu-view-preload-$name.so ($target)"
done
