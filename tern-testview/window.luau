--!strict
-- The window half: a palette command and key bind that open the Test Explorer for the
-- focused pane's directory, beside it (or focus the explorer already showing tests).
--
-- It also follows test runs started in panes, by you or by an agent: panes opened while
-- the plugin is loaded report their pytest and unittest runs to a spool directory
-- (host.luau's spawn hook, helpers/python/). When a run starts in a pane this window
-- shows, the explorer of that workspace takes it, or one opens beside the pane, and the
-- tests fill in as they run.

local KIND = "testview.explorer"
local WATCH = tern.plugin.data .. "/watch"
local POLL_MS = 500
-- Spool files nobody took (no window showed the pane) are dropped after an hour.
local STALE_MS = 60 * 60 * 1000
-- A run found when the window (or a plugin reload) starts is taken if it began this recently.
local FRESH_MS = 15 * 1000

local function open_explorer(cx: WindowCx)
	local focused = cx.session:focused()
	local info = if focused then cx.session:pane(focused) else nil
	for _, pane in cx.session:panes() do
		if pane.block == KIND and not pane.parked then
			cx.layout:focus(pane.pane)
			return
		end
	end
	local cwd = if info and info.cwd ~= "" then info.cwd else nil
	local args = if cwd then { cwd :: string } else nil
	if cx:new_block(KIND, args, "beside", { ratio = 0.5 }) == nil then
		cx:toast("error", "Test Explorer is not loaded on this host", "Install the plugin where your panes run.")
	end
end

tern.command({
	id = "open",
	title = "Open test explorer",
	icon = "list-checks",
	run = open_explorer,
})

tern.bind("cmd+shift+u", "plugin.testview.open")

-- A clickable launcher in the status line.
tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	return { { text = "Tests", icon = "list-checks", command = "plugin.testview.open" } }
end)

-- ---------------------------------------------------------------- following runs in panes

local function following(): boolean
	return tern.kv.get("follow") ~= false
end

tern.command({
	id = "follow",
	title = "Follow test runs in panes (on/off)",
	icon = "list-checks",
	run = function(cx: WindowCx)
		local on = not following()
		tern.kv.set("follow", on)
		if on then
			cx:toast("success", "Test Explorer follows test runs", "In panes opened from now on.")
		else
			cx:toast("info", "Test Explorer no longer follows test runs")
		end
	end,
})

-- macOS reports /tmp as /private/tmp; the explorer keeps the short form.
local function norm(p: string): string
	if string.sub(p, 1, 13) == "/private/tmp/" or string.sub(p, 1, 13) == "/private/var/" then
		return string.sub(p, 9)
	end
	return p
end

local function under(path: string, root: string): boolean
	return path == root or string.sub(path, 1, #root + 1) == root .. "/"
end

-- The first event of a run's spool file, once it is written whole.
local function header(path: string): { [string]: any }?
	local ok, text = pcall(tern.fs.read, path, 256 * 1024)
	if not ok then
		return nil
	end
	local line = string.match(text, "^([^\n]*)\n")
	if line == nil then
		return nil
	end
	local decoded, ev = pcall(tern.json.decode, line)
	if decoded and type(ev) == "table" and ev.ev == "watch" then
		return ev
	end
	return nil
end

-- The explorer already showing the workspace `cwd` is in.
local function explorer_for(cx: WindowCx, cwd: string): number?
	for _, p in cx.session:panes() do
		if p.block == KIND and not p.parked then
			local root = tern.kv.get("explorer:" .. tostring(p.pane))
			if type(root) == "string" and under(cwd, root) then
				return p.pane
			end
		end
	end
	return nil
end

local function take(cx: WindowCx, path: string, run: { [string]: any })
	local pane = tonumber(run.pane)
	if pane == nil or cx.session:pane(pane :: number) == nil then
		return
	end
	local cwd = norm(if type(run.cwd) == "string" then run.cwd else "/")
	local explorer = explorer_for(cx, cwd)
	if explorer then
		cx.session:event(explorer, { ev = "action", id = "main.watch", act = "watch=" .. path })
		return
	end
	cx:new_block(KIND, { cwd, "watch=" .. path }, "beside", { target = pane, focus = false, ratio = 0.45 })
end

local seen: { [string]: boolean } = {}
local primed = false

local function poll(cx: WindowCx)
	local ok, names = pcall(tern.fs.list, WATCH)
	if ok then
		local now = os.time() * 1000
		for _, name in names do
			local path = WATCH .. "/" .. name
			if not seen[path] then
				local born = tonumber(string.match(name, "^(%d+)%-"))
				if born and now - born > STALE_MS then
					seen[path] = true
					pcall(tern.fs.remove, path)
				elseif not primed and (born == nil or now - born > FRESH_MS) then
					-- Runs from well before this window (or this plugin load) are not news.
					seen[path] = true
				else
					local run = header(path)
					if run then
						seen[path] = true
						if following() then
							take(cx, path, run)
						end
					end
				end
			end
		end
	end
	primed = true
end

local function loop()
	tern.timer(POLL_MS, function(cx: WindowCx?)
		if cx then
			local ok, err = pcall(poll, cx)
			if not ok then
				tern.log.warn("testview: following runs failed", err)
			end
		end
		loop()
	end)
end

-- Each load of this half (a new window, or a plugin reload) starts one loop.
loop()
