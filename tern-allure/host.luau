--!strict

local results = require("./results")
local tree = require("./tree")
local detail = require("./detail")
local view = require("./view")

type Source = results.Source
type Launch = results.Launch
type Result = results.Result
type Status = results.Status
type Tab = view.Tab

local HOME = tern.getenv("HOME")
local POLL_MS = 2000
local DISCOVER_MS = 30 * 1000
local DISCOVER_EMPTY_MS = 10 * 1000
local FIND_TIMEOUT_MS = 20 * 1000
local SLICE_MS = 120
local LIVE_MS = 8000
local PREVIEW_BYTES = 512 * 1024
local HEAD_BYTES = 256 * 1024
local MAX_DIFF_BYTES = 32 * 1024 * 1024
local TABLE_ROWS = 200
local SMALL_TREE = 60
local DOUBLE_CLICK_MS = 400

type Job = { source: Source, name: string }

type State = {
	cx: BlockCx,
	root: string,
	start: string,
	pinned: boolean,
	focusFile: string?,
	phase: string,
	problem: string?,
	sources: { Source },
	launches: { Launch },
	byLaunch: { [string]: Launch },
	launch: string?,
	queue: { Job },
	qhead: number,
	queued: { [string]: boolean },
	done: number,
	initial: boolean,
	pumping: boolean,
	gen: number,
	version: number,
	tab: Tab,
	statuses: { [string]: boolean },
	query: string,
	filtering: boolean,
	open: { [string]: boolean },
	sel: { [string]: string },
	sizes: { number }?,
	keys: { [string]: string },
	byKey: { [string]: string },
	keyCount: number,
	attKeys: { [string]: string },
	attByKey: { [string]: detail.Attachment },
	attCount: number,
	expanded: { [string]: boolean },
	previews: { [string]: detail.Preview },
	attempt: string?,
	model: detail.Model?,
	modelKey: string?,
	cache: { sig: string, tree: tree.Tree }?,
	discovered: number,
	discovering: boolean,
	wasLive: boolean,
	toggled: { key: string, at: number }?,
	poll: TimerHandle?,
}

local running: { [number]: State } = {}

local function pane_alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
		tern.kv.set("report:" .. tostring(state.cx.pane), nil)
	end
	state.gen += 1
	if state.poll then
		state.poll:cancel()
		state.poll = nil
	end
end

local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	if pane_alive(state.cx.pane) then
		return true
	end
	retire(state)
	return false
end

local function key_of(state: State, ident: string): string
	local k = state.keys[ident]
	if k == nil then
		state.keyCount += 1
		k = "r" .. state.keyCount
		state.keys[ident] = k
		state.byKey[k] = ident
	end
	return k :: string
end

local function launch_key(state: State, l: Launch): string
	return key_of(state, "launch\0" .. l.id)
end

local function launch_of_key(state: State, key: string): Launch?
	local ident = state.byKey[key]
	if ident == nil or string.sub(ident, 1, 7) ~= "launch\0" then
		return nil
	end
	return state.byLaunch[string.sub(ident, 8)]
end

local function launch_name(l: Launch): string
	return "Run " .. l.index
end

local function att_key(state: State, att: detail.Attachment): string
	local k = state.attKeys[att.path]
	if k == nil then
		state.attCount += 1
		local made = "a" .. state.attCount
		state.attKeys[att.path] = made
		state.attByKey[made] = att
		return made
	end
	return k :: string
end

local function current(state: State): Launch?
	return if state.launch then state.byLaunch[state.launch :: string] else nil
end

local function rel_of(state: State, dir: string): string
	if state.pinned then
		return results.basename(dir)
	end
	if dir == state.root then
		return results.basename(dir)
	end
	if string.sub(dir, 1, #state.root + 1) == state.root .. "/" then
		return string.sub(dir, #state.root + 2)
	end
	return results.tilde(dir, HOME)
end

local function find_source(state: State, dir: string): Source?
	for _, src in state.sources do
		if src.dir == dir then
			return src
		end
	end
	return nil
end

local function add_source(state: State, dir: string): Source
	local existing = find_source(state, dir)
	if existing then
		return existing
	end
	local src = results.source(dir, rel_of(state, dir))
	table.insert(state.sources, src)
	table.sort(state.sources, function(a: Source, b: Source): boolean
		return a.rel < b.rel
	end)
	return src
end

local function enqueue(state: State, src: Source, names: { string })
	for _, name in names do
		local id = src.dir .. "\0" .. name
		if not state.queued[id] then
			state.queued[id] = true
			table.insert(state.queue, { source = src, name = name })
		end
	end
end

local function pending(state: State): number
	return #state.queue - state.qhead + 1
end

local function pick_default_launch(state: State): string?
	for _, l in state.launches do
		if results.under(l.source.dir, state.start) or results.under(state.start, l.source.dir) then
			return l.id
		end
	end
	local newest = state.launches[1]
	return if newest then newest.id else nil
end

local function relaunch(state: State)
	local all: { Launch } = {}
	local by: { [string]: Launch } = {}
	for _, src in state.sources do
		for _, l in src.launches do
			table.insert(all, l)
			by[l.id] = l
		end
	end
	table.sort(all, function(a: Launch, b: Launch): boolean
		local sa, sb = a.start or -1, b.start or -1
		if sa ~= sb then
			return sa > sb
		end
		return a.id < b.id
	end)
	local previous = current(state)
	local followed = previous ~= nil and state.launches[1] == previous
	local known = state.byLaunch
	state.launches = all
	state.byLaunch = by
	local newest = all[1]
	if followed and newest and known[newest.id] == nil then
		state.launch = newest.id
		state.attempt = nil
	elseif state.launch == nil or by[state.launch :: string] == nil then
		local replacement: string? = nil
		if previous then
			for _, l in all do
				if l.source == previous.source then
					replacement = l.id
					break
				end
			end
		end
		state.launch = replacement or pick_default_launch(state)
	end
	state.version += 1
	state.cache = nil
end

local function focus(state: State, id: string?)
	local cx = state.cx
	tern.timer(1, function()
		if alive(state) then
			local op: { any } = { "focus", if id then id else tern.json.null }
			cx:frame({ op })
		end
	end)
end

local function words(query: string): { string }
	local out: { string } = {}
	for w in string.gmatch(string.lower(query), "%S+") do
		table.insert(out, w)
	end
	return out
end

local function statuses_sig(state: State): string
	local parts: { string } = {}
	for _, s in results.STATUSES do
		table.insert(parts, if state.statuses[s] ~= false then "1" else "0")
	end
	return table.concat(parts)
end

local function tree_for(state: State, l: Launch): tree.Tree
	local kind: tree.Kind = (state.tab :: any) :: tree.Kind
	local sig = table.concat({ l.id, kind, state.query, statuses_sig(state), tostring(state.version) }, "\0")
	local cached = state.cache
	if cached and cached.sig == sig then
		return cached.tree
	end
	local ws = words(state.query)
	local function keep(r: Result): boolean
		if state.statuses[r.status] == false then
			return false
		end
		for _, w in ws do
			if string.find(r.hay, w, 1, true) == nil then
				return false
			end
		end
		return true
	end
	local t = tree.build(kind, l.tests, keep, results.category_names(l.source))
	state.cache = { sig = sig, tree = t }
	return t
end

local function is_open_fn(state: State, t: tree.Tree): (string, number) -> boolean
	local everything = state.query ~= "" or t.size <= SMALL_TREE
	return function(ident: string, depth: number): boolean
		local v = state.open[ident]
		if v ~= nil then
			return v
		end
		return everything or depth == 0
	end
end

local function rows_of(state: State): (tree.Tree?, { tree.Row })
	local l = current(state)
	if l == nil or state.tab == "launches" then
		return nil, {}
	end
	local t = tree_for(state, l)
	return t, tree.rows(t, is_open_fn(state, t))
end

local function selected_row(state: State, rows: { tree.Row }): tree.Row?
	local ident = state.sel[state.tab]
	if ident == nil then
		return nil
	end
	for _, row in rows do
		if row.ident == ident then
			return row
		end
	end
	return nil
end

local function reveal(state: State, t: tree.Tree, ident: string)
	for _, g in tree.ancestors(t, ident) do
		state.open[g] = true
	end
end

local function scroll_detail(state: State)
	local cx = state.cx
	tern.timer(1, function()
		if alive(state) then
			local id = if cx.cols < 100 then "main.stack.detail" else "main.split.detail"
			local op: { any } = { "scroll", id, "start" }
			cx:frame({ op })
		end
	end)
end

local function select_ident(state: State, ident: string?)
	if state.sel[state.tab] ~= ident then
		state.attempt = nil
		scroll_detail(state)
	end
	state.sel[state.tab] = ident :: string
end

local function auto_select(state: State)
	if state.tab == "launches" then
		return
	end
	local t, rows = rows_of(state)
	if t == nil then
		return
	end
	local ident = state.sel[state.tab]
	if ident and ((t :: tree.Tree).leaves[ident :: string] or (t :: tree.Tree).groups[ident :: string]) then
		return
	end
	local first_bad: tree.Leaf? = nil
	local function find(g: tree.Group)
		if first_bad then
			return
		end
		for _, child in g.groups do
			find(child)
			if first_bad then
				return
			end
		end
		for _, leaf in g.tests do
			if leaf.result.status == "failed" or leaf.result.status == "broken" then
				first_bad = leaf
				return
			end
		end
	end
	find((t :: tree.Tree).root)
	if first_bad then
		reveal(state, t :: tree.Tree, (first_bad :: tree.Leaf).ident)
		select_ident(state, (first_bad :: tree.Leaf).ident)
	elseif rows[1] then
		select_ident(state, rows[1].ident)
	end
end

local function apply_focus_file(state: State)
	local file = state.focusFile
	if file == nil then
		return
	end
	for _, src in state.sources do
		for _, r in src.results do
			if r.file == file then
				state.focusFile = nil
				local latest = if r.launch then (r.launch :: Launch).byHistory[r.historyId] else nil
				if r.launch then
					state.launch = (r.launch :: Launch).id
				end
				if state.tab == "launches" then
					state.tab = "suites"
				end
				local t = rows_of(state)
				if t then
					local leaf = (t :: tree.Tree).byHistory[r.historyId]
					if leaf then
						reveal(state, t :: tree.Tree, leaf.ident)
						select_ident(state, leaf.ident)
						if latest and latest ~= r then
							state.attempt = r.uuid
						end
					end
				end
				return
			end
		end
	end
end

local function history_of(state: State, hid: string): { Result }
	local out: { Result } = {}
	for _, l in state.launches do
		local r = l.byHistory[hid]
		if r then
			table.insert(out, r)
		end
	end
	return out
end

local function model_for(state: State, row: tree.Row?): detail.Model?
	if row == nil or row.leaf == nil then
		state.model = nil
		state.modelKey = nil
		return nil
	end
	local latest = (row.leaf :: tree.Leaf).result
	local r = latest
	if state.attempt and latest.attempts then
		for _, a in latest.attempts :: { Result } do
			if a.uuid == state.attempt then
				r = a
			end
		end
	end
	if r == latest then
		state.attempt = nil
	end
	local mkey = r.file .. "\0" .. tostring(state.version)
	if state.model and state.modelKey == mkey then
		return state.model
	end
	local raw, problem = results.read_json(r.file)
	local befores, afters = results.fixtures(r.source, r.uuid)
	local model: detail.Model = {
		result = r,
		raw = if type(raw) == "table" then raw else nil,
		problem = problem,
		befores = befores,
		afters = afters,
		history = history_of(state, latest.historyId),
		attempt = r ~= latest,
	}
	state.model = model
	state.modelKey = mkey
	return model
end

local function selected_result(state: State): (Result?, { [string]: any }?)
	local _, rows = rows_of(state)
	local row = selected_row(state, rows)
	local model = model_for(state, row)
	if model then
		return model.result, model.raw
	end
	return nil, nil
end

local finish_loading: (State) -> ()

local function pump(state: State)
	if state.pumping then
		return
	end
	state.pumping = true
	local gen = state.gen
	local touched: { [Source]: boolean } = {}
	local function slice()
		if gen ~= state.gen or not alive(state) then
			state.pumping = false
			return
		end
		local started = tern.now()
		while state.qhead <= #state.queue and tern.now() - started < SLICE_MS do
			local job = state.queue[state.qhead]
			state.qhead += 1
			state.queued[job.source.dir .. "\0" .. job.name] = nil
			results.load(job.source, job.name)
			touched[job.source] = true
			state.done += 1
		end
		if state.qhead <= #state.queue then
			if state.initial then
				state.cx:render()
			end
			tern.timer(1, slice)
			return
		end
		state.queue = {}
		state.qhead = 1
		state.pumping = false
		for src in touched do
			results.reload_meta(src)
			results.finish(src)
		end
		if next(touched) ~= nil then
			finish_loading(state)
		end
	end
	tern.timer(1, slice)
end

finish_loading = function(state: State)
	if state.initial then
		for _, src in state.sources do
			src.arrived = nil
		end
	end
	relaunch(state)
	state.initial = false
	state.done = 0
	if state.phase ~= "failed" then
		state.phase = "ready"
	end
	apply_focus_file(state)
	auto_select(state)
	state.cx:render()
end

local function scan_sources(state: State)
	for _, src in state.sources do
		local before = src.version
		local fresh = results.listing(src)
		if fresh and #fresh > 0 then
			enqueue(state, src, fresh)
		elseif src.version ~= before then
			results.finish(src)
			relaunch(state)
			state.cx:render()
		end
	end
	if pending(state) > 0 then
		if state.initial then
			state.phase = "loading"
		end
		pump(state)
	elseif state.initial then
		state.initial = false
		state.phase = "ready"
		relaunch(state)
		auto_select(state)
		state.cx:render()
	end
end

local function discover(state: State)
	if state.discovering then
		return
	end
	state.discovering = true
	state.discovered = tern.now()
	local gen = state.gen
	local started, err = pcall(function()
		tern.process.run(results.find_argv(state.root), { timeout_ms = FIND_TIMEOUT_MS }, function(r: ProcessResult, _)
			if gen ~= state.gen or not alive(state) then
				return
			end
			state.discovering = false
			if r.timed_out then
				if #state.sources == 0 then
					state.phase = "failed"
					state.problem = "Looking for allure-results folders under " .. results.tilde(state.root, HOME)
						.. " took longer than " .. (FIND_TIMEOUT_MS // 1000) .. " seconds."
				end
			else
				local found = results.parse_find(r.stdout)
				local keep: { Source } = {}
				local seen: { [string]: boolean } = {}
				for _, f in found do
					seen[f.dir] = true
				end
				for _, src in state.sources do
					if seen[src.dir] or not src.missing then
						table.insert(keep, src)
					end
				end
				state.sources = keep
				for _, f in found do
					add_source(state, f.dir)
				end
				if state.phase == "scanning" or state.phase == "failed" then
					state.phase = if #state.sources > 0 then "loading" else "ready"
					state.problem = nil
				end
			end
			scan_sources(state)
			state.cx:render()
		end)
	end)
	if not started then
		state.discovering = false
		state.phase = "failed"
		state.problem = tostring(err)
	end
end

local function schedule_poll(state: State)
	local gen = state.gen
	state.poll = tern.timer(POLL_MS, function()
		if gen ~= state.gen or not alive(state) then
			return
		end
		if not state.pumping then
			scan_sources(state)
			local every = if #state.sources == 0 then DISCOVER_EMPTY_MS else DISCOVER_MS
			if not state.pinned and tern.now() - state.discovered > every then
				discover(state)
			end
		end
		local l = current(state)
		local live = l ~= nil and l.source.arrived ~= nil and tern.now() - (l.source.arrived :: number) < LIVE_MS
		if live ~= state.wasLive then
			state.wasLive = live
			state.cx:render()
		end
		schedule_poll(state)
	end)
end

local function reload(state: State)
	state.gen += 1
	if state.poll then
		state.poll:cancel()
		state.poll = nil
	end
	state.queue = {}
	state.qhead = 1
	state.queued = {}
	state.pumping = false
	state.discovering = false
	state.initial = true
	state.done = 0
	state.model = nil
	state.modelKey = nil
	state.previews = {}
	state.cache = nil
	local kept: { Source } = {}
	for _, src in state.sources do
		table.insert(kept, results.source(src.dir, src.rel))
	end
	state.sources = kept
	state.launches = {}
	state.byLaunch = {}
	if state.pinned then
		state.phase = "loading"
		scan_sources(state)
	else
		state.phase = "scanning"
		discover(state)
	end
	schedule_poll(state)
end

local function utf8_drop_last(s: string): string
	local cut = utf8.offset(s, -1) or 1
	return string.sub(s, 1, cut - 1)
end

local function pretty_json(text: string): string
	local out: { string } = {}
	local depth = 0
	local in_string = false
	local escaped = false
	local i = 1
	local n = #text
	local function newline()
		table.insert(out, "\n" .. string.rep("  ", depth))
	end
	while i <= n do
		local c = string.sub(text, i, i)
		if in_string then
			table.insert(out, c)
			if escaped then
				escaped = false
			elseif c == "\\" then
				escaped = true
			elseif c == '"' then
				in_string = false
			end
		elseif c == '"' then
			in_string = true
			table.insert(out, c)
		elseif c == "{" or c == "[" then
			local close = if c == "{" then "}" else "]"
			local j = i + 1
			while j <= n and string.find(string.sub(text, j, j), "^%s$") do
				j += 1
			end
			if string.sub(text, j, j) == close then
				table.insert(out, c .. close)
				i = j
			else
				table.insert(out, c)
				depth += 1
				newline()
			end
		elseif c == "}" or c == "]" then
			depth = math.max(0, depth - 1)
			newline()
			table.insert(out, c)
		elseif c == "," then
			table.insert(out, c)
			newline()
		elseif c == ":" then
			table.insert(out, ": ")
		elseif not string.find(c, "^%s$") then
			table.insert(out, c)
		end
		i += 1
	end
	return table.concat(out)
end

local function parse_delimited(text: string, sep: string): { { string } }
	local rows: { { string } } = {}
	local row: { string } = {}
	local field: { string } = {}
	local quoted = false
	local i = 1
	local n = #text
	local function push_field()
		table.insert(row, table.concat(field))
		field = {}
	end
	local function push_row()
		push_field()
		table.insert(rows, row)
		row = {}
	end
	while i <= n and #rows < TABLE_ROWS do
		local c = string.sub(text, i, i)
		if quoted then
			if c == '"' then
				if string.sub(text, i + 1, i + 1) == '"' then
					table.insert(field, '"')
					i += 1
				else
					quoted = false
				end
			else
				table.insert(field, c)
			end
		elseif c == '"' and #field == 0 then
			quoted = true
		elseif c == sep then
			push_field()
		elseif c == "\n" then
			push_row()
		elseif c ~= "\r" then
			table.insert(field, c)
		end
		i += 1
	end
	if #field > 0 or #row > 0 then
		push_row()
	end
	return rows
end

local function text_preview(att: detail.Attachment, kind: string, text: string, truncated: boolean): detail.Preview
	if kind == "csv" or kind == "tsv" then
		local rows = parse_delimited(text, if kind == "tsv" then "\t" else ",")
		if #rows > 1 and #rows[1] > 1 then
			return { kind = "table", rows = rows, truncated = truncated or #rows >= TABLE_ROWS }
		end
	elseif kind == "uri" then
		local links: { string } = {}
		for line in string.gmatch(text, "[^\r\n]+") do
			local url = string.match(line, "^%s*(.-)%s*$") or ""
			if url ~= "" and string.sub(url, 1, 1) ~= "#" then
				table.insert(links, url)
			end
		end
		return { kind = "links", links = links, truncated = truncated }
	elseif kind == "json" and not truncated and not string.find(text, "\n", 1, true) and #text > 80 then
		return { kind = "text", text = pretty_json(text), lang = "json" }
	end
	return { kind = "text", text = text, lang = detail.lang_of(att, kind), truncated = truncated }
end

local function build_preview(state: State, key: string)
	local att = state.attByKey[key]
	if att == nil or state.previews[key] ~= nil then
		return
	end
	local kind = detail.kind_of(att)
	if detail.is_media(kind) then
		return
	end
	if kind == "diff" then
		local raw, problem = results.read_json(att.path, MAX_DIFF_BYTES)
		if type(raw) ~= "table" then
			state.previews[key] = { kind = "error", problem = problem or "Not a screenshot diff" }
			return
		end
		local blobs: { { label: string, blob: string } } = {}
		for _, part in { { "expected", "Expected" }, { "actual", "Actual" }, { "diff", "Diff" } } do
			local uri = raw[part[1]]
			if type(uri) == "string" then
				local mime, data = string.match(uri, "^data:([^;,]+);base64,(.*)$")
				if mime and data then
					local ok, bytes = pcall(tern.base64.decode, data :: string)
					if ok then
						table.insert(blobs, { label = part[2], blob = state.cx:blob(bytes, mime :: string) })
					end
				end
			end
		end
		state.previews[key] = { kind = "diff", blobs = blobs }
		return
	end
	if not detail.is_text(kind) then
		state.previews[key] = { kind = "none" }
		return
	end
	local ok, text = pcall(tern.fs.read, att.path, PREVIEW_BYTES)
	if ok then
		state.previews[key] = text_preview(att, kind, text, false)
		return
	end
	if not tern.fs.exists(att.path) then
		state.previews[key] = { kind = "error", problem = "The attachment file is missing: " .. att.source }
		return
	end
	state.previews[key] = { kind = "loading" }
	local gen = state.gen
	tern.process.run({ "head", "-c", tostring(HEAD_BYTES), att.path }, { timeout_ms = 5000 }, function(r: ProcessResult, _)
		if gen ~= state.gen or not alive(state) then
			return
		end
		if r.status == 0 and r.stdout ~= "" then
			state.previews[key] = text_preview(att, kind, r.stdout, true)
		else
			state.previews[key] = { kind = "error", problem = "Could not read " .. att.name }
		end
		state.cx:render()
	end)
end

local function move(state: State, rows: { tree.Row }, delta: number)
	if #rows == 0 then
		return
	end
	local at = 0
	local ident = state.sel[state.tab]
	for i, row in rows do
		if row.ident == ident then
			at = i
			break
		end
	end
	local to = if at == 0 then (if delta > 0 then 1 else #rows) else math.clamp(at + delta, 1, #rows)
	select_ident(state, rows[to].ident)
end

local function toggle_group(state: State, t: tree.Tree, row: tree.Row)
	if row.group == nil then
		return
	end
	local open = is_open_fn(state, t)(row.ident, row.depth)
	state.open[row.ident] = not open
end

local function fold(state: State, opening: boolean)
	local t, rows = rows_of(state)
	if t == nil then
		return
	end
	local row = selected_row(state, rows)
	if row == nil then
		return
	end
	local open = row.group ~= nil and is_open_fn(state, t :: tree.Tree)(row.ident, row.depth)
	if opening then
		if row.group and not open then
			state.open[row.ident] = true
		elseif row.group then
			for i, r in rows do
				if r.ident == row.ident and rows[i + 1] and rows[i + 1].parent == row.ident then
					select_ident(state, rows[i + 1].ident)
				end
			end
		end
	else
		if row.group and open then
			state.open[row.ident] = false
		elseif row.parent then
			select_ident(state, row.parent)
		end
	end
end

local function set_tab(state: State, tab: Tab)
	state.tab = tab
	state.cache = nil
	auto_select(state)
end

local function cycle_tab(state: State, step: number)
	local at = table.find(view.TABS, state.tab) or 1
	set_tab(state, view.TABS[(at - 1 + step) % #view.TABS + 1])
end

local function set_launch(state: State, l: Launch?)
	if l == nil or l.id == state.launch then
		return
	end
	state.launch = l.id
	state.attempt = nil
	state.cache = nil
	auto_select(state)
end

local function reveal_path(state: State, raw: string)
	local path = results.norm(raw)
	if results.ends(path, "-result.json") then
		state.focusFile = path
		apply_focus_file(state)
		return
	end
	local best: Source? = nil
	local inside: { Source } = {}
	for _, src in state.sources do
		if results.under(path, src.dir) then
			if best == nil or #src.dir > #(best :: Source).dir then
				best = src
			end
		elseif results.under(src.dir, path) then
			table.insert(inside, src)
		end
	end
	if best == nil and #inside == 1 then
		best = inside[1]
	end
	if best == nil then
		return
	end
	local newest: Launch? = nil
	for _, l in (best :: Source).launches do
		if newest == nil or (l.start or 0) > ((newest :: Launch).start or 0) then
			newest = l
		end
	end
	if newest then
		set_launch(state, newest)
	end
end

local function step_launch(state: State, step: number)
	local l = current(state)
	if l == nil then
		return
	end
	local at = table.find(state.launches, l) or 1
	set_launch(state, state.launches[math.clamp(at + step, 1, #state.launches)])
end

local function failures_only(state: State): boolean
	for _, s in results.STATUSES do
		local want = s == "failed" or s == "broken"
		if (state.statuses[s] ~= false) ~= want then
			return false
		end
	end
	return true
end

local function toggle_failures(state: State)
	local only = failures_only(state)
	for _, s in results.STATUSES do
		state.statuses[s] = only or s == "failed" or s == "broken"
	end
	state.cache = nil
end

local function copy_failure(state: State, cx: BlockCx)
	local r, raw = selected_result(state)
	if r == nil then
		return
	end
	cx:copy(detail.failure_text(r :: Result, raw))
	cx:toast("success", "Copied the failure of " .. (r :: Result).name)
end

local function open_result(state: State, cx: BlockCx)
	local r = selected_result(state)
	if r then
		cx:open((r :: Result).file)
	end
end

local function set_query(state: State, query: string)
	state.query = query
	state.cache = nil
	local t, rows = rows_of(state)
	if t and selected_row(state, rows) == nil then
		for _, row in rows do
			if row.leaf then
				select_ident(state, row.ident)
				return
			end
		end
	end
end

local function leave_filter(state: State)
	state.filtering = false
	focus(state, nil)
end

local function filter_key(state: State, key: Key): boolean?
	local name = key.name
	if name == "escape" then
		set_query(state, "")
		leave_filter(state)
	elseif name == "enter" or name == "tab" then
		leave_filter(state)
	elseif name == "backspace" then
		if state.query == "" then
			leave_filter(state)
		else
			set_query(state, utf8_drop_last(state.query))
		end
	elseif name == "up" or name == "down" then
		local _, rows = rows_of(state)
		move(state, rows, if name == "up" then -1 else 1)
	elseif name == "paste" then
		local text = string.gsub(key.text or "", "%c+", " ")
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
end

local function tree_key(state: State, key: Key, cx: BlockCx): boolean?
	local name = key.name
	local k = key.text or name
	local t, rows = rows_of(state)
	if name == "up" or k == "k" then
		move(state, rows, -1)
	elseif name == "down" or k == "j" then
		move(state, rows, 1)
	elseif name == "page_up" then
		move(state, rows, -10)
	elseif name == "page_down" then
		move(state, rows, 10)
	elseif name == "home" or k == "g" then
		move(state, rows, -#rows)
	elseif name == "end" or k == "G" then
		move(state, rows, #rows)
	elseif name == "left" or k == "h" then
		fold(state, false)
	elseif name == "right" or k == "l" then
		fold(state, true)
	elseif name == "space" or name == "enter" then
		local row = selected_row(state, rows)
		if t == nil or row == nil or row.group == nil then
			return false
		end
		toggle_group(state, t :: tree.Tree, row :: tree.Row)
	elseif k == "f" or k == "F" then
		toggle_failures(state)
	elseif k == "c" or k == "C" then
		copy_failure(state, cx)
		return false
	elseif k == "o" or k == "O" then
		open_result(state, cx)
		return false
	elseif name == "escape" then
		if state.query == "" then
			return false
		end
		set_query(state, "")
	else
		return false
	end
	return true
end

local function launches_key(state: State, key: Key): boolean?
	local name = key.name
	local k = key.text or name
	if name == "up" or k == "k" then
		step_launch(state, -1)
	elseif name == "down" or k == "j" then
		step_launch(state, 1)
	elseif name == "home" or k == "g" then
		set_launch(state, state.launches[1])
	elseif name == "end" or k == "G" then
		set_launch(state, state.launches[#state.launches])
	elseif name == "enter" then
		set_tab(state, "suites")
	else
		return false
	end
	return true
end

local function last_segment(id: any): string?
	if type(id) ~= "string" then
		return nil
	end
	return string.match(id, "([^%.]+)$")
end

local function page(state: State, cx: BlockCx): view.Page
	local t, rows = rows_of(state)
	local row = selected_row(state, rows)
	local model = model_for(state, row)
	local l = current(state)
	local categorized = 0
	if l then
		for _, r in (l :: Launch).tests do
			if r.categories then
				categorized += 1
			end
		end
	end
	local progress = nil
	if state.initial and (state.phase == "loading" or pending(state) > 0) then
		progress = { done = state.done, total = state.done + pending(state) }
	end
	local live = l ~= nil and (l :: Launch).source.arrived ~= nil
		and tern.now() - ((l :: Launch).source.arrived :: number) < LIVE_MS
	state.wasLive = live
	return {
		phase = state.phase,
		problem = state.problem,
		root = state.root,
		home = HOME,
		pinned = state.pinned,
		sources = state.sources,
		launches = state.launches,
		launch = l,
		launchKey = function(launch: Launch): string
			return launch_key(state, launch)
		end,
		launchName = launch_name,
		tab = state.tab,
		query = state.query,
		filtering = state.filtering,
		statuses = state.statuses,
		rows = rows,
		selected = row,
		rowKey = function(ident: string): string
			return key_of(state, ident)
		end,
		isOpen = if t then is_open_fn(state, t :: tree.Tree) else function(_: string, _: number): boolean
			return false
		end,
		shown = if t then (t :: tree.Tree).size else 0,
		categoryCount = categorized,
		cols = cx.cols,
		rows_h = cx.rows,
		sizes = state.sizes,
		progress = progress,
		live = live,
		model = model,
		ctx = {
			attKey = function(att: detail.Attachment): string
				return att_key(state, att)
			end,
			expanded = state.expanded,
			previews = state.previews,
			launchName = launch_name,
			launch = l,
			multiSource = #state.sources > 1,
		},
	}
end

local function select_from_tree(state: State, ev: UiEvent)
	local key = last_segment(ev.item)
	local ident = if key then state.byKey[key :: string] else nil
	if ident == nil then
		return
	end
	select_ident(state, ident)
	local t, rows = rows_of(state)
	local row = selected_row(state, rows)
	if t == nil or row == nil or row.group == nil or ev.ev ~= "select" then
		return
	end
	local last = state.toggled
	if last and last.key == key and tern.now() - last.at < DOUBLE_CLICK_MS then
		return
	end
	state.toggled = { key = key :: string, at = tern.now() }
	toggle_group(state, t :: tree.Tree, row :: tree.Row)
end

local function select_leaf(state: State, ident: string)
	local t = rows_of(state)
	if t then
		reveal(state, t :: tree.Tree, ident)
	end
	select_ident(state, ident)
end

local function select_history(state: State, index: number)
	local model = state.model
	if model == nil then
		return
	end
	local r = model.history[index]
	if r == nil or r.launch == nil then
		return
	end
	local hid = r.historyId
	state.launch = (r.launch :: Launch).id
	state.attempt = nil
	state.cache = nil
	local t = rows_of(state)
	if t then
		local leaf = (t :: tree.Tree).byHistory[hid]
		if leaf then
			reveal(state, t :: tree.Tree, leaf.ident)
			state.sel[state.tab] = leaf.ident
		end
	end
end

local function select_attempt(state: State, index: number)
	local _, rows = rows_of(state)
	local row = selected_row(state, rows)
	if row == nil or row.leaf == nil then
		return
	end
	local latest = (row.leaf :: tree.Leaf).result
	local list = latest.attempts
	if list == nil then
		return
	end
	local a = (list :: { Result })[index]
	state.attempt = if a and a ~= latest then a.uuid else nil
end

tern.block.define("report", {
	font = "sans",

	init = function(cx: BlockCx, args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local arg = args[1] or (if type(saved) == "table" and type(saved.start) == "string" then saved.start else nil)
		local start = results.norm(arg or cx.cwd or HOME or "/")
		local focusFile: string? = nil
		local ok = pcall(tern.fs.list, start)
		if not ok and tern.fs.exists(start) then
			if results.ends(start, "-result.json") then
				focusFile = start
			end
			start = results.dirname(start)
		end
		local pinned = results.is_results_dir(start)
		local root = if pinned then start else results.root_of(start)
		local state: State = {
			cx = cx,
			root = root,
			start = start,
			pinned = pinned,
			focusFile = focusFile,
			phase = if pinned then "loading" else "scanning",
			problem = nil,
			sources = {},
			launches = {},
			byLaunch = {},
			launch = nil,
			queue = {},
			qhead = 1,
			queued = {},
			done = 0,
			initial = true,
			pumping = false,
			gen = 0,
			version = 0,
			tab = "suites",
			statuses = {},
			query = "",
			filtering = false,
			open = {},
			sel = {},
			sizes = nil,
			keys = {},
			byKey = {},
			keyCount = 0,
			attKeys = {},
			attByKey = {},
			attCount = 0,
			expanded = {},
			previews = {},
			attempt = nil,
			model = nil,
			modelKey = nil,
			cache = nil,
			discovered = 0,
			discovering = false,
			wasLive = false,
			toggled = nil,
			poll = nil,
		}
		if type(saved) == "table" and saved.root == root then
			if type(saved.tab) == "string" and table.find(view.TABS, saved.tab) then
				state.tab = (saved.tab :: any) :: Tab
			end
			if type(saved.launch) == "string" then
				state.launch = saved.launch
			end
			if type(saved.statuses) == "table" then
				for k, v in saved.statuses do
					if type(k) == "string" and type(v) == "boolean" then
						state.statuses[k] = v
					end
				end
			end
			if type(saved.open) == "table" then
				for k, v in saved.open do
					if type(k) == "string" and type(v) == "boolean" then
						state.open[k] = v
					end
				end
			end
			if type(saved.sel) == "table" then
				for k, v in saved.sel do
					if type(k) == "string" and type(v) == "string" then
						state.sel[k] = v
					end
				end
			end
			if type(saved.sizes) == "table" and #saved.sizes == 2 then
				state.sizes = saved.sizes
			end
		end
		running[cx.pane] = state
		tern.kv.set("report:" .. tostring(cx.pane), root)
		if pinned then
			add_source(state, root)
			scan_sources(state)
		else
			discover(state)
		end
		schedule_poll(state)
		return state
	end,

	title = function(state: State): string?
		local l = current(state)
		if l then
			local bad = (l :: Launch).counts.failed + (l :: Launch).counts.broken
			if bad > 0 then
				return "Allure · " .. bad .. " failed"
			end
		end
		return "Allure"
	end,

	view = function(state: State, cx: BlockCx): BlockView
		return view.render(page(state, cx))
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if key.meta or key.ctrl or key.alt then
			return false
		end
		if state.filtering then
			return filter_key(state, key)
		end
		local name = key.name
		local k = key.text or name
		if k == "/" and state.tab ~= "launches" then
			state.filtering = true
			focus(state, view.FILTER)
			return true
		elseif name == "tab" then
			cycle_tab(state, if key.shift then -1 else 1)
			return true
		elseif k == "[" then
			step_launch(state, 1)
			return true
		elseif k == "]" then
			step_launch(state, -1)
			return true
		elseif k == "r" or k == "R" or name == "f5" then
			reload(state)
			return true
		elseif k and string.match(k, "^[1-5]$") then
			set_tab(state, view.TABS[tonumber(k) :: number])
			return true
		end
		if state.tab == "launches" then
			return launches_key(state, key)
		end
		return tree_key(state, key, cx)
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		local list = last_segment(ev.id)
		if ev.ev == "select" or ev.ev == "activate" then
			if ev.id == view.TREE or ev.id == view.TREE_STACKED then
				select_from_tree(state, ev)
				if ev.ev == "activate" then
					local _, rows = rows_of(state)
					local row = selected_row(state, rows)
					if row and row.leaf then
						open_result(state, cx)
					end
				end
			elseif ev.id == "main.tabs" and type(ev.item) == "string" and table.find(view.TABS, ev.item) then
				set_tab(state, ev.item :: Tab)
			elseif list == "failures" then
				local key = last_segment(ev.item)
				local ident = if key then state.byKey[key :: string] else nil
				if ident then
					select_leaf(state, ident :: string)
				end
			elseif list == "retries" then
				local index = tonumber(string.match(last_segment(ev.item) or "", "^u(%d+)$") or "")
				if index then
					select_attempt(state, index :: number)
				end
			elseif list == "history" then
				local index = tonumber(string.match(last_segment(ev.item) or "", "^h(%d+)$") or "")
				if index then
					select_history(state, index :: number)
				end
			elseif list == "table" and type(ev.item) == "string" then
				set_launch(state, launch_of_key(state, ev.item))
				if ev.ev == "activate" then
					set_tab(state, "suites")
				end
			end
		elseif ev.ev == "change" then
			if list == "launch" and type(ev.value) == "string" then
				set_launch(state, launch_of_key(state, ev.value))
			elseif ev.id == "main.split" and type(ev.value) == "table" then
				state.sizes = ev.value
			end
		elseif ev.ev == "toggle" then
			local key = ev.key
			if type(key) == "string" and state.attByKey[key] then
				state.expanded[key] = not ev.collapsed
				if state.expanded[key] then
					build_preview(state, key)
				end
			end
		elseif ev.ev == "focus" then
			if ev.id == view.FILTER then
				state.filtering = true
				focus(state, view.FILTER)
			end
		elseif ev.ev == "action" then
			local act = ev.act
			if act == "refresh" then
				reload(state)
			elseif act == "status" and type(ev.value) == "string" then
				state.statuses[ev.value] = state.statuses[ev.value] == false
				state.cache = nil
			elseif act == "clear" then
				set_query(state, "")
			elseif act == "copy-failure" then
				copy_failure(state, cx)
			elseif act == "open-result" then
				open_result(state, cx)
			elseif act == "latest" then
				state.attempt = nil
			elseif act == "toggle" then
				local t, rows = rows_of(state)
				local row = selected_row(state, rows)
				if t and row then
					toggle_group(state, t :: tree.Tree, row :: tree.Row)
				end
			elseif act == "open-att" and type(ev.value) == "string" then
				local att = state.attByKey[ev.value]
				if att then
					cx:open(att.path)
				end
			elseif act == "copy-att" and type(ev.value) == "string" then
				local att = state.attByKey[ev.value]
				if att then
					cx:copy(att.path)
					cx:toast("success", "Copied the attachment's path")
				end
			elseif act == "show-tests" then
				set_tab(state, "suites")
			elseif act == "copy-folder" then
				local l = current(state)
				if l then
					cx:copy((l :: Launch).source.dir)
					cx:toast("success", "Copied the folder path")
				end
			elseif act == "reveal" and type(ev.value) == "string" then
				reveal_path(state, ev.value)
			end
		end
	end,

	save = function(state: State): any
		return {
			start = state.start,
			root = state.root,
			tab = state.tab,
			launch = state.launch,
			statuses = state.statuses,
			open = state.open,
			sel = state.sel,
			sizes = state.sizes,
		}
	end,
})
