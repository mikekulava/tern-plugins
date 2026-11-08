--!strict
-- The explorer's data: suites (one runner in one project directory), their test files
-- and tests; applying the runners' JSON events; counts; and the flat row list the
-- left pane draws. Nothing here touches the UI or starts processes.

local model = {}

export type Kind = "pytest" | "unittest" | "python" | "vitest" | "jest"
export type Status = "idle" | "queued" | "running" | "passed" | "failed" | "error" | "skipped"

export type Frame = {
	file: string?,
	line: number?,
	col: number?,
	fn: string?,
	app: boolean?,
	code: { start: number?, lines: { string } }?,
}

export type TestError = {
	type: string?,
	message: string?,
	frames: { Frame }?,
	text: string?,
	diff: string?,
	phase: string?,
}

export type Test = {
	id: string,
	ident: string,
	name: string,
	line: number?,
	status: Status,
	duration: number?,
	error: TestError?,
	output: string?,
	reason: string?,
}

export type File = {
	ident: string,
	path: string,
	rel: string,
	tests: { Test },
	byId: { [string]: Test },
	error: TestError?,
	output: string?,
}

export type Suite = {
	ident: string,
	kind: Kind,
	dir: string,
	rel: string,
	files: { File },
	byPath: { [string]: File },
	phase: "pending" | "collecting" | "ready" | "failed",
	problem: string?,
	detail: string?,
	python: string?,
	bin: string?,
	rootdir: string?,
	output: string?,
}

export type Row = {
	key: string,
	kind: "suite" | "file" | "test",
	depth: number,
	suite: Suite,
	file: File?,
	test: Test?,
}

export type Counts = {
	total: number,
	passed: number,
	failed: number,
	skipped: number,
	running: number,
	queued: number,
	idle: number,
	duration: number,
}

-- ---------------------------------------------------------------- paths

-- macOS reports /tmp and /var through their real /private paths; fold them back so
-- runner paths match the paths the explorer was opened with.
function model.norm(p: string): string
	if string.sub(p, 1, 13) == "/private/tmp/" or string.sub(p, 1, 13) == "/private/var/" then
		return string.sub(p, 9)
	end
	if #p > 1 and string.sub(p, -1) == "/" then
		return string.sub(p, 1, -2)
	end
	return p
end

function model.join(a: string, b: string): string
	if string.sub(b, 1, 1) == "/" then
		return b
	end
	if b == "" or b == "." then
		return a
	end
	if string.sub(a, -1) == "/" then
		return a .. b
	end
	return a .. "/" .. b
end

function model.dirname(p: string): string
	local d = string.match(p, "^(.*)/[^/]*$")
	if d == nil or d == "" then
		return "/"
	end
	return d
end

function model.basename(p: string): string
	return string.match(p, "([^/]*)$") or p
end

-- `p` relative to `base` when inside it, else `p` with the home directory as `~`.
function model.rel(p: string, base: string, home: string?): string
	if p == base then
		return "."
	end
	local prefix = if string.sub(base, -1) == "/" then base else base .. "/"
	if string.sub(p, 1, #prefix) == prefix then
		return string.sub(p, #prefix + 1)
	end
	return model.tilde(p, home)
end

function model.tilde(p: string, home: string?): string
	if home and home ~= "" and string.sub(p, 1, #home + 1) == home .. "/" then
		return "~" .. string.sub(p, #home + 1)
	end
	return p
end

-- ---------------------------------------------------------------- formatting

function model.duration(ms: number?): string?
	if ms == nil then
		return nil
	end
	if ms < 1 then
		return "<1 ms"
	elseif ms < 1000 then
		return string.format("%d ms", math.floor(ms + 0.5))
	elseif ms < 60000 then
		return string.format("%.1f s", ms / 1000)
	end
	local s = math.floor(ms / 1000 + 0.5)
	return string.format("%d m %d s", s // 60, s % 60)
end

-- The parts of a test name: its describe/class path and its own name.
function model.split_name(name: string): ({ string }, string)
	local parts: { string } = {}
	local norm = string.gsub(name, " › ", "\0")
	norm = string.gsub(norm, " > ", "\0")
	for part in string.gmatch(norm, "[^%z]+") do
		table.insert(parts, part)
	end
	local last = table.remove(parts) or name
	return parts, last
end

-- ---------------------------------------------------------------- building

function model.suite(kind: Kind, dir: string, root: string, home: string?): Suite
	local rel = model.rel(dir, root, home)
	return {
		ident = "s|" .. dir .. "|" .. kind,
		kind = kind,
		dir = dir,
		rel = rel,
		files = {},
		byPath = {},
		phase = "pending",
		problem = nil,
		detail = nil,
		python = nil,
		bin = nil,
		rootdir = nil,
		output = nil,
	}
end

function model.file(suite: Suite, path: string, root: string, home: string?): File
	path = model.norm(path)
	local f = suite.byPath[path]
	if f then
		return f
	end
	local nf: File = {
		ident = suite.ident .. "|" .. path,
		path = path,
		rel = model.rel(path, root, home),
		tests = {},
		byId = {},
		error = nil,
		output = nil,
	}
	suite.byPath[path] = nf
	table.insert(suite.files, nf)
	return nf
end

local function by_line(a: Test, b: Test): boolean
	local la, lb = a.line or math.huge, b.line or math.huge
	if la ~= lb then
		return la < lb
	end
	return a.name < b.name
end

function model.sort(suite: Suite)
	table.sort(suite.files, function(a: File, b: File): boolean
		return a.rel < b.rel
	end)
	for _, f in suite.files do
		table.sort(f.tests, by_line)
	end
end

function model.test(file: File, id: string, name: string, line: number?): Test
	local t = file.byId[id]
	if t then
		if line then
			t.line = line
		end
		t.name = name
		return t
	end
	local nt: Test = {
		id = id,
		ident = file.ident .. "|" .. id,
		name = name,
		line = line,
		status = "idle",
		duration = nil,
		error = nil,
		output = nil,
		reason = nil,
	}
	file.byId[id] = nt
	table.insert(file.tests, nt)
	return nt
end

-- The id a JS runner's test gets: its file and full name (runner paths normalized).
function model.js_id(file: string, name: string): string
	return model.norm(file) .. "::" .. name
end

export type Collected = { id: string?, file: string, name: string?, line: number? }

-- Replaces the suite's tree with a fresh collection, keeping what is known about tests
-- that are still there. `files_only` (jest) keeps a listed file's previous tests.
function model.collect(suite: Suite, items: { Collected }, root: string, home: string?, files_only: boolean)
	local old = suite.byPath
	suite.files, suite.byPath = {}, {}
	for _, it in items do
		local path = model.norm(it.file)
		local f = model.file(suite, path, root, home)
		local prev = old[path]
		if prev and f.error == nil then
			f.output = prev.output
		end
		if files_only then
			if prev then
				for _, t in prev.tests do
					f.byId[t.id] = t
					table.insert(f.tests, t)
				end
			end
		elseif it.id and it.name then
			local prevTest = if prev then prev.byId[it.id] else nil
			if prevTest then
				prevTest.name = it.name
				prevTest.line = it.line or prevTest.line
				f.byId[it.id] = prevTest
				table.insert(f.tests, prevTest)
			else
				model.test(f, it.id, it.name, it.line)
			end
		end
	end
	model.sort(suite)
end

-- ---------------------------------------------------------------- events

export type Target = {
	-- Test ids the run was limited to (nil: no limit).
	ids: { [string]: boolean }?,
	-- Files the run was limited to (nil: no limit).
	files: { [string]: boolean }?,
}

local VALID: { [string]: Status } = {
	passed = "passed",
	failed = "failed",
	error = "error",
	skipped = "skipped",
}

-- Whether a result for test `id` in `path` belongs to the run's targets: a filtered
-- run reports the tests it didn't select as skipped, which must not overwrite them.
local function targeted(target: Target?, path: string, id: string): boolean
	if target == nil then
		return true
	end
	if target.ids then
		return target.ids[id] == true
	end
	if target.files then
		return target.files[path] == true
	end
	return true
end

local function err_of(v: any): TestError?
	if type(v) ~= "table" then
		return nil
	end
	local frames: { Frame } = {}
	if type(v.frames) == "table" then
		for _, f in v.frames do
			if type(f) == "table" then
				local code = nil
				if type(f.code) == "table" and type(f.code.lines) == "table" then
					code = { start = tonumber(f.code.start), lines = f.code.lines }
				end
				table.insert(frames, {
					file = if type(f.file) == "string" then model.norm(f.file) else nil,
					line = tonumber(f.line),
					col = tonumber(f.col),
					fn = if type(f.fn) == "string" then f.fn else nil,
					app = f.app == true,
					code = code,
				})
			end
		end
	end
	return {
		type = if type(v.type) == "string" then v.type else nil,
		message = if type(v.message) == "string" then v.message else nil,
		frames = frames,
		text = if type(v.text) == "string" then v.text else nil,
		diff = if type(v.diff) == "string" then v.diff else nil,
		phase = if type(v.phase) == "string" then v.phase else nil,
	}
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function is_js(kind: Kind): boolean
	return kind == "vitest" or kind == "jest"
end

-- Applies one runner event to the suite. Returns true when something visible changed.
function model.apply(suite: Suite, ev: { [string]: any }, target: Target?, root: string, home: string?): boolean
	local kind = ev.ev
	if kind == "start" then
		if type(ev.id) ~= "string" then
			return false
		end
		for _, f in suite.files do
			local t = f.byId[ev.id]
			if t and (t.status == "queued" or t.status == "idle") then
				t.status = "running"
				return true
			end
		end
		return false
	elseif kind == "result" then
		local status: Status? = VALID[tostring(ev.status)]
		local name = str(ev.name)
		if status == nil or name == nil then
			return false
		end
		local path = if type(ev.file) == "string" then model.norm(ev.file) else model.join(suite.dir, "?")
		local id = if is_js(suite.kind) then model.js_id(path, name) else (str(ev.id) or name)
		if not targeted(target, path, id) then
			return false
		end
		local f = model.file(suite, path, root, home)
		local fresh = f.byId[id] == nil
		local t = model.test(f, id, name, tonumber(ev.line))
		t.status = status
		t.duration = tonumber(ev.duration)
		t.error = err_of(ev.error)
		t.output = str(ev.output)
		t.reason = str(ev.reason)
		if fresh then
			table.sort(f.tests, by_line)
			if #f.tests == 1 then
				model.sort(suite)
			end
		end
		return true
	elseif kind == "file_error" then
		if type(ev.file) ~= "string" then
			return false
		end
		local f = model.file(suite, ev.file, root, home)
		local e: TestError = err_of(ev.error) or {
			type = "Error",
			message = str(ev.message),
			frames = {},
			text = str(ev.text),
		}
		if e.message == nil then
			e.message = str(ev.message)
		end
		if e.text == nil then
			e.text = str(ev.text)
		end
		f.error = e
		model.sort(suite)
		return true
	elseif kind == "output" then
		local text = str(ev.text)
		if text == nil then
			return false
		end
		if type(ev.file) == "string" then
			local f = model.file(suite, ev.file, root, home)
			f.output = text
		else
			suite.output = text
		end
		return true
	elseif kind == "fatal" then
		suite.problem = "The test runner failed"
		suite.detail = str(ev.message)
		return true
	end
	return false
end

-- ---------------------------------------------------------------- counts

function model.counts(): Counts
	return { total = 0, passed = 0, failed = 0, skipped = 0, running = 0, queued = 0, idle = 0, duration = 0 }
end

function model.add_test(c: Counts, t: Test)
	c.total += 1
	local s = t.status
	if s == "passed" then
		c.passed += 1
	elseif s == "failed" or s == "error" then
		c.failed += 1
	elseif s == "skipped" then
		c.skipped += 1
	elseif s == "running" then
		c.running += 1
	elseif s == "queued" then
		c.queued += 1
	else
		c.idle += 1
	end
	c.duration += t.duration or 0
end

function model.file_counts(f: File): Counts
	local c = model.counts()
	for _, t in f.tests do
		model.add_test(c, t)
	end
	if f.error then
		c.failed += 1
	end
	return c
end

function model.suite_counts(s: Suite): Counts
	local c = model.counts()
	for _, f in s.files do
		for _, t in f.tests do
			model.add_test(c, t)
		end
		if f.error then
			c.failed += 1
		end
	end
	return c
end

-- The status a group of tests shows: failures win, then work in progress.
function model.rollup(c: Counts, problem: boolean?): Status
	if problem or c.failed > 0 then
		return "failed"
	elseif c.running > 0 then
		return "running"
	elseif c.queued > 0 then
		return "queued"
	elseif c.passed > 0 and c.idle == 0 then
		return "passed"
	elseif c.total > 0 and c.skipped == c.total then
		return "skipped"
	elseif c.passed > 0 then
		return "passed"
	end
	return "idle"
end

-- ---------------------------------------------------------------- rows

-- The rows the left pane lists: a suite row per suite when there are several, its files,
-- and the tests of open files. `keys` gives each identity a short, stable row key.
function model.rows(
	suites: { Suite },
	open: { [string]: boolean },
	keys: { [string]: string },
	nextKey: () -> string,
	filter: ((Test) -> boolean)?
): { Row }
	local rows: { Row } = {}
	local function key(ident: string): string
		local k = keys[ident]
		if k == nil then
			k = nextKey()
			keys[ident] = k
		end
		return k
	end
	local headed = #suites > 1
	for _, s in suites do
		local depth = 0
		if headed then
			table.insert(rows, { key = key(s.ident), kind = "suite", depth = 0, suite = s, file = nil, test = nil })
			depth = 1
		end
		if not headed or open[s.ident] ~= false then
			for _, f in s.files do
				local shown: { Test } = {}
				for _, t in f.tests do
					if filter == nil or filter(t) then
						table.insert(shown, t)
					end
				end
				if filter == nil or #shown > 0 or (f.error ~= nil) then
					table.insert(rows, { key = key(f.ident), kind = "file", depth = depth, suite = s, file = f, test = nil })
					if open[f.ident] == true or (filter ~= nil and open[f.ident] ~= false) then
						for _, t in shown do
							table.insert(rows, { key = key(t.ident), kind = "test", depth = depth + 1, suite = s, file = f, test = t })
						end
					end
				end
			end
		end
	end
	return rows
end

-- ---------------------------------------------------------------- cache

-- The results worth keeping between sessions: per suite, each file's tests and errors.
function model.snapshot(suites: { Suite }): any
	local out = {}
	for _, s in suites do
		local files = {}
		for _, f in s.files do
			local tests = {}
			for _, t in f.tests do
				local status = t.status
				if status == "running" or status == "queued" then
					status = "idle"
				end
				table.insert(tests, {
					id = t.id,
					name = t.name,
					line = t.line,
					status = status,
					duration = t.duration,
					error = t.error,
					output = t.output,
					reason = t.reason,
				})
			end
			table.insert(files, { path = f.path, error = f.error, output = f.output, tests = tern.json.array(tests) })
		end
		out[s.ident] = { files = tern.json.array(files) }
	end
	return out
end

-- Puts cached results into a suite that has no collection yet.
function model.restore(suite: Suite, cached: any, root: string, home: string?)
	if type(cached) ~= "table" or type(cached.files) ~= "table" then
		return
	end
	for _, cf in cached.files do
		if type(cf) == "table" and type(cf.path) == "string" then
			local f = model.file(suite, cf.path, root, home)
			f.error = err_of(cf.error)
			f.output = str(cf.output)
			if type(cf.tests) == "table" then
				for _, ct in cf.tests do
					if type(ct) == "table" and type(ct.id) == "string" and type(ct.name) == "string" then
						local t = model.test(f, ct.id, ct.name, tonumber(ct.line))
						t.status = VALID[tostring(ct.status)] or "idle"
						t.duration = tonumber(ct.duration)
						t.error = err_of(ct.error)
						t.output = str(ct.output)
						t.reason = str(ct.reason)
					end
				end
			end
		end
	end
	model.sort(suite)
end

return model
