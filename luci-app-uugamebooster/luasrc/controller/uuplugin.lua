module("luci.controller.uuplugin", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/uuplugin") then
		return
	end

	entry({"admin", "services", "uuplugin"}, cbi("uuplugin"),
		_("UU Game Booster"), 99).dependent = true
	entry({"admin", "services", "uuplugin", "status"}, call("act_status")).leaf = true
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

	-- OpenClash integration state
	e.openclash_installed = fs.access("/etc/config/openclash")
	e.openclash_running = det:match("openclash=(%d+)") ~= nil
	e.boosted = det:match("boosted=([^\r\n]*)")
	if e.boosted == "" then e.boosted = nil end

	-- Registered with NetEase, and talking to their control servers. Until both
	-- are true the phone app cannot find the router, even though the process is
	-- up - so the UI distinguishes "running" from "ready".
	e.cloud = det:match("cloud=([^\r\n]*)")
	if e.cloud == "" then e.cloud = nil end
	e.activated = det:match("activated=([^\r\n]*)")
	if e.activated == "" then e.activated = nil end
	-- Three distinct phases after a start, which look identical from the
	-- outside but mean different things to someone waiting to bind:
	--   starting     process up, no control connection yet
	--   registering  talking to NetEase, no registration record yet
	--   ready        bindable in the app
	e.ready = (e.running and e.cloud ~= nil and e.activated ~= nil)
	if not e.running then
		e.phase = "stopped"
	elseif e.cloud == nil then
		e.phase = "starting"
	elseif e.activated == nil then
		e.phase = "registering"
	else
		e.phase = "ready"
	end
	e.mode = uci:get_first("uuplugin", "uuplugin", "openclash_mode") or "cooperative"

	-- Number of destination prefixes currently diverted away from OpenClash
	e.bypassed = 0
	local st = fs.readfile("/var/run/uu-openclash.state")
	if st then
		for _ in st:gmatch("[^\r\n]+") do
			e.bypassed = e.bypassed + 1
		end
	end

	-- UU creates one TUN per boosted device (tun163, tun164, ...), so list them all
	local tun = sys.exec("ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^tun' | grep -v '^utun' | tr '\\n' ' '")
	e.tun = tun and tun:gsub("%s+$", "") or ""

	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end
