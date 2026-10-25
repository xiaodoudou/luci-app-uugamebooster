# Running alongside UA3F

[UA3F](https://github.com/SunBK201/UA3F) rewrites the HTTP User-Agent of LAN traffic, mostly to get past campus networks that limit how many devices one account can use. To do that it pulls LAN TCP into its own listener, and a boosted device's game connections go with it, so UU never sees them and nothing gets accelerated.

## How UA3F grabs traffic

Everything lives in its own nftables table, `inet UA3F`:

| UA3F mode | What happens |
|---|---|
| TPROXY | chain `PREROUTING` (priority `filter + 20`) marks TCP `0x1c9` and hands it to `127.0.0.1:1080` |
| REDIRECT | a nat chain, also `PREROUTING` (priority `dstnat - 20`), redirects TCP to UA3F's port |

UDP is never touched: the chain starts with `meta l4proto != tcp return`. So only TCP needs an exemption.

## What gets kept out of UA3F

UA3F has its own skip list, `UA3F_SKIP_IPSET`, but it's destination-only and global, the same trap as OpenClash's `wan_ac_black_ips`. Filling it with UU's routes would take those destinations out of UA3F for every device on the LAN.

So `uu-ua3f-sync` does what the [OpenClash split](openclash.md) does. It puts one `return` rule at the top of UA3F's `PREROUTING` chain, matching **boosted device AND a destination UU routes into its tunnel**, both read from UU's live state. Everything else from that device, its web browsing included, still gets UA3F's rewrite. That matters here more than with OpenClash: the point of UA3F is that the campus network never sees an unrewritten User-Agent, and exempting whole devices would undo that for as long as they're boosted.

The two sets the rule uses (`uu_boosted`, `uu_dests`) have to live inside `inet UA3F`, because a rule can't reference another table's sets.

## Surviving UA3F restarts

UA3F deletes and recreates its table every time it starts, and our sets and rule go with it. Every poll checks for both and rebuilds what's missing, so the exemption is back within one poll interval (5 s by default, shared with the OpenClash setting) of UA3F coming back up. When nothing is boosted, or UU stops, the rule and sets are removed and UA3F behaves exactly as it would without this plugin.

## Settings

The **UA3F** tab has one setting, **Coexistence**:

| Setting | What happens |
|---|---|
| **Keep game traffic out of UA3F** (default) | as above |
| **Leave UA3F alone** | nothing gets touched |

The daemon only starts when UA3F is installed (`/etc/config/ua3f` exists), and only acts while its table is there. Installing UA3F after this plugin needs one restart of the UU service to pick it up.

## Things to watch out for

- **IPv4 only**, like the OpenClash split. UA3F also handles IPv6, and a boosted device's IPv6 game traffic would still go to UA3F.
- **TPROXY and REDIRECT only.** UA3F's other modes (NFQUEUE, netlink) hook traffic differently and aren't covered.

[← back to the README](../README.md)
