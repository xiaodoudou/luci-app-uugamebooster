local mp, s, o
require("luci.util")
require("luci.sys")

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
s:tab("clash",   translate("OpenClash"))
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

-- --------------------------------------------------------------- OpenClash

o = s:taboption("clash", ListValue, "openclash_mode", translate("Coexistence"))
o:value("cooperative", translate("Split the traffic (recommended)"))
o:value("bypass", translate("Take whole devices off OpenClash"))
o:value("off", translate("Leave OpenClash alone"))
o.default = "cooperative"
o.description = translate(
	"UU and OpenClash both intercept LAN traffic, so left alone one of them " ..
	"silently wins." ..
	"<br /><br /><strong>Split the traffic</strong> lets each handle what it is " ..
	"for. Only what UU actually accelerates leaves OpenClash: the game servers " ..
	"UU routes into its tunnel, plus the UDP ports it marks - both read back " ..
	"from UU's own live rules, for boosted devices only. Everything else from " ..
	"that same device keeps going through OpenClash." ..
	"<br /><em>So most of a boosted PC's traffic still going through OpenClash " ..
	"is the intended result, not a fault.</em>" ..
	"<br /><br /><strong>Take whole devices off OpenClash</strong> is the blunt " ..
	"fallback: the devices you list stop using the proxy entirely while UU runs." ..
	"<br /><strong>Leave OpenClash alone</strong> changes nothing - useful if " ..
	"you would rather tune OpenClash by hand.")

o = s:taboption("clash", Flag, "oc_manage_lan_ac",
	translate("Move devices off OpenClash's own bypass list"),
	translate("OpenClash keeps a list of devices that skip the proxy completely " ..
		"(lan_ac_black_ips). A boosted device on that list skips OpenClash for " ..
		"everything, so the split above can do nothing for it. Turn this on to " ..
		"let the plugin take such a device off OpenClash's list while it is " ..
		"boosted and put it back afterwards. Off by default, because it edits " ..
		"and saves OpenClash's configuration."))
o.default = 0
o:depends("openclash_mode", "cooperative")

o = s:taboption("clash", DynamicList, "oc_bypass_mac",
	translate("Devices to bypass - by MAC"),
	translate("These stop using OpenClash while UU is running."))
o.datatype = "macaddr"
o:depends("openclash_mode", "bypass")

o = s:taboption("clash", DynamicList, "oc_bypass_ip",
	translate("Devices to bypass - by IP"),
	translate("Addresses or CIDR ranges that stop using OpenClash while UU runs."))
o.datatype = "ipaddr"
o:depends("openclash_mode", "bypass")

o = s:taboption("clash", Value, "oc_interval",
	translate("How often to re-check UU's routes"),
	translate("In seconds. UU adds and removes game routes as it goes."))
o.datatype = "range(1,60)"
o.default = "5"
o:depends("openclash_mode", "cooperative")

o = s:taboption("clash", Value, "oc_min_prefix",
	translate("Widest route to divert"),
	translate("A safety limit, as a prefix length: never send a route broader " ..
		"than this around OpenClash. Stops one stray default route from pulling " ..
		"the whole internet out of the proxy."))
o.datatype = "range(1,32)"
o.default = "8"
o:depends("openclash_mode", "cooperative")

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
