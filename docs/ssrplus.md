# Running alongside SSR+

On OpenWrt systems running the SSR+ nftables backend, a TCP destination rule can take precedence over the device bypass list. The UDP hook can also drop packets on ports 80 and 443 before Linux routes them into UU's tunnel.

## Setup

The **SSR+** row appears under **Services → UU Game Booster → Coexistence** when `/etc/config/shadowsocksr` exists. Upgrades retain any saved selection.

| Mode | Effect |
| --- | --- |
| **Split the traffic (recommended)** | Default. IPv4 traffic routed to UU's tunnel bypasses SSR+. |
| **Take whole devices off the proxy** | All IPv4 traffic from a boosted device bypasses SSR+'s interception chains. |
| **Leave it alone** | SSR+ uses its own rules. |

## How the split works

- The plugin inserts tagged rules at the start of `inet ss_spec / ss_spec_prerouting` and `ip ss_spec_mangle / prerouting`, when present. The first hook handles TCP redirection and can also block UDP 443 when TPROXY is disabled.
- A rule matches the source IPv4 address against the active boosted devices. In split mode, the kernel looks up the route using the packet's source, destination and current mark. The rule returns from the SSR+ chain only when that lookup selects a UU tunnel. This covers both destination routes and marked UDP or DNS traffic.
- The sync process updates its device sets and restores its rules after SSR+ rebuilds either chain. It clears its rules and sets when boosting or the integration stops. An SSR+ snapshot may contain these rules, so each mode has its own absolute deadline. With the default five-second poll interval, a snapshot stops matching within twenty seconds of its last refresh. In split mode, the live tunnel check also stops matching when UU's routes disappear.

IPv4 is supported on SSR+ builds using the above nftables chains and the nftables FIB expression. The route lookup works without concatenated interval sets, which some 5.4 router kernels lack. This integration covers prerouting for client traffic. SSR+ keeps its LAN access lists, router-originated traffic rules, and upstream DNS settings. Builds with legacy iptables chains require a separate adapter.

## Check the rules

```sh
/usr/libexec/uuplugin/uu-detect | grep -E '^(ssrplus|boosted)='
nft list chain inet ss_spec ss_spec_prerouting
nft list chain ip ss_spec_mangle prerouting
logread -e uu-ssrplus
```

During a boost, look for the `uu-sync-dest` counter in split mode or `uu-sync-bypass` in whole-device bypass mode. A TCP redirect applies to new connections. Start a new connection when checking the split.

[← back to the README](../README.md)
