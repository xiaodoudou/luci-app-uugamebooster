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

[← back to the README](../README.md)
