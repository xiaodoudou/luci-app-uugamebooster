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
# The package bundles an x86_64 qemu for the emulated OEM build.
LUCI_PKGARCH:=x86_64
# Two pieces cannot come from the SDK and are built out of tree instead - the
# qemu binary, and the view filters in src/, one of which targets aarch64. See
# tools/build-preload.sh and tools/mkipk.py, and the Install section of README.

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
