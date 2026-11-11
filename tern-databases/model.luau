--!strict
-- The Databases block's state, shared by host.luau (what happens) and view.luau (what shows).

local field = require("./field")
local conns = require("./conns")
local complete = require("./complete")
local driver = require("./driver")

export type Column = { name: string, type: string?, num: boolean? }
export type Result = {
	statement: number?,
	columns: { Column }?,
	rows: { { any } }?,
	truncated: boolean?,
	count: number?,
	command: string?,
	elapsed_ms: number?,
	notices: { string }?,
	-- A Redis reply that is not a table, or a per-command error.
	text: string?,
	error: string?,
}
export type Failure = {
	message: string,
	detail: string?,
	hint: string?,
	code: string?,
	position: number?,
	statement: number?,
	line: number?,
	column: number?,
	where: string?,
}
-- What one request brought back, as the results pane shows it.
export type Outcome = {
	-- "run" (the editor), "browse" (a table's first rows), "value" (a Redis key).
	source: string,
	title: string,
	statements: { string },
	-- Where each statement starts in the editor (bytes), for error positions.
	starts: { number }?,
	results: { Result },
	failure: Failure?,
	notices: { string }?,
	elapsed_ms: number?,
	value: { [string]: any }?,
}
-- A request to the driver the block may cancel: `handle` once the process started.
export type Job = { handle: driver.Handle?, cancelled: boolean }
export type Run = {
	job: Job,
	started: number,
	conn: string,
	title: string,
	count: number,
}
-- What a connection's explorer knows; kept per connection while the block runs.
export type Meta = {
	schema: complete.Schema?,
	keys: { complete.RedisKey }?,
	keys_complete: boolean?,
	dbsize: number?,
	pattern: string?,
	loading: boolean,
	failure: Failure?,
	server: string?,
	-- Trino's USE: the catalog and schema the next run starts in.
	session: { catalog: string?, schema: string? }?,
	outcome: Outcome?,
}
export type Pending = {
	op: string,
	at: number,
	done: (data: any?, err: string?) -> (),
}
export type Form = {
	id: string?,
	kind: string,
	fields: { [string]: field.Field },
	sslmode: string,
	tls: boolean,
	insecure: boolean,
	focus: string,
	-- A password is stored for the connection being edited.
	stored: boolean,
	forget: boolean,
	error: string?,
	bad: string?,
	test: { ok: boolean, text: string }?,
	busy: string?,
	confirm_delete: boolean,
}
export type Popup = complete.Popup & { sel: number }
export type Ask = {
	req: number,
	started: number,
	-- The editor text the answer replaces: [from, to) in characters, and what it said then.
	from: number,
	to: number,
	was: string,
	label: string,
}

export type State = {
	cx: BlockCx,
	alive: boolean,
	conns: { conns.Conn },
	conn: string?,
	meta: { [string]: Meta },
	editor: field.Field,
	drafts: { [string]: string },
	-- "editor", "filter" or "form".
	focus: string,
	filter: field.Field,
	object: string?,
	popup: Popup?,
	run: Run?,
	result: number,
	row: string?,
	ask: Ask?,
	note: { text: string, tone: string }?,
	mark: { from: number, to: number }?,
	form: Form?,
	req: number,
	pending: { [number]: Pending },
	agent: number?,
	sizes: { number }?,
	split: { number }?,
	max_rows: number,
}

local model = {}

function model.form_input(name: string): string
	return "layer.form.f_" .. name .. ".in"
end

model.MAX_ROWS = { 100, 500, 1000, 5000 }

function model.conn(state: State): conns.Conn?
	return conns.find(state.conns, state.conn)
end

function model.meta(state: State, id: string): Meta
	local m = state.meta[id]
	if not m then
		m = { loading = false }
		state.meta[id] = m
	end
	return m
end

function model.dialect(c: conns.Conn?): string
	return if c then conns.kind(c.kind).dialect else "postgres"
end

-- Node ids the block refers to: focus ops, caret anchors, events. They follow the view's keys.
model.IDS = {
	editor = "main.ws.work.edit.sql",
	filter = "main.ws.nav.filter",
	conns = "main.ws.nav.conns",
	objects = "main.ws.nav.objects",
	results = "main.ws.work.out.grid",
	table = "main.ws.work.out.grid.body.list.table",
	result_tabs = "main.ws.work.out.bar.end.tabs",
	limit = "main.ws.work.out.bar.end.limit",
	outer = "main.ws",
	inner = "main.ws.work",
	popup = "layer.complete.items",
	form = "layer.form",
	kind = "layer.form.kind",
	sslmode = "layer.form.f_sslmode.in",
	tls = "layer.form.f_tls",
	verify = "layer.form.f_verify",
}

return model
