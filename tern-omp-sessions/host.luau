--!strict
local ui = tern.ui

local SCHEME = "omp-sessions://"
local LIST_ID = "main.tree."
local FILTER_ID = "main.filter"
local REFRESH_MS = 30000
local SCAN_TIMEOUT_MS = 20000
local DOUBLE_CLICK_MS = 400

local SCAN = [[
root=$1
if [ ! -d "$root" ]; then
	echo "E No omp session folder at $root"
	exit 0
fi
if stat -c %Y / >/dev/null 2>&1; then
	find "$root" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -exec stat -c 'M %Y %s %n' {} +
else
	find "$root" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -exec stat -f 'M %m %z %N' {} +
fi
find "$root" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -exec awk '
FNR == 1 { print "F " FILENAME }
/^[{]"type":"(title|session)"/ { print "L " $0 }
/^[{]"type":"session"/ || FNR >= 4 { nextfile }
' {} +
]]

type Session = {
	path: string,
	id: string,
	cwd: string,
	shown_cwd: string,
	title: string,
	started: number?,
	mtime: number,
	size: number,
	hay: string,
}

type Folder = {
	path: string,
	name: string,
	folders: { Folder },
	sessions: { Session },
	children: { [string]: Folder },
	total: number,
	latest: number,
}

type Row = {
	key: string,
	depth: number,
	parent: string?,
	folder: Folder?,
	session: Session?,
	hits: number?,
}

type State = {
	cx: BlockCx,
	home: string?,
	root: string?,
	roots: { Folder },
	sessions: number,
	folders: number,
	open: { [string]: boolean },
	query: string,
	rows: { Row },
	index: { [string]: number },
	cursor: string?,
	loading: boolean,
	loaded: boolean,
	error: string?,
	gen: number,
	focused: boolean,
	toggled: { key: string, at: number }?,
	reveal: string?,
}

local function alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or s
end

local function split(path: string): { string }
	local parts: { string } = {}
	for seg in string.gmatch(path, "[^/]+") do
		table.insert(parts, seg)
	end
	return parts
end

local function under(path: string, base: string): boolean
	return path == base or string.sub(path, 1, #base + 1) == base .. "/"
end

local function shorten(path: string, home: string?): string
	if home and under(path, home) then
		return "~" .. string.sub(path, #home + 1)
	end
	return path
end

local function utc_epoch(iso: any): number?
	if type(iso) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, s = string.match(iso, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if y == nil then
		return nil
	end
	local year, month, day = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	if month <= 2 then
		year -= 1
	end
	local era = year // 400
	local yoe = year - era * 400
	local mp = (month + 9) % 12
	local doy = (153 * mp + 2) // 5 + day - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	local days = era * 146097 + doe - 719468
	return days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(s) :: number)
end

local function ago(t: number): string
	local d = math.max(0, os.time() - t)
	if d < 60 then
		return "just now"
	elseif d < 3600 then
		return d // 60 .. "m ago"
	elseif d < 86400 then
		return d // 3600 .. "h ago"
	elseif d < 86400 * 30 then
		return d // 86400 .. "d ago"
	end
	if os.date("%Y", t) == os.date("%Y") then
		return os.date("%b %d", t) :: string
	end
	return os.date("%b %Y", t) :: string
end

local function stamp(t: number): string
	return os.date("%Y-%m-%d %H:%M", t) :: string
end

local function bytes(n: number): string
	if n < 1024 then
		return n .. " B"
	elseif n < 1024 * 1024 then
		return string.format("%.0f KB", n / 1024)
	end
	return string.format("%.1f MB", n / (1024 * 1024))
end

local function plural(n: number, word: string): string
	return n .. " " .. word .. (if n == 1 then "" else "s")
end

local function parse_scan(out: string, home: string?): ({ Session }, string?)
	local meta: { [string]: { mtime: number, size: number } } = {}
	local titles: { [string]: string } = {}
	local headers: { [string]: any } = {}
	local order: { string } = {}
	local current: string? = nil
	for line in string.gmatch(out, "[^\n]+") do
		local tag = string.sub(line, 1, 2)
		if tag == "L " then
			if current then
				local ok, obj = pcall(tern.json.decode, string.sub(line, 3))
				if ok and type(obj) == "table" then
					if obj.type == "title" and type(obj.title) == "string" then
						titles[current] = obj.title
					elseif obj.type == "session" then
						headers[current] = obj
					end
				end
			end
		elseif tag == "F " then
			local path = string.sub(line, 3)
			current = path
			table.insert(order, path)
		elseif tag == "M " then
			local mtime, size, path = string.match(line, "^M (%d+) (%d+) (.+)$")
			if path then
				meta[path] = { mtime = tonumber(mtime) :: number, size = tonumber(size) :: number }
			end
		elseif tag == "E " then
			return {}, string.sub(line, 3)
		end
	end

	local sessions: { Session } = {}
	for _, path in order do
		local header = headers[path]
		if header and type(header.cwd) == "string" and type(header.id) == "string" then
			local title = trim(titles[path] or (if type(header.title) == "string" then header.title else ""))
			if title == "" then
				title = "Untitled session"
			end
			local started = utc_epoch(header.timestamp)
			local m = meta[path]
			local shown = shorten(header.cwd, home)
			table.insert(sessions, {
				path = path,
				id = header.id,
				cwd = header.cwd,
				shown_cwd = shown,
				title = title,
				started = started,
				mtime = if m then m.mtime else (started or 0),
				size = if m then m.size else 0,
				hay = string.lower(title .. " " .. shown .. " " .. header.id),
			})
		end
	end
	return sessions, nil
end

local function new_folder(path: string, name: string): Folder
	return { path = path, name = name, folders = {}, sessions = {}, children = {}, total = 0, latest = 0 }
end

local function finish(f: Folder): number
	while #f.sessions == 0 and #f.folders == 1 do
		local c = f.folders[1]
		f.name = if f.name == "/" then "/" .. c.name else f.name .. "/" .. c.name
		f.path = c.path
		f.folders = c.folders
		f.sessions = c.sessions
	end
	local count = 1
	local total = #f.sessions
	local latest = 0
	for _, s in f.sessions do
		latest = math.max(latest, s.mtime)
	end
	for _, c in f.folders do
		count += finish(c)
		total += c.total
		latest = math.max(latest, c.latest)
	end
	table.sort(f.folders, function(a: Folder, b: Folder): boolean
		return string.lower(a.name) < string.lower(b.name)
	end)
	table.sort(f.sessions, function(a: Session, b: Session): boolean
		return a.mtime > b.mtime
	end)
	f.total = total
	f.latest = latest
	return count
end

local function build(state: State, sessions: { Session })
	local home = state.home
	local by_base: { [string]: Folder } = {}
	local roots: { Folder } = {}
	for _, s in sessions do
		local base, label, rest
		if home and under(s.cwd, home) then
			base, label, rest = home, "~", split(string.sub(s.cwd, #home + 2))
		else
			base, label, rest = "/", "/", split(s.cwd)
		end
		local node = by_base[base]
		if node == nil then
			node = new_folder(base, label)
			by_base[base] = node
			table.insert(roots, node)
		end
		for _, seg in rest do
			local nxt = node.children[seg]
			if nxt == nil then
				nxt = new_folder(if node.path == "/" then "/" .. seg else node.path .. "/" .. seg, seg)
				node.children[seg] = nxt
				table.insert(node.folders, nxt)
			end
			node = nxt
		end
		table.insert(node.sessions, s)
	end
	local folders = 0
	for _, r in roots do
		folders += finish(r)
	end
	table.sort(roots, function(a: Folder, b: Folder): boolean
		local ah, bh = string.sub(a.name, 1, 1) == "~", string.sub(b.name, 1, 1) == "~"
		if ah ~= bh then
			return ah
		end
		return string.lower(a.name) < string.lower(b.name)
	end)
	state.roots = roots
	state.sessions = #sessions
	state.folders = folders
end

local function is_open(state: State, path: string, depth: number): boolean
	local v = state.open[path]
	if v == nil then
		return depth == 0
	end
	return v
end

local function words(query: string): { string }
	local out: { string } = {}
	for w in string.gmatch(string.lower(query), "%S+") do
		table.insert(out, w)
	end
	return out
end

local function matches(s: Session, ws: { string }): boolean
	for _, w in ws do
		if string.find(s.hay, w, 1, true) == nil then
			return false
		end
	end
	return true
end

local function relayout(state: State)
	local rows: { Row } = {}
	local index: { [string]: number } = {}
	local ws = words(state.query)
	local filtering = #ws > 0
	local hits: { [Folder]: number } = {}

	local function count(f: Folder): number
		local n = 0
		for _, s in f.sessions do
			if matches(s, ws) then
				n += 1
			end
		end
		for _, c in f.folders do
			n += count(c)
		end
		hits[f] = n
		return n
	end

	local function add(row: Row)
		table.insert(rows, row)
		index[row.key] = #rows
	end

	local function walk(f: Folder, depth: number, parent: string?)
		if filtering and hits[f] == 0 then
			return
		end
		local key = "d:" .. f.path
		add({ key = key, depth = depth, parent = parent, folder = f, hits = if filtering then hits[f] else nil })
		if not (filtering or is_open(state, f.path, depth)) then
			return
		end
		for _, c in f.folders do
			walk(c, depth + 1, key)
		end
		for _, s in f.sessions do
			if not filtering or matches(s, ws) then
				add({ key = "s:" .. s.path, depth = depth + 1, parent = key, session = s })
			end
		end
	end

	if filtering then
		for _, r in state.roots do
			count(r)
		end
	end
	for _, r in state.roots do
		walk(r, 0, nil)
	end
	state.rows = rows
	state.index = index
	if state.cursor == nil or index[state.cursor] == nil then
		state.cursor = nil
		for _, row in rows do
			if row.session or not filtering then
				state.cursor = row.key
				break
			end
		end
	end
end

local function first_session(state: State)
	for _, row in state.rows do
		if row.session then
			state.cursor = row.key
			return
		end
	end
end

local function folder_chain(roots: { Folder }, target: string): { Folder }?
	local best: { Folder }? = nil
	local function walk(f: Folder, chain: { Folder })
		if not under(target, f.path) then
			return
		end
		local here = table.clone(chain)
		table.insert(here, f)
		if best == nil or #f.path > #best[#best].path then
			best = here
		end
		for _, c in f.folders do
			walk(c, here)
		end
	end
	for _, r in roots do
		walk(r, {})
	end
	if best == nil then
		for _, r in roots do
			if under(r.path, target) then
				return { r }
			end
		end
	end
	return best
end

local function apply_reveal(state: State)
	local target = state.reveal
	if target == nil or not state.loaded then
		return
	end
	state.reveal = nil
	local trimmed = string.gsub(target, "(.)/+$", "%1")
	local chain = folder_chain(state.roots, trimmed)
	if chain == nil then
		return
	end
	state.query = ""
	for _, f in chain do
		state.open[f.path] = true
	end
	state.cursor = "d:" .. chain[#chain].path
	relayout(state)
end

local function scan(state: State)
	local root = state.root
	if root == nil then
		state.error = "HOME is not set, so the omp session folder is unknown"
		return
	end
	state.gen += 1
	local gen = state.gen
	state.loading = true
	local cx = state.cx
	local started, err = pcall(function()
		tern.process.run({ "/bin/sh", "-c", SCAN, "sh", root }, { timeout_ms = SCAN_TIMEOUT_MS }, function(r: ProcessResult, _)
			if gen ~= state.gen or not alive(cx.pane) then
				return
			end
			state.loading = false
			if r.timed_out then
				state.error = "Scanning sessions timed out"
			elseif r.stdout == "" and r.status ~= 0 then
				state.error = trim(r.stderr) ~= "" and trim(r.stderr) or ("The scan exited with status " .. r.status)
			else
				local sessions, problem = parse_scan(r.stdout, state.home)
				state.error = problem
				build(state, sessions)
				state.loaded = true
				relayout(state)
				apply_reveal(state)
			end
			cx:render()
			if not state.focused then
				state.focused = true
				cx:frame({ { "focus", FILTER_ID } })
			end
			tern.timer(REFRESH_MS, function()
				if gen == state.gen and alive(cx.pane) then
					scan(state)
				end
			end)
		end)
	end)
	if not started then
		state.loading = false
		state.error = tostring(err)
	end
end

local function encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~/]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end))
end

local function launch(cx: BlockCx, verb: string, how: string, cwd: string, path: string?)
	local url = SCHEME .. verb .. "?how=" .. how .. "&cwd=" .. encode(cwd)
	if path then
		url ..= "&path=" .. encode(path)
	end
	cx:open(url)
end

local function current(state: State): Row?
	local at = state.cursor and state.index[state.cursor]
	return if at then state.rows[at] else nil
end

local function toggle(state: State, row: Row)
	local f = row.folder
	if f and #words(state.query) == 0 then
		state.open[f.path] = not is_open(state, f.path, row.depth)
		relayout(state)
	end
end

local function activate(state: State, cx: BlockCx, row: Row?, how: string)
	if row == nil then
		return
	end
	local s = row.session
	if s then
		launch(cx, "resume", how, s.cwd, s.path)
	else
		toggle(state, row)
	end
end

local function move(state: State, to: number)
	local row = state.rows[math.clamp(to, 1, math.max(1, #state.rows))]
	if row then
		state.cursor = row.key
	end
end

local function set_query(state: State, query: string)
	state.query = query
	relayout(state)
	if #words(query) > 0 then
		first_session(state)
	end
end

local function list_lines(cx: BlockCx): number
	return math.max(4, math.floor((cx.rows - 10) * 0.72))
end

local function item(state: State, row: Row): Item
	local indent = string.rep("  ", row.depth)
	local f = row.folder
	if f then
		local open = #words(state.query) > 0 or is_open(state, f.path, row.depth)
		return {
			label = {
				ui.span(indent .. (if open then "▾ " else "▸ "), "muted"),
				ui.span(if open then "\u{f07c}" else "\u{f07b}", "icon info"),
				ui.span(f.name, "strong link"),
			},
			value = { ui.span(tostring(row.hits or f.total), "muted num") },
		}
	end
	local s = row.session :: Session
	return {
		label = { ui.span(indent .. "· ", "dim"), s.title },
		value = {
			ui.span(string.format("%7s", bytes(s.size)), "dim"),
			ui.span(string.format("  %8s", ago(s.mtime)), "muted"),
		},
	}
end

local function button(text: string, act: string, props: { [string]: any }?): Node
	local p: { [string]: any } = props or {}
	p.size = "sm"
	p.actions = { click = act }
	return ui.button(text, p)
end

local function tree_view(state: State, cx: BlockCx): Node
	local items: { Item } = {}
	for i, row in state.rows do
		items[i] = item(state, row)
	end
	local list = ui.list(items)
	local kids = list.c or {}
	for i, row in state.rows do
		local p: { [string]: any } = kids[i].p or {}
		p.key = row.key
		kids[i].p = p
	end
	local p: { [string]: any } = list.p or {}
	p.key = "tree"
	p.selected = if state.cursor then LIST_ID .. state.cursor else nil
	p.max = { lines = list_lines(cx) }
	p.filter = state.query
	p.empty = { ui.span(if state.query ~= "" then "No session matches the filter" else "No omp sessions yet", "muted") }
	list.p = p
	return list
end

local function filter_view(state: State): Node
	local n = 0
	for _ in utf8.codes(state.query) do
		n += 1
	end
	return ui.node("input", {
		key = "filter",
		text = state.query,
		cursor = n,
		placeholder = "Type to filter by title or folder",
		icon = "search",
		clear = true,
	})
end

local function details(state: State): { Node }
	local row = current(state)
	if row == nil then
		return {}
	end
	local s = row.session
	if s then
		local facts: { Span | string } = {
			ui.span(s.shown_cwd, "path"),
			ui.span("  ·  updated " .. ago(s.mtime), "muted"),
		}
		if s.started then
			table.insert(facts, ui.span("  ·  started " .. stamp(s.started), "muted"))
		end
		table.insert(facts, ui.span("  ·  " .. bytes(s.size), "muted"))
		return {
			ui.text({ ui.span(s.title, "strong") }),
			ui.text(facts),
			ui.text({ ui.span(s.id, "mono dim") }),
			ui.row({
				button("Resume", "resume=tab", { icon = "play", variant = "primary", keys = { "enter" } }),
				button("Resume in split", "resume=split", { icon = "split", keys = { "shift", "enter" } }),
				button("Copy ID", "copy-id", { icon = "copy" }),
			}),
		}
	end
	local f = row.folder :: Folder
	return {
		ui.text({ ui.span(shorten(f.path, state.home), "strong path") }),
		ui.text({
			ui.span(plural(f.total, "session"), "muted"),
			ui.span(if f.latest > 0 then "  ·  last active " .. ago(f.latest) else "", "muted"),
		}),
		ui.row({
			button("New session here", "new=tab", { icon = "plus", variant = "primary" }),
			button(if is_open(state, f.path, row.depth) then "Collapse" else "Expand", "toggle", { keys = { "enter" } }),
		}),
	}
end

local function dock_view(state: State): Node
	local lines = details(state)
	table.insert(lines, ui.row({
		ui.text({ ui.span(plural(state.sessions, "session") .. " in " .. plural(state.folders, "folder"), "dim") }),
		button("", "refresh", { icon = "repeat", variant = "quiet", busy = state.loading, title = "Refresh (F5)" }),
	}))
	table.insert(lines, ui.text({ ui.span("↑↓ move · ←→ fold · ⏎ resume · ⇧⏎ split · esc clear · F5 refresh", "dim") }))
	return ui.col(lines)
end

local function error_view(state: State): Node
	local card = ui.card({ ui.span("Could not list omp sessions", "strong") }, {
		ui.text({ ui.span(state.error or "", "muted") }),
		ui.row({ button("Retry", "refresh", { icon = "repeat" }) }),
	})
	local p: { [string]: any } = card.p or {}
	p.tone = "error"
	card.p = p
	return card
end

local function step_in(state: State, row: Row)
	local f = row.folder
	if f == nil then
		return
	end
	local filtering = #words(state.query) > 0
	if not filtering and not is_open(state, f.path, row.depth) then
		toggle(state, row)
	else
		local at = state.index[row.key] or 0
		local nxt = state.rows[at + 1]
		if nxt and nxt.parent == row.key then
			state.cursor = nxt.key
		end
	end
end

local function step_out(state: State, row: Row)
	local f = row.folder
	local filtering = #words(state.query) > 0
	if f and not filtering and is_open(state, f.path, row.depth) then
		toggle(state, row)
	elseif row.parent then
		state.cursor = row.parent
	end
end

tern.block.define("browser", {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		local home = tern.getenv("HOME")
		if home then
			home = (string.gsub(home, "/+$", ""))
			if home == "" then
				home = nil
			end
		end
		local state: State = {
			cx = cx,
			home = home,
			root = if home then home .. "/.omp/agent/sessions" else nil,
			roots = {},
			sessions = 0,
			folders = 0,
			open = {},
			query = "",
			rows = {},
			index = {},
			cursor = nil,
			loading = false,
			loaded = false,
			error = nil,
			gen = 0,
			focused = false,
			toggled = nil,
			reveal = args[1],
		}
		if type(saved) == "table" then
			if type(saved.open) == "table" then
				for _, p in saved.open do
					if type(p) == "string" then
						state.open[p] = true
					end
				end
			end
			if type(saved.closed) == "table" then
				for _, p in saved.closed do
					if type(p) == "string" then
						state.open[p] = false
					end
				end
			end
			if type(saved.cursor) == "string" then
				state.cursor = saved.cursor
			end
		end
		scan(state)
		return state
	end,

	title = function(_state: State): string?
		return "omp sessions"
	end,

	view = function(state: State, cx: BlockCx): BlockView
		if state.error and not state.loaded then
			return { main = ui.col({ error_view(state) }) }
		end
		if not state.loaded then
			return { main = ui.col({ ui.progress(nil, "Reading omp sessions…") }) }
		end
		local main: { Node } = { filter_view(state) }
		if state.error then
			table.insert(main, error_view(state))
		end
		table.insert(main, tree_view(state, cx))
		return { main = ui.col(main), dock = dock_view(state) }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if key.meta or key.ctrl then
			return false
		end
		local name = key.name
		if name == "f5" then
			scan(state)
			return true
		end
		if not state.loaded then
			return false
		end
		local at = (state.cursor and state.index[state.cursor]) or 1
		local row = current(state)
		local page = math.max(1, list_lines(cx) - 1)
		if name == "up" then
			move(state, at - 1)
		elseif name == "down" then
			move(state, at + 1)
		elseif name == "page_up" then
			move(state, at - page)
		elseif name == "page_down" then
			move(state, at + page)
		elseif name == "home" then
			move(state, 1)
		elseif name == "end" then
			move(state, #state.rows)
		elseif name == "right" then
			if row then
				step_in(state, row)
			end
		elseif name == "left" then
			if row then
				step_out(state, row)
			end
		elseif name == "enter" then
			activate(state, cx, row, if key.shift then "split" else "tab")
		elseif name == "escape" then
			if state.query == "" then
				return false
			end
			set_query(state, "")
		elseif name == "backspace" then
			if state.query == "" then
				return false
			end
			local cut = utf8.offset(state.query, -1) or 1
			set_query(state, string.sub(state.query, 1, cut - 1))
		elseif name == "paste" then
			local text = trim((string.gsub(key.text or "", "%c+", " ")))
			if text == "" then
				return false
			end
			set_query(state, state.query .. text)
		elseif key.text and key.text ~= "" and string.find(key.text, "%c") == nil then
			set_query(state, state.query .. key.text)
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			local key = string.sub(ev.item, #LIST_ID + 1)
			local at = state.index[key]
			local row = state.rows[at or 0]
			if row then
				state.cursor = key
				if row.folder then
					local last = state.toggled
					if ev.ev == "select" and not (last and last.key == key and tern.now() - last.at < DOUBLE_CLICK_MS) then
						state.toggled = { key = key, at = tern.now() }
						toggle(state, row)
					end
				elseif ev.ev == "activate" then
					activate(state, cx, row, "tab")
				end
			end
		elseif ev.ev == "focus" then
			cx:frame({ { "focus", FILTER_ID } })
		elseif ev.ev == "action" then
			local row = current(state)
			if ev.act == "resume" then
				activate(state, cx, row, if ev.value == "split" then "split" else "tab")
			elseif ev.act == "new" and row and row.folder then
				launch(cx, "new", "tab", row.folder.path, nil)
			elseif ev.act == "toggle" and row then
				toggle(state, row)
			elseif ev.act == "copy-id" and row and row.session then
				cx:copy(row.session.id)
				cx:toast("success", "Copied session ID", row.session.id)
			elseif ev.act == "clear" then
				set_query(state, "")
			elseif ev.act == "refresh" then
				scan(state)
			elseif ev.act == "reveal" and type(ev.value) == "string" then
				state.reveal = ev.value
				apply_reveal(state)
			end
		end
	end,

	save = function(state: State): any
		local open: { string } = {}
		local closed: { string } = {}
		for path, v in state.open do
			table.insert(if v then open else closed, path)
		end
		table.sort(open)
		table.sort(closed)
		return { open = tern.json.array(open), closed = tern.json.array(closed), cursor = state.cursor }
	end,
})
