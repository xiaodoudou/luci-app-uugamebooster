# Conflicts with an existing UU install

Installed UU before using [NetEase's own script](https://router.uu.163.com/app/html/online/baike_share.html?baike_id=5f963c9304c215e129ca40e8)? That install is still there: a watchdog in `/usr/sbin/uu`, with the binary running out of `/tmp/uu`. It and this plugin both want to own `/var/run/uuplugin.pid`, and only one of them can have it. Start this service next to it and you get:

```
uuplugin: Create or open pid file failed; Maybe another instance is running.
procd: Instance uuplugin::uuplugin s in a crash loop 6 crashes
```

The service now spots that up front and refuses to start, telling you what it found and what to do about it, instead of letting procd loop forever. The status panel shows the same warning.

To hand over to this plugin:

```bash
/etc/init.d/uuplugin takeover
```

That stops the watchdog first, since otherwise it just respawns the binary. Then it kills any foreign `uuplugin` and removes `/usr/sbin/uu`, `/tmp/uu` and the S99 hook.

It goes out of its way to avoid `pkill`, for two reasons: busybox's `pkill -x uuplugin` matches nothing even when a process is named exactly that, and `pkill -f uuplugin_monitor.sh` would match the very shell running the command. Both were discovered the hard way.

Want to keep the official install instead? Just leave this service disabled. The plugin won't interfere with it.

## Cleaning up rules from a manual setup

If you followed NetEase's per-interface firewall instructions, you have three hand-written rules per boosted device, each pinned to one `tun163` or `tun164`. The `tun16+` zone replaces the lot:

```bash
/etc/init.d/uuplugin cleanup_legacy
```

That only reports what it thinks is redundant. Add `apply` to actually delete them (highest section index first, since deleting one renumbers the rest).

It only ever touches firewall rules bound to a UU tunnel, and only when the UU zone exists to replace them. OpenClash's access-control lists are never modified: UU address ranges parked there stay useful for any other UU client on your LAN.

One last thing, in case you're wondering whether you had the right setup all along. The official installer's config on such a machine reads `router=openwrt` / `model=x86_64`, and it pulls the same `openwrt-x86_64` build this plugin uses. So they run the same thing. What this plugin adds is the LuCI interface, the firewall automation, the device list and the OpenClash split.

[← back to the README](../README.md)
