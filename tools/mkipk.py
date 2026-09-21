#!/usr/bin/env python3
"""Build a luci-app-uugamebooster .ipk without the OpenWrt SDK.

Apart from the LD_PRELOAD view filters - which the SDK could not build anyway,
since they target five architectures at once - the package is scripts and Lua,
so the SDK's only real jobs are file placement and control metadata. This
reproduces both. Run tools/build-preload.sh first.

Two flavours:

  --arch x86_64   also bundles the user-mode qemu and the aarch64 musl sysroot
                  that the emulated OEM build needs, so nothing is downloaded
                  beyond the plugin itself. Installs on x86_64 only.
  --arch all      no qemu, so it installs on any target. The OEM build still
                  works wherever the router's own architecture matches it,
                  which covers the ARM routers those builds are made for.

Usage: tools/mkipk.py [--arch x86_64|all] [output.ipk]
"""
import io, os, sys, tarfile, gzip, time, hashlib, urllib.request, ssl

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import po2lmo

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "luci-app-uugamebooster")
PAYLOAD = os.path.join(ROOT, "payload")
PRELOAD = os.path.join(PAYLOAD, "preload")
PKG = "luci-app-uugamebooster"
MTIME = 0  # reproducible

argv = sys.argv[1:]
ARCH = "x86_64"
if "--arch" in argv:
    i = argv.index("--arch")
    ARCH = argv[i + 1]
    del argv[i:i + 2]
if ARCH not in ("x86_64", "all"):
    sys.exit("--arch must be x86_64 or all")
OUT_ARG = argv[0] if argv else None

# Emulation is the only arch-bound part, and it is only reachable on x86_64: the
# qemu build used here is itself an x86_64 binary, so an ARM router can run an
# OEM build natively or not at all. Everything else is architecture-neutral.
BUNDLE_QEMU = ARCH == "x86_64"
QEMU_URL = ("https://github.com/multiarch/qemu-user-static/releases/download/"
            "v7.2.0-1/qemu-aarch64-static")
QEMU_SHA = "dce64b2dc6b005485c7aa735a7ea39cb0006bf7e5badc28b324b2cd0c73d883f"
OW_BASE = ("https://downloads.openwrt.org/releases/23.05.5/targets/armsr/armv8/"
           "packages")
OW_LIBS = ["libc_1.2.4-4_aarch64_generic.ipk",
           "libgcc1_12.3.0-4_aarch64_generic.ipk",
           "libstdcpp6_12.3.0-4_aarch64_generic.ipk"]

# Read the dependency list out of the Makefile rather than keeping a second copy
# here. The two lists had already drifted: unshare was declared there and not
# here, so an installed package never pulled it.
def read_makefile(key, default=None):
    """One version and one dependency list, both read from the Makefile."""
    mk = open(os.path.join(SRC, "Makefile"), encoding="utf-8").read()
    for raw in mk.splitlines():
        if raw.startswith(key + ":="):
            return raw.split(":=", 1)[1].strip()
    if default is None:
        sys.exit("could not find %s in the Makefile" % key)
    return default


def read_depends():
    line = read_makefile("LUCI_DEPENDS")
    deps = [d.lstrip("+") for d in line.split() if d.strip()]
    # luci.mk adds these for every LuCI app; nothing declares them explicitly.
    return ["libc", "luci-base"] + deps


# Version too, in the form luci.mk produces, so an SDK build and this one cannot
# disagree about what they just built.
VER = "%s-%s" % (read_makefile("PKG_VERSION"), read_makefile("PKG_RELEASE", "1"))
OUT = OUT_ARG or "%s_%s_%s.ipk" % (PKG, VER, ARCH)


# published path -> (source file, mode)
FILES = {
    "./etc/config/uuplugin":                        ("root/etc/config/uuplugin", 0o644),
    "./etc/init.d/uuplugin":                        ("root/etc/init.d/uuplugin", 0o755),
    "./etc/uci-defaults/45_luci-uuplugin":          ("root/etc/uci-defaults/45_luci-uuplugin", 0o755),
    "./usr/libexec/uuplugin/uu-openclash-sync":     ("root/usr/libexec/uuplugin/uu-openclash-sync", 0o755),
    "./usr/libexec/uuplugin/uu-detect":             ("root/usr/libexec/uuplugin/uu-detect", 0o755),
    "./usr/libexec/uuplugin/uu-view":               ("root/usr/libexec/uuplugin/uu-view", 0o755),
    "./usr/lib/lua/luci/controller/uuplugin.lua":   ("luasrc/controller/uuplugin.lua", 0o644),
    "./usr/lib/lua/luci/model/cbi/uuplugin.lua":    ("luasrc/model/cbi/uuplugin.lua", 0o644),
    "./usr/lib/lua/luci/view/uuplugin/uuplugin_status.htm": ("luasrc/view/uuplugin/uuplugin_status.htm", 0o644),
    "./usr/lib/lua/luci/view/uuplugin/uuplugin_howto.htm":  ("luasrc/view/uuplugin/uuplugin_howto.htm", 0o644),
    "./www/uuios.png":                              ("root/www/uuios.png", 0o644),
    "./www/uuandriod.png":                          ("root/www/uuandriod.png", 0o644),
}

POSTINST = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
\tchmod +x /etc/init.d/uuplugin 2>/dev/null
\tchmod +x /usr/libexec/uuplugin/* 2>/dev/null
\t( . /etc/uci-defaults/45_luci-uuplugin ) && rm -f /etc/uci-defaults/45_luci-uuplugin
\trm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
\t# An upgrade had to stop the service to replace its files. Put it back the
\t# way the user left it, so upgrading does not silently switch UU off.
\tif [ "$(uci -q get uuplugin.@uuplugin[0].enabled)" = "1" ]; then
\t\t/etc/init.d/uuplugin enable >/dev/null 2>&1
\t\t/etc/init.d/uuplugin start >/dev/null 2>&1
\tfi
\texit 0
}
exit 0
"""

PRERM = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
\t/etc/init.d/uuplugin stop >/dev/null 2>&1
\t# This runs on an upgrade as well as on a removal, and dropping the boot
\t# entry there would leave the service off after every upgrade.
\t[ "$1" = "upgrade" ] || /etc/init.d/uuplugin disable >/dev/null 2>&1
}
exit 0
"""

CONFFILES = "/etc/config/uuplugin\n"


def norm(data: bytes, path: str) -> bytes:
    """Scripts and text must use LF; this repo is checked out on Windows."""
    if path.endswith(".png"):
        return data
    return data.replace(b"\r\n", b"\n")


def add(tf, name, data, mode, typ=tarfile.REGTYPE):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    ti.mode = mode
    ti.mtime = MTIME
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.type = typ
    tf.addfile(ti, io.BytesIO(data))


def adddir(tf, name):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.DIRTYPE
    ti.mode = 0o755
    ti.mtime = MTIME
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    tf.addfile(ti)


def addlink(tf, name, target):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.SYMTYPE
    ti.linkname = target
    ti.mode = 0o777
    ti.mtime = MTIME
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    tf.addfile(ti)


def make_tgz(entries, dirs):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for d in dirs:
            adddir(tf, d)
        for name, ent in entries.items():
            if len(ent) == 3 and ent[2]:          # symlink
                addlink(tf, name, ent[0])
            else:
                add(tf, name, ent[0], ent[1])
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=MTIME) as gz:
        gz.write(raw.getvalue())
    return buf.getvalue()


# ---- emulation payload -----------------------------------------------------
ssl._create_default_https_context = ssl._create_unverified_context


def _get(url):
    r = urllib.request.Request(url, headers={"User-Agent": "curl/8"})
    return urllib.request.urlopen(r, timeout=300).read()


def build_payload():
    """Assemble payload/ once; it is gitignored so the repo stays free of blobs."""
    qemu = os.path.join(PAYLOAD, "qemu-aarch64-static")
    sysroot = os.path.join(PAYLOAD, "sysroot")

    if os.path.exists(qemu) and \
       hashlib.sha256(open(qemu, "rb").read()).hexdigest() == QEMU_SHA:
        pass
    else:
        os.makedirs(PAYLOAD, exist_ok=True)
        print("  downloading qemu-aarch64-static ...")
        blob = _get(QEMU_URL)
        got = hashlib.sha256(blob).hexdigest()
        if got != QEMU_SHA:
            sys.exit("qemu checksum mismatch: expected %s, got %s" % (QEMU_SHA, got))
        open(qemu, "wb").write(blob)

    if not os.path.exists(os.path.join(sysroot, "lib", "ld-musl-aarch64.so.1")):
        os.makedirs(sysroot, exist_ok=True)
        for pkg in OW_LIBS:
            print("  downloading %s ..." % pkg)
            outer = tarfile.open(fileobj=io.BytesIO(_get("%s/%s" % (OW_BASE, pkg))),
                                 mode="r:gz")
            data = outer.extractfile("./data.tar.gz").read()
            inner = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
            inner.extractall(sysroot)
    return qemu, sysroot


def walk_payload(root, prefix):
    """Yield (published_path, source_path_or_symlink_target, mode, is_link)."""
    for base, dirs, files in os.walk(root):
        for fn in files + [d for d in dirs if os.path.islink(os.path.join(base, d))]:
            p = os.path.join(base, fn)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            dest = "%s/%s" % (prefix, rel)
            if os.path.islink(p):
                yield dest, os.readlink(p), 0o777, True
            else:
                mode = 0o755 if (os.access(p, os.X_OK) or ".so" in fn) else 0o644
                yield dest, p, mode, False


qemu_path = sysroot_path = None
if BUNDLE_QEMU:
    print("assembling emulation payload ...")
    qemu_path, sysroot_path = build_payload()

# ---- data.tar.gz -----------------------------------------------------------
entries, total = {}, 0
for dest, (rel, mode) in FILES.items():
    p = os.path.join(SRC, rel.replace("/", os.sep))
    if not os.path.exists(p):
        sys.exit("missing source file: %s" % p)
    data = norm(open(p, "rb").read(), dest)
    entries[dest] = (data, mode, False)
    total += len(data)

# Translation catalogues, compiled from po/<lang>/. LuCI's load_catalog() globs
# every *.<lang>.lmo in the i18n directory, so the file only has to be named for
# the language; the basename is ours to choose. The directory names follow LuCI's
# convention, where zh_Hans is published as zh-cn.
LANG_SUFFIX = {"zh_Hans": "zh-cn", "zh_Hant": "zh-tw"}
po_root = os.path.join(SRC, "po")
nlang = 0
if os.path.isdir(po_root):
    for lang in sorted(os.listdir(po_root)):
        po = os.path.join(po_root, lang, "uugamebooster.po")
        if not os.path.exists(po):
            continue
        suffix = LANG_SUFFIX.get(lang, lang.lower().replace("_", "-"))
        blob, count = po2lmo.build(po2lmo.parse_po(po))
        dest = "./usr/lib/lua/luci/i18n/uugamebooster.%s.lmo" % suffix
        entries[dest] = (blob, 0o644, False)
        total += len(blob)
        nlang += 1
        print("  %s -> %s (%d translations)" % (lang, suffix, count))

# The view filters. All of them ship regardless of package architecture: the one
# that gets used has to match the plugin, not the router, and they are ~17 KB
# each. Built out of tree by tools/build-preload.sh.
for target in ("x86_64", "aarch64", "arm", "mipsel", "mips"):
    name = "uu-view-preload-%s.so" % target
    p = os.path.join(PRELOAD, name)
    if not os.path.exists(p):
        sys.exit("missing %s - run tools/build-preload.sh first" % p)
    entries["./usr/lib/uuplugin/" + name] = (open(p, "rb").read(), 0o755, False)
    total += os.path.getsize(p)

# emulation payload -> /opt/uu-oem
npay = 0
if BUNDLE_QEMU:
    entries["./opt/uu-oem/qemu-aarch64-static"] = (open(qemu_path, "rb").read(), 0o755, False)
    total += os.path.getsize(qemu_path)
    npay = 1
    for dest, src, mode, is_link in walk_payload(sysroot_path, "./opt/uu-oem/sysroot"):
        if is_link:
            entries[dest] = (src, 0o777, True)
        else:
            entries[dest] = (open(src, "rb").read(), mode, False)
            total += os.path.getsize(src)
        npay += 1
    print("  payload files: %d" % npay)

dirs = set()
for dest in entries:
    parts = dest.split("/")[1:-1]
    for i in range(1, len(parts) + 1):
        dirs.add("./" + "/".join(parts[:i]))
data_tgz = make_tgz(entries, sorted(dirs))

# ---- control.tar.gz --------------------------------------------------------
control = (
    "Package: %s\n"
    "Version: %s\n"
    "Depends: %s\n"
    "Section: luci\n"
    "Category: LuCI\n"
    "Architecture: %s\n"
    "Installed-Size: %d\n"
    "Maintainer: Fork of lmq8267/luci-app-uugamebooster\n"
    "Description: LuCI support for NetEase UU Game Booster.\n"
    " English UI, PC and phone boosting, and cooperative OpenClash coexistence.\n"
    "%s"
) % (PKG, VER, ", ".join(read_depends()), ARCH, total,
     " Bundles a user-mode qemu so the OEM build runs on x86_64.\n"
     if BUNDLE_QEMU else
     " No emulator bundled; the OEM build runs natively where the CPU matches.\n")

ctl_entries = {
    "./control":   (control.encode(), 0o644),
    "./postinst":  (POSTINST.encode(), 0o755),
    "./prerm":     (PRERM.encode(), 0o755),
    "./conffiles": (CONFFILES.encode(), 0o644),
}
ctl_tgz = make_tgz(ctl_entries, [])

# ---- outer container -------------------------------------------------------
# OpenWrt's opkg expects the tar.gz-flavoured ipk (a gzipped tar holding the
# three members), not the Debian-style ar archive.
outer_raw = io.BytesIO()
with tarfile.open(fileobj=outer_raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
    for name, blob in (("./debian-binary", b"2.0\n"),
                       ("./data.tar.gz", data_tgz),
                       ("./control.tar.gz", ctl_tgz)):
        ti = tarfile.TarInfo(name)
        ti.size = len(blob)
        ti.mode = 0o644
        ti.mtime = MTIME
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        tf.addfile(ti, io.BytesIO(blob))

with open(OUT, "wb") as f:
    with gzip.GzipFile(fileobj=f, mode="wb", mtime=MTIME) as gz:
        gz.write(outer_raw.getvalue())

print("wrote %s (%d bytes, installed-size %d)" % (OUT, os.path.getsize(OUT), total))
for d in sorted(entries)[:12]:
    print("   %-58s %o" % (d, entries[d][1]))
print("   ... %d entries total" % len(entries))
