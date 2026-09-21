# What has actually been tested

Checked on a **live OpenWrt 23.05.5 x86-64 router running OpenClash**:

- Arch detection lands on `openwrt-x86_64`, and the download, MD5 check and extraction all work against the live API
- The service starts under procd, the firewall zone appears, and the OpenClash sync comes up in cooperative mode
- Conflict detection finds a pre-existing official install and refuses to start rather than crash-looping
- Stopping puts `/etc/config/firewall` and `/etc/config/openclash` back byte-identical to the pre-install baseline
- The emulated vendor build registers with NetEase's cloud and offers a PC as boostable, which the generic build never does
- A live boost was watched end to end: the `ip rule` and tunnel per device, UU's own mangle rules, and packet counters ticking on all three exemptions
- Cooperative mode reads the right values off the router (`udp 53`, `mark 0x163` for the vendor build), installs all three exemptions, sees real traffic on each, and clears both rules and sets on shutdown
- Device visibility narrows all four discovery sources at once. With a single address whitelisted, the plugin's view of a 56-entry ARP table, a 28-entry lease file and a 10-entry IPv6 neighbour table is one device in each, matched across both address and MAC
- The view filter is confirmed mapped into the emulated process, and `LD_PRELOAD` confirmed gone from its environment, so the native commands UU shells out to still run
- Reload doesn't disturb anything it doesn't have to. Changing coexistence or the device list restarts only the procd instance that changed, leaving the plugin, an active boost and its registration alone. Changing the build does restart it, as it has to.

Checked off the router:

- Interposition, against a real aarch64/musl binary under qemu: reads of `/proc/net/arp` come back filtered, an unrelated `/proc/net` file is untouched, a write reaches the real file rather than the view, and deleting the view falls back to the real files
- A clean 23.05.5 x86-64 root filesystem installs the package and resolves every dependency. The extracted binary is a real x86-64 ELF (`e_machine` 0x3E) and it **runs**: `uuplugin -v` reports `hw: openwrt`, `v14.9.4`
- Lua parses under the real interpreter, views render through `tools/check-views.lua`, and the status endpoint runs with `luci.http` stubbed
- Route filtering, the minimum-prefix guard and multi-TUN merging have unit tests, including rejection of `default`, `0.0.0.0/0` and anything over-broad

**Not covered:** any router that isn't x86-64. The native vendor-build path is implemented and reasoned from the ELF header, but it has never run on ARM hardware.

One incidental find: the tarball ships more than the booster. There's `xtables-nft-multi` (UU carries its own iptables-nft) and `xuplugin-guardian`, a watchdog. So UU manipulates netfilter itself, which is precisely why the two tools collide without the coexistence work.

[← back to the README](../README.md)
