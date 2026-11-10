--!strict

local KIND = "allure.report"

local RESULT_DIRS = { "allure-results", "build/allure-results", "target/allure-results" }
local MAX_UP = 6

local function dirname(path: string): string
	local d = string.match(path, "^(.*)/[^/]*$")
	if d == nil or d == "" then
		return "/"
	end
	return d
end

local function norm(path: string): string
	local p = string.gsub(path, "/+$", "")
	if p == "" then
		return "/"
	end
	if string.sub(p, 1, 13) == "/private/tmp/" or string.sub(p, 1, 13) == "/private/var/" then
		return string.sub(p, 9)
	end
	return p
end

local function under(path: string, root: string): boolean
	return path == root or string.sub(path, 1, #root + 1) == root .. "/"
end

local function root_of(dir: string): string
	local home = tern.getenv("HOME")
	local d = dir
	for _ = 1, 12 do
		if d == "/" or d == "" or d == home then
			break
		end
		if tern.fs.exists(d .. "/.git") then
			return d
		end
		d = dirname(d)
	end
	return dir
end

local function report_for(cx: WindowCx, raw: string): PaneInfo?
	local path = norm(raw)
	local root = root_of(path)
	for _, p in cx.session:panes() do
		if p.block == KIND then
			local shown = tern.kv.get("report:" .. tostring(p.pane))
			if type(shown) == "string" and (shown == path or under(path, shown) or under(shown, root)) then
				return p
			end
		end
	end
	return nil
end

local function show(cx: WindowCx, path: string?)
	if path then
		local existing = report_for(cx, path :: string)
		if existing then
			if existing.parked then
				cx.layout:unpark(existing.pane)
			else
				cx.layout:focus(existing.pane)
			end
			cx.session:event(existing.pane, { ev = "action", id = "main", act = "reveal", value = path })
			return
		end
	end
	if cx:new_block(KIND, if path then { path :: string } else nil, "beside", { ratio = 0.6 }) == nil then
		cx:toast("error", "Allure Report is not loaded on this host", "Install the plugin where your panes run.")
	end
end

local function focused_dir(cx: WindowCx): string?
	local id = cx.session:focused()
	local p = if id then cx.session:pane(id) else nil
	if p == nil or p.block == KIND or p.cwd == nil or p.cwd == "" then
		return nil
	end
	return p.cwd
end

tern.command({
	id = "open",
	title = "Open Allure report",
	icon = "chart",
	keys = { "cmd+shift+j" },
	run = function(cx: WindowCx)
		show(cx, focused_dir(cx))
	end,
})

tern.files.button({
	id = "report",
	title = "Allure report for this folder",
	icon = "chart",
	run = function(files: FilesInfo, cx: WindowCx)
		show(cx, files.selection[1] or files.root)
	end,
})

local function has_results(cwd: string): boolean
	local d = cwd
	for _ = 1, MAX_UP do
		for _, sub in RESULT_DIRS do
			if tern.fs.exists(d .. "/" .. sub) then
				return true
			end
		end
		if d == "/" or tern.fs.exists(d .. "/.git") then
			return false
		end
		d = dirname(d)
	end
	return false
end

tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	if pane.block == KIND then
		return nil
	end
	local found = pane.cwd ~= nil and pane.cwd ~= "" and has_results(pane.cwd :: string)
	return { { text = "Allure", icon = "chart", tone = if found then nil else "muted", command = "plugin.allure.open" } }
end)
