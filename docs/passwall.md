# PassWall

PassWall and UU do not fight over netfilter. UU steers a boosted device with its
own policy routing — `from <ip> lookup 179` for the game prefixes,
`from <ip> fwmark 0x163 lookup 163` for everything it marks — and those rules
carry a **lower priority number** than PassWall's `fwmark 0x50535731 lookup 999`.
A game destination is therefore routed into UU's tunnel, and everything else
falls through to PassWall's tproxy, in that order, with nobody configuring
anything. That is measured on an IPQ60xx: with both running, `tun163` carried the
game traffic while the rest of the same PC's connections went through the proxy.

So unlike [OpenClash](openclash.md), there is no traffic split to arrange. The
one thing that collides is DNS.

## What UU does to DNS

For every boosted device the OEM core installs, and keeps installed while the
boost runs:

```
iptables  -t nat -I PREROUTING -i br-lan -s <ip> -p udp --dport 53 \
          -j DNAT --to-destination 8.8.8.8
iptables  -t mangle -A PREROUTING -i br-lan -s <ip> -p udp --dport 53 \
          -j MARK --set-xmark 0x163/0x163
ip rule    add from <ip> fwmark 0x163/0x163 lookup 163      # default via tun163
ip6tables -t filter -I INPUT   -i br-lan -p udp --dport 53 \
          -m mac --mac-source <mac> -j DROP
ip6tables -t filter -I FORWARD -i br-lan -p udp --dport 53 \
          -m mac --mac-source <mac> -j DROP
```

The first three are one mechanism. UU's list of destinations is a **static prefix
table** (154 prefixes for a PC), so the only way to guarantee that the game
client connects to an address UU has a route for is to answer its DNS itself:
the query is rewritten to `8.8.8.8`, marked, and routed into the tunnel.

That rule is load-bearing. NetEase's own documentation says a boost is rolled
back — tunnel and all — when it cannot be installed, which is why there is no
switch to turn it off.

The `ip6tables` pair is the other half. UU has no IPv6 tunnel (`IPv4 only for
now`), so a device that resolves AAAA and prefers it cannot be accelerated at
all. Blocking the device's IPv6 DNS forces IPv4-only resolution.

## Why it breaks PassWall

PassWall's resolver chain is dnsmasq → chinadns-ng → sing-box:

```
lan device → dnsmasq (53) → chinadns-ng (15355) ─┬→ 192.168.1.1   (direct)
                                                  └→ sing-box (15353) → proxy
```

With the redirect in place a boosted device never reaches that chain. Its queries
go into the game tunnel, where they are answered from the wrong place or dropped
— and because the answer is all the client gets, it either connects to an address
UU has no route for (no acceleration) or fails to resolve at all.

The IPv6 block is worse, because **UU never removes it**. Stopping the boost
takes out the `ip rule`, the tunnel and the nat rules, and leaves the two
`ip6tables` DROPs behind. One session of gaming therefore leaves that device
unable to resolve over IPv6 until the next reboot, with nothing on screen to say
why: browsers keep working through DoH, so only command-line tools and anything
that uses the system resolver fails.

## What the plugin does about it

`uu-passwall-sync`, started by `/etc/init.d/uuplugin` when `passwall_mode` is
`cooperative`, and only when `/etc/config/passwall` exists. It is off by
default, because of the trade-off under *What it does not do*:

| Step | Effect |
|---|---|
| insert `-t nat PREROUTING` position 1: `-i <lan> -s <ip> -d <lan ip> -p udp --dport 53 -j RETURN` | the device's DNS goes to PassWall's resolver again |
| delete `ip6tables -t filter` rules matching `--dport 53 … --mac-source <mac> … -j DROP` in `INPUT` and `FORWARD`, by rule spec, for MACs that are no longer boosted | IPv6 resolution comes back once the boost ends; during a boost the DROP stays, since it is what keeps the device on IPv4 and in the tunnel |
| re-check every `oc_interval` seconds (the Coexistence tab's re-check interval, default 5) | UU inserts its rule at position 1 on every boost, and a `fw4` reload can flush the table; both are corrected within one interval |
| drop the `RETURN` of a device that is no longer boosted | nothing is left behind for it |
| `cleanup` whenever the service stops or PassWall is switched off | our rules are ours, so they go |

Only the **router's own address** is exempted, not the whole of port 53. A query
aimed anywhere else still takes UU's redirect, exactly as before.

Acceleration is unaffected, and not by luck: the core checks that its DNAT rule
was *accepted*, not that packets reach it. The rule is still installed, still at
position 1 of its own insertion, and the boost stays up. Measured with the
exemption in place: `tun163` carried several MB while the same PC browsed through
PassWall.

## What it does not do

- **It does not split traffic.** Nothing needs splitting; see the top of this
  page. If you came here expecting the engine's two nftables sets, that is
  because OpenClash hooks netfilter and PassWall does not.
- **It does not touch the game's own resolution.** If a game's server name
  resolves, through PassWall, to an address outside UU's prefix table, that
  connection leaves the tunnel and is not accelerated. Check one with
  `ip route get <ip> from <device ip> iif br-lan`: `dev tun163` means UU,
  `dev wan` means it is not.
- **It cannot help a device that does not use the router's DNS.** A client with
  its own resolver configured bypasses PassWall entirely, and the redirect UU
  installs is the only thing that would have caught it. Turn on PassWall's own
  DNS redirect if that matters to you.
- **It does not cover firmware without iptables DNAT.** There UU's redirect is
  done in nftables (`dnat=nft` in `uu-detect`), out of reach of an iptables
  `RETURN`.

## Turning it on

LuCI → **Services → UU Game Booster → Coexistence → PassWall → Split the traffic**,
or:

```sh
uci set uuplugin.@uuplugin[0].passwall_mode='cooperative'
uci commit uuplugin
/etc/init.d/uuplugin reload
```

[← back to the README](../README.md)
