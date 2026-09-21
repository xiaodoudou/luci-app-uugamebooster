# Device visibility

Out of the box, the UU app lists every host on your network. That's because the plugin enumerates the LAN and tells NetEase what it found. **Device visibility** cuts that down to the devices you name, by IP or MAC:

| Mode | What it does |
|---|---|
| Every device | Stock behaviour |
| Everything except the devices below | Those get hidden from the plugin |
| Only the devices below | Everything else gets hidden |

This is about visibility, not firewalling. A hidden device is simply one the plugin never hears about, so it's never offered for boosting and never reaches NetEase's cloud. Naming a device by MAC survives DHCP changes; naming it by IP is quicker to type.

## How it works

The plugin looks for devices in four fixed places. `uu-view` keeps a filtered copy of each under `/var/run/uu-view`:

| Source | Swapped out by |
|---|---|
| `/tmp/dhcp.leases` | bind mount in a private mount namespace |
| `/tmp/nmp_client_list`, `/jffs/nmp_client_list` | bind mount |
| `/proc/net/arp` | `LD_PRELOAD` shim |
| `ip -6 neigh show` | `LD_PRELOAD` shim |

The ARP table needs the second trick because you can't mount over it. `/proc/net` is a symlink to `self/net`, and the table gets regenerated from the network namespace on every single read. A bind mount there is accepted and then quietly ignored, which is a fun half hour to debug.

So the shim ([`src/uu-view-preload.c`](../src/uu-view-preload.c)) interposes the plugin's own `open`, `fopen`, `popen` and `system` calls instead. That works because every UU build is dynamically linked against musl. The plugin checks that at start-up rather than assuming it, so a statically linked build would warn you instead of silently filtering nothing.

One detail worth knowing: the shim drops `LD_PRELOAD` from the environment the moment it loads. Otherwise the native `ip` and `brctl` commands the plugin shells out to would inherit a pointer to an object built for the wrong architecture. musl treats that as fatal, and UU's own routing would stop working.

Nothing outside the plugin notices any of this. Your real lease file and ARP table are untouched and dnsmasq isn't involved. If the filtered view goes missing for any reason, every call falls through to the real file, so you get stock behaviour rather than a broken plugin.

[← back to the README](../README.md)
