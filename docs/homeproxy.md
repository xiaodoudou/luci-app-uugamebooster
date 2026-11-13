# Running alongside HomeProxy

[HomeProxy](https://github.com/immortalwrt/homeproxy) runs sing-box. In builds where it uses sing-box's TUN inbound with `auto_redirect`, the two collide lopsidedly: **UDP keeps working while every TCP connection fails**, so a console shows "connected" in the app, gets into some menus, and then cannot matchmake.

This page covers that mode only. Official HomeProxy's redirect and TPROXY modes hook fw4 instead, and the plugin leaves them alone (see [Other HomeProxy modes](#other-homeproxy-modes)).

## What actually breaks: TCP, and only TCP

Measured on a live router (ImmortalWrt, sing-box 1.15, TUN + `auto_route` + `auto_redirect`), with a boosted console at 192.0.2.240:

| | Result |
|---|---|
| DNS reply source | `8.8.8.8` - UU's DNAT landed, name resolution was fine |
| UDP game traffic | `ip route get … mark 0x2024` → `dev tun163 table 179` - already in UU's tunnel |
| **TCP** | **11 of 11 active connections came back from the proxy's own port** |

Two facts explain the split:

| Priority | Table | What runs |
|---|---|---|
| `mangle` (-150) | `ip mangle` | UU marks a boosted device's UDP |
| `dstnat - 1` (-101) | `inet sing-box` | sing-box queues TCP to NFQUEUE |
| `dstnat` (-100) | `ip nat` | UU DNATs DNS to 8.8.8.8 |
| `dstnat + 2` (-98) | `inet sing-box` | **`th dport 53 dnat to <tun>`**, **`tcp redirect to :<port>`** |

UU's policy routing sits at `pref 0` - `from 192.0.2.240 lookup 179` - ahead of the marks sing-box sets. So UDP reaches `tun163` even though sing-box has already marked it. But `redirect` rewrites the destination in nat, **before any route lookup**, so a game's TCP lands on sing-box's listener and UU's `ip rule` is never consulted. Nothing in the routing layer can win that back.

That matters for what not to try: setting UU's prefixes to `direct` in sing-box's route rules does nothing, because the packet has already been redirected into sing-box, and `direct` leaves via the WAN rather than `tun163`.

## What the integration does

Same shape as the OpenClash split, inserted at the top of **both** sing-box chains so the packets never reach the redirect:

| Exemption | Scope |
|---|---|
| the destinations UU routes into its tunnel | boosted device + destination |
| port 53 | boosted device only |

Both come from UU's own live state - `ip route show ... dev tun16*` and the boosted device list - never from a hardcoded table.

### Why DNS is exempted without a destination

This is the one exception that cannot be destination-scoped. sing-box rewrites port 53 to its own DNS server on the TUN peer. If that happens, the console resolves game names **through the proxy exit**, gets back addresses from the wrong CDN region, and those addresses are not in UU's route list - so the exemption above no longer matches and the boost silently stops working while every rule still looks correct.

UU DNATs DNS to `8.8.8.8` for exactly this reason (and `8.8.8.8` is itself in its route table on the setups we measured - it sends its own DNS queries through the tunnel). Port 53 therefore returns unconditionally for a boosted device, and the two never fight over it.

## Rebuilding and cleanup

sing-box regenerates its whole table on every start and on subscription updates (`utpl ... | nft -f -`), which deletes the integration's sets and rules along with it. The daemon therefore checks for its sets on every pass instead of trusting its signature file - a signature that survived a reload would otherwise leave empty sets and a rule that matches nothing.

Everything is removed when UU stops, when the device stops being boosted, or on `uuplugin stop`. While UU is not accelerating anything, HomeProxy behaves exactly as it would without this plugin.

## What to expect

**Most of a boosted console's traffic still goes through the proxy** - store downloads, system updates, streaming - and that is the point of the split. Only the game destinations and DNS leave it.

If a game still will not connect, check in this order:

```sh
ip route show table 179 | head          # is UU routing anything?
nft list chain inet sing-box prerouting | head -4
```

The first line of the chain should be the `uu-hp-dns` return, then `uu-hp-dest`. If both are there and the game still fails to matchmake, the problem is past the netfilter layer - check `logread | grep uuplugin`.

## Status page

When HomeProxy is installed, the status panel shows whether it is running and, in TUN mode, how many game destinations are currently exempted from it. In any other mode it says that mode isn't handled.

## Modes

| Mode | What happens |
|---|---|
| **Keep game traffic out of HomeProxy** (default) | Game destinations and DNS take the UU tunnel. Everything else from that device keeps using HomeProxy. |
| **Take whole devices off HomeProxy** | The boosted device gets one `return` at the top of the chain: it skips sing-box entirely, whatever it is talking to. |
| **Leave HomeProxy alone** | Nothing gets touched. |

Both modes are nftables rules in sing-box's own table, so neither edits HomeProxy's configuration nor restarts it. In TUN mode that is all it takes; in the modes below there is no chain to reach, which is what the status page is warning about.

## Other HomeProxy modes

Official HomeProxy defaults to "Redirect TCP + TProxy UDP", with its rules in fw4's chains rather than a table of sing-box's own. The plugin doesn't touch those, and the status panel says so while HomeProxy is running. There, HomeProxy's own Access Control does the job for a whole device: set *Proxy filter mode* to *Proxy all except listed* and add the console under *Direct IPv4 IP-s* or *Direct MAC-s*. The device then skips HomeProxy entirely, not just for games.

Some HomeProxy builds offer only TUN and have no such list, which is where the split above comes in.

## Limits

- **IPv4 only**, like the OpenClash split.
- **Tested by one user**, on ImmortalWrt with sing-box 1.15 and a Nintendo Switch. Not run on the maintainer's routers.

[← back to the README](../README.md)
