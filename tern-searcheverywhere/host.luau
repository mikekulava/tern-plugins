--!strict
-- The `search` block: an overlay with a query line over the best matching files and
-- declarations (classes, functions, methods, variables, constants) under a folder.
-- Typing filters, ↑↓ pick, ⏎ opens at the line, ⇥ cycles All / Files / Symbols, Esc
-- closes. `name:42` opens the match at line 42. An empty query lists recent picks.

local index = require("./index")
local fuzzy = require("./fuzzy")

local ui = tern.ui
local find, sub, match, gsub, lower = string.find, string.sub, string.match, string.gsub, string.lower

local HOME = tern.getenv("HOME") or ""
local LIMIT = 100
local SEARCH_BUDGET_MS = 600
local THROTTLE_MS = 200
local RECENT_MAX = 15
local LIST_ID = "main.results"

type Scope = "all" | "files" | "symbols"
local SCOPES: { Scope } = { "all", "files", "symbols" }
local SCOPE_LABEL: { [string]: string } = { all = "All", files = "Files", symbols = "Symbols" }

local ICON: { [string]: string } = {
	file = "file-code",
	class = "box",
	struct = "stack",
	interface = "puzzle",
	enum = "layers",
	type = "doc",
	module = "layers",
	["function"] = "braces",
	method = "braces",
	variable = "tag",
	field = "tag",
	constant = "key",
}

-- Breaks score ties within a band: types, then files, then functions, then values.
local KIND_BONUS: { [string]: number } = {
	class = 3, struct = 3, interface = 3, enum = 3, type = 3, module = 3,
	file = 2,
	["function"] = 1, method = 1,
}

type Result = {
	kind: string,
	-- Path relative to the folder.
	path: string,
	name: string,
	owner: string?,
	line: number?,
	score: number,
	-- The text drawn as the label, and the matched byte positions in it.
	label: string,
	positions: { number }?,
}

type Cache = {
	idx: index.Index,
	version: number,
	mode: string,
	q: string,
	files: { number },
	syms: { number },
}

type State = {
	cx: BlockCx,
	root: string,
	entry: index.Entry,
	query: string,
	scope: Scope,
	results: { Result },
	sel: number,
	matched: number,
	partial: boolean,
	recent: boolean,
	cache: Cache?,
	timer: TimerHandle?,
	last: number,
	closed: boolean,
	-- The window half on this machine opens the pick (see window.luau).
	handoff: boolean,
	-- ↓ on an empty query lists recent picks; typing ends it.
	browsing: boolean,
}

-- ---------------------------------------------------------------- paths

local function norm(p: string): string
	if p == "~" then
		p = HOME
	elseif sub(p, 1, 2) == "~/" then
		p = HOME .. sub(p, 2)
	end
	p = gsub(p, "/+$", "")
	return if p == "" then "/" else p
end

local function tilde(p: string): string
	if HOME ~= "" and (p == HOME or sub(p, 1, #HOME + 1) == HOME .. "/") then
		return "~" .. sub(p, #HOME + 1)
	end
	return p
end

local function is_dir(p: string): boolean
	return (pcall(tern.fs.list, p))
end

local function dirname(rel: string): string
	return match(rel, "^(.*)/[^/]*$") or ""
end

local function absolute(state: State, rel: string): string
	return if state.root == "/" then "/" .. rel else state.root .. "/" .. rel
end

local function pane_alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------- recent picks

local function recent_key(root: string): string
	return "recent:" .. root
end

local function remember(state: State, r: Result, line: number?)
	local list = tern.kv.get(recent_key(state.root))
	local out: { any } = { { path = r.path, kind = r.kind, name = r.name, owner = r.owner, line = line } }
	if type(list) == "table" then
		for _, e in list do
			if type(e) == "table" and #out < RECENT_MAX
				and not (e.path == r.path and e.name == r.name and e.kind == r.kind)
			then
				table.insert(out, e)
			end
		end
	end
	tern.kv.set(recent_key(state.root), out)
end

local function recent_results(state: State): { Result }
	local list = tern.kv.get(recent_key(state.root))
	local out: { Result } = {}
	if type(list) ~= "table" then
		return out
	end
	for _, e in list do
		if type(e) == "table" and type(e.path) == "string" and type(e.kind) == "string" then
			if state.scope == "all" or (state.scope == "files") == (e.kind == "file") then
				local name = if type(e.name) == "string" then e.name else (match(e.path, "([^/]*)$") or e.path)
				table.insert(out, {
					kind = e.kind,
					path = e.path,
					name = name,
					owner = if type(e.owner) == "string" and e.owner ~= "" then e.owner else nil,
					line = if type(e.line) == "number" then e.line else nil,
					score = 0,
					label = name,
					positions = nil,
				})
			end
		end
	end
	return out
end

-- ---------------------------------------------------------------- searching

-- The query without surrounding space and an optional `:line` suffix, and that line.
local function parse_query(raw: string): (string, number?)
	local text = match(raw, "^%s*(.-)%s*$") or ""
	local q, line = match(text, "^(.-):(%d+)$")
	if q and q ~= "" then
		return q, tonumber(line)
	end
	local typing = match(text, "^(.-):$")
	if typing and typing ~= "" then
		return typing, nil
	end
	return text, nil
end

local function better(a: Result, b: Result): boolean
	if a.score ~= b.score then
		return a.score > b.score
	end
	if #a.label ~= #b.label then
		return #a.label < #b.label
	end
	if a.path ~= b.path then
		return a.path < b.path
	end
	return (a.line or 0) < (b.line or 0)
end

-- Inserts `r` into `top` (sorted best first, at most LIMIT long) when it ranks.
local function insert_top(top: { Result }, r: Result)
	local n = #top
	if n >= LIMIT and not better(r, top[n]) then
		return
	end
	local lo, hi = 1, n + 1
	while lo < hi do
		local mid = (lo + hi) // 2
		if better(r, top[mid]) then
			hi = mid
		else
			lo = mid + 1
		end
	end
	table.insert(top, lo, r)
	if #top > LIMIT then
		top[#top] = nil
	end
end

local function result_key(r: Result): string
	return r.kind .. "\0" .. r.path .. "\0" .. r.name .. "\0" .. tostring(r.line)
end

-- Searches again for the query. `keep_selection` (index progress) keeps the selected result
-- selected when it still ranks; a changed query starts at the top.
local function search(state: State, keep_selection: boolean?)
	local keep = if keep_selection then state.results[state.sel] else nil
	local keep_key = if keep then result_key(keep) else nil
	state.partial = false
	local text = gsub((parse_query(state.query)), "%s+", "")
	if text == "" then
		state.recent = true
		state.results = if state.browsing then recent_results(state) else {}
		state.matched = #state.results
		state.sel = 1
		return
	end
	state.recent = false

	local idx = state.entry.current
	local q = fuzzy.query(text)
	-- One character matches name prefixes only (everything has an `e` in it); two match
	-- at word starts (`qs` → QuerySet) but not as a loose subsequence.
	local mode = if q.n == 1 then "prefix" else "fuzzy"
	local min_score = if q.n == 2 then 300 else -math.huge
	local path_mode = find(text, "/", 1, true) ~= nil
	local dot_mode = find(text, ".", 1, true) ~= nil
	local want_files = state.scope ~= "symbols"
	local want_syms = state.scope ~= "files"

	local c = state.cache
	local reuse = c ~= nil and c.idx == idx and c.version == idx.version and c.mode == mode
		and sub(q.lower, 1, #c.q) == c.q
	local paths, lpaths, bases, lbases = idx.paths, idx.lpaths, idx.bases, idx.lbases
	local names, lnames, lfulls, kinds, files, lines, owners =
		idx.names, idx.lnames, idx.lfulls, idx.kinds, idx.files, idx.lines, idx.owners
	local qn, ql = q.n, q.lower

	local top: { Result } = {}
	local matched = 0
	local t0 = tern.now()
	local partial = false

	-- Files.
	local file_hits: { number } = {}
	local function try_file(i: number)
		local hit
		if mode == "prefix" then
			hit = sub(lbases[i], 1, qn) == ql or (path_mode and fuzzy.has(lpaths[i], q))
		else
			hit = fuzzy.has(lpaths[i], q)
		end
		if not hit then
			return
		end
		table.insert(file_hits, i)
		if not want_files then
			return
		end
		local label = if path_mode then paths[i] else bases[i]
		local score = fuzzy.score(label, if path_mode then lpaths[i] else lbases[i], q)
		if score == nil and not path_mode then
			score = fuzzy.score(paths[i], lpaths[i], q)
			if score then
				score -= 300
				label = paths[i]
			end
		end
		if score == nil or score < min_score then
			return
		end
		matched += 1
		score += KIND_BONUS.file
		if #top >= LIMIT and score < top[LIMIT].score then
			return
		end
		insert_top(top, {
			kind = "file",
			path = paths[i],
			name = bases[i],
			owner = nil,
			line = nil,
			score = score,
			label = label,
			positions = nil,
		})
	end

	-- Declarations.
	local sym_hits: { number } = {}
	local function try_sym(i: number)
		local hit
		if mode == "prefix" then
			hit = sub(lnames[i], 1, qn) == ql or (dot_mode and sub(lfulls[i], 1, qn) == ql)
		else
			hit = fuzzy.has(lfulls[i], q)
		end
		if not hit then
			return
		end
		table.insert(sym_hits, i)
		if not want_syms then
			return
		end
		local owner = owners[i]
		local label, l = names[i], lnames[i]
		if dot_mode and owner ~= "" then
			label, l = owner .. "." .. names[i], lfulls[i]
		end
		local score = fuzzy.score(label, l, q)
		if score == nil or score < min_score then
			return
		end
		matched += 1
		local kind = kinds[i]
		score += KIND_BONUS[kind] or 0
		if #top >= LIMIT and score < top[LIMIT].score then
			return
		end
		insert_top(top, {
			kind = kind,
			path = paths[files[i]],
			name = names[i],
			owner = if owner ~= "" then owner else nil,
			line = lines[i],
			score = score,
			label = label,
			positions = nil,
		})
	end

	local function over_budget(): boolean
		if tern.now() - t0 > SEARCH_BUDGET_MS then
			partial = true
			return true
		end
		return false
	end

	if reuse then
		local cache = c :: Cache
		for k, i in cache.files do
			try_file(i)
			if k % 2048 == 0 and over_budget() then
				break
			end
		end
		if not partial then
			for k, i in cache.syms do
				try_sym(i)
				if k % 2048 == 0 and over_budget() then
					break
				end
			end
		end
	else
		for i = 1, #paths do
			try_file(i)
			if i % 2048 == 0 and over_budget() then
				break
			end
		end
		if not partial then
			for i = 1, #names do
				try_sym(i)
				if i % 2048 == 0 and over_budget() then
					break
				end
			end
		end
	end

	state.cache = if partial
		then nil
		else { idx = idx, version = idx.version, mode = mode, q = q.lower, files = file_hits, syms = sym_hits }
	state.partial = partial
	state.matched = matched
	for _, r in top do
		local _, positions = fuzzy.score(r.label, lower(r.label), q, true)
		r.positions = positions
	end
	state.results = top
	state.sel = 1
	if keep_key then
		for i, r in top do
			if result_key(r) == keep_key then
				state.sel = i
				break
			end
		end
	end
end

-- Searches again soon (index progress), at most every THROTTLE_MS.
local function schedule(state: State)
	if state.timer then
		return
	end
	local wait = math.max(0, THROTTLE_MS - (tern.now() - state.last))
	state.timer = tern.timer(wait, function()
		state.timer = nil
		if state.closed then
			return
		end
		state.last = tern.now()
		search(state, true)
		state.cx:render()
	end)
end

local function close(state: State)
	state.closed = true
	index.unsubscribe(state.entry, state)
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
end

local function open_result(state: State, r: Result?)
	if r == nil then
		return
	end
	local _, query_line = parse_query(state.query)
	local line = query_line or r.line
	remember(state, r, if r.kind == "file" then query_line else r.line)
	close(state)
	local target = absolute(state, r.path)
	if line then
		target ..= "#L" .. line
	end
	if state.handoff then
		tern.kv.set("open:" .. tostring(state.cx.pane), { target = target })
	else
		state.cx:open(target)
	end
	state.cx:exit(0)
end

-- ---------------------------------------------------------------- editing the query

local function drop_char(s: string): string
	if s == "" then
		return s
	end
	local at = utf8.offset(s, -1)
	return if at then sub(s, 1, at - 1) else sub(s, 1, -2)
end

local function drop_word(s: string): string
	s = gsub(s, "%s+$", "")
	local cut = match(s, "^(.-)[%w_]+$")
	if cut and cut ~= s then
		return cut
	end
	return drop_char(s)
end

local function set_query(state: State, q: string)
	if q ~= state.query then
		state.query = q
		state.browsing = false
		search(state)
	end
end

local function move(state: State, by: number)
	local n = #state.results
	if n == 0 then
		return
	end
	state.sel = math.clamp(state.sel + by, 1, n)
end

local function set_scope(state: State, scope: Scope)
	if scope ~= state.scope then
		state.scope = scope
		search(state)
	end
end

local function cycle_scope(state: State, by: number)
	local at = table.find(SCOPES, state.scope) or 1
	set_scope(state, SCOPES[((at - 1 + by) % #SCOPES) + 1])
end

-- ---------------------------------------------------------------- view

local function highlighted(text: string, positions: { number }?, base: string?): { Span }
	if positions == nil or #positions == 0 then
		return { ui.span(text, base) }
	end
	local hit: { [number]: boolean } = {}
	for _, p in positions do
		hit[p] = true
	end
	local spans: { Span } = {}
	local i, n = 1, #text
	while i <= n do
		local on = hit[i] == true
		local j = i
		while j < n and (hit[j + 1] == true) == on do
			j += 1
		end
		local style = if on then (if base then base .. " accent" else "accent strong") else base
		table.insert(spans, ui.span(sub(text, i, j), style))
		i = j + 1
	end
	return spans
end

local function item(r: Result, i: number): Node
	local props: { [string]: any } = {
		key = "r" .. i,
		icon = ICON[r.kind] or "doc",
		label = highlighted(r.label, r.positions),
	}
	if r.kind == "file" then
		if r.label ~= r.path then
			local dir = dirname(r.path)
			props.detail = { ui.span(if dir == "" then "./" else dir, "muted") }
		end
	else
		if r.owner and r.label == r.name then
			props.detail = { ui.span(r.owner, "muted") }
		end
		props.value = { ui.span(r.path .. (if r.line then ":" .. r.line else ""), "muted mono") }
	end
	return ui.node("item", props)
end

local function plural(n: number, word: string): string
	if n == 1 then
		return n .. " " .. word
	end
	return n .. " " .. word .. (if find(word, "[sxz]$") or find(word, "[cs]h$") then "es" else "s")
end

local function scope_buttons(state: State): Node
	local buttons: { Node } = {}
	for _, s in SCOPES do
		table.insert(buttons, ui.button(SCOPE_LABEL[s], {
			key = "scope-" .. s,
			size = "sm",
			variant = "quiet",
			on = state.scope == s,
			actions = { click = "scope=" .. s },
		}))
	end
	return ui.node("row", { key = "scopes", gap = "sm" }, buttons)
end

-- What the head row's right side says: progress, the match count, else the folder.
local function status(state: State): { Span }
	local idx = state.entry.current
	local spans: { Span } = {}
	local function add(text: string, style: string?)
		if #spans > 0 then
			table.insert(spans, ui.span("  ·  ", "dim"))
		end
		table.insert(spans, ui.span(text, style or "muted"))
	end
	if idx.phase == "listing" then
		add("listing files… " .. #idx.paths)
	elseif idx.phase == "parsing" then
		add(string.format("indexing %d/%d", idx.parsed, #idx.paths))
	end
	if idx.truncated then
		add("index limit reached", "warning")
	end
	if state.partial then
		add("search cut short, type more", "warning")
	end
	local text = gsub((parse_query(state.query)), "%s+", "")
	if text ~= "" then
		local shown = #state.results
		if shown == 0 then
			add("no matches")
		elseif state.matched > shown then
			add(string.format("best %d of %d", shown, state.matched))
		else
			add(plural(state.matched, "match"))
		end
	elseif #spans == 0 then
		add(tilde(state.root))
	end
	return spans
end

local function head(state: State): Node
	return ui.node("row", { key = "head", gap = "md", justify = "between", align = "center" }, {
		scope_buttons(state),
		ui.text(status(state)),
	})
end

local function query_line(state: State): Node
	local spans: { Span } = {}
	if state.query == "" then
		table.insert(spans, ui.span("▏", "accent"))
		table.insert(spans, ui.span("Files, classes, functions, variables  ·  ↓ recent", "muted"))
	else
		table.insert(spans, ui.span(state.query, "strong"))
		table.insert(spans, ui.span("▏", "accent"))
	end
	local node = ui.text(spans)
	local props: { [string]: any } = node.p or {}
	props.key = "query"
	node.p = props
	return node
end

local function results(state: State, cx: BlockCx): Node
	local items: { Node } = {}
	for i, r in state.results do
		table.insert(items, item(r, i))
	end
	return ui.node("list", {
		key = "results",
		selected = LIST_ID .. ".r" .. state.sel,
		max = { lines = math.max(3, cx.rows - 5) },
	}, items)
end

local function legend(): Node
	local spans: { Span } = {}
	local function k(key: string, what: string)
		table.insert(spans, ui.span(key, "key"))
		table.insert(spans, ui.span(" " .. what .. "   ", "muted"))
	end
	k("↑↓", "select")
	k("⏎", "open")
	k("⇥", "all / files / symbols")
	k(":42", "go to line")
	k("esc", "close")
	return ui.col({ ui.text(spans) })
end

-- ---------------------------------------------------------------- the block

tern.block.define("search", {
	font = "sans",

	init = function(cx: BlockCx, args: { string }, _saved: any): State
		local fallback = norm(cx.cwd or HOME)
		local root = norm(if args[1] and args[1] ~= "" then args[1] else fallback)
		if not is_dir(root) then
			local parent = match(root, "^(.*)/[^/]*$")
			root = if parent and parent ~= "" and is_dir(parent) then parent else fallback
		end
		local entry = index.get(root)
		local state: State = {
			cx = cx,
			root = root,
			entry = entry,
			query = "",
			scope = "all",
			results = {},
			sel = 1,
			matched = 0,
			partial = false,
			recent = true,
			cache = nil,
			timer = nil,
			last = 0,
			closed = false,
			handoff = args[2] == "handoff",
			browsing = false,
		}
		index.subscribe(entry, state, function()
			if state.closed then
				return
			end
			if not pane_alive(state.cx.pane) then
				close(state)
				return
			end
			if state.query ~= "" or entry.current.phase == "ready" then
				schedule(state)
			else
				state.cx:render()
			end
		end)
		search(state)
		return state
	end,

	-- window.luau sizes the overlay from the title: compact without results, else tall
	-- enough for this many list lines (the "Recent" rule counts as one).
	title = function(state: State): string?
		local n = #state.results
		if n == 0 then
			return "Search Everywhere"
		end
		return "Search Everywhere · results " .. (n + (if state.recent then 1 else 0))
	end,

	view = function(state: State, cx: BlockCx): BlockView
		local main: { Node } = { head(state), query_line(state) }
		if #state.results == 0 then
			return { main = ui.node("col", { gap = "sm" }, main) }
		end
		if state.recent then
			table.insert(main, ui.rule("Recent"))
		end
		table.insert(main, results(state, cx))
		return {
			main = ui.node("col", { gap = "sm" }, main),
			dock = legend(),
		}
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		local name = key.name
		local mod = key.ctrl or key.meta
		if name == "escape" then
			close(state)
			cx:exit(0)
			return false
		elseif name == "enter" then
			open_result(state, state.results[state.sel])
			return false
		elseif name == "up" or (key.ctrl and name == "p") then
			move(state, -1)
		elseif name == "down" or (key.ctrl and name == "n") then
			if state.query == "" and not state.browsing then
				state.browsing = true
				search(state)
			else
				move(state, 1)
			end
		elseif name == "page_up" then
			move(state, -10)
		elseif name == "page_down" then
			move(state, 10)
		elseif name == "tab" then
			cycle_scope(state, if key.shift then -1 else 1)
		elseif name == "backspace" then
			if key.meta or (key.ctrl and key.shift) then
				set_query(state, "")
			elseif key.alt or key.ctrl then
				set_query(state, drop_word(state.query))
			else
				set_query(state, drop_char(state.query))
			end
		elseif key.ctrl and name == "u" then
			set_query(state, "")
		elseif key.ctrl and name == "w" then
			set_query(state, drop_word(state.query))
		elseif name == "paste" and key.text then
			set_query(state, state.query .. (match(key.text, "^[^\r\n]*") or ""))
		elseif not mod and key.text and key.text ~= "" then
			set_query(state, state.query .. key.text)
		elseif not mod and name == "space" then
			set_query(state, state.query .. " ")
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if ev.ev == "select" or ev.ev == "activate" then
			local key = if type(ev.item) == "string" then match(ev.item, "%.r(%d+)$") else nil
			local i = if key then tonumber(key) else nil
			if i and state.results[i] then
				state.sel = i
				if ev.ev == "activate" then
					open_result(state, state.results[i])
				end
			end
		elseif ev.ev == "action" and ev.act == "scope" and type(ev.value) == "string" then
			local s = ev.value :: string
			if SCOPE_LABEL[s] then
				set_scope(state, s :: Scope)
			end
		end
	end,
})
