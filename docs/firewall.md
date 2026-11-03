# Firewall

On OpenWrt 22.03 and newer the default forward policy is REJECT. UU's tunnel gets blocked and acceleration silently does nothing. NetEase [documents four ways out](https://router.uu.163.com/happ/qa/detail/675154eced42e98791b640a1?app=router): a dedicated zone, per-interface traffic rules, editing `/etc/config/firewall` by hand, or setting the whole firewall to ACCEPT.

**Open the firewall for UU's tunnel** (on by default) does the first one, because it's the only one that scales:

```
config zone
    option name    'UU'
    option input   'ACCEPT'
    option output  'ACCEPT'
    option forward 'ACCEPT'
    option device  'tun16+'
config forwarding
    option src  'lan'
    option dest 'UU'
```

UU creates **one TUN per boosted device**: `tun163` for the first, `tun164` for the second, and so on. That's why NetEase's per-interface instructions have you add three more rules by hand for every extra console. The `tun16+` wildcard matches all of them at once, so you never touch it again.

The last of NetEase's options, setting input/output/forward to ACCEPT, does work. It also disables your router's firewall for *all* traffic. This fork won't do that.

## Why the zone survives a restart

The zone is removed when you **disable** the service, not every time it stops.

It used to come out on every stop, which meant a restart removed and re-added it, and each of those reloads fw4. Reloading fw4 discards the chains OpenClash adds at runtime, while OpenClash's `ip rule` survives. So a service that restarted a few times took the whole network down with it, which is exactly as much fun as it sounds.

Leaving the zone in place is safe: it only matches `tun16+`, and those interfaces don't exist while UU isn't running.

## Firmware whose iptables has no DNAT

For every boosted device the vendor build sends that device's DNS to `8.8.8.8`:

```
iptables -t nat -I PREROUTING -i br-lan -s <device> -p udp --dport 53 -j DNAT --to-destination 8.8.8.8
```

If that one rule fails, it rolls the whole boost back. The tunnel comes up, its rules go in, then everything is deleted again within a fraction of a second, over and over. Stock OpenWrt builds DNAT into iptables, but some vendor firmware leaves it out. photonicatWrt 26.04.1 on the Photonicat 2 is one, where the rule fails with `unknown option "--to-destination"` and no package in its feeds adds DNAT back.

The service checks for this at every start, the way the core calls iptables (`XTABLES_LIBDIR=/lib iptables -j DNAT -h`). Where DNAT is missing, it puts a small stand-in, `/usr/libexec/uuplugin/xt/iptables`, first on the core's `PATH`. That turns UU's DNAT calls (add, check and delete) into the same rule in an nftables table of its own, `ip uuplugin_nat`, and passes every other call to the real iptables untouched. A call it doesn't fully understand also goes to the real one, so the worst case is the failure that was there anyway. The table goes away when the service stops.

The log says so at start, and the status page notes it under **Running**. On firmware where DNAT works, none of this happens and the core runs exactly as before.

[← back to the README](../README.md)
