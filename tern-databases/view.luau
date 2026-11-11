--!strict
-- What the Databases block shows. A page in the UI face: the head row (the connection and its
-- state), then a split — the explorer (connections, then the tables or keys of the chosen one)
-- beside the work area (the query editor over its results). Sheets go in the layer: the
-- completion list at the editor's caret, the connection form docked on the right.

local ui = tern.ui
local complete = require("./complete")
local field = require("./field")
local conns = require("./conns")
local model = require("./model")
local sqltext = require("./sqltext")

local view = {}

local ROLE = "databases."

local function keyed(node: Node, key: string, extra: { [string]: any }?): Node
	local p: { [string]: any } = node.p or {}
	p.key = key
	if extra then
		for k, v in extra do
			p[k] = v
		end
	end
	node.p = p
	return node
end

local function text(key: string, spans: { any }): Node
	return keyed(ui.text(spans), key)
end

local function plural(n: number, one: string, many: string?): string
	return tostring(n) .. " " .. (if n == 1 then one else (many or one .. "s"))
end
view.plural = plural

local function ms(n: number?): string
	if not n then
		return ""
	end
	if n < 1000 then
		return string.format("%d ms", math.floor(n + 0.5))
	end
	if n < 60000 then
		return string.format("%.1f s", n / 1000)
	end
	return string.format("%dm %02ds", n // 60000, (n % 60000) // 1000)
end
view.ms = ms

local function grouped(n: number): string
	local s = tostring(math.floor(n))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

-- Head row ----------------------------------------------------------------

local function head(state: model.State, cx: BlockCx): Node
	local c = model.conn(state)
	local narrow = cx.cols < 120
	local spans: { any } = { ui.span("Databases", "title") }
	local right: { Node } = {}
	if c then
		local m = model.meta(state, c.id)
		local server = m.server or (m.schema and m.schema.server) or conns.kind(c.kind).label
		table.insert(spans, ui.span("   " .. c.name, "strong"))
		table.insert(spans, ui.span("   " .. server .. " · " .. conns.detail(c), "muted"))
		-- Trino's USE moved the session: say where the next run starts.
		local session = m.session
		if c.kind == "trino" and session and session.catalog
			and (session.catalog ~= c.catalog or session.schema ~= c.schema) then
			local where = session.catalog .. (if session.schema then "." .. session.schema else "")
			table.insert(right, keyed(ui.badge("in " .. where, "info"), "session"))
		end
		local badge: Node
		if state.run and state.run.conn == c.id then
			badge = ui.badge("Running", "accent")
		elseif m.failure then
			badge = ui.badge("Not connected", "error")
		elseif m.loading then
			badge = ui.badge("Connecting", "pending")
		elseif m.schema or m.keys then
			badge = ui.badge("Connected", "success")
		else
			badge = ui.badge(conns.kind(c.kind).label, "neutral")
		end
		table.insert(right, keyed(badge, "status"))
		table.insert(right, ui.button(if narrow then "" else "Edit", {
			key = "edit", icon = "pen", keys = if narrow then nil else { "f2" }, variant = "quiet", title = "Edit the connection (F2)",
			actions = { click = "edit=" .. c.id },
		}))
	end
	table.insert(right, ui.button(if narrow then "" else "New connection", {
		key = "new", icon = "plus", keys = if narrow then nil else { "shift", "cmd", "n" }, title = "New connection (⇧⌘N)",
		actions = { click = "new" },
	}))
	return ui.node("row", { key = "head", justify = "between", align = "center" }, {
		keyed(ui.text(spans), "title", { truncate = "end" }),
		ui.node("row", { key = "end", gap = "sm", align = "center" }, right),
	})
end

-- Explorer ----------------------------------------------------------------

local function conn_list(state: model.State): Node
	local items: { Node } = {}
	for _, c in state.conns do
		local k = conns.kind(c.kind)
		local m = state.meta[c.id]
		table.insert(items, ui.node("item", {
			key = c.id,
			label = c.name,
			detail = k.label,
			icon = k.icon,
			tone = if m and m.failure then "error" elseif c.id == state.conn then "accent" else nil,
			actions = {
				dblclick = "edit=" .. c.id,
				menu = {
					{ id = "edit=" .. c.id, label = "Edit…", icon = "pen", keys = { "f2" } },
					{ id = "duplicate=" .. c.id, label = "Duplicate", icon = "copy" },
					"-",
					{ id = "delete=" .. c.id, label = "Delete…", icon = "trash", danger = true },
				} :: { any },
			},
		}))
	end
	return ui.node("list", {
		key = "conns",
		selected = if state.conn then model.IDS.conns .. "." .. state.conn else nil,
		empty = { ui.span("No connections yet", "muted") },
	}, items)
end

-- The explorer's objects: tables and views of a SQL database, keys of Redis.
export type Object = { key: string, name: string, schema: string?, kind: string, detail: string?, value: string? }

function view.objects(state: model.State): { Object }
	local c = model.conn(state)
	if not c then
		return {}
	end
	local m = model.meta(state, c.id)
	local q = string.lower(sqltext.trim(state.filter.text))
	local out: { Object } = {}
	if c.kind == "redis" then
		local keys: { complete.RedisKey } = m.keys or {}
		for i, k in keys do
			local ttl = if k.ttl and k.ttl > 0 then (if k.ttl >= 3600000 then string.format("%dh", k.ttl // 3600000)
					elseif k.ttl >= 60000 then string.format("%dm", k.ttl // 60000) else string.format("%ds", k.ttl // 1000))
				else nil
			table.insert(out, { key = "k" .. tostring(i), name = k.key, kind = k.type, detail = k.type, value = ttl })
		end
		return out
	end
	local s = m.schema
	if not s then
		return out
	end
	local default = string.lower(s.default_schema or "")
	for i, t in s.tables do
		local qualified = string.lower((t.schema or "") .. "." .. t.name)
		if q == "" or string.find(qualified, q, 1, true) then
			local shown_schema = if t.schema and string.lower(t.schema) ~= default then t.schema else nil
			table.insert(out, {
				key = "t" .. tostring(i),
				name = t.name,
				schema = t.schema,
				kind = t.kind,
				detail = if shown_schema and t.kind ~= "table" then shown_schema .. " · " .. t.kind
					elseif shown_schema then shown_schema
					elseif t.kind ~= "table" then t.kind
					else nil,
			})
		end
	end
	return out
end

local KIND_ICON: { [string]: string } = {
	table = "grid", view = "eye", ["materialized view"] = "layers", ["foreign table"] = "globe",
	string = "type", hash = "braces", list = "list", set = "tag", zset = "chart", stream = "activity",
}

local function explorer(state: model.State): Node
	local c = model.conn(state)
	local kids: { Node } = { conn_list(state) }
	if not c then
		return ui.node("col", { key = "nav", gap = "md" }, kids)
	end
	local m = model.meta(state, c.id)
	local redis = c.kind == "redis"
	local objects = view.objects(state)
	local count: string
	if redis then
		local total = if m.dbsize then " of " .. grouped(m.dbsize) else ""
		count = plural(#objects, "key") .. total
	else
		count = plural(#objects, "table")
	end
	table.insert(kids, ui.node("row", { key = "objhead", justify = "between", align = "center" }, {
		text("label", { ui.span(if redis then "Keys" else "Tables", "strong"), ui.span("  " .. count, "muted") }),
		ui.button("", {
			key = "refresh", icon = "repeat", size = "sm", variant = "quiet", title = "Load again (⌘R)",
			busy = m.loading, actions = { click = "refresh" },
		}),
	}))
	table.insert(kids, ui.node("input", field.props(state.filter, {
		key = "filter",
		icon = if redis then "funnel" else "search",
		placeholder = if redis then "Match keys: user:*" else "Filter tables",
		clear = true,
		mono = true,
		keys = { "shift", "cmd", "f" },
	})))
	if m.loading and not (m.schema or m.keys) then
		table.insert(kids, ui.node("skeleton", { key = "objects", variant = "rows", rows = 6 }))
	elseif m.failure and not (m.schema or m.keys) then
		table.insert(kids, ui.node("empty", {
			key = "objects",
			variant = "inline",
			tone = "error",
			title = "Couldn't connect",
			text = m.failure.message,
		}, {
			ui.button("Retry", { key = "retry", variant = "quiet", size = "sm", actions = { click = "refresh" } }),
		}))
	else
		local items: { Node } = {}
		for _, o in objects do
			local menu: { any } = if redis
				then { { id = "insert=" .. o.key, label = "Insert into the query", icon = "path-insert" }, { id = "copyname=" .. o.key, label = "Copy key", icon = "copy" } }
				else {
					{ id = "browse=" .. o.key, label = "Show rows", icon = "grid" },
					{ id = "insert=" .. o.key, label = "Insert SELECT into the query", icon = "path-insert" },
					{ id = "count=" .. o.key, label = "Count rows", icon = "hash" },
					{ id = "copyname=" .. o.key, label = "Copy name", icon = "copy" },
				}
			table.insert(items, ui.node("item", {
				key = o.key,
				label = o.name,
				detail = o.detail,
				value = o.value,
				icon = KIND_ICON[o.kind] or (if redis then "key" else "grid"),
				actions = { menu = menu },
			}))
		end
		local empty = if redis and not m.keys then "Press ⌘R to scan keys"
			elseif redis then "No keys match " .. (m.pattern or "*")
			elseif sqltext.trim(state.filter.text) ~= "" then "No table matches"
			else "No tables"
		table.insert(kids, ui.node("list", {
			key = "objects",
			selected = if state.object then model.IDS.objects .. "." .. state.object else nil,
			filter = if redis then nil else sqltext.trim(state.filter.text),
			empty = { ui.span(empty, "muted") },
		}, items))
		if redis and m.keys and not m.keys_complete then
			table.insert(kids, text("more", { ui.span("The scan stopped early: narrow the pattern to see the rest", "muted") }))
		end
		local t = (not redis) and view.table_of(state, state.object) or nil
		if t then
			local cols: { Node } = {}
			for i, col in t.columns do
				local value: { any } = {}
				if col.pk then
					table.insert(value, ui.span("key", "accent"))
				elseif col.notnull then
					table.insert(value, ui.span("not null", "dim"))
				end
				table.insert(cols, ui.node("item", {
					key = "c" .. tostring(i),
					label = col.name,
					detail = { ui.span(col.type or "", "mono") },
					value = value,
					icon = if col.pk then "key" else "columns",
				}))
			end
			table.insert(kids, ui.node("col", { key = "cols", gap = "xs" }, {
				text("colhead", { ui.span(t.name, "strong"), ui.span("  " .. plural(#t.columns, "column"), "muted") }),
				ui.node("list", { key = "columns", empty = { ui.span("No columns", "muted") } }, cols),
			}))
		end
	end
	return ui.node("col", { key = "nav", gap = "md" }, kids)
end

-- The table an explorer object key names.
function view.table_of(state: model.State, key: string?): any
	local c = model.conn(state)
	if not c or not key then
		return nil
	end
	local s = model.meta(state, c.id).schema
	local i = tonumber(string.match(key, "^t(%d+)$"))
	return if s and i then s.tables[i] else nil
end

-- Editor ------------------------------------------------------------------

-- The editor's height in lines of the region's face: its pane's share of the work area, which
-- is about as many lines as the pane has terminal rows, less the head row and the pane's
-- toolbar. A block learns its rows from the window, so a new pane may start smaller.
local function editor_lines(state: model.State, cx: BlockCx): number
	local share = if state.split and state.split[1] then state.split[1] else 0.42
	local page = math.max(12, math.floor(cx.rows * 1.04) - 4)
	return math.max(3, math.floor(page * share) - 4)
end

local function decor_of(state: model.State, dialect: string): { any }
	local out: { any } = {}
	local s = state.editor.text
	for _, r in sqltext.ask_ranges(s, dialect) do
		table.insert(out, { from = field.utf16_of_byte(s, r[1] - 1), to = field.utf16_of_byte(s, r[2]), s = "accent" })
	end
	local mark = state.mark
	if mark then
		table.insert(out, {
			from = field.utf16(s, mark.from),
			to = field.utf16(s, math.max(mark.to, mark.from + 1)),
			s = "error typo",
		})
	end
	return out
end

local function ghost_of(state: model.State): string?
	local p = state.popup
	if not p or p.to ~= state.editor.cur then
		return nil
	end
	local item = p.items[p.sel]
	if not item or (item.back or 0) > 0 then
		return nil
	end
	if string.sub(item.insert, 1, #p.prefix) == p.prefix and #item.insert > #p.prefix then
		return string.sub(item.insert, #p.prefix + 1)
	end
	return nil
end

local function editor(state: model.State, cx: BlockCx): Node
	local c = model.conn(state)
	local dialect = model.dialect(c)
	local redis = dialect == "redis"
	local running = state.run ~= nil
	local asking = state.ask ~= nil
	local info: { any }
	if asking then
		info = {}
	elseif state.note then
		local note = state.note :: { text: string, tone: string }
		info = { ui.span(note.text, note.tone) }
	elseif c then
		info = { ui.span("Query", "strong"), ui.span(if redis then "  one command per line" else "  statements end with ;", "muted") }
	else
		info = { ui.span("Add a connection to run queries", "muted") }
	end
	local left: Node
	if asking then
		local a = state.ask :: model.Ask
		left = ui.node("row", { key = "info", gap = "sm", align = "center" }, {
			ui.node("shimmer", { key = "asking", text = "Asking " .. a.label .. "…" }),
			ui.node("elapsed", { key = "took", age = tern.now() - a.started }),
		})
	else
		left = keyed(ui.text(info), "info", { truncate = "end" })
	end
	local buttons: { Node } = {
		ui.button("Ask agent", {
			key = "ask", icon = "sparkle", keys = { "cmd", "i" }, variant = "quiet",
			busy = asking, disabled = if c then false else "Add a connection first", actions = { click = "ask" },
		}),
	}
	if running then
		table.insert(buttons, ui.button("Cancel", {
			key = "run", icon = "stop", keys = { "cmd", "." }, actions = { click = "cancel" },
		}))
	else
		table.insert(buttons, ui.button("Run", {
			key = "run", icon = "play", keys = { "cmd", "enter" }, variant = "primary",
			disabled = if c then false else "Add a connection first", actions = { click = "run" },
		}))
	end
	local placeholder = if redis
		then "GET user:1 — one command per line; ⌃Space completes, ? asks the agent"
		else "SELECT * FROM … ; ⌃Space completes, a line starting with ? asks the agent"
	local props = field.props(state.editor, {
		key = "sql",
		lang = if redis then nil else "sql",
		placeholder = placeholder,
		decor = decor_of(state, dialect),
		ghost = ghost_of(state),
		maxLines = editor_lines(state, cx),
		min = { h = tostring(editor_lines(state, cx)) .. "lines" },
		aria = "Query",
	})
	return ui.node("col", { key = "edit", gap = "sm" }, {
		ui.node("row", { key = "bar", justify = "between", align = "center" }, {
			left,
			ui.node("row", { key = "end", gap = "sm", align = "center" }, buttons),
		}),
		ui.node("editor", props),
	})
end

-- Results -----------------------------------------------------------------

-- Characters a cell shows at most; the whole value is its tooltip and in the row's card.
local CELL_CHARS = 60

local function cell(v: any): (any, number)
	if v == nil or v == tern.json.null then
		return { ui.span("NULL", "dim") }, 4
	end
	local s = tostring(v)
	local flat = string.gsub(s, "\n", "⏎")
	local width = field.len(flat)
	if width > CELL_CHARS then
		local cut = table.concat(field.chars(flat), "", 1, CELL_CHARS - 1) .. "…"
		return { text = { ui.span(cut) }, title = string.sub(s, 1, 2000) }, CELL_CHARS
	end
	if flat ~= s then
		return { ui.span(flat) }, width
	end
	return s, width
end

type Built = { cols: { any }, rows: { any }, width: number }

-- The cells of each result, built once: the view runs at every key typed in the editor, and a
-- big result is thousands of cells. Weak keys: a result's cells go with it.
local built: { [model.Result]: Built } = setmetatable({}, { __mode = "k" }) :: any

local function build(r: model.Result): Built
	local hit = built[r]
	if hit then
		return hit
	end
	local cols: { any } = { { id = "n", head = "#", align = "end", mono = true } }
	local columns: { model.Column } = r.columns or {}
	local widths: { number } = {}
	for i, col in columns do
		widths[i] = math.min(field.len(col.name), CELL_CHARS)
		table.insert(cols, {
			id = "c" .. tostring(i),
			head = col.name,
			align = if col.num then "end" else nil,
			mono = true,
		})
	end
	local rows: { any } = {}
	local data: { { any } } = r.rows or {}
	for i, row in data do
		local cells: { [string]: any } = { n = { ui.span(tostring(i), "dim") } }
		for j = 1, #columns do
			local value, width = cell(row[j])
			cells["c" .. tostring(j)] = value
			if width > widths[j] then
				widths[j] = width
			end
		end
		table.insert(rows, { id = "r" .. tostring(i), cells = cells })
	end
	local total = #tostring(#data) + 3
	for _, w in widths do
		total += w + 3
	end
	local out: Built = { cols = cols, rows = rows, width = total }
	built[r] = out
	return out
end

-- A result table. Tern hides the columns a table can't fit; a result keeps them all: the table
-- is at least as wide as its columns (cells cut at CELL_CHARS), and its pane scrolls sideways.
local function grid(state: model.State, r: model.Result): Node
	local b = build(r)
	return ui.node("table", {
		key = "table",
		cols = b.cols,
		rows = b.rows,
		selectable = true,
		selected = state.row,
		empty = { ui.span("No rows", "muted") },
		min = { w = tostring(b.width) .. "ch" },
	})
end

local function row_card(state: model.State, r: model.Result): Node?
	local i = tonumber(string.match(state.row or "", "^r(%d+)$"))
	local row = if i and r.rows then r.rows[i] else nil
	if not row then
		return nil
	end
	local pairs: { { any } } = {}
	local columns: { model.Column } = r.columns or {}
	for j, col in columns do
		local v = row[j]
		local value: any = if v == nil or v == tern.json.null then { ui.span("NULL", "dim") } else { ui.span(tostring(v), "mono") }
		table.insert(pairs, { { ui.span(col.name) }, value })
	end
	return ui.card("Row " .. tostring(i), {
		ui.button("", { key = "end", icon = "x", size = "sm", variant = "quiet", title = "Close (Esc)", actions = { click = "unrow" } }),
		keyed(ui.kv(pairs), "kv"),
		ui.node("row", { key = "acts", gap = "sm" }, {
			ui.button("Copy as JSON", { key = "json", size = "sm", icon = "copy", actions = { click = "copyrow=json" } }),
			ui.button("Copy values", { key = "tsv", size = "sm", actions = { click = "copyrow=tsv" } }),
		}),
	}, { key = "row", icon = "list", meta = plural(#(r.columns or {}), "column"), ["end"] = model.IDS.results .. ".body.row.end",
		min = { w = "36ch" }, max = { w = "56ch" } })
end

local function failure_card(f: model.Failure, outcome: model.Outcome): Node
	local lines: { string } = { f.message }
	if f.detail and f.detail ~= "" then
		table.insert(lines, f.detail)
	end
	if f.where and f.where ~= "" then
		table.insert(lines, f.where)
	end
	local cancelled = f.code == "cancelled" or f.code == "57014"
	local meta: string? = nil
	if f.statement and #outcome.statements > 1 then
		meta = "statement " .. tostring(f.statement + 1) .. " of " .. tostring(#outcome.statements)
	end
	if f.code and not cancelled then
		meta = (if meta then meta .. " · " else "") .. f.code
	end
	local kids: { Node } = {}
	if not cancelled then
		table.insert(kids, ui.button("Ask agent to fix", {
			key = "end", icon = "sparkle", size = "sm", keys = { "cmd", "shift", "i" }, actions = { click = "fix" },
		}))
	end
	table.insert(kids, keyed(ui.code(table.concat(lines, "\n")), "message"))
	if f.hint and f.hint ~= "" then
		table.insert(kids, text("hint", { ui.span("Hint: ", "strong"), ui.span(f.hint, "muted") }))
	end
	return ui.card(if cancelled then "Cancelled" else "The query failed", kids, {
		key = "fail", icon = if cancelled then "stop" else "warn", tone = if cancelled then nil else "error", meta = meta,
		["end"] = if cancelled then nil else model.IDS.results .. ".fail.end",
	})
end

local function summary(r: model.Result): string
	if r.error then
		return (r.command or "Command") .. " failed"
	end
	if r.columns then
		local n = r.count or #(r.rows or {})
		local s = plural(n, "row")
		if r.truncated then
			s = "first " .. s
		end
		return s
	end
	if r.text then
		return r.command or "Reply"
	end
	return r.command or "Done"
end

-- How to pick one of several results: a segmented strip for a few, a menu (each reply's text
-- beside its command) for a script's many.
local function result_tabs(outcome: model.Outcome, active: number): Node?
	local n = #outcome.results
	if n < 2 then
		return nil
	end
	local function word(r: model.Result): string
		return if r.command then string.match(r.command, "^(%S+)") or r.command else "Result"
	end
	if n <= 4 then
		local items: { any } = {}
		for i, r in outcome.results do
			items[i] = { id = tostring(i), label = { ui.span(tostring(i) .. " "), ui.span(word(r), if r.error then "error" else "muted") } }
		end
		return ui.node("tabs", { key = "tabs", variant = "segmented", active = tostring(active), items = items })
	end
	local options: { any } = {}
	for i, r in outcome.results do
		local detail = if r.error then "error"
			elseif r.text then string.sub((string.gsub(r.text, "%s+", " ")), 1, 24)
			elseif r.columns then plural(r.count or #(r.rows or {}), "row")
			else nil
		options[i] = { value = tostring(i), label = tostring(i) .. " · " .. word(r), detail = detail }
	end
	return ui.node("select", {
		key = "tabs", variant = "quiet", size = "sm", label = "Result", value = tostring(active), options = options,
	})
end

-- The results pane's content, keyed "grid": the failure (if any), then the chosen result
-- ("body"), then notices. A rows result is a row of the table and, for a picked row, its card.
local function result_view(state: model.State, outcome: model.Outcome): Node
	local kids: { Node } = {}
	if outcome.failure then
		table.insert(kids, failure_card(outcome.failure, outcome))
	end
	local r = outcome.results[state.result] or outcome.results[#outcome.results]
	if not r then
		if not outcome.failure then
			table.insert(kids, ui.node("empty", { key = "body", variant = "inline", icon = "check", title = "Done",
				text = ms(outcome.elapsed_ms) }))
		end
		return ui.node("col", { key = "grid", gap = "md" }, kids)
	end
	if r.error then
		table.insert(kids, ui.node("empty", { key = "body", variant = "inline", tone = "error", icon = "warn",
			title = r.command or "Error", text = r.error }))
	elseif r.columns then
		local row: { Node } = { ui.node("col", { key = "list", grow = 1, basis = 0 }, { grid(state, r) }) }
		local card = row_card(state, r)
		if card then
			table.insert(row, card)
		end
		table.insert(kids, ui.node("row", { key = "body", gap = "lg", align = "stretch" }, row))
	elseif r.text then
		table.insert(kids, keyed(ui.code(r.text), "body"))
	else
		table.insert(kids, ui.node("empty", { key = "body", variant = "inline", icon = "check", title = r.command or "Done",
			text = if r.count then plural(r.count, "row") .. " · " .. ms(r.elapsed_ms) else ms(r.elapsed_ms) }))
	end
	local notes: { string } = {}
	local own: { string } = r.notices or {}
	for _, n in own do
		table.insert(notes, n)
	end
	local shared: { string } = outcome.notices or {}
	for _, n in shared do
		table.insert(notes, n)
	end
	if #notes > 0 then
		table.insert(kids, text("notices", { ui.span(table.concat(notes, "\n"), "muted") }))
	end
	return ui.node("col", { key = "grid", gap = "md" }, kids)
end

local function results(state: model.State): Node
	local c = model.conn(state)
	local m = if c then model.meta(state, c.id) else nil
	local outcome = if m then m.outcome else nil
	local left: Node
	local right: { Node } = {}
	local content: Node
	local run = state.run
	if run and c and run.conn == c.id then
		left = ui.node("row", { key = "info", gap = "sm", align = "center" }, {
			ui.node("shimmer", { key = "running", text = "Running " .. run.title }),
			ui.node("elapsed", { key = "took", age = tern.now() - run.started }),
		})
		content = ui.node("skeleton", { key = "grid", variant = "rows", rows = 5 })
	elseif outcome then
		local r = outcome.results[state.result] or outcome.results[#outcome.results]
		local spans: { any } = { ui.span(if outcome.source == "run" then "Results" else outcome.title, "strong") }
		if r then
			table.insert(spans, ui.span("  " .. summary(r), "muted"))
			local took = r.elapsed_ms or outcome.elapsed_ms
			if took then
				table.insert(spans, ui.span(" · " .. ms(took), "muted"))
			end
		end
		left = keyed(ui.text(spans), "info", { truncate = "end" })
		local tabs = result_tabs(outcome, state.result)
		if tabs then
			table.insert(right, tabs)
		end
		if r and r.columns and #(r.rows or {}) > 0 then
			table.insert(right, ui.node("menu", {
				key = "copy", text = "Copy", icon = "copy", size = "sm", trigger = "quiet", align = "end",
				items = {
					{ id = "copy=csv", label = "As CSV" },
					{ id = "copy=tsv", label = "As TSV (paste into a spreadsheet)" },
					{ id = "copy=json", label = "As JSON" },
					{ id = "copy=markdown", label = "As a Markdown table" },
				},
			}))
		end
		content = result_view(state, outcome)
	else
		left = keyed(ui.text({ ui.span("Results", "strong"), ui.span(if c and c.kind == "redis"
			then "  ⌘↵ runs the command block at the caret, ⌥⌘↵ every line"
			else "  ⌘↵ runs the statement at the caret, ⌥⌘↵ the whole editor", "muted") }), "info", { truncate = "end" })
		content = text("grid", { ui.span(if c and c.kind == "redis" then "Pick a key to see its value." else "Double-click a table to see its rows.", "dim") })
	end
	local limits: { any } = {}
	for _, n in model.MAX_ROWS do
		table.insert(limits, { value = tostring(n), label = grouped(n) })
	end
	table.insert(right, ui.node("select", {
		key = "limit", variant = "quiet", size = "sm", label = "Limit", value = tostring(state.max_rows), options = limits,
	}))
	return ui.node("col", { key = "out", gap = "sm" }, {
		ui.node("row", { key = "bar", justify = "between", align = "center" }, {
			left,
			ui.node("row", { key = "end", gap = "sm", align = "center" }, right),
		}),
		content,
	})
end

-- Page --------------------------------------------------------------------

local function welcome(): Node
	return ui.node("empty", {
		key = "ws",
		icon = "database",
		title = "No connections yet",
		text = "Add PostgreSQL, SQLite, Trino or Redis. Passwords go to the system keychain, never into files.",
		grow = 1,
	}, {
		ui.button("New connection", { key = "new", variant = "primary", icon = "plus", keys = { "shift", "cmd", "n" }, actions = { click = "new" } }),
	})
end

local LEGEND: { { string } } = {
	{ "⌘↵", "run" }, { "⌥⌘↵", "run all" }, { "⌘.", "cancel" }, { "⌘I", "ask agent" }, { "⌃Space", "complete" },
	{ "⌘/", "comment" }, { "⌥↑↓", "connection" }, { "⌘R", "reload" }, { "⇧⌘F", "filter" },
}
local POPUP_LEGEND: { { string } } = { { "↑↓", "choose" }, { "⇥ ↵", "insert" }, { "Esc", "close" } }

local function legend(state: model.State): Node
	local spans: { any } = {}
	local entries: { { string } } = if state.popup then POPUP_LEGEND else LEGEND
	for _, entry in entries do
		table.insert(spans, ui.span(entry[1], "key"))
		table.insert(spans, ui.span(" " .. entry[2] .. "   ", "muted"))
	end
	return text("keys", spans)
end

local KIND_GLYPH: { [string]: string } = {
	column = "columns", table = "grid", view = "eye", schema = "folder", keyword = "tag", ["function"] = "braces",
	alias = "link", command = "terminal", key = "key",
}

local function popup(state: model.State): Node?
	local p = state.popup
	if not p or state.focus ~= "editor" then
		return nil
	end
	local items: { Node } = {}
	for i, it in p.items do
		table.insert(items, ui.node("item", {
			key = "i" .. tostring(i),
			label = it.label,
			detail = it.detail,
			icon = KIND_GLYPH[it.kind] or "tag",
			tone = if it.kind == "column" then "accent" elseif it.kind == "keyword" then "muted" else nil,
		}))
	end
	return ui.node("overlay", { key = "complete", anchor = { caret = model.IDS.editor }, size = "md", role = ROLE .. "complete" }, {
		ui.node("list", {
			key = "items",
			selected = model.IDS.popup .. ".i" .. tostring(p.sel),
			filter = p.prefix,
			max = { lines = 9 },
		}, items),
	})
end

-- Connection form ---------------------------------------------------------

local LABELS: { [string]: string } = {
	name = "Name", host = "Host", port = "Port", database = "Database", user = "User", password = "Password",
	path = "Database file", catalog = "Catalog", schema = "Schema", db = "Database number",
}

local function form_view(state: model.State): Node
	local f = state.form :: model.Form
	local kind = conns.kind(f.kind)
	local kids: { Node } = {
		ui.button("", { key = "close", icon = "x", size = "sm", variant = "quiet", title = "Close (Esc)", actions = { click = "form-close" } }),
	}
	local kinds: { any } = {}
	for _, k in conns.KINDS do
		table.insert(kinds, { id = k.id, label = k.label })
	end
	table.insert(kids, ui.node("tabs", { key = "kind", variant = "segmented", active = f.kind, items = kinds }))
	local function input(name: string, extra: { [string]: any }): Node
		local p: { [string]: any } = { key = "in", mono = name ~= "name", aria = LABELS[name] }
		for k, v in extra do
			p[k] = v
		end
		return ui.node("input", field.props(f.fields[name], p))
	end
	for _, name in kind.fields do
		local hint: string? = nil
		local extra: { [string]: any } = {}
		if name == "name" then
			extra.placeholder = "prod, analytics, local cache…"
		elseif name == "host" then
			extra.placeholder = "localhost"
			hint = "Or paste a URL: " .. (if f.kind == "postgres" then "postgres://user@host:5432/db"
				elseif f.kind == "redis" then "redis://:password@host:6379/0"
				else "trino://user@host:443/catalog/schema")
		elseif name == "port" then
			extra.placeholder = tostring(if f.kind == "trino" and f.tls then 443 else kind.port)
		elseif name == "database" then
			extra.placeholder = "the user's name"
		elseif name == "user" then
			extra.placeholder = if f.kind == "redis" then "default" elseif f.kind == "trino" then "tern" else (tern.getenv("USER") or "")
			if f.kind == "redis" then
				hint = "Only for Redis 6 ACL users"
			end
		elseif name == "password" then
			extra.secret = true
			-- window.luau finds the typed password by this role to store it.
			extra.role = ROLE .. "password"
			extra.placeholder = if f.forget then "Removed when you save"
				elseif f.stored then "Stored in the keychain: type to replace it"
				else "None"
			hint = if f.kind == "trino"
				then "Kept in the system keychain, never in Tern's files; Trino takes it only over HTTPS"
				else "Kept in the system keychain, never in Tern's files"
		elseif name == "path" then
			extra.placeholder = "~/data/app.db"
			hint = "An existing SQLite file"
		elseif name == "catalog" then
			extra.placeholder = "hive, iceberg, tpch…"
		elseif name == "schema" then
			extra.placeholder = "optional"
		elseif name == "db" then
			extra.placeholder = "0"
		end
		if name == "sslmode" then
			local modes: { any } = {}
			for _, mode in conns.SSLMODES do
				table.insert(modes, { id = mode, label = mode })
			end
			table.insert(kids, ui.node("field", {
				key = "f_sslmode",
				label = "SSL",
				hint = if f.sslmode == "prefer" then "Encrypts when the server offers it"
					elseif f.sslmode == "require" then "Encrypts and doesn't check the certificate"
					elseif f.sslmode == "verify-full" then "Encrypts and checks the certificate and host name"
					else "Never encrypts",
			}, {
				ui.node("tabs", { key = "in", variant = "segmented", active = f.sslmode, items = modes }),
			}))
		elseif name == "tls" then
			table.insert(kids, ui.node("switch", {
				key = "f_tls",
				label = if f.kind == "trino" then "HTTPS" else "TLS",
				hint = if f.kind == "trino" then "Needed for a password" else "rediss://, as cloud Redis services need",
				on = f.tls,
			}))
			if f.tls then
				table.insert(kids, ui.node("switch", {
					key = "f_verify",
					label = "Check the certificate",
					hint = "Turn off only for a self-signed certificate on a network you trust",
					on = not f.insecure,
				}))
			end
		else
			local row: { Node } = { input(name, extra) }
			if name == "password" and f.stored and not f.forget then
				table.insert(row, ui.button("Remove", { key = "forget", size = "sm", variant = "quiet", actions = { click = "form-forget" } }))
			end
			table.insert(kids, ui.node("field", {
				key = "f_" .. name,
				label = LABELS[name] or name,
				hint = hint,
				error = if f.bad == name then f.error else nil,
				required = name == "name" or name == "path",
			}, row))
		end
	end
	if f.test then
		local t = f.test :: { ok: boolean, text: string }
		table.insert(kids, ui.node("empty", {
			key = "test", variant = "inline", frame = true,
			icon = if t.ok then "check" else "warn", tone = if t.ok then nil else "error",
			title = if t.ok then "Connected" else "Couldn't connect", text = t.text,
		}))
	elseif f.error and not f.bad then
		table.insert(kids, ui.node("empty", {
			key = "test", variant = "inline", frame = true, icon = "warn", tone = "error", title = "Not saved", text = f.error,
		}))
	end
	if f.confirm_delete then
		local name = sqltext.trim(f.fields.name.text)
		table.insert(kids, ui.card("Delete " .. (if name ~= "" then name else "this connection") .. "?", {
			ui.node("row", { key = "end", gap = "sm" }, {
				ui.button("Cancel", { key = "cancel", variant = "quiet", size = "sm", keys = { "esc" }, actions = { click = "form-undelete" } }),
				ui.button("Delete", { key = "go", variant = "danger", size = "sm", keys = { "enter" }, actions = { click = "form-delete-confirm" } }),
			}),
			text("why", { ui.span("It goes from every Databases block, and its password from the keychain.", "muted") }),
		}, { key = "confirm", tone = "error", icon = "trash", ["end"] = model.IDS.form .. ".confirm.end" }))
	end
	local left: { Node } = {}
	if f.id and not f.confirm_delete then
		table.insert(left, ui.button("Delete…", { key = "delete", variant = "danger", actions = { click = "form-delete" } }))
	end
	local foot = ui.node("row", { key = "foot", justify = "between", align = "center" }, {
		ui.node("row", { key = "left", gap = "sm" }, left),
		ui.node("row", { key = "right", gap = "sm" }, {
			ui.button("Test", { key = "test", icon = "plug", busy = f.busy == "test", actions = { click = "form-test" } }),
			ui.button(if f.id then "Save" else "Add connection", {
				key = "save", variant = "primary", keys = { "cmd", "enter" }, busy = f.busy == "save", actions = { click = "form-save" },
			}),
		}),
	})
	table.insert(kids, foot)
	return ui.node("overlay", {
		key = "form",
		side = "right",
		modal = true,
		size = "md",
		icon = kind.icon,
		head = if f.id then "Edit connection" else "New connection",
		meta = kind.label,
		["end"] = model.IDS.form .. ".close",
		foot = model.IDS.form .. ".foot",
		role = ROLE .. "form",
	}, kids)
end

function view.view(state: model.State, cx: BlockCx): BlockView
	local body: Node
	if #state.conns == 0 then
		body = welcome()
	else
		body = ui.node("split", {
			key = "ws",
			sizes = state.sizes or { 0.26, 0.74 },
			min = { "24ch", "44ch" },
			-- databases.css makes it fill the pane under the head row.
			grow = 1,
		}, {
			explorer(state),
			ui.node("split", {
				key = "work",
				dir = "col",
				sizes = state.split or { 0.42, 0.58 },
				min = { "5lines", "6lines" },
				grow = 1,
			}, { editor(state, cx), results(state) }),
		})
	end
	local layer: Node? = nil
	if state.form then
		layer = ui.col({ form_view(state) })
	else
		local p = popup(state)
		if p then
			layer = ui.col({ p })
		end
	end
	return {
		main = ui.node("col", { gap = "md", grow = 1, role = ROLE .. "page" }, { head(state, cx), body }),
		dock = ui.col({ legend(state) }),
		layer = layer,
	}
end

return view
