# Changelog

## 2.5 (2026-11-13)
- Each boosted device is exempted from the proxy only for the routes UU sets up for that device. With two devices boosted, each was also exempted for the other's game prefixes, and that traffic went out the WAN ([#15](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/15), [#16](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/16)).
- One coexistence engine, `uu-sync`, with a descriptor per proxy, replaces the three daemons and adds nikki ([#14](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/14)).
- PassWall coexistence, off by default. It keeps a boosted device's DNS on PassWall's resolver and removes the IPv6 DNS blocks UU leaves behind after a boost ([#12](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/12)).
- OpenClash's exemption sets are refilled after a fw4 reload. They used to stay empty until the boosted devices changed.
- The OpenClash mark rule covers every boosted device, not just the first.
- The status page says Ready once UU is connected to NetEase, instead of waiting for a file that is gone after a reboot ([#13](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/13)).
- The Coexistence tab lists only installed proxies. A General setting shows all of them.
- New `uu-route-check` diagnostic, with `tcpdump-mini` as a dependency for its capture.

## 2.4 (2026-11-09)
- HomeProxy coexistence for sing-box's TUN inbound with auto-redirect: a boosted device's game destinations and DNS skip sing-box, the rest stays on the proxy. Contributed by AxeroOvO ([#11](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/11)).

## 2.3.1 (2026-11-04)
- The apk carries the Chinese translation. apk installs used to show the plugin in English ([#8](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/8)).

## 2.3 (2026-11-03)
- On firmware whose iptables has no DNAT target, UU's DNS redirect is done in nftables, so a boost no longer comes up and drops straight away ([#5](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/5)).

## 2.2.2 (2026-10-27)
- OpenClash running its core from /tmp is detected ([#5](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/5)).
- The OpenClash doc says plainly that fake-ip breaks UU, and points to redir-host.

## 2.2.1 (2026-10-26)
- A missing boot link is put back on the next start or reload, and the status panel warns until then ([#5](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/5)).

## 2.2 (2026-10-25)
- UA3F coexistence: TCP from a boosted device to UU's routes skips UA3F, and everything else still gets its User-Agent rewritten ([#3](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/3)).

## 2.1 (2026-10-24)
- The vendor build runs natively on ARM. Architecture detection, the foreign-install check and takeover are fixed ([#1](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/1)).
- `iptables` is a dependency. Without it the vendor build's tunnel kept coming up and dropping ([#1](https://github.com/xiaodoudou/luci-app-uugamebooster/issues/1)).

## 2.0 (2026-09-22)
- Fork of lmq8267/luci-app-uugamebooster. x86_64 works through NetEase's generic builds, and the vendor builds (native, or under qemu on x86_64) add PC and phone boosting.
- OpenClash coexistence that splits traffic using the ports and fwmark UU actually installs.
- Device list, so the UU app only sees the devices you pick.
- English and Simplified Chinese UI, a live status panel, a firewall zone on tun16+ kept across restarts, and takeover of an install made by NetEase's own script.
- ipk and apk packages, built without the OpenWrt SDK.
