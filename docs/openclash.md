# Running alongside OpenClash

UU and OpenClash both grab LAN traffic transparently. Leave them to it and whichever hooks netfilter first wins, while the other sits there doing nothing. That's why "UU says connected but nothing is accelerated" comes up so often.

The UU **PC** client sidesteps the problem by hooking individual game *processes* through the Windows Filtering Platform. A router has no processes to hook, only packets. The equivalent here is to split on source **and** destination.

## Modes

| Mode | What happens |
|---|---|
| **Split the traffic** (default) | Game traffic takes the UU tunnel. **Everything else from the same device still goes through OpenClash.** Nothing gets excluded wholesale. |
| **Take whole devices off OpenClash** | The fallback. Whatever you list stops using the proxy entirely (`lan_ac_mode=0` blacklist) for as long as UU runs. |
| **Leave OpenClash alone** | Nothing gets touched. |

Splitting is re-applied on every poll, so it heals itself when OpenClash restarts and rebuilds its chains. Everything is undone when UU stops.

## What actually leaves OpenClash

The obvious approach doesn't work. OpenClash's `wan_ac_black_ips` is destination-only and global, so copying UU's route list into it would take *every* device on your LAN off the proxy for those destinations. Not what anyone wants.

Instead `uu-openclash-sync` owns two nftables sets of its own and inserts `return` rules at the top of OpenClash's chain. Three exemptions, all limited to boosted devices, and all read back from UU's live rules rather than assumed:

| Exemption | Where it comes from |
|---|---|
| the destinations UU routes into its tunnel | `ip route show ... dev tun16*` |
| the UDP ports UU marks | UU's own mangle rules for that device |
| UU's fwmark | `ip rule ... from <device> fwmark …` |

That last group has to be read rather than hardcoded, because the UDP slice isn't the same between builds. The generic build marks the whole ephemeral range `1025-65535`. The vendor build marks only DNS and leaves everything else to its destination routes.

Here's what that cost when it was assumed. Measured on a live router with passive counters over 150 seconds, one boosted PC sent **131** packets in `1025-65535` against **16** that UU actually marked. So the wide guess was sending roughly six times more traffic around the proxy than UU was accelerating. Reading it back makes the exemption exactly as wide as UU's real behaviour on either build, and skips the UDP exemption entirely when UU marks nothing.

This is also the answer to the most common surprise: **most of a boosted PC's traffic still shows up in OpenClash, and that's correct.** Only game destinations and UU's own DNS leave the proxy.

## Safety guard

The **minimum prefix length** (default `/8`) stops an over-broad route from ever being exempted, a stray default route especially. Without it, one bad route could pull your entire WAN out of the proxy. Raise it if you want to be stricter.

## Things to watch out for

- **fake-ip mode gets in the way.** With OpenClash in fake-ip mode your device resolves game domains to `198.18.x.x`, so UU never sees a real server IP for *domain-addressed* traffic and can't classify it. Console matchmaking is mostly raw-IP UDP and is unaffected, but a game that looks up its servers by name needs that domain in OpenClash's fake-ip filter, or `redir-host` mode instead.
- **A device on OpenClash's own bypass list can't be split.** `lan_ac_black_ips` returns before any finer rule gets a look, so that device skips the proxy wholesale. **Move devices off OpenClash's own bypass list** lets the plugin pull it out while it's boosted and put it back afterwards. It's off by default, because it edits and saves OpenClash's config.
- **IPv4 only for now.** `wan_ac_black_ipv6s` exists and the same approach would work. It just isn't wired up.

[← back to the README](../README.md)
