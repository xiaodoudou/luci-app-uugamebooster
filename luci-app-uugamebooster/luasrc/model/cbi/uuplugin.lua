local mp, s, o, fs, ctl
require("luci.util")
require("luci.sys")

fs = require("nixio.fs")
-- The list of proxies lives in uu-sync.d/ as descriptor files, and this form is
-- built from them: a second hard-coded list here would be the thing that drifts
-- from the scripts next.
ctl = require("luci.controller.uuplugin")

-- A proxy counts as installed when its config exists, the same test the init
-- script makes before starting its backend. "all" lists every supported one.
local show_all = require("luci.model.uci").cursor():get_first("uuplugin", "uuplugin", "coex_tabs") == "all"
local proxies = {}
for _, b in ipairs(ctl.backends()) do
	if show_all or (b.config ~= "" and fs.access(b.config)) then
		proxies[#proxies + 1] = b
	end
end
-- PassWall has no engine descriptor (it works in iptables), but sits here too.
if show_all or fs.access("/etc/config/passwall") then
	proxies[#proxies + 1] = { id = "passwall", label = "PassWall", config = "/etc/config/passwall" }
end

mp = Map("uuplugin")
mp.title = translate("UU Game Booster")
mp.description = translate(
	"Runs NetEase's UU game accelerator on this router. See the " ..
	"<strong>How to use</strong> tab to get started.")

mp:section(SimpleSection).template = "uuplugin/uuplugin_status"

-- One section, grouped with tabs. Several TypedSections over the same config
-- section would look similar, but :depends() then attaches a newly shown option
-- to the first fieldset instead of its own - the vendor model would appear under
-- "Service". Tabs keep one section, so dependencies stay where they belong.
s = mp:section(TypedSection, "uuplugin")
s.anonymous = true
s.addremove = false

s:tab("general", translate("General"))
s:tab("build",   translate("What to boost"))
if #proxies > 0 then s:tab("coexist", translate("Coexistence")) end
s:tab("devices", translate("Device visibility"))
s:tab("howto",   translate("How to use"))

-- ----------------------------------------------------------------- general

o = s:taboption("general", Flag, "enabled", translate("Enable"))
o.default = 0
o.rmempty = false

o = s:taboption("general", Value, "model", translate("Router name"),
	translate("Shown in the UU app, so you can tell routers apart. Changing it " ..
		"after binding means unbinding and binding again."))
o.placeholder = "OpenWrt"

o = s:taboption("general", Flag, "addfw",
	translate("Open the firewall for UU's tunnel"),
	translate("Adds a firewall zone for UU's tunnel (tun16+) and lets the LAN " ..
		"forward into it. Required on OpenWrt 22.03 and newer, where forwarding " ..
		"is rejected by default - without it nothing can be boosted."))
o.default = 1

o = s:taboption("general", ListValue, "coex_tabs", translate("Proxies on the Coexistence tab"),
	translate("Takes effect after Save &amp; Apply."))
o:value("auto", translate("Only those installed on this router"))
o:value("all", translate("Every supported proxy"))
o.default = "auto"

-- ------------------------------------------------------------ plugin build

o = s:taboption("build", ListValue, "arch", translate("Plugin build"))
o:value("auto", translate("Game consoles only (recommended)"))
o:value("oem", translate("Game consoles, PCs and phones"))
o.default = "auto"
o.description = translate(
	"NetEase ships PC and phone boosting only in the builds it makes for router " ..
	"vendors, which identify themselves to its servers as H3C hardware. Ask for " ..
	"those and the plugin fetches one and works out how to run it:" ..
	"<br />&#8226; on an ARM router it runs directly;" ..
	"<br />&#8226; on x86_64 it runs under emulation - everything needed is " ..
	"bundled, only the plugin itself is downloaded, and CPU use is a little " ..
	"higher." ..
	"<br />The console-only builds are NetEase's plain OpenWrt ones. They are " ..
	"leaner, but the app will not offer your PC or phone.")

o = s:taboption("build", ListValue, "oem_model", translate("Vendor model"),
	translate("Which vendor build to ask NetEase for. Both behave the same; try " ..
		"the other one if a download fails."))
o:value("h3c-nx30pro", "H3C NX30 Pro")
o:value("h3c-bx54", "H3C BX54")
o.default = "h3c-nx30pro"
o:depends("arch", "oem")

o = s:taboption("build", ListValue, "arch_force", translate("CPU architecture"),
	translate("Only needed if the automatic choice is wrong."))
o:value("", translate("Detect automatically"))
o:value("x86_64", "x86_64")
o:value("aarch64", "aarch64")
o:value("arm", "arm")
o:value("mipsel", translate("mipsel (little endian)"))
o:value("mipseb", translate("mipseb (big endian)"))
o.default = ""
o.rmempty = true
o:depends("arch", "auto")

-- ------------------------------------------------------------- coexistence

-- UU and a transparent proxy both intercept LAN traffic, so left alone one of
-- them silently wins. Every proxy gets the same choices, because the fix is the
-- same for all of them: exempt only what UU actually accelerates, and only for
-- devices it is boosting. What that exemption has to look like differs per
-- proxy, and that is what its descriptor in uu-sync.d/ encodes - so this form
-- asks one question per installed proxy and nothing about how it works.
--
-- The explanation is written once, above the proxies, rather than as the
-- description of every one of them: with four installed it was the same four
-- paragraphs, four times, and the answer took scrolling to find.

if #proxies > 0 then
o = s:taboption("coexist", DummyValue, "_coexist_why",
	translate("How coexistence works"))
o.description = translate(
	"Left alone, whichever of the two hooks netfilter first wins and the other " ..
	"does nothing. Coexistence moves the dividing line onto UU's side: only " ..
	"what UU actually accelerates leaves the proxy, and only for devices it is " ..
	"boosting. Everything else from that same device keeps going through the " ..
	"proxy - so most of a boosted PC's traffic still showing up there is the " ..
	"intended result, not a fault." ..
	"<br /><br /><strong>Split the traffic</strong> - the split described " ..
	"above. The recommended one." ..
	"<br /><strong>Take whole devices off the proxy</strong> - the blunt " ..
	"fallback: a boosted device skips the proxy entirely, whatever it is " ..
	"talking to. For the device that will not split cleanly." ..
	"<br /><strong>Leave it alone</strong> - the two are left to fight over the " ..
	"packets.")

-- One short line each. Anything longer repeats what the paragraph above already
-- said, and the detail lives in docs/ anyway.
local NOTE = {
	openclash = translate(
		"Redirects LAN traffic from chains inside fw4. The exemption is UU's own " ..
		"destination routes, plus the UDP ports and fwmark UU sets - all read " ..
		"back from its live rules, because they differ between builds."),
	nikki = translate(
		"Drives mihomo behind an nftables table of its own. DNS is exempted too, " ..
		"because UU sends a boosted device's lookups through its tunnel. Give it " ..
		"a <code>redir-host</code> DNS profile: fake-ip breaks the boost."),
	homeproxy = translate(
		"Only its TUN mode with auto-redirect is handled. In its other modes the " ..
		"traffic is hooked inside fw4, out of reach - add the device under " ..
		"HomeProxy's own Access Control instead."),
	ua3f = translate(
		"Rewrites the User-Agent of LAN traffic by diverting TCP to itself. Only " ..
		"TCP is exempted, because that is all UA3F touches."),
	passwall = translate(
		"Game traffic reaches UU's tunnel on its own; only DNS collides. Keeping " ..
		"a boosted device on PassWall's resolver can hand the game addresses UU " ..
		"does not route, so this is off unless PassWall's DNS matters more."),
}

local has_openclash = false
for _, b in ipairs(proxies) do
	if b.id == "openclash" then has_openclash = true end

	o = s:taboption("coexist", ListValue, b.id .. "_mode", b.label)
	if b.id == "passwall" then
		-- Not a split: the only thing it changes is where DNS goes.
		o:value("off", translate("Leave it alone (recommended)"))
		o:value("cooperative", translate("Keep boosted devices on PassWall's DNS"))
		o.default = "off"
	else
		o:value("cooperative", translate("Split the traffic (recommended)"))
		-- UA3F is not a proxy: it rewrites User-Agents and hands the
		-- connection back to the router. "Off the proxy" would be the wrong
		-- words for it, so it gets the two choices that mean something.
		if b.id ~= "ua3f" then
			o:value("bypass", translate("Take whole devices off the proxy"))
		end
		o:value("off", translate("Leave it alone"))
		o.default = "cooperative"
	end
	o.description = NOTE[b.id]
end

-- OpenClash keeps a list of devices that skip the proxy completely. A boosted
-- device on that list skips OpenClash for everything, so splitting it is a
-- no-op until it is taken off.
if has_openclash then
	o = s:taboption("coexist", Flag, "oc_manage_lan_ac",
		translate("OpenClash: move boosted devices off its bypass list"),
		translate("OpenClash keeps a list of devices that skip the proxy " ..
			"completely (lan_ac_black_ips), and a device on it returns before " ..
			"any finer exemption can apply. Turn this on to take such a device " ..
			"off that list while it is boosted and put it back afterwards. Off " ..
			"by default, because it edits and saves OpenClash's config."))
	o.default = 0
	o:depends("openclash_mode", "cooperative")
end

-- Tuning, for all proxies at once: the poll and the prefix limit are properties
-- of the engine, not of any one proxy.
o = s:taboption("coexist", Value, "oc_interval",
	translate("Re-check interval"),
	translate("Seconds between re-reads of UU's route list. UU adds and removes " ..
		"game routes while it runs, and every proxy above follows this interval."))
o.datatype = "range(1,60)"
o.default = "5"

o = s:taboption("coexist", Value, "oc_min_prefix",
	translate("Widest route to divert"),
	translate("A safety limit, as a prefix length: a route broader than this is " ..
		"never sent around the proxy. Stops one stray default route from " ..
		"pulling the whole internet out of it."))
o.datatype = "range(1,32)"
o.default = "8"
end

-- ------------------------------------------------------------ device list

o = s:taboption("devices", ListValue, "device_mode",
	translate("Devices UU is allowed to see"))
o:value("all", translate("Every device on the network"))
o:value("blacklist", translate("Everything except the devices below"))
o:value("whitelist", translate("Only the devices below"))
o.default = "all"
o.description = translate(
	"The UU app lists whatever the plugin finds on your network, which by " ..
	"default is everything. This narrows what it can find at all, so a device " ..
	"left out never appears in the app, is never offered for boosting, and is " ..
	"never reported to NetEase." ..
	"<br />Nothing else on the router is affected: the real DHCP leases and ARP " ..
	"table are untouched, and no traffic is blocked.")

o = s:taboption("devices", DynamicList, "device_ip", translate("By IP address"))
o.datatype = "ipaddr"
o:depends("device_mode", "blacklist")
o:depends("device_mode", "whitelist")

o = s:taboption("devices", DynamicList, "device_mac", translate("By MAC address"),
	translate("Steadier than an IP for anything using DHCP. Resolved to " ..
		"whichever address the device currently holds."))
o.datatype = "macaddr"
o:depends("device_mode", "blacklist")
o:depends("device_mode", "whitelist")

-- ------------------------------------------------------------- how to use

o = s:taboption("howto", DummyValue, "_howto")
o.template = "uuplugin/uuplugin_howto"

mp.apply_on_parse = true
mp.on_after_apply = function(self, map)
	-- reload, not restart: procd then restarts only the parts whose definition
	-- actually changed, so editing a setting does not drop an active boost or
	-- cost a re-registration with NetEase.
	luci.sys.exec("/etc/init.d/uuplugin reload >/dev/null 2>&1 &")
end

return mp
