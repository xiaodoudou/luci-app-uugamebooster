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

Checked on a **NanoPi R4S (aarch64) running OpenWrt 25.12.5**, with the `h3c-nx30pro` vendor build running natively:

- The ELF check picks the native path, the plugin registers with NetEase's cloud, and the phone app binds it
- A boost brings up `tun163`, UU's policy routes and its mangle/nat rules, once `iptables` is installed. Without it, binding still works but every boost tears the tunnel down within seconds
- `uu-detect` reports the native process as ours, and `takeover` leaves it, `/tmp/uu` and the service's own boot link alone

UA3F coexistence, on the same R4S with **UA3F 3.7.0 in TPROXY mode**:

- Within one poll of a boost, the exemption sits at the top of UA3F's real `PREROUTING` chain, ahead of its `tproxy` rules, with UU's prefixes for each boosted device (119 for one, 426 with two)
- A phone's connection to a UU-routed address hit the exemption (13 packets), carried no UA3F mark, and went out through UU's tunnel, while UA3F kept intercepting the rest of that phone's TCP
- The phone's game talked to servers UU wasn't routing, and those correctly stayed with UA3F
- Restarting UA3F wipes the exemption with its table; it was back 8 seconds later
- The LuCI views, the new status rows included, render through `tools/check-views.lua` on the router

Off the router, a WSL harness in throwaway network namespaces sends real SYNs at a UA3F-shaped table: TPROXY and REDIRECT chains, recovery after the table is recreated or gone for a while, removal when nothing is boosted, cleanup on SIGTERM, and the OpenClash sync after its discovery code moved to `uu-lib.sh`.

**Not covered:** MIPS routers. On the R4S, start-up and registration ran with a normal WAN, but binding and boosting were only exercised with the router on the home LAN and no WAN. UA3F's REDIRECT mode only ran in the WSL harness.

One incidental find: the generic tarball ships more than the booster. There's `xtables-nft-multi` (UU carries its own iptables-nft) and `xuplugin-guardian`, a watchdog. So UU manipulates netfilter itself, which is precisely why the two tools collide without the coexistence work. The vendor tarball has only the watchdog, and calls the system `iptables` instead.

[← back to the README](../README.md)
