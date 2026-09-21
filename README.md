<div align="center">

# luci-app-uugamebooster

> OpenWrt LuCI - NetEase UU Game Booster, with PC and phone boosting and OpenClash coexistence

[![GitHub Release](https://img.shields.io/github/v/release/xiaodoudou/luci-app-uugamebooster?style=flat-square&color=e94560)](https://github.com/xiaodoudou/luci-app-uugamebooster/releases/latest)
[![Build](https://img.shields.io/github/actions/workflow/status/xiaodoudou/luci-app-uugamebooster/build.yml?branch=master&style=flat-square&label=build)](https://github.com/xiaodoudou/luci-app-uugamebooster/actions/workflows/build.yml)
[![Stars](https://img.shields.io/github/stars/xiaodoudou/luci-app-uugamebooster?style=flat-square&color=yellow)](https://github.com/xiaodoudou/luci-app-uugamebooster/stargazers)
[![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](https://www.apache.org/licenses/LICENSE-2.0)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-22.03%2B-brightgreen?style=flat-square)](#requirements)
[![Arch](https://img.shields.io/badge/Arch-x86__64%20%7C%20aarch64%20%7C%20arm%20%7C%20mipsel%20%7C%20mipseb-blueviolet?style=flat-square)](docs/builds.md)
[![UI](https://img.shields.io/badge/UI-English%20%7C%20%E4%B8%AD%E6%96%87-orange?style=flat-square)](#language)
[![Package](https://img.shields.io/badge/Package-IPK-blue?style=flat-square)](#install)

A LuCI web interface for [NetEase UU](https://uu.163.com) on OpenWrt. Fork of
[lmq8267/luci-app-uugamebooster](https://github.com/lmq8267/luci-app-uugamebooster).

</div>

---

What this fork adds:

- **Native x86_64**, plus big-endian MIPS. Upstream supports neither.
- **PC and phone boosting**, not just consoles. Runs natively on ARM routers, emulated on x86_64.
- **Coexistence with OpenClash.** The two split the traffic instead of one of them quietly winning.
- **As fast as UU's own PC client**, measured: 25 ms vs 25-27 ms on CS2 through Hong Kong.
- **A device list**, so the UU app only sees the devices you pick.
- **English and Chinese UI**, following LuCI's language setting.

The plugin ships **no accelerator binary**. On first start it downloads the official one for your architecture and checks its MD5 before running it.

---

## Requirements

OpenWrt 19.07 or newer, 22.03+ recommended. The OpenClash split needs nftables, so in practice 22.03+.

Everything else the package pulls in itself: `kmod-tun`, `luci-compat`, `libstdcpp6`, `kmod-ipt-nat`, `ca-bundle`, `unshare`, `ip` and `nftables`. There is nothing to install by hand.

Two things it can't do for you:

- On 22.03 and newer, leave **Open the firewall for UU's tunnel** on. The default forward policy is REJECT, so the LAN can't reach the tunnel otherwise. It's on by default.
- For a Chinese LuCI, `opkg install luci-i18n-base-zh-cn`. This app's own Chinese ships in the package, but LuCI's isn't pulled in as a dependency because that would force it on everyone.

Seeing `libbpf.so.0` errors from `ip`? That's a broken `ip-full` in some iStoreOS images rather than a missing dependency, and NetEase's fix applies here too:

```bash
opkg install libbpf && opkg install --force-reinstall ip-full
```

## Install

`tools/` builds two flavours:

```bash
tools/build-preload.sh                # needs zig; writes payload/preload/
python3 tools/mkipk.py --arch x86_64  # ~4 MB, bundles the emulator
python3 tools/mkipk.py --arch all     # ~580 KB, installs anywhere
```

| Flavour | What's in it | Who it's for |
|---|---|---|
| `x86_64` | everything, emulator and aarch64 sysroot included | x86_64 routers. Nothing left to download for the vendor build. |
| `all` | no emulator | everything else. The vendor build runs natively when the CPU matches. |

Both carry all five view filters. The one that gets used has to match the *plugin's* architecture rather than the router's, and under emulation those two differ. `mkipk.py` fetches and checksums the emulator and the sysroot the first time you run it, then caches them in `payload/` (gitignored).

On the router:

```bash
opkg install luci-app-uugamebooster_*.ipk
```

An OpenWrt SDK build handles the scripts and Lua fine, but it can't produce the two compiled pieces: the emulator, and view filters for five architectures. You get a package without them, which means no emulated build and a device list that only filters what a mount namespace can reach.

```bash
git clone <this-repo> package/luci-app-uugamebooster
./scripts/feeds update -a && ./scripts/feeds install -a
echo "CONFIG_PACKAGE_luci-app-uugamebooster=m" >> .config
make defconfig && make package/luci-app-uugamebooster/compile V=s
```

## Use

1. Go to **Services → UU Game Booster**
2. Under **General**, tick **Enable** and hit Save & Apply
3. Wait for the status panel to say **Ready**. Before that the app can't find your router, even though the service is already running.
4. Follow the **How to use** tab: install the app, bind the router, pick a device

Settings are split across five tabs (General, What to boost, OpenClash, Device visibility, How to use). The panel above them shows how far along the service is, which build is running, the tunnel devices, and what's being boosted.

### Language

The UI follows whatever LuCI is set to, in English or Simplified Chinese. The Chinese catalogue ships inside the package, so there's nothing extra to install for this app.

LuCI itself is a different matter: if its own Chinese translation isn't installed, the language won't even appear in the dropdown. Add it once and then pick it under **System -> Language and Style**:

```bash
opkg install luci-i18n-base-zh-cn
```

Translations live in [`luci-app-uugamebooster/po/`](luci-app-uugamebooster/po/). `tools/i18n-scan.py` rebuilds the string list from the sources and `tools/po2lmo.py` compiles a catalogue, so adding another language means copying `po/zh_Hans/` and translating it.

---

## How it works

Each of these got its own page, because each one turned out to need it:

| | |
|---|---|
| [Which build runs](docs/builds.md) | Why x86_64 works at all, why PC and phone boosting needs a vendor build, and how the plugin picks between running one natively and emulating it |
| [Device visibility](docs/device-list.md) | Keeping the UU app from listing every host you own, and why the ARP table can't be filtered the obvious way |
| [Running alongside OpenClash](docs/openclash.md) | What actually leaves the proxy for a boosted device, measured rather than guessed |
| [Firewall](docs/firewall.md) | The `tun16+` zone, and why it survives a restart |
| [Conflicts with an existing UU install](docs/existing-install.md) | Taking over from NetEase's own installer script |
| [What has actually been tested](docs/testing.md) | What was checked on a live router, and what wasn't |

---

## Notes

NetEase runs the UU service. It's aimed at users in mainland China and needs a NetEase account. This project only packages the official client. It doesn't modify, patch or redistribute it.

## Credits

Upstream is [lmq8267/luci-app-uugamebooster](https://github.com/lmq8267/luci-app-uugamebooster). Licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
