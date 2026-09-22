# Copyright (C) 2021 Openwrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for NetEase UU Game Booster (x86_64 / English / OpenClash)
# tools/mkipk.py parses this line, so the SDK build and the hand-built package
# cannot drift apart. They already had: unshare was declared here and missing
# there, so the device list's mount namespace silently did nothing.
#   ip        iproute2, for "ip rule" and "ip route show table all"; busybox's
#             applet does not cover them. Either ip-tiny or ip-full satisfies it.
#   nftables  the OpenClash split and boost detection read nft directly.
#   unshare   the mount namespace half of the device list.
LUCI_DEPENDS:=+kmod-tun +luci-compat +libstdcpp6 +kmod-ipt-nat +ca-bundle +unshare +ip +nftables
# Nothing here is built for the host architecture. The view filters are carried
# as prebuilt objects for all five, and the right one is chosen at runtime, so
# the package is genuinely portable.
LUCI_PKGARCH:=all
# Two pieces cannot be produced by the SDK. The view filters are compiled out of
# tree by tools/build-preload.sh into root/usr/lib/uuplugin/, from where luci.mk
# packages them like any other file. The user-mode qemu is not carried here at
# all: this path downloads and checksums it on first use of the emulated build.
# tools/mkipk.py bundles it instead, which is why that flavour is x86_64 only.

PKG_NAME:=luci-app-uugamebooster
PKG_VERSION:=2.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Fork of lmq8267/luci-app-uugamebooster

define Package/$(PKG_NAME)/postinst
#!/bin/sh
chmod +x /etc/init.d/uuplugin
chmod +x /usr/libexec/uuplugin/*
endef

include $(TOPDIR)/feeds/luci/luci.mk
# call BuildPackage - OpenWrt buildroot signature
