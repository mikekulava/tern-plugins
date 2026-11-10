--!strict
-- The window half: double-tapping Shift (or the palette command, or the Files pane's
-- button) opens the search overlay over the tab for the focused pane's folder. Doing it
-- again while the overlay shows closes it.
--
-- On this machine the overlay hands its pick back through `tern.kv` (`open:<pane>`) as it
-- closes and this half opens it, so the opened file takes focus. Overlays on a remote host
-- open their pick themselves (their kv is on the other machine).

local KIND = "searcheverywhere.search"

local function dirname(path: string): string
	local dir = string.match(path, "^(.*)/[^/]*$")
	if dir == nil then
		return "."
	end
	return if dir == "" then "/" else dir
end

-- The folder of the focused pane: its working directory, else the folder of the file it shows.
local function folder_of(cx: WindowCx): string?
	local focused = cx.session:focused()
	local info = if focused then cx.session:pane(focused) else nil
	if info == nil then
		return nil
	end
	if info.cwd and info.cwd ~= "" then
		return info.cwd
	end
	if info.path and info.path ~= "" then
		return dirname(info.path)
	end
	return nil
end

local function is_local(cx: WindowCx): boolean
	local ok, host = pcall(function(): ManagedHost
		return cx.hosts:current()
	end)
	return ok and host ~= nil and host.kind == "local"
end

-- ---------------------------------------------------------------- overlay size

-- The overlay is a glimpse, which Tern draws over the whole tab. While ours shows, a sheet
-- shrinks the glimpse to a bar under the top of the tab, without its header and footer,
-- and grows it to fit the results once there are some. The block says how many list lines
-- it shows through its title (host.luau): "Search Everywhere" with none,
-- "Search Everywhere · results 8" with eight. Glimpses have no per-block selector, so the
-- sheet is only installed while ours shows.

local SHEET = "size"
-- Heights in CSS px of the sans block surface: the bar (tabs row and query), the list's
-- top within the panel, one list line, and what goes under the list (legend, padding).
local BAR_PX = 104
local LIST_TOP_PX = 112
local LINE_PX = 31.4
local BELOW_PX = 42
local MAX_LINES = 12

local function sheet(height: number): string
	return [[
.tn-stage .tn-pane.glimpse {
	top: 56px !important;
	left: 20% !important;
	width: 60% !important;
	height: ]] .. math.ceil(height) .. [[px !important;
	max-height: 75% !important;
}
.tn-stage .tn-pane.glimpse > .tn-head,
.tn-stage .tn-pane.glimpse > .tn-gl-foot {
	display: none !important;
}
.tn-gl-scrim.on {
	background: transparent !important;
	backdrop-filter: none !important;
}
]]
end

-- The overlay pane showing in this window, and the list lines it is sized for.
local shown: number? = nil
local sized_for = -1

local function size(lines: number)
	if lines == sized_for then
		return
	end
	sized_for = lines
	local height = if lines == 0
		then BAR_PX
		else LIST_TOP_PX + math.min(lines, MAX_LINES) * LINE_PX + BELOW_PX
	tern.css(SHEET, sheet(height))
end

local function unsize()
	shown = nil
	sized_for = -1
	tern.css(SHEET, "")
end

local function open(cx: WindowCx, folder: string?)
	for _, pane in cx.session:panes() do
		if pane.block == KIND and not pane.parked then
			cx.layout:close(pane.pane)
			return
		end
	end
	size(0)
	local args = { folder or "", if is_local(cx) then "handoff" else "" }
	local pane = cx:new_block(KIND, args, "glimpse", { focus = true })
	if pane == nil then
		unsize()
		cx:toast("error", "Search Everywhere is not loaded on this host", "Install the plugin where your panes run.")
		return
	end
	shown = pane
	cx.layout:focus(pane)
end

tern.on("title", function(ev: TitleEvent, _cx: WindowCx)
	if ev.pane == shown then
		size(tonumber(string.match(ev.title, "· results (%d+)$")) or 0)
	end
end)

-- The file block showing `path`, if there is one.
local function file_pane(cx: WindowCx, path: string): number?
	for _, pane in cx.session:panes() do
		if pane.kind == "file" and pane.path == path and not pane.parked then
			return pane.pane
		end
	end
	return nil
end

-- Focuses the file block showing `path` once it shows, checking every 50 ms for a second:
-- a new block takes a moment to appear, and the overlay's close hands focus back to the
-- pane under it.
local function focus_file(path: string, tries: number)
	tern.timer(50, function(cx: WindowCx?)
		if cx == nil then
			return
		end
		local pane = file_pane(cx, path)
		if pane and cx.session:focused() == pane then
			return
		end
		if pane then
			cx.layout:focus(pane)
		end
		if tries > 1 then
			focus_file(path, tries - 1)
		end
	end)
end

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	if ev.pane == shown then
		unsize()
	end
	local key = "open:" .. tostring(ev.pane)
	local pick = tern.kv.get(key)
	if type(pick) ~= "table" or type(pick.target) ~= "string" then
		return
	end
	tern.kv.set(key, nil)
	local target: string = pick.target
	cx:open(target, "default", { focus = true })
	focus_file(string.match(target, "^(.-)#L%d+$") or target, 20)
end)

tern.command({
	id = "open",
	title = "Search everywhere",
	icon = "search",
	keys = { "shift>shift" },
	run = function(cx: WindowCx)
		open(cx, folder_of(cx))
	end,
})

tern.files.button({
	id = "search",
	title = "Search everywhere in this folder",
	icon = "search",
	run = function(files: FilesInfo, cx: WindowCx)
		open(cx, files.root)
	end,
})

-- A clickable launcher in the status line.
tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	return { { text = "Search", icon = "search", command = "plugin.searcheverywhere.open" } }
end)
