# Coexistence, and the one engine behind it

UU and every transparent proxy want the same packets. A proxy takes them all; UU needs the game ones. The resolution is always the same shape: keep a rule at the top of the proxy's chain that returns **boosted device AND a destination UU routes into its tunnel**, both read from UU's live state, and undo it all when UU stops.

What used to differ per proxy was only three things — which table, which chains, and what the exempted packet matches. Everything else was copy-paste:

| | before | after |
|---|---|---|
| engines | `uu-openclash-sync` (461 lines), `uu-ua3f-sync` (152), `uu-homeproxy-sync` (202) | `uu-sync` (one loop) |
| per-proxy code | one full copy each | one descriptor in `uu-sync.d/`, ~40-90 lines |
| adding a proxy | copy a fifth of a daemon and re-derive the whole reconciliation | add a file, add an option |
| LuCI | a tab and a set of status fields per proxy | generated from whatever is in `uu-sync.d/` |

The copies had already started to drift: the OpenClash one had grown the UDP-port and fwmark read-back, the HomeProxy one had DNS handling the others didn't, and the UA3F one still assumed TPROXY. Now the differences are data.

## A backend is a file

`uu-sync.d/<name>.sh` answers:

| | |
|---|---|
| `NAME`, `LABEL`, `CONFIG` | identifier, display name, and the uci file whose presence means "installed" |
| `sync_family`, `sync_table` | where the proxy keeps its rules |
| `sync_chains` | the chains to act on, one per line. Empty output means "not intercepting yet" — the engine waits instead of guessing |
| `sync_dest_match` | optional. The destination exemption's match; defaults to source + destination, which covers a plain split |
| `sync_extra_rules` | optional. Further `tag|match` lines for DNS, UDP ports, fwmark |
| `sync_before_apply`, `sync_on_cleanup` | optional. Edit the proxy's own config around a boost, and undo it |
| `sync_bypass_on`, `sync_bypass_off` | optional. Whole-device bypass, for proxies that support it |

`uu-sync.d/nikki.sh` is the smallest useful example.

The engine owns the rest: the poll loop, the two nftables sets, reconciliation, the lock that keeps one instance per backend, and teardown.

## Why it repairs itself

Every rule carries a `uu-sync-*` comment tag. Reconciliation reads the tags present in a chain, subtracts the ones wanted, deletes the difference and inserts what's missing. A proxy that rebuilds its tables on restart — all of them do — therefore comes back to a correct state on the next poll, without stacking duplicates and without a single line of per-proxy recovery code.

It also means a backend can change its mind: OpenClash decides per poll whether it wants the UDP slice and the fwmark exemption, based on what UU is actually marking on this build. When the answer changes, the old rules are deleted by tag rather than left behind.

## Where the settings live

One **Coexistence** tab, generated from the descriptors. Each installed proxy gets a **Coexistence** dropdown (`<backend>_mode` in `/etc/config/uuplugin`):

| Mode | What happens |
|---|---|
| **Split the traffic** (`cooperative`, default) | game traffic leaves the proxy, everything else stays on it |
| **Take whole devices off** (`bypass`) | a boosted device skips the proxy entirely, whatever it is talking to |
| **Leave it alone** (`off`) | nothing gets touched |

The two modes differ by one match expression, not by mechanism: cooperative wants `device AND destination`, bypass wants `device` alone. Both are nftables rules in the proxy's own chains, so neither writes the proxy's configuration and switching between them never restarts it. UA3F has no bypass — it rewrites User-Agents rather than proxying, so "off the proxy" would be the wrong words for it.

A proxy the plugin has never been told about still appears, because the tab is built by listing `uu-sync.d/`. So does its line on the status page, and its count of active exemptions.

## Things to watch out for

- **The order of the hooks decides everything.** A proxy that hooks at `mangle` or `dstnat` priority always beats one that hooks at `filter` priority, no matter what you configure. [UA3F](ua3f.md#where-ua3f-sits-relative-to-the-proxy) is the one that gets bitten by this.
- **Only one mode at a time.** A backend runs as exactly one instance; the init script starts one per installed proxy and stops them all on `stop`.
- **IPv4 only**, for every backend. The set of IPv6 equivalents exists in UU's own rules and the same approach would work; it just isn't wired up.

[← back to the README](../README.md)
