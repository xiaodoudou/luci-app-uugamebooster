-- Render every LuCI view in this package and fail on the mistakes that are
-- invisible until a browser shows them.
--
-- Run it on a machine with LuCI installed (i.e. the router):
--
--     lua tools/check-views.lua [view-dir]
--
-- luci.template itself cannot load outside uhttpd - it wants the host's "L"
-- global - but the parser is a plain C module, so it compiles and runs a view
-- standalone with write() captured.
--
-- Two bugs have reached a browser this way and both are checked for here:
--
--   * markup inside a translated string, which the escaping colon form turns
--     into visible <strong> text;
--   * a comment block whose own text contains the closing delimiter, which ends
--     the comment early and dumps the rest onto the page.
--
-- Both leave a recognisable trace in the rendered HTML.

local parser = require "luci.template.parser"

local dir = (... or arg and arg[1]) or
	"/usr/lib/lua/luci/view/uuplugin"
dir = dir:gsub("/+$", "")

local BAD = {
	{ pattern = "&#60;",  why = "escaped markup - use the non-escaping translate form" },
	{ pattern = "%-%%>",  why = "template comment ended early and leaked onto the page" },
	{ pattern = "<%%",    why = "unrendered template delimiter in the output" },
}

local function render(path)
	local out = {}
	local env = setmetatable({
		write     = function(s) out[#out + 1] = tostring(s) end,
		translate = function(s) return s end,
		pcdata    = parser.pcdata,
		striptags = parser.striptags,
		include   = function() end,
		-- Helpers the dispatcher normally puts in a view's environment.
		url       = function(...) return "/cgi-bin/luci/" .. table.concat({ ... }, "/") end,
		resource  = "/luci-static/resources",
		media     = "/luci-static/bootstrap",
		theme     = "bootstrap",
		node      = {},
		luci      = { http = { formvalue = function() return nil end } },
	}, { __index = _G })

	local fn, err = parser.parse(path)
	if not fn then return nil, "does not compile: " .. tostring(err) end
	setfenv(fn, env)
	local ok, e = pcall(fn)
	if not ok then return nil, "raises when rendered: " .. tostring(e) end
	return table.concat(out)
end

local p = io.popen("ls " .. dir .. "/*.htm 2>/dev/null")
local files = {}
for line in p:lines() do files[#files + 1] = line end
p:close()

if #files == 0 then
	print("no views found in " .. dir)
	os.exit(1)
end

local failed = 0
for _, path in ipairs(files) do
	local name = path:match("[^/]+$")
	local html, err = render(path)
	if not html then
		print(string.format("FAIL %-24s %s", name, err))
		failed = failed + 1
	else
		local problems = {}
		for _, b in ipairs(BAD) do
			if html:find(b.pattern) then problems[#problems + 1] = b.why end
		end
		if #problems > 0 then
			print(string.format("FAIL %-24s %s", name, table.concat(problems, "; ")))
			failed = failed + 1
		else
			print(string.format("ok   %-24s %d bytes", name, #html))
		end
	end
end

os.exit(failed == 0 and 0 or 1)
