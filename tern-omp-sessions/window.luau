--!strict
local KIND = "omp-sessions.browser"

local function decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h: string): string
		return string.char(tonumber(h, 16) :: number)
	end))
end

local function params(query: string): { [string]: string }
	local out: { [string]: string } = {}
	for k, v in string.gmatch(query, "([^&=]+)=([^&]*)") do
		out[k] = decode(v)
	end
	return out
end

local function quote(s: string): string
	return "'" .. (string.gsub(s, "'", "'\\''")) .. "'"
end

local function browser_pane(cx: WindowCx): PaneInfo?
	for _, p in cx.session:panes() do
		if p.block == KIND then
			return p
		end
	end
	return nil
end

local function show(cx: WindowCx, folder: string?)
	local p = browser_pane(cx)
	if p == nil then
		cx:new_block(KIND, if folder then { folder } else {}, "tab")
		return
	end
	if p.parked then
		cx.layout:unpark(p.pane)
	else
		cx.layout:focus(p.pane)
	end
	if folder then
		cx.session:event(p.pane, { ev = "action", id = "main", act = "reveal", value = folder })
	end
end

local function focused_folder(cx: WindowCx): string?
	local id = cx.session:focused()
	local p = if id then cx.session:pane(id) else nil
	if p == nil or p.block == KIND or p.cwd == nil or p.cwd == "" then
		return nil
	end
	return p.cwd
end

tern.command({
	id = "browse",
	title = "Browse omp sessions",
	icon = "history",
	keys = { "cmd+shift+h" },
	run = function(cx: WindowCx)
		show(cx, focused_folder(cx))
	end,
})

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	return { { text = "sessions", icon = "history", command = "plugin.omp-sessions.browse" } }
end)

tern.files.button({
	id = "sessions",
	title = "omp sessions for this folder",
	icon = "history",
	run = function(files: FilesInfo, cx: WindowCx)
		show(cx, files.selection[1] or files.root)
	end,
})

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	local verb, query = string.match(link.url, "^omp%-sessions://(%a+)%?(.*)$")
	if verb == nil or query == nil then
		return nil
	end
	local from = if link.pane then cx.session:pane(link.pane) else nil
	if from == nil or from.block ~= KIND then
		cx:toast("error", "Ignored an omp-sessions link", "Only the omp sessions browser can start sessions")
		return { handled = true }
	end
	local q = params(query)
	local command: string
	if verb == "resume" and q.path then
		command = "omp --resume " .. quote(q.path)
	elseif verb == "new" then
		command = "omp"
	else
		return { handled = true }
	end
	local cwd = q.cwd
	if cwd == nil or not tern.fs.exists(cwd) then
		cwd = tern.getenv("HOME")
		cx:toast("info", "The session's folder no longer exists", "Starting in your home folder instead")
	end
	local launch: Launch = { cwd = cwd }
	local pane = if q.how == "split" then cx.layout:split(from.pane, "right", launch) else cx.layout:new_tab(launch)
	if pane then
		cx:run(pane, command .. "\r")
	end
	return { handled = true }
end)
