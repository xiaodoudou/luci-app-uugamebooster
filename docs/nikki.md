# Running alongside nikki

[nikki](https://github.com/nikkinikki-org/OpenWrt-nikki) is an OpenWrt front end for mihomo (Clash.Meta). It intercepts LAN traffic transparently, so it runs into exactly the same problem as [OpenClash](openclash.md): whichever of the two hooks netfilter first wins, and a boosted device's game connections end up inside the proxy where UU can't see them.

The fix is the same split — source **and** destination — and it lives in one file, `uu-sync.d/nikki.sh`, which describes nikki to the shared engine. See [Coexistence](coexistence.md) for how that engine works.

## How nikki grabs traffic

nikki keeps everything in one table, `inet nikki`. Unlike OpenClash's two chains, it has a chain per interception method, and only the ones matching its settings are hooked:

| `proxy.tcp_mode` / `udp_mode` | Chain | Hook |
|---|---|---|
| `redirect` | `dstnat` → `lan_redirect` | `nat prerouting priority dstnat + 1` (`-99`) |
| `tproxy` | `mangle_prerouting_lan` | `filter prerouting priority mangle` (`-150`) |
| `tun` | none — a `tun` device and routing rules | not netfilter at all |

The chain names are probed at runtime rather than assumed: if `mangle_prerouting_lan` is missing, the descriptor falls back to `lan_redirect`, `lan_tproxy`, `lan_tun` and `lan_dns_hijack`.

DNS goes through its own chains (`lan_dns_hijack`, `router_dns_hijack`), which is why the exemption has to cover port 53 explicitly and not just "the same destination".

## What gets kept out of nikki

Same three exemptions as everywhere else, all limited to boosted devices and all read back from UU's live state:

| Exemption | Where it comes from |
|---|---|
| the destinations UU routes into its tunnel | `ip route show ... dev tun16*` |
| the UDP ports UU marks | UU's own mangle rules for that device |
| UU's fwmark | `ip rule ... from <device> fwmark …` |

They go in as `return` rules tagged `uu-sync-*` at the top of whichever chain nikki is actually using. nikki rebuilding its table removes them; the engine notices and puts them back within one poll.

## Taking a device off nikki entirely

**Take whole devices off the proxy** drops the destination condition and leaves one rule at the head of each chain: `ip saddr @uu_boosted return`. The device then leaves nikki whatever it is talking to, DNS included. Same sets, same tags, same self-healing — switching between the two modes is a rule swap on the next poll, with no nikki restart and nothing written to `/etc/config/nikki`. That is deliberately *not* done through `lan_access_control`: nikki only turns that into rules when it regenerates and restarts, which would drop every connection on the LAN for a one-device change.

## Where nikki sits relative to UA3F

This is the part that costs people an afternoon, and it isn't nikki's fault.

| Service | Hook | Priority |
|---|---|---|
| UA3F in **REDIRECT** mode | `nat prerouting` | `dstnat - 20` = **-120** |
| nikki in `redirect` mode | `nat prerouting` | `dstnat + 1` = **-99** |
| nikki in `tproxy` mode | `filter prerouting` | `mangle` = **-150** |
| UA3F in **TPROXY** mode | `filter prerouting` | `filter + 20` = **+20** |

Lower numbers run first. So a UA3F in TPROXY mode hooks at `+20`, dead last — nikki has already taken every packet it wanted, and UA3F's `tproxy` statement never finds a socket to hand the connection to. UA3F looks alive (its counters climb) while rewriting nothing.

**Put UA3F in REDIRECT mode and let nikki work behind it.** UA3F hooks at `-120`, rewrites the User-Agent, and re-originates the connection from the router; nikki then picks that up on the `output` path and proxies it. That's the only arrangement where both do their job.

The split still matters on top of this: a boosted device's game destinations return out of UA3F early, so UU sees them, and they return out of nikki too.

## Two settings that quietly break it

- **`nikki.mixin.socks_port` defaults to `1080`, which is UA3F's tproxy/redirect port.** Whoever starts second loses the bind, and if that's UA3F it exits or runs with no listener — no error anywhere except in its own log. Move nikki's SOCKS port (`1081` here) or point UA3F somewhere else.
- **`nikki.proxy.bypass_china_mainland_ip` defaults to `0`**, which leaves the `china_ip` nft set empty. Every LAN destination then goes into the proxy, so nothing is left for UA3F to rewrite even when the priorities are right. Turn it on; it also saves mihomo a pointless round trip for domestic traffic.

## Things to watch out for

- **fake-ip doesn't work with UU**, for the same reason as [with OpenClash](openclash.md#things-to-watch-out-for): the core never sees the real server IPs that UU routes on. Use `redir-host`, with DoH resolvers written as plain IPs and `respect-rules` set.
- **IPv4 only for now**, like the other splits.
- **`tun` mode isn't covered.** There is no chain to insert into; the descriptor reports `tun-only` on the status page and does nothing.
- **A subscription node pointing at a placeholder** — a "see our website" node with `server: 0.0.0.0` — is a common default for the proxy group, and every request fails with `dial tcp 0.0.0.0:443`. Pick a real node once through the `/proxies` API or the dashboard; nikki remembers it with `mixin.selection_cache`.

[← back to the README](../README.md)
