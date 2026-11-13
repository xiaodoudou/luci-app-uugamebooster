module("luci.controller.uuplugin", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/uuplugin") then
		return
	end

	entry({"admin", "services", "uuplugin"}, cbi("uuplugin"),
		_("UU Game Booster"), 99).dependent = true
	entry({"admin", "services", "uuplugin", "status"}, call("act_status")).leaf = true
end

-- The proxies this plugin can share the LAN with, read from the descriptors in
-- uu-sync.d/ rather than kept as a list here. One file per proxy is the whole
-- contract: the engine (uu-sync) runs it, the service starts it, and both this
-- controller and the CBI form ask this function rather than keeping a second
-- copy of the list that could drift from the scripts.
function backends()
	local fs = require "nixio.fs"
	local list = {}
	local d = "/usr/libexec/uuplugin/uu-sync.d"

	local p = io.popen("ls " .. d .. "/*.sh 2>/dev/null")
	if p then
		for path in p:read("*a"):gmatch("%S+") do
			local id = path:match("([^/]+)%.sh$")
			local body = fs.readfile(path) or ""
			if id then
				list[#list + 1] = {
					id = id,
					label = body:match("\nLABEL=\"([^\"]+)\"")
						or body:match("\nLABEL=([^\r\n]+)")
						or id,
					config = body:match("\nCONFIG=([^\r\n]+)") or "",
				}
			end
		end
		p:close()
	end

	-- ls sorts alphabetically, which puts HomeProxy above the two proxies most
	-- people actually run. Order the known ones the way the docs do, and leave
	-- anything new at the end in the order it was found.
	local rank = { openclash = 1, nikki = 2, homeproxy = 3, ua3f = 4 }
	for i, b in ipairs(list) do
		b._rank = rank[b.id] or (100 + i)
	end
	table.sort(list, function(a, b) return a._rank < b._rank end)

	return list
end

function act_status()
	local sys = require "luci.sys"
	local fs  = require "nixio.fs"
	local uci = require "luci.model.uci".cursor()
	local e = {}

	-- uu-detect distinguishes our instance from a competing UU install by
	-- comparing /proc/<pid>/exe. Doing this inline with pgrep does not work:
	-- "pgrep -f <path>" matches the shell running the check, and busybox's
	-- "pgrep -x" misses a process whose comm is an exact match.
	local det = sys.exec("/usr/libexec/uuplugin/uu-detect 2>/dev/null") or ""
	e.running = det:match("ours=(%d+)") ~= nil
	e.foreign = det:match("foreign=([^\r\n]+)")

	-- What is running, in the terms that matter to someone reading this page:
	-- which CPU, and whether the build in use can boost PCs and phones. The
	-- token is passed through untranslated - a controller has no "translate" in
	-- scope (the dispatcher only defines the no-op _() used to extract menu
	-- strings), so the wording lives in the template instead.
	e.arch = sys.exec("uname -m"):gsub("%s+$", "")
	e.build = det:match("build=([%w%-]*)")
	if e.build == "" then e.build = nil end
	-- This firmware's iptables has no DNAT target, so the core's DNS redirect
	-- is being done in nftables instead
	e.dnat_fallback = det:match("dnat=nft") ~= nil

	e.boosted = det:match("boosted=([^\r\n]*)")
	if e.boosted == "" then e.boosted = nil end

	-- Until the control connection is up the phone app cannot find the router,
	-- even though the process is running. Binding itself lives in NetEase's
	-- cloud and nothing on the router records it, so the app is the place to
	-- check that.
	e.cloud = det:match("cloud=([^\r\n]*)")
	if e.cloud == "" then e.cloud = nil end
	e.ready = (e.running and e.cloud ~= nil)
	if not e.running then
		e.phase = "stopped"
	elseif e.cloud == nil then
		e.phase = "starting"
	else
		e.phase = "ready"
	end

	-- Switched on, but without its boot link it would not come back after a
	-- reboot. The next start or reload repairs it; until then, say so.
	e.no_bootstart = uci:get_first("uuplugin", "uuplugin", "enabled") == "1"
		and not fs.access("/etc/rc.d/S99uuplugin")

	local function lines(path)
		local n, st = 0, fs.readfile(path)
		if st then
			for _ in st:gmatch("[^\r\n]+") do n = n + 1 end
		end
		return n
	end

	-- One entry per installed proxy. "running" here means intercepting, as
	-- reported from the live system: a proxy can be installed and stopped, and
	-- then there is nothing to exempt.
	e.sync = {}
	for _, b in ipairs(backends()) do
		if b.config ~= "" and fs.access(b.config) then
			local state = det:match("\n" .. b.id .. "=(%S*)") or ""
			local entry = {
				id = b.id,
				label = b.label,
				running = (state ~= "" and state ~= "0"),
				mode = uci:get_first("uuplugin", "uuplugin", b.id .. "_mode")
					or "cooperative",
				exempted = lines("/var/run/uu-" .. b.id .. ".state"),
			}
			-- HomeProxy's only handled mode is sing-box's TUN inbound; its
			-- other modes hook fw4 and this exemption cannot reach them.
			if b.id == "homeproxy" and entry.running and state ~= "tun" then
				entry.note = "tun-only"
			end
			e.sync[#e.sync + 1] = entry
		end
	end

	-- PassWall is not an engine backend (it works in iptables), but the panel
	-- shows it alongside them. Its count is boosted devices, not prefixes.
	if fs.access("/etc/config/passwall") then
		e.sync[#e.sync + 1] = {
			id = "passwall",
			label = "PassWall",
			running = true,
			mode = uci:get_first("uuplugin", "uuplugin", "passwall_mode") or "off",
			exempted = lines("/var/run/uu-passwall.state"),
		}
	end

	-- UU creates one TUN per boosted device (tun163, tun164, ...), so list them all
	local tun = sys.exec("ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^tun' | grep -v '^utun' | tr '\\n' ' '")
	e.tun = tun and tun:gsub("%s+$", "") or ""

	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end
