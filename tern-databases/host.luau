--!strict
-- Block `databases.console`: saved connections to PostgreSQL, SQLite, Trino and Redis, an
-- explorer of the chosen one's tables (or keys), a query editor with completion, and results.
--
-- Connections are in tern.kv "connections" without their passwords; each password is in the
-- system keychain (plugin secret "conn.<id>"), which only window halves reach: this block asks
-- window.luau over "databases:" links (link.luau) and keeps what it gets in memory, never in
-- its saved state. Queries run in the bundled Python driver (drivers/tdb.py), one process per
-- run, the password on its stdin.
--
-- Keys: ⌘↵ runs the statement at the caret (a Redis block of lines), ⌥⌘↵ the whole editor,
-- ⌘. cancels; ⌃Space completes (typing opens the list on its own), ↑↓ choose, ⇥/↵ insert;
-- ⌘I asks the session's agent for the query a `? …` line describes (⇧⌘I to fix the error
-- shown); ⌘/ comments lines; ⇥/⇧⇥ indent; ⌥↑↓ switch connection; ⇧⌘N new connection, F2 edit
-- it; ⌘R loads the tables or keys again; ⇧⌘F filters them.

local field = require("./field")
local conns = require("./conns")
local complete = require("./complete")
local driver = require("./driver")
local sqltext = require("./sqltext")
local link = require("./link")
local model = require("./model")
local view = require("./view")
local ask = require("./ask")

type State = model.State
type Conn = conns.Conn

local IDS = model.IDS
-- A run may take this long; the driver cancels it at the limit.
local RUN_MS = 30 * 60 * 1000
local SCHEMA_MS = 90 * 1000
local TEST_MS = 20 * 1000
-- How long the block waits for the window to read the keychain (it may show an unlock prompt).
local SECRET_WAIT_MS = 60 * 1000
local ASK_WAIT_MS = 30 * 60 * 1000
local KEYS_LIMIT = 1000
local WATCH_MS = 3000
local FIELDS = { "name", "host", "port", "database", "user", "password", "path", "catalog", "schema", "db" }

-- Passwords from the keychain (through a window) or typed in the form, by connection id, for
-- every block of this worker. Memory only: never saved, never in a view.
local SECRETS: { [string]: string } = {}

-- The block's functions, as fields of one table: the chunk stays under Luau's 200 locals.
local M = {}

function M.alive(state: State): boolean
	if not state.alive then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	state.alive = false
	return false
end

function M.set_focus(state: State, focus: string)
	state.focus = focus
	local id: any = tern.json.null
	if focus == "editor" then
		id = IDS.editor
	elseif focus == "filter" then
		id = IDS.filter
	elseif focus == "form" and state.form then
		id = model.form_input((state.form :: model.Form).focus)
	end
	if focus ~= "editor" then
		state.popup = nil
	end
	state.cx:frame({ { "focus", id } })
end

-- Window requests ---------------------------------------------------------------

-- Asks the window for `op`; `done(data, err)` runs with its answer, or with an error when no
-- window answers within `wait_ms`. Returns the request number.
function M.request(state: State, op: string, query: { [string]: string | number }, wait_ms: number,
	done: (data: any?, err: string?) -> ()): number
	state.req += 1
	local req = state.req
	query.req = req
	query.pane = state.cx.pane
	state.pending[req] = { op = op, at = tern.now(), done = done }
	state.cx:open(link.build(op, query))
	tern.timer(wait_ms, function(_cx: WindowCx?)
		local p = state.pending[req]
		if p and M.alive(state) then
			state.pending[req] = nil
			p.done(nil, "no Tern window answered (is the block open in one?)")
			state.cx:render()
		end
	end)
	return req
end

function M.answer(state: State, data: any)
	if type(data) ~= "table" then
		return
	end
	local req = tonumber(data.req)
	local p = if req then state.pending[req] else nil
	if not p then
		return
	end
	if data.progress then
		local a = state.ask
		if a and a.req == req and type(data.label) == "string" then
			a.label = data.label
		end
		return
	end
	state.pending[req :: number] = nil
	p.done(data, if type(data.error) == "string" and data.error ~= "" then data.error else nil)
end

-- The password of `c`, from memory or (through the window) the keychain.
function M.with_secret(state: State, c: Conn, fn: (secret: string?, err: string?) -> ())
	if not c.secret then
		fn(nil, nil)
		return
	end
	local known = SECRETS[c.id]
	if known then
		fn(known, nil)
		return
	end
	M.request(state, "secret", { conn = c.id }, SECRET_WAIT_MS, function(data: any?, err: string?)
		if err then
			fn(nil, "Couldn't read the password from the keychain: " .. err)
			return
		end
		local secret = if data and type(data.secret) == "string" and data.secret ~= "" then data.secret else nil
		if secret then
			SECRETS[c.id] = secret
		end
		fn(secret, nil)
	end)
end

-- Driver -----------------------------------------------------------------------

local function failure_of(answer: any, err: string?): model.Failure
	if err then
		return { message = err }
	end
	local e = if type(answer) == "table" and type(answer.error) == "table" then answer.error else {}
	local f: model.Failure = { message = if type(e.message) == "string" then e.message else "The driver gave no answer" }
	for _, k in { "detail", "hint", "code", "where" } do
		if type(e[k]) == "string" and e[k] ~= "" then
			(f :: any)[k] = e[k]
		end
	end
	for _, k in { "position", "statement", "line", "column" } do
		if type(e[k]) == "number" then
			(f :: any)[k] = e[k]
		end
	end
	return f
end
M.failure_of = failure_of

-- A refused login: the stored password may be stale, so read the keychain again next time.
local function auth_failed(f: model.Failure?): boolean
	if not f then
		return false
	end
	return f.code == "28P01" or string.find(f.message, "WRONGPASS", 1, true) ~= nil
		or string.find(f.message, "refused the user or password", 1, true) ~= nil
		or string.find(f.message, "refused the login", 1, true) ~= nil
end

type Job = model.Job

-- Runs `req` against `c` with its password; `done(answer, err)` runs when it ends.
function M.call(state: State, c: Conn, req: { [string]: any }, timeout: number, job: Job,
	done: (answer: any?, err: string?) -> ())
	M.with_secret(state, c, function(secret: string?, err: string?)
		if not M.alive(state) then
			return
		end
		if err then
			done(nil, err)
			state.cx:render()
			return
		end
		if job.cancelled then
			done(nil, "Cancelled")
			state.cx:render()
			return
		end
		req.conn = conns.wire(c)
		req.password = secret
		job.handle = driver.start(req, timeout, function(answer: any, derr: string?)
			if not M.alive(state) then
				return
			end
			if type(answer) == "table" and not answer.ok and auth_failed(failure_of(answer, nil)) then
				SECRETS[c.id] = nil
			end
			done(answer, derr)
			state.cx:render()
		end)
	end)
end

-- Explorer ---------------------------------------------------------------------

-- The SCAN pattern the Redis filter asks for: a glob as typed, else keys containing it.
function M.pattern(state: State): string
	local q = sqltext.trim(state.filter.text)
	if q == "" then
		return "*"
	end
	if string.find(q, "[%*%?%[]") then
		return q
	end
	return "*" .. q .. "*"
end

-- Loads the tables (SQL) or keys (Redis) of `c` unless they are there (`force` again).
function M.load(state: State, c: Conn, force: boolean)
	local m = model.meta(state, c.id)
	if m.loading or (not force and (m.schema or m.keys or m.failure)) then
		return
	end
	m.loading, m.failure = true, nil
	local redis = c.kind == "redis"
	local req: { [string]: any } = { op = if redis then "keys" else "schema" }
	if redis then
		req.pattern, req.limit = M.pattern(state), KEYS_LIMIT
	end
	if c.kind == "trino" and m.session then
		req.session = m.session
	end
	M.call(state, c, req, SCHEMA_MS, { cancelled = false }, function(answer: any?, err: string?)
		m.loading = false
		if err or type(answer) ~= "table" or not answer.ok then
			m.failure = failure_of(answer, err)
			return
		end
		if type(answer.schema) == "table" then
			local s = answer.schema :: complete.Schema
			s.tables = s.tables or {}
			s.schemas = s.schemas or {}
			s.functions = s.functions or {}
			complete.index(s)
			m.schema = s
			m.server = s.server or m.server
		end
		if type(answer.keys) == "table" then
			m.keys = answer.keys.keys or {}
			m.keys_complete = answer.keys.complete == true
			m.dbsize = tonumber(answer.keys.dbsize)
			m.pattern = answer.keys.pattern
			m.server = if type(answer.keys.server) == "string" then answer.keys.server else m.server
		end
		if state.object and redis and m.keys then
			state.object = nil
		end
	end)
end

function M.select_conn(state: State, id: string?)
	if id == state.conn then
		return
	end
	if state.conn then
		state.drafts[state.conn] = state.editor.text
	end
	state.conn = id
	field.reset(state.editor, if id then state.drafts[id] or "" else "")
	state.popup, state.object, state.row, state.mark, state.note = nil, nil, nil, nil, nil
	state.result = 1
	field.reset(state.filter, "")
	local c = model.conn(state)
	if c then
		M.load(state, c, false)
	end
end

function M.step_conn(state: State, step: number)
	local n = #state.conns
	if n == 0 then
		return
	end
	local at = 1
	for i, c in state.conns do
		if c.id == state.conn then
			at = i
		end
	end
	M.select_conn(state, state.conns[(at - 1 + step) % n + 1].id)
end

-- The name a table is written by in a query.
function M.table_name(state: State, t: complete.Table): string
	local c = model.conn(state)
	local dialect = model.dialect(c)
	local name = complete.quote_name(t.name, dialect)
	local s = if c then model.meta(state, c.id).schema else nil
	if t.schema and t.schema ~= "" and s and string.lower(t.schema) ~= string.lower(s.default_schema or "") then
		name = complete.quote_name(t.schema, dialect) .. "." .. name
	end
	return name
end

-- The editor's text grows by `text` as a new statement (or line) at its end, the caret after it.
function M.append(state: State, text: string)
	local f = state.editor
	local n = field.len(f.text)
	local sep = if sqltext.trim(f.text) == "" then "" elseif string.sub(f.text, -1) == "\n" then "\n" else "\n\n"
	if sqltext.trim(f.text) == "" then
		field.set(f, text)
	else
		field.replace(f, n, n, sep .. text, false)
	end
	state.popup, state.mark = nil, nil
end

function M.object_action(state: State, act: string, key: string)
	local c = model.conn(state)
	if not c then
		return
	end
	if c.kind == "redis" then
		local i = tonumber(string.match(key, "^k(%d+)$"))
		local k = if i then (model.meta(state, c.id).keys or {})[i] else nil
		if not k then
			return
		end
		if act == "value" then
			state.object = key
			M.value(state, c, k.key)
		elseif act == "insert" then
			local word = if string.find(k.key, "[%s\"']") then '"' .. string.gsub(k.key, '["\\]', "\\%0") .. '"' else k.key
			local f = state.editor
			local lo, hi = field.bounds(f)
			field.replace(f, lo, hi, word, false)
			M.set_focus(state, "editor")
		elseif act == "copyname" then
			state.cx:copy(k.key)
		end
		return
	end
	local t = view.table_of(state, key)
	if not t then
		return
	end
	local name = M.table_name(state, t)
	if act == "browse" then
		state.object = key
		-- One row past the limit, so the results say when there are more.
		M.execute(state, c, { "SELECT * FROM " .. name .. " LIMIT " .. tostring(state.max_rows + 1) }, nil, "browse", t.name)
	elseif act == "count" then
		M.execute(state, c, { "SELECT count(*) FROM " .. name }, nil, "browse", t.name)
	elseif act == "insert" then
		M.append(state, "SELECT *\nFROM " .. name .. "\nLIMIT 100;")
		M.set_focus(state, "editor")
	elseif act == "copyname" then
		state.cx:copy(name)
	end
end

-- A Redis key's value in the results pane.
function M.value(state: State, c: Conn, key: string)
	if state.run then
		state.cx:toast("info", "A query is running", "Cancel it with ⌘. first")
		return
	end
	local m = model.meta(state, c.id)
	local job: Job = { cancelled = false }
	local run: model.Run = { job = job, started = tern.now(), conn = c.id, title = key, count = 1 }
	state.run = run
	state.row, state.result = nil, 1
	M.call(state, c, { op = "value", key = key }, SCHEMA_MS, job, function(answer: any?, err: string?)
		if state.run == run then
			state.run = nil
		end
		local ok = type(answer) == "table" and answer.ok
		local meta = if ok and type((answer :: any).value) == "table" then (answer :: any).value else nil
		local title = key
		if meta then
			local parts: { string } = { tostring(meta.type) }
			if type(meta.length) == "number" then
				table.insert(parts, view.plural(meta.length, if meta.type == "string" then "byte" else "item"))
			end
			if type(meta.ttl) == "number" and meta.ttl > 0 then
				table.insert(parts, "expires in " .. view.ms(meta.ttl))
			end
			title = key .. "  ·  " .. table.concat(parts, " · ")
		end
		m.outcome = {
			source = "value",
			title = title,
			statements = {},
			results = if ok then (answer :: any).results or {} else {},
			failure = if ok then nil else failure_of(answer, err),
			elapsed_ms = if type(answer) == "table" then answer.elapsed_ms else nil,
			value = meta,
		}
	end)
end

-- Running ----------------------------------------------------------------------

local DDL: { [string]: boolean } = { CREATE = true, ALTER = true, DROP = true, RENAME = true, TRUNCATE = true, COMMENT = true }

-- Runs `statements` of `c` and shows what they return. `starts` are their editor offsets.
function M.execute(state: State, c: Conn, statements: { string }, starts: { number }?, source: string, title: string)
	if state.run then
		state.cx:toast("info", "A query is running", "Cancel it with ⌘. first")
		return
	end
	local m = model.meta(state, c.id)
	local job: Job = { cancelled = false }
	local run: model.Run = { job = job, started = tern.now(), conn = c.id, title = title, count = #statements }
	state.run = run
	state.mark, state.row, state.result, state.note = nil, nil, 1, nil
	local req: { [string]: any } = { op = "run", statements = statements, max_rows = state.max_rows }
	if c.kind == "trino" and m.session then
		req.session = m.session
	end
	M.call(state, c, req, RUN_MS, job, function(answer: any?, err: string?)
		if state.run == run then
			state.run = nil
		end
		local a: any = if type(answer) == "table" then answer else {}
		local outcome: model.Outcome = {
			source = source,
			title = title,
			statements = statements,
			starts = starts,
			results = if type(a.results) == "table" then a.results else {},
			failure = if err or a.ok == false or answer == nil then failure_of(answer, err) else nil,
			notices = a.notices,
			elapsed_ms = a.elapsed_ms,
		}
		m.outcome = outcome
		if type(a.server) == "string" then
			m.server = a.server
		end
		if type(a.session) == "table" then
			m.session = a.session
		end
		-- Show the last result that has rows (a script's final SELECT), else the last one.
		state.result = math.max(1, #outcome.results)
		for i = #outcome.results, 1, -1 do
			if outcome.results[i].columns then
				state.result = i
				break
			end
		end
		if source == "run" and outcome.failure then
			state.mark = M.mark_of(state, outcome)
		end
		local changed = false
		for _, s in statements do
			local word = string.upper(string.match(s, "^%s*(%a+)") or "")
			if DDL[word] or (c.kind == "trino" and word == "USE") then
				changed = true
			end
		end
		if changed and c.kind ~= "redis" then
			M.load(state, c, true)
		end
	end)
end

-- Where in the editor the error points: the word at PostgreSQL's position, Trino's line and
-- column, or what SQLite's `near "…"` quotes; nil when the editor no longer holds the statement.
function M.mark_of(state: State, outcome: model.Outcome): { from: number, to: number }?
	local f = outcome.failure
	if not f then
		return nil
	end
	local i = (f.statement or 0) + 1
	local stmt = outcome.statements[i]
	local start = if outcome.starts then outcome.starts[i] else nil
	local text = state.editor.text
	if not stmt or not start or string.sub(text, start, start + #stmt - 1) ~= stmt then
		return nil
	end
	local off: number? = nil
	if f.position then
		off = field.byte(stmt, f.position - 1)
	elseif f.line and f.column then
		local line, at = 1, 1
		while line < f.line do
			local nl = string.find(stmt, "\n", at, true)
			if not nl then
				break
			end
			at, line = nl + 1, line + 1
		end
		off = at - 1 + field.byte(string.sub(stmt, at), f.column - 1)
	else
		local near = string.match(f.message, 'near "([^"]+)"')
		local found = if near then string.find(stmt, near, 1, true) else nil
		if found then
			off = found - 1
		end
	end
	if not off then
		return nil
	end
	local b = start + off
	local e = b
	while e <= #text and sqltext.is_word_byte(string.byte(text, e) :: number) do
		e += 1
	end
	if e == b then
		e = b + 1
	end
	return { from = field.char_of_byte(text, b - 1), to = field.char_of_byte(text, e - 1) }
end

-- The statement (or Redis block) at the caret, or every one with `all`.
function M.units(state: State, all: boolean): ({ sqltext.Unit }, string)
	local c = model.conn(state)
	local dialect = model.dialect(c)
	local text = state.editor.text
	local units = sqltext.units(text, dialect)
	if all then
		return units, dialect
	end
	local u = sqltext.at(units, text, field.byte(text, state.editor.cur))
	return (if u then { u } else {}), dialect
end

function M.run(state: State, all: boolean)
	local c = model.conn(state)
	if not c then
		M.open_form(state, nil)
		return
	end
	local units, dialect = M.units(state, all)
	if not all and units[1] and #units[1].asks > 0 then
		M.ask(state, units[1], nil)
		return
	end
	local statements: { string } = {}
	local starts: { number } = {}
	for _, u in units do
		for i, s in u.commands do
			table.insert(statements, s)
			table.insert(starts, u.starts[i])
		end
	end
	if #statements == 0 then
		state.note = { text = "Nothing to run at the caret", tone = "muted" }
		return
	end
	local title: string
	if #statements == 1 then
		local first = string.gsub(statements[1], "%s+", " ")
		title = if #first > 48 then string.sub(first, 1, 45) .. "…" else first
	else
		title = view.plural(#statements, if dialect == "redis" then "command" else "statement")
	end
	M.execute(state, c, statements, starts, "run", title)
end

function M.cancel(state: State)
	local run = state.run
	if not run then
		return
	end
	run.job.cancelled = true
	if run.job.handle then
		driver.cancel(run.job.handle :: driver.Handle)
	end
end

-- Asking the agent ---------------------------------------------------------------

-- No request at the caret yet: a `? ` line above the statement, the caret on it.
function M.start_request(state: State, unit: sqltext.Unit?)
	local f = state.editor
	if sqltext.trim(f.text) == "" then
		field.set(f, "? ")
	else
		local at = if unit then field.char_of_byte(f.text, unit.from - 1) else f.cur
		field.replace(f, at, at, "? \n", false)
		f.cur = at + 2
	end
	state.popup = nil
	state.note = { text = "Describe the query after ?, then ⌘I or ⌘↵ asks the agent", tone = "muted" }
	M.set_focus(state, "editor")
end

function M.ask(state: State, unit: sqltext.Unit?, failure: string?)
	local c = model.conn(state)
	if not c or state.ask then
		return
	end
	local dialect = model.dialect(c)
	local text = state.editor.text
	if not unit then
		local units = M.units(state, false)
		unit = units[1]
	end
	local requests: { string } = {}
	local blank = false
	for _, r in (if unit then unit.asks else {}) :: { string } do
		if r ~= "" then
			table.insert(requests, r)
		else
			blank = true
		end
	end
	if #requests == 0 and not failure then
		if blank then
			-- A `?` line with nothing after it yet: the request is still to be written.
			state.note = { text = "Describe the query after ?, then ⌘I asks the agent", tone = "warning" }
		else
			M.start_request(state, unit)
		end
		return
	end
	local m = model.meta(state, c.id)
	local current = if unit then table.concat(unit.commands, if dialect == "redis" then "\n" else ";\n\n") else ""
	local prompt = ask.prompt({
		conn = c, server = m.server, requests = requests, current = current, failure = failure,
		schema = m.schema, keys = m.keys,
	})
	local from = if unit then field.char_of_byte(text, (unit :: sqltext.Unit).from - 1) else field.len(text)
	local to = if unit then field.char_of_byte(text, (unit :: sqltext.Unit).to) else field.len(text)
	local chars = field.chars(text)
	local was = table.concat(chars, "", from + 1, to)
	local had_semicolon = string.match(was, ";%s*$") ~= nil
	local req = M.request(state, "ask", { conn = c.id }, ASK_WAIT_MS, function(data: any?, err: string?)
		local a = state.ask
		state.ask = nil
		pcall(tern.kv.set, link.payload_key(state.cx.pane), nil)
		if err then
			state.note = { text = "The agent didn't write a query: " .. err, tone = "error" }
			return
		end
		local d: any = data or {}
		if tonumber(d.agent) then
			state.agent = tonumber(d.agent)
		end
		local label = if a then a.label else "The agent"
		local q = ask.extract(if type(d.text) == "string" then d.text else "", dialect == "redis")
		if not q then
			state.note = { text = label .. " answered without a query: its reply is in its pane", tone = "warning" }
			return
		end
		if dialect ~= "redis" and had_semicolon and string.sub(q, -1) ~= ";" then
			q ..= ";"
		end
		local f = state.editor
		local now = table.concat(field.chars(f.text), "", from + 1, to)
		if now == was then
			field.replace(f, from, to, q, false)
		else
			-- The text moved on meanwhile: the query goes to the end rather than over the edits.
			M.append(state, q)
		end
		state.popup, state.mark = nil, nil
		state.note = { text = label .. " wrote this · ⌘Z brings back what was there", tone = "muted" }
	end)
	local payload = { req = req, prompt = prompt, cwd = state.cx.cwd or tern.getenv("HOME") or "/", agent = state.agent }
	local ok, err = pcall(function(): any
		tern.kv.set(link.payload_key(state.cx.pane), payload)
		return nil
	end)
	if not ok then
		state.pending[req] = nil
		state.note = { text = "Couldn't hand the request to the window: " .. tostring(err), tone = "error" }
		return
	end
	state.ask = { req = req, started = tern.now(), from = from, to = to, was = was, label = "the agent" }
	state.note = nil
end

-- ⇧⌘I, or the failure card's button: the agent fixes the statement that failed.
function M.fix(state: State)
	local c = model.conn(state)
	local m = if c then model.meta(state, c.id) else nil
	local outcome = if m then m.outcome else nil
	local f = if outcome then outcome.failure else nil
	if not c or not outcome or not f or f.code == "cancelled" or f.code == "57014" then
		return
	end
	local why = f.message
	for _, extra in { f.detail, f.hint } do
		if extra then
			why ..= "\n" .. extra
		end
	end
	local i = (f.statement or 0) + 1
	local start = if outcome.starts then outcome.starts[i] else nil
	local unit: sqltext.Unit? = nil
	if start then
		for _, u in sqltext.units(state.editor.text, model.dialect(c)) do
			if start >= u.from and start <= u.to then
				unit = u
			end
		end
	end
	if not unit and outcome.statements[i] then
		unit = { from = #state.editor.text + 1, to = #state.editor.text, commands = { outcome.statements[i] }, starts = {}, asks = {} }
	end
	M.ask(state, unit, why)
end

-- Completion ---------------------------------------------------------------------

function M.refresh_popup(state: State, explicit: boolean)
	local c = model.conn(state)
	if not c or state.focus ~= "editor" then
		state.popup = nil
		return
	end
	local f = state.editor
	local m = model.meta(state, c.id)
	local p = if c.kind == "redis"
		then complete.redis(f.text, f.cur, m.keys, explicit)
		else complete.sql(f.text, f.cur, model.dialect(c), m.schema, explicit)
	if not p then
		state.popup = nil
		return
	end
	local sel = 1
	local old = state.popup
	if old then
		local was = old.items[old.sel]
		for i, it in p.items do
			if was and it.label == was.label and it.kind == was.kind then
				sel = i
				break
			end
		end
	end
	local popup = p :: model.Popup
	popup.sel = sel
	state.popup = popup
end

function M.accept(state: State, index: number?): boolean
	local p = state.popup
	if not p then
		return false
	end
	local item = p.items[index or p.sel]
	if not item then
		return false
	end
	local f = state.editor
	field.replace(f, p.from, p.to, item.insert, false)
	if item.back then
		f.cur -= item.back
	end
	state.popup = nil
	if string.sub(item.insert, -1) == "." then
		M.refresh_popup(state, true)
	end
	return true
end

-- Keys ---------------------------------------------------------------------------

function M.after_edit(state: State)
	state.mark = nil
	if state.conn then
		state.drafts[state.conn] = state.editor.text
	end
end

function M.editor_key(state: State, key: Key): boolean
	local f = state.editor
	local p = state.popup
	local name = key.name
	local plain = not (key.ctrl or key.meta or key.alt)
	if key.ctrl and not key.meta and name == "space" then
		M.refresh_popup(state, true)
		return true
	end
	if p then
		if (name == "up" and plain) or (key.ctrl and name == "p") then
			p.sel = (p.sel - 2) % #p.items + 1
			return true
		elseif (name == "down" and plain) or (key.ctrl and name == "n") then
			p.sel = p.sel % #p.items + 1
			return true
		elseif name == "page_up" then
			p.sel = math.max(1, p.sel - 8)
			return true
		elseif name == "page_down" then
			p.sel = math.min(#p.items, p.sel + 8)
			return true
		elseif (name == "tab" or name == "enter") and plain then
			M.accept(state)
			M.after_edit(state)
			return true
		elseif name == "escape" then
			state.popup = nil
			return true
		end
	end
	local c = model.conn(state)
	if key.meta and not key.ctrl and name == "/" then
		local lo, hi = field.bounds(f)
		field.toggle_prefix(f, lo, hi, if c and c.kind == "redis" then "# " else "-- ")
		state.popup = nil
		M.after_edit(state)
		return true
	end
	if name == "tab" and not (key.ctrl or key.meta or key.alt) then
		local chars = field.chars(f.text)
		local lo, hi = field.bounds(f)
		local start = field.line_start(chars, lo)
		if key.shift then
			local n = 0
			while n < 4 and chars[start + n + 1] == " " do
				n += 1
			end
			if n > 0 then
				local cur = f.cur
				field.replace(f, start, start + n, "", false)
				f.cur = math.max(start, cur - n)
			end
		else
			field.replace(f, lo, hi, string.rep(" ", 4 - (lo - start) % 4), false)
		end
		state.popup = nil
		M.after_edit(state)
		return true
	end
	if name == "escape" then
		if state.note or state.mark or state.row then
			state.note, state.mark, state.row = nil, nil, nil
			return true
		end
		return false
	end
	local what = field.key(f, key, state.cx)
	if what == nil then
		return false
	end
	if what == "text" then
		M.after_edit(state)
		local typed = key.text or ""
		if name ~= "paste" and (string.match(typed, "^[%w_$]$") or typed == "." or #typed > 1) then
			M.refresh_popup(state, false)
		elseif (name == "backspace" or name == "delete") and state.popup then
			M.refresh_popup(state, false)
		else
			state.popup = nil
		end
	else
		state.popup = nil
	end
	return true
end

function M.filter_changed(state: State)
	local c = model.conn(state)
	if not c or c.kind ~= "redis" then
		return
	end
	-- Redis filters on the server (SCAN MATCH): scan again once typing pauses.
	local text = state.filter.text
	tern.timer(400, function(_cx: WindowCx?)
		if M.alive(state) and state.filter.text == text and model.conn(state) == c then
			M.load(state, c, true)
			state.cx:render()
		end
	end)
end

function M.filter_key(state: State, key: Key): boolean
	local name = key.name
	if name == "escape" then
		if state.filter.text ~= "" then
			field.reset(state.filter, "")
			M.filter_changed(state)
		else
			M.set_focus(state, "editor")
		end
		return true
	end
	if name == "enter" or name == "down" or name == "up" then
		local objects = view.objects(state)
		if #objects == 0 then
			return true
		end
		local at = 0
		for i, o in objects do
			if o.key == state.object then
				at = i
			end
		end
		if name == "enter" then
			local o = objects[math.max(at, 1)]
			M.object_action(state, if model.conn(state) and (model.conn(state) :: Conn).kind == "redis" then "value" else "browse", o.key)
		else
			at = math.clamp(at + (if name == "down" then 1 else -1), 1, #objects)
			state.object = objects[at].key
		end
		return true
	end
	if name == "tab" then
		M.set_focus(state, "editor")
		return true
	end
	local what = field.key(state.filter, key, state.cx)
	if what == "text" then
		M.filter_changed(state)
	end
	return what ~= nil
end

function M.key(state: State, key: Key): boolean
	if state.form then
		return M.form_key(state, key)
	end
	local name = key.name
	local cmd = key.meta and not key.ctrl
	if cmd and name == "enter" and not key.shift then
		M.run(state, key.alt)
		return true
	elseif cmd and name == "." then
		M.cancel(state)
		return true
	elseif cmd and name == "i" and not key.alt then
		if key.shift then
			M.fix(state)
		else
			M.ask(state, nil, nil)
		end
		return true
	elseif cmd and key.shift and name == "n" then
		M.open_form(state, nil)
		return true
	elseif name == "f2" then
		M.open_form(state, state.conn)
		return true
	elseif cmd and name == "r" and not key.shift then
		local c = model.conn(state)
		if c then
			M.load(state, c, true)
		end
		return true
	elseif cmd and key.shift and name == "f" then
		M.set_focus(state, "filter")
		return true
	elseif key.alt and not key.meta and not key.ctrl and (name == "up" or name == "down") then
		M.step_conn(state, if name == "up" then -1 else 1)
		return true
	end
	if state.focus == "filter" then
		return M.filter_key(state, key)
	end
	return M.editor_key(state, key)
end

-- Connection form ------------------------------------------------------------------

local function form_fields(c: Conn?): { [string]: field.Field }
	local out: { [string]: field.Field } = {}
	for _, name in FIELDS do
		out[name] = field.new("", false)
	end
	if c then
		for _, name in FIELDS do
			local v = (c :: any)[name]
			if v ~= nil and name ~= "password" then
				field.reset(out[name], tostring(v))
			end
		end
		if c.path then
			field.reset(out.path, conns.home_short(c.path))
		end
	end
	return out
end

function M.open_form(state: State, id: string?, copy: boolean?, secret: string?)
	local c = if id then conns.find(state.conns, id) else nil
	local kind = if c then c.kind else "postgres"
	local f: model.Form = {
		id = if c and not copy then c.id else nil,
		kind = kind,
		fields = form_fields(c),
		sslmode = if c and c.sslmode then c.sslmode else "prefer",
		tls = if c and c.tls then true else false,
		insecure = if c and c.insecure then true else false,
		focus = "name",
		stored = (c ~= nil and not copy and c.secret == true),
		forget = false,
		confirm_delete = false,
	}
	if c and copy then
		field.reset(f.fields.name, c.name .. " copy")
		if secret then
			field.reset(f.fields.password, secret)
		end
	end
	state.form = f
	state.popup = nil
	M.set_focus(state, "form")
end

function M.close_form(state: State)
	state.form = nil
	M.set_focus(state, "editor")
end

local function kind_fields(f: model.Form): { string }
	local out: { string } = {}
	for _, name in conns.kind(f.kind).fields do
		if f.fields[name] then
			table.insert(out, name)
		end
	end
	return out
end

-- The form as a connection; nil, the problem and its field when it can't be saved.
function M.form_conn(state: State): (Conn?, string?, string?)
	local f = state.form :: model.Form
	local function v(name: string): string?
		local t = sqltext.trim(f.fields[name].text)
		return if t ~= "" then t else nil
	end
	local c: Conn = { id = f.id or conns.new_id(), name = v("name") or "", kind = f.kind }
	if f.kind == "sqlite" then
		local path = v("path")
		if not path then
			return nil, "Choose the database file", "path"
		end
		if string.sub(path :: string, 1, 1) == "~" then
			path = (tern.getenv("HOME") or "") .. string.sub(path :: string, 2)
		end
		c.path = path
		c.name = if c.name ~= "" then c.name else (string.match(path :: string, "([^/]+)$") or "SQLite")
	else
		c.host = v("host")
		local port = v("port")
		if port then
			local n = tonumber(port)
			if not n or n ~= math.floor(n) or n < 1 or n > 65535 then
				return nil, "A port is a number from 1 to 65535", "port"
			end
			c.port = n
		end
		c.user = v("user")
		if f.kind == "postgres" then
			c.database = v("database")
			c.sslmode = f.sslmode
		elseif f.kind == "trino" then
			c.catalog, c.schema = v("catalog"), v("schema")
			c.tls = f.tls or nil
		elseif f.kind == "redis" then
			local db = v("db")
			if db then
				local n = tonumber(db)
				if not n or n ~= math.floor(n) or n < 0 then
					return nil, "The database number is 0 or more", "db"
				end
				c.db = n
			end
			c.tls = f.tls or nil
		end
		c.insecure = if c.tls and f.insecure then true else nil
		if c.name == "" then
			c.name = c.database or c.catalog or c.host or conns.kind(f.kind).label
		end
	end
	local typed = f.fields.password.text ~= ""
	c.secret = if typed or (f.stored and not f.forget) then true else nil
	if f.kind == "sqlite" then
		c.secret = nil
	end
	return c, nil, nil
end

function M.commit_conn(state: State, c: Conn)
	local list, err = conns.put(c)
	if not list then
		(state.form :: model.Form).error = "Couldn't save the connection: " .. tostring(err)
		return
	end
	state.conns = list
	-- What the explorer knew may not hold for the edited connection.
	state.meta[c.id] = nil
	state.form = nil
	if state.conn == c.id then
		state.conn = nil
	end
	M.select_conn(state, c.id)
	state.cx:toast("success", "Saved " .. c.name)
	M.set_focus(state, "editor")
end

function M.form_save(state: State)
	local f = state.form :: model.Form
	if f.busy then
		return
	end
	local c, err, bad = M.form_conn(state)
	f.error, f.bad, f.test = err, bad, nil
	if not c then
		return
	end
	local conn = c :: Conn
	local typed = f.fields.password.text
	if conn.kind ~= "sqlite" and typed ~= "" then
		f.busy = "save"
		M.request(state, "store", { conn = conn.id, field = model.form_input("password") }, SECRET_WAIT_MS,
			function(_data: any?, serr: string?)
				f.busy = nil
				if serr then
					f.error = "Couldn't store the password in the keychain: " .. serr
					return
				end
				SECRETS[conn.id] = typed
				M.commit_conn(state, conn)
			end)
	elseif f.id and (f.forget or (f.stored and conn.kind == "sqlite")) then
		f.busy = "save"
		M.request(state, "forget", { conn = conn.id }, SECRET_WAIT_MS, function(_data: any?, serr: string?)
			f.busy = nil
			if serr then
				f.error = "Couldn't remove the password from the keychain: " .. serr
				return
			end
			SECRETS[conn.id] = nil
			M.commit_conn(state, conn)
		end)
	else
		M.commit_conn(state, conn)
	end
end

function M.form_test(state: State)
	local f = state.form :: model.Form
	if f.busy then
		return
	end
	local c, err, bad = M.form_conn(state)
	f.error, f.bad, f.test = err, bad, nil
	if not c then
		return
	end
	local conn = c :: Conn
	f.busy = "test"
	local function go(secret: string?)
		driver.start({ op = "test", conn = conns.wire(conn), password = secret }, TEST_MS, function(answer: any, derr: string?)
			if state.form ~= f or not M.alive(state) then
				return
			end
			f.busy = nil
			if type(answer) == "table" and answer.ok then
				f.test = { ok = true, text = tostring(answer.server or "Connected") .. " · " .. view.ms(answer.elapsed_ms) }
			else
				local failure = failure_of(answer, derr)
				f.test = { ok = false, text = failure.message .. (if failure.hint then ". " .. failure.hint else "") }
			end
			state.cx:render()
		end)
	end
	local typed = f.fields.password.text
	local stored = if f.id then conns.find(state.conns, f.id) else nil
	if typed ~= "" or conn.kind == "sqlite" then
		go(if typed ~= "" then typed else nil)
	elseif f.stored and not f.forget and stored then
		M.with_secret(state, stored, function(secret: string?, serr: string?)
			if serr then
				f.busy = nil
				f.test = { ok = false, text = serr }
				state.cx:render()
				return
			end
			go(secret)
		end)
	else
		go(nil)
	end
end

function M.form_delete(state: State)
	local f = state.form :: model.Form
	local id = f.id
	if not id or f.busy then
		return
	end
	f.busy = "save"
	M.request(state, "forget", { conn = id }, SECRET_WAIT_MS, function(_data: any?, serr: string?)
		f.busy = nil
		if serr then
			f.error = "Couldn't remove the password from the keychain: " .. serr
			f.confirm_delete = false
			return
		end
		SECRETS[id] = nil
		local list, err = conns.remove(id)
		if not list then
			f.error = "Couldn't delete the connection: " .. tostring(err)
			return
		end
		local name = sqltext.trim(f.fields.name.text)
		state.conns = list
		state.meta[id] = nil
		state.drafts[id] = nil
		state.form = nil
		if state.conn == id then
			state.conn = nil
			M.select_conn(state, if list[1] then list[1].id else nil)
		end
		state.cx:toast("success", "Deleted " .. name)
		M.set_focus(state, "editor")
	end)
end

-- A connection URL pasted or typed into Host fills in the form.
function M.form_url(state: State)
	local f = state.form :: model.Form
	local parsed = conns.parse_url(f.fields.host.text)
	if not parsed then
		return
	end
	local p = parsed :: conns.Parsed
	f.kind = p.kind
	local function put(name: string, v: any)
		if v ~= nil then
			field.reset(f.fields[name], tostring(v))
		end
	end
	field.reset(f.fields.host, "")
	put("host", p.host)
	put("port", p.port)
	put("database", p.database)
	put("user", p.user)
	put("password", p.password)
	put("path", p.path)
	put("catalog", p.catalog)
	put("schema", p.schema)
	put("db", p.db)
	if p.sslmode then
		f.sslmode = p.sslmode
	end
	if p.tls then
		f.tls = true
	end
	if p.password then
		f.forget = false
	end
	if sqltext.trim(f.fields.name.text) == "" then
		put("name", p.database or p.catalog or p.host)
	end
end

function M.form_key(state: State, key: Key): boolean
	local f = state.form :: model.Form
	local name = key.name
	if f.confirm_delete then
		if name == "enter" then
			M.form_delete(state)
		elseif name == "escape" then
			f.confirm_delete = false
		else
			return false
		end
		return true
	end
	if name == "escape" then
		M.close_form(state)
		return true
	end
	if key.meta and name == "enter" then
		M.form_save(state)
		return true
	end
	local order = kind_fields(f)
	if name == "tab" or (name == "enter" and not (key.meta or key.ctrl or key.alt)) then
		local at = table.find(order, f.focus) or 1
		if name == "enter" and at == #order then
			M.form_save(state)
			return true
		end
		local step = if key.shift and name == "tab" then -1 else 1
		f.focus = order[(at - 1 + step) % #order + 1]
		M.set_focus(state, "form")
		return true
	end
	local fld = f.fields[f.focus]
	if not fld then
		return false
	end
	local what = field.key(fld, key, state.cx)
	if what == "text" then
		f.test, f.error, f.bad = nil, nil, nil
		if f.focus == "host" and key.name == "paste" and string.find(fld.text, "://", 1, true) then
			M.form_url(state)
		end
		if f.focus == "password" and fld.text ~= "" then
			f.forget = false
		end
	end
	return what ~= nil
end

function M.form_event(state: State, ev: UiEvent)
	local f = state.form :: model.Form
	local id = if type(ev.id) == "string" then ev.id else ""
	if ev.ev == "focus" then
		local name = string.match(id, "^layer%.form%.f_(%w+)%.in$")
		if name and f.fields[name] then
			f.focus = name
			M.set_focus(state, "form")
		end
		return
	end
	if ev.ev == "edit" or ev.ev == "undo" then
		local name = string.match(id, "^layer%.form%.f_(%w+)%.in$")
		local fld = if name then f.fields[name] else nil
		if fld then
			local what = if ev.ev == "undo" then (if field.undo_step(fld, false) then "text" else nil) else field.apply_edit(fld, ev)
			if what == "text" then
				f.test, f.error, f.bad = nil, nil, nil
				if name == "host" and type(ev.text) == "string" and string.find(ev.text, "://", 1, true) then
					M.form_url(state)
				end
			end
			f.focus = name :: string
		end
		return
	end
	if ev.ev == "select" and id == IDS.kind and type(ev.item) == "string" then
		f.kind = ev.item
		f.test, f.error, f.bad = nil, nil, nil
		if not table.find(kind_fields(f), f.focus) then
			f.focus = "name"
		end
		M.set_focus(state, "form")
		return
	end
	if ev.ev == "select" and id == IDS.sslmode and type(ev.item) == "string" then
		f.sslmode = ev.item
		return
	end
	if ev.ev == "change" and id == IDS.tls then
		f.tls = ev.value == true
		return
	end
	if ev.ev == "change" and id == IDS.verify then
		f.insecure = ev.value ~= true
		return
	end
	if ev.ev ~= "action" then
		return
	end
	local act = ev.act
	if act == "form-close" then
		M.close_form(state)
	elseif act == "form-save" then
		M.form_save(state)
	elseif act == "form-test" then
		M.form_test(state)
	elseif act == "form-delete" then
		f.confirm_delete = true
	elseif act == "form-undelete" then
		f.confirm_delete = false
	elseif act == "form-delete-confirm" then
		M.form_delete(state)
	elseif act == "form-forget" then
		f.forget = true
		field.reset(f.fields.password, "")
	elseif act == "clear" then
		local fld = f.fields[f.focus]
		if fld then
			field.reset(fld, "")
		end
	end
end

-- Results ------------------------------------------------------------------------

local function csv_field(v: any, sep: string): string
	if v == nil or v == tern.json.null then
		return ""
	end
	local s = tostring(v)
	if sep == "\t" then
		return (string.gsub(s, "[\t\r\n]", " "))
	end
	if string.find(s, '[,"\r\n]') then
		return '"' .. string.gsub(s, '"', '""') .. '"'
	end
	return s
end

-- The shown result as text: CSV, TSV, JSON or a Markdown table.
function M.export(r: model.Result, format: string, only: number?): string
	local cols: { model.Column } = r.columns or {}
	local rows: { { any } } = r.rows or {}
	if only then
		rows = { rows[only] }
	end
	if format == "json" then
		local out: { any } = {}
		for _, row in rows do
			local obj: { [string]: any } = {}
			for j, col in cols do
				obj[col.name] = if row[j] == nil then tern.json.null else row[j]
			end
			table.insert(out, obj)
		end
		return tern.json.encode(if only then out[1] else tern.json.array(out), true)
	end
	local lines: { string } = {}
	if format == "markdown" then
		local head: { string } = {}
		local rule: { string } = {}
		for _, col in cols do
			table.insert(head, (string.gsub(col.name, "|", "\\|")))
			table.insert(rule, if col.num then "---:" else "---")
		end
		table.insert(lines, "| " .. table.concat(head, " | ") .. " |")
		table.insert(lines, "| " .. table.concat(rule, " | ") .. " |")
		for _, row in rows do
			local cells: { string } = {}
			for j = 1, #cols do
				local v = row[j]
				table.insert(cells, if v == nil or v == tern.json.null then "NULL" else (string.gsub(string.gsub(tostring(v), "|", "\\|"), "\n", " ")))
			end
			table.insert(lines, "| " .. table.concat(cells, " | ") .. " |")
		end
		return table.concat(lines, "\n")
	end
	local sep = if format == "tsv" then "\t" else ","
	if not only then
		local head: { string } = {}
		for _, col in cols do
			table.insert(head, csv_field(col.name, sep))
		end
		table.insert(lines, table.concat(head, sep))
	end
	for _, row in rows do
		local cells: { string } = {}
		for j = 1, #cols do
			table.insert(cells, csv_field(row[j], sep))
		end
		table.insert(lines, table.concat(cells, sep))
	end
	return table.concat(lines, "\n")
end

function M.shown(state: State): model.Result?
	local c = model.conn(state)
	local outcome = if c then model.meta(state, c.id).outcome else nil
	return if outcome then outcome.results[state.result] or outcome.results[#outcome.results] else nil
end

-- Events -----------------------------------------------------------------------------

local function tail(id: any, prefix: string): string?
	if type(id) ~= "string" or string.sub(id, 1, #prefix + 1) ~= prefix .. "." then
		return nil
	end
	return string.sub(id, #prefix + 2)
end

function M.action(state: State, act: string, value: string?, ev: UiEvent)
	local c = model.conn(state)
	if act == "new" then
		M.open_form(state, nil)
	elseif act == "edit" then
		M.open_form(state, value or state.conn)
	elseif act == "delete" and value then
		M.open_form(state, value)
		if state.form then
			(state.form :: model.Form).confirm_delete = true
		end
	elseif act == "duplicate" and value then
		local src = conns.find(state.conns, value)
		if src then
			M.with_secret(state, src, function(secret: string?, _err: string?)
				if M.alive(state) then
					M.open_form(state, value, true, secret)
					state.cx:render()
				end
			end)
		end
	elseif act == "refresh" then
		if c then
			M.load(state, c, true)
		end
	elseif act == "run" then
		M.run(state, false)
	elseif act == "cancel" then
		M.cancel(state)
	elseif act == "ask" then
		M.ask(state, nil, nil)
	elseif act == "fix" then
		M.fix(state)
	elseif act == "clear" then
		field.reset(state.filter, "")
		M.filter_changed(state)
	elseif act == "unrow" then
		state.row = nil
	elseif (act == "browse" or act == "insert" or act == "count" or act == "copyname") and value then
		M.object_action(state, act, value)
	elseif act == "copy" and value then
		local r = M.shown(state)
		if r and r.columns then
			state.cx:copy(M.export(r, value, nil))
			state.cx:toast("success", "Copied " .. view.plural(#(r.rows or {}), "row") .. " as " .. string.upper(value))
		end
	elseif act == "copyrow" and value then
		local r = M.shown(state)
		local i = tonumber(string.match(state.row or "", "^r(%d+)$"))
		if r and i then
			state.cx:copy(M.export(r, value, i))
			state.cx:toast("success", "Copied row " .. tostring(i))
		end
	end
end

function M.event(state: State, ev: UiEvent)
	if ev.ev == "action" and ev.act == link.ACT then
		local ok, data = pcall(tern.json.decode, if type(ev.json) == "string" then ev.json else "")
		if ok then
			M.answer(state, data)
		end
		return
	end
	if state.form then
		M.form_event(state, ev)
		return
	end
	local id = if type(ev.id) == "string" then ev.id else ""
	if ev.ev == "focus" then
		if id == IDS.editor then
			M.set_focus(state, "editor")
		elseif id == IDS.filter then
			M.set_focus(state, "filter")
		end
		return
	end
	if ev.ev == "edit" or ev.ev == "undo" then
		local f = if id == IDS.editor then state.editor elseif id == IDS.filter then state.filter else nil
		if not f then
			return
		end
		local what = if ev.ev == "undo" then (if field.undo_step(f, false) then "text" else "caret") else field.apply_edit(f, ev)
		if f == state.editor then
			state.focus = "editor"
			if what == "text" then
				M.after_edit(state)
				if state.popup then
					M.refresh_popup(state, false)
				end
			elseif what == "caret" then
				state.popup = nil
			end
		elseif what == "text" then
			state.focus = "filter"
			M.filter_changed(state)
		end
		return
	end
	if ev.ev == "select" or ev.ev == "activate" then
		local item = if type(ev.item) == "string" then ev.item else nil
		if id == IDS.conns and item then
			local key = tail(item, IDS.conns)
			if key then
				M.select_conn(state, key)
			end
		elseif id == IDS.objects and item then
			local key = tail(item, IDS.objects)
			local c = model.conn(state)
			if key and c then
				if c.kind == "redis" then
					M.object_action(state, "value", key)
				elseif ev.ev == "activate" then
					M.object_action(state, "browse", key)
				else
					state.object = key
				end
			end
		elseif id == IDS.popup and item then
			local i = tonumber(string.match(tail(item, IDS.popup) or "", "^i(%d+)$"))
			if i then
				M.accept(state, i)
				M.after_edit(state)
				M.set_focus(state, "editor")
			end
		elseif id == IDS.table and item then
			state.row = if state.row == item and ev.ev == "select" then nil else item
		elseif id == IDS.result_tabs and item then
			state.result = tonumber(item) or 1
			state.row = nil
		end
		return
	end
	if ev.ev == "change" then
		if id == IDS.outer and type(ev.value) == "table" then
			state.sizes = ev.value
		elseif id == IDS.inner and type(ev.value) == "table" then
			state.split = ev.value
		elseif id == IDS.limit then
			state.max_rows = tonumber(ev.value) or state.max_rows
		elseif id == IDS.result_tabs then
			state.result = tonumber(ev.value) or state.result
			state.row = nil
		end
		return
	end
	if ev.ev == "action" and type(ev.act) == "string" then
		M.action(state, ev.act, if type(ev.value) == "string" then ev.value else nil, ev)
	end
end

-- Lifecycle ----------------------------------------------------------------------------

-- Connections another window or block added, edited or deleted show up here too.
function M.watch(state: State)
	local last = tern.json.encode(state.conns)
	local function tick()
		if not M.alive(state) then
			return
		end
		local list = conns.load()
		local now = tern.json.encode(list)
		if now ~= last then
			last = now
			state.conns = list
			for id in state.meta do
				if not conns.find(list, id) then
					state.meta[id] = nil
				end
			end
			if state.conn and not conns.find(list, state.conn) then
				state.conn = nil
				M.select_conn(state, if list[1] then list[1].id else nil)
			elseif not state.conn and list[1] then
				M.select_conn(state, list[1].id)
			end
			state.cx:render()
		end
		tern.timer(WATCH_MS, function(_cx: WindowCx?)
			tick()
		end)
	end
	tern.timer(WATCH_MS, function(_cx: WindowCx?)
		tick()
	end)
end

-- "Open with Databases" on a SQLite file: its connection, added when there is none yet.
function M.open_file(state: State, path: string)
	for _, c in state.conns do
		if c.kind == "sqlite" and c.path == path then
			state.conn = c.id
			return
		end
	end
	local c: Conn = { id = conns.new_id(), name = string.match(path, "([^/]+)$") or path, kind = "sqlite", path = path }
	local list = conns.put(c)
	if list then
		state.conns = list
		state.conn = c.id
	end
end

function M.new(cx: BlockCx, saved: any): State
	local s: any = if type(saved) == "table" then saved else {}
	local drafts: { [string]: string } = {}
	if type(s.drafts) == "table" then
		for k, v in s.drafts do
			if type(k) == "string" and type(v) == "string" then
				drafts[k] = v
			end
		end
	end
	local function sizes(v: any): { number }?
		if type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" then
			return { v[1], v[2] }
		end
		return nil
	end
	local max_rows = tonumber(s.max_rows)
	return {
		cx = cx,
		alive = true,
		conns = conns.load(),
		conn = if type(s.conn) == "string" then s.conn else nil,
		meta = {},
		editor = field.new("", true),
		drafts = drafts,
		focus = "editor",
		filter = field.new("", false),
		result = 1,
		req = 0,
		pending = {},
		sizes = sizes(s.sizes),
		split = sizes(s.split),
		max_rows = if max_rows and table.find(model.MAX_ROWS, max_rows) then max_rows else 500,
	}
end

tern.block.define("console", {
	font = "sans",
	features = { "edit", "undo" } :: { "edit" | "undo" },

	init = function(cx: BlockCx, args: { string }, saved: any): State
		local state = M.new(cx, saved)
		local path = args[1]
		if type(path) == "string" and path ~= "" and tern.fs.exists(path) then
			M.open_file(state, path)
		end
		if not (state.conn and conns.find(state.conns, state.conn)) then
			state.conn = if state.conns[1] then state.conns[1].id else nil
		end
		field.reset(state.editor, if state.conn then state.drafts[state.conn] or "" else "")
		local c = model.conn(state)
		if c then
			M.load(state, c, false)
		end
		M.watch(state)
		-- The view exists once init returns: give the editor the caret then.
		tern.timer(50, function(_cx: WindowCx?)
			if M.alive(state) and not state.form then
				M.set_focus(state, state.focus)
			end
		end)
		return state
	end,

	title = function(state: State): string?
		local c = model.conn(state)
		return if c then "Databases · " .. c.name else "Databases"
	end,

	view = function(state: State, cx: BlockCx): BlockView
		return view.view(state, cx)
	end,

	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		return M.key(state, key)
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		M.event(state, ev)
	end,

	save = function(state: State): any
		if state.conn then
			state.drafts[state.conn] = state.editor.text
		end
		local drafts: { [string]: string } = {}
		for id, text in state.drafts do
			if text ~= "" and conns.find(state.conns, id) then
				drafts[id] = text
			end
		end
		return {
			conn = state.conn,
			drafts = drafts,
			sizes = state.sizes,
			split = state.split,
			max_rows = state.max_rows,
		}
	end,
})
