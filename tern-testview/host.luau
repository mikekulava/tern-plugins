--!strict
-- The `explorer` block: finds the test suites under a workspace, lists their tests by
-- file, runs them (all, a suite, a file, one test, the failed ones) and shows each
-- result's trace and output.
--
-- Runs happen one at a time. Each is a runner process writing JSON events to a file in
-- the plugin's data directory (see helpers/); a timer reads new events while it runs.

local model = require("./model")
local frameworks = require("./frameworks")
local view = require("./view")

type Suite = model.Suite
type File = model.File
type Test = model.Test
type Row = model.Row

local POLL_MS = 250
local SCAN_TIMEOUT_MS = 30 * 1000
local COLLECT_TIMEOUT_MS = 3 * 60 * 1000
local RUN_TIMEOUT_MS = 60 * 60 * 1000
local MAX_EVENTS_BYTES = 64 * 1024 * 1024

local HOME = frameworks.HOME
local DATA = tern.plugin.data
local RUNS = DATA .. "/runs"
local CACHE = DATA .. "/cache"

type Job = {
	kind: "collect" | "run",
	suite: Suite,
	cmd: frameworks.Command?,
	target: model.Target?,
	sel: frameworks.Selection?,
	out: string,
	pidfile: string,
	offset: number,
	collected: any,
	done: boolean,
	stopped: boolean,
	timer: TimerHandle?,
	total: number,
	finished: number,
	seen: { [string]: boolean },
	current: string?,
	started: number,
}

type State = {
	cx: BlockCx,
	root: string,
	focus: string?,
	phase: "scanning" | "ready" | "failed",
	problem: string?,
	suites: { Suite },
	open: { [string]: boolean },
	keys: { [string]: string },
	byKey: { [string]: string },
	keyCount: number,
	sel: string?,
	sizes: { number }?,
	hidePassed: boolean,
	queue: { Job },
	job: Job?,
	lastRun: { at: number, took: number }?,
	runStarted: number?,
	cached: any,
	seq: number,
}

-- A pane id survives Restart; the state object identifies this block run.
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
	end
	local job = state.job
	if job and job.timer then
		job.timer:cancel()
		job.timer = nil
	end
	state.queue = {}
end

-- Blocks have no close hook: callbacks check the run is current and its pane is there.
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

-- ---------------------------------------------------------------- rows and selection

local function key_of(state: State, ident: string): string
	local k = state.keys[ident]
	if k == nil then
		state.keyCount += 1
		k = "r" .. state.keyCount
		state.keys[ident] = k
		state.byKey[k] = ident
	end
	return k
end

local function rows(state: State): { Row }
	local filter = nil
	if state.hidePassed then
		filter = function(t: Test): boolean
			return t.status ~= "passed" and t.status ~= "skipped"
		end
	end
	return model.rows(state.suites, state.open, state.keys, function(): string
		state.keyCount += 1
		return "r" .. state.keyCount
	end, filter)
end

-- Registers the keys `model.rows` just assigned, so events can map a key back.
local function index(state: State, list: { Row }): { [string]: Row }
	local by: { [string]: Row } = {}
	for _, r in list do
		by[r.key] = r
		local ident = if r.kind == "test" then (r.test :: Test).ident elseif r.kind == "file" then (r.file :: File).ident else r.suite.ident
		state.byKey[r.key] = ident
	end
	return by
end

local function selected_row(state: State, list: { Row }): Row?
	if state.sel == nil then
		return nil
	end
	for _, r in list do
		local ident = if r.kind == "test" then (r.test :: Test).ident elseif r.kind == "file" then (r.file :: File).ident else r.suite.ident
		if ident == state.sel then
			return r
		end
	end
	return nil
end

local function ident_of(r: Row): string
	if r.kind == "test" then
		return (r.test :: Test).ident
	elseif r.kind == "file" then
		return (r.file :: File).ident
	end
	return r.suite.ident
end

-- Finds the test, file or suite an identity names.
local function lookup(state: State, ident: string): (Suite?, File?, Test?)
	for _, s in state.suites do
		if s.ident == ident then
			return s, nil, nil
		end
		if string.sub(ident, 1, #s.ident + 1) == s.ident .. "|" then
			for _, f in s.files do
				if f.ident == ident then
					return s, f, nil
				end
				if string.sub(ident, 1, #f.ident + 1) == f.ident .. "|" then
					for _, t in f.tests do
						if t.ident == ident then
							return s, f, t
						end
					end
				end
			end
		end
	end
	return nil, nil, nil
end

-- Makes sure the selected row is listed: opens its file and suite.
local function reveal(state: State, ident: string)
	local s, f, t = lookup(state, ident)
	if s then
		state.open[s.ident] = true
	end
	if f and t then
		state.open[f.ident] = true
	end
end

-- ---------------------------------------------------------------- cache

local function cache_path(root: string): string
	local name = string.gsub(root, "[^%w%-_]", "_")
	if #name > 120 then
		name = string.sub(name, -120)
	end
	return CACHE .. "/" .. name .. ".json"
end

local function load_cache(root: string): any
	local path = cache_path(root)
	if not tern.fs.exists(path) then
		return nil
	end
	local ok, text = pcall(tern.fs.read, path, 32 * 1024 * 1024)
	if not ok then
		return nil
	end
	local ok2, data = pcall(tern.json.decode, text)
	return if ok2 then data else nil
end

local function save_cache(state: State)
	local ok, err = pcall(function()
		tern.fs.mkdir(CACHE)
		tern.fs.write(cache_path(state.root), tern.json.encode(model.snapshot(state.suites)))
	end)
	if not ok then
		tern.log.warn("testview: could not write the results cache", err)
	end
end

-- ---------------------------------------------------------------- processes

local function tail(text: string, lines: number): string
	local all: { string } = {}
	for line in string.gmatch(text, "[^\n]*") do
		table.insert(all, line)
	end
	while #all > 0 and all[#all] == "" do
		table.remove(all)
	end
	local from = math.max(1, #all - lines + 1)
	return table.concat(all, "\n", from)
end

-- Starts `argv` in `cwd`, recording its pid in `pidfile` so Stop can end it.
local function spawn(argv: { string }, cwd: string, env: { [string]: string }, timeout: number, pidfile: string?, done: (ProcessResult) -> ()): string?
	local full = argv
	if pidfile then
		full = { "/bin/sh", "-c", 'echo $$ > "$0"; exec "$@"', pidfile }
		for _, a in argv do
			table.insert(full, a)
		end
	end
	local ok, err = pcall(function()
		tern.process.run(full, { cwd = cwd, env = env, timeout_ms = timeout }, function(result: ProcessResult, _)
			done(result)
		end)
	end)
	return if ok then nil else tostring(err)
end

local pump: (State) -> ()
local scan: (State) -> ()

-- Reads the events the runner appended since the last read; true when the view changed.
local function drain(state: State, job: Job): boolean
	if not tern.fs.exists(job.out) then
		return false
	end
	local ok, data = pcall(tern.fs.read, job.out, MAX_EVENTS_BYTES)
	if not ok or #data <= job.offset then
		return false
	end
	local chunk = string.sub(data, job.offset + 1)
	local last = 0
	local changed = false
	local pos = 1
	while true do
		local nl = string.find(chunk, "\n", pos, true)
		if nl == nil then
			break
		end
		local line = string.sub(chunk, pos, nl - 1)
		pos = nl + 1
		last = nl
		local decoded, ev = pcall(tern.json.decode, line)
		if decoded and type(ev) == "table" then
			if ev.ev == "collect" then
				job.collected = ev
			elseif ev.ev == "done" then
				job.done = true
			else
				if ev.ev == "start" and type(ev.id) == "string" then
					local id: string = ev.id
					job.current = string.match(id, "::([^:]+)$") or string.match(id, "%.([^%.]+)$") or id
				end
				if model.apply(job.suite, ev, job.target, state.root, HOME) then
					changed = true
					if ev.ev == "result" then
						local k = tostring(ev.file) .. "\0" .. tostring(ev.id or ev.name)
						if not job.seen[k] then
							job.seen[k] = true
							job.finished += 1
						end
					end
				end
			end
		end
	end
	job.offset += last
	return changed
end

local function poll(state: State, job: Job)
	job.timer = tern.timer(POLL_MS, function()
		job.timer = nil
		if not alive(state) or state.job ~= job then
			return
		end
		if drain(state, job) then
			state.cx:render()
		end
		poll(state, job)
	end)
end

-- Tests a run touches: everything, or what the target names.
local function each_target(job: Job, fn: (Test, File) -> ())
	for _, f in job.suite.files do
		for _, t in f.tests do
			local target = job.target
			local hit = target == nil
				or (target.ids ~= nil and target.ids[t.id] == true)
				or (target.ids == nil and target.files ~= nil and target.files[f.path] == true)
			if hit then
				fn(t, f)
			end
		end
	end
end

local function finish_collect(state: State, job: Job, result: ProcessResult)
	local s = job.suite
	local cmd = job.cmd :: frameworks.Command
	s.phase = "ready"
	local items: { model.Collected }? = nil
	if cmd.via == "vitest-list" then
		items = frameworks.parse_vitest_list(result.stdout)
	elseif cmd.via == "jest-list" then
		items = if result.status == 0 then frameworks.parse_jest_list(result.stdout) else nil
	else
		drain(state, job)
		local c = job.collected
		if type(c) == "table" and type(c.tests) == "table" then
			if c.framework == "pytest" or c.framework == "unittest" then
				s.kind = c.framework
			end
			if type(c.rootdir) == "string" then
				s.rootdir = model.norm(c.rootdir)
			end
			local list: { model.Collected } = {}
			for _, t in c.tests do
				if type(t) == "table" and type(t.id) == "string" and type(t.file) == "string" then
					table.insert(list, {
						id = t.id,
						file = t.file,
						name = if type(t.name) == "string" then t.name else t.id,
						line = tonumber(t.line),
					})
				end
			end
			items = list
		end
	end
	if items == nil then
		s.phase = "failed"
		if s.problem == nil then
			s.problem = "Could not list the tests"
			local text = result.stderr ~= "" and result.stderr or result.stdout
			s.detail = if result.timed_out then "The runner did not answer in time." else tail(text, 40)
		end
		return
	end
	-- Keep file errors the collection reported (a test module that fails to import).
	local errors: { [string]: model.TestError } = {}
	for _, f in s.files do
		if f.error then
			errors[f.path] = f.error
		end
	end
	model.collect(s, items, state.root, HOME, cmd.via == "jest-list")
	for path, e in errors do
		local f = model.file(s, path, state.root, HOME)
		f.error = e
	end
	model.sort(s)
end

local function finish_run(state: State, job: Job, result: ProcessResult)
	drain(state, job)
	local s = job.suite
	local reported = job.finished
	each_target(job, function(t: Test)
		if t.status == "queued" or t.status == "running" then
			t.status = "idle"
		end
	end)
	if job.stopped then
		return
	end
	if reported == 0 and result.status ~= 0 then
		local hasFileError = false
		for _, f in s.files do
			hasFileError = hasFileError or f.error ~= nil
		end
		if not hasFileError then
			s.problem = if result.timed_out then "The run timed out" else "The run failed (exit " .. result.status .. ")"
			local text = result.stderr ~= "" and result.stderr or result.stdout
			s.detail = tail(text, 60)
		end
	elseif s.problem and s.phase ~= "failed" then
		s.problem, s.detail = nil, nil
	end
end

local function start_job(state: State, job: Job)
	local s = job.suite
	state.job = job
	pcall(tern.fs.mkdir, RUNS)
	pcall(tern.fs.remove, job.out)
	local cmd: frameworks.Command
	if job.kind == "collect" then
		s.phase = "collecting"
		cmd = frameworks.collect(s, job.out)
	else
		cmd = frameworks.run(s, job.out, job.sel or {})
		-- A fresh run clears earlier problems with file loading; results bring them back.
		for _, f in s.files do
			if job.target == nil or (job.target.files and job.target.files[f.path]) then
				f.error = nil
				f.output = nil
			end
		end
		if job.target == nil then
			s.output = nil
		end
		each_target(job, function(t: Test)
			t.status = "queued"
			t.error = nil
			t.output = nil
			job.total += 1
		end)
	end
	job.cmd = cmd
	job.started = tern.now()
	local timeout = if job.kind == "collect" then COLLECT_TIMEOUT_MS else RUN_TIMEOUT_MS
	local err = spawn(cmd.argv, cmd.cwd, frameworks.env(job.out), timeout, job.pidfile, function(result)
		if not alive(state) or state.job ~= job then
			return
		end
		if job.timer then
			job.timer:cancel()
			job.timer = nil
		end
		if job.kind == "collect" then
			finish_collect(state, job, result)
		else
			finish_run(state, job, result)
		end
		pcall(tern.fs.remove, job.out)
		pcall(tern.fs.remove, job.pidfile)
		state.job = nil
		pump(state)
		state.cx:render()
	end)
	if err then
		state.job = nil
		s.phase = "failed"
		s.problem = "Could not start the runner"
		s.detail = err .. "\n\n" .. table.concat(cmd.argv, " ")
		pump(state)
		return
	end
	if job.kind == "run" or cmd.via == "events" then
		poll(state, job)
	end
end

local function new_job(state: State, kind: "collect" | "run", s: Suite): Job
	state.seq += 1
	local base = RUNS .. "/" .. state.cx.pane .. "-" .. state.seq
	return {
		kind = kind,
		suite = s,
		cmd = nil,
		target = nil,
		sel = nil,
		out = base .. ".jsonl",
		pidfile = base .. ".pid",
		offset = 0,
		collected = nil,
		done = false,
		stopped = false,
		timer = nil,
		total = 0,
		finished = 0,
		seen = {},
		current = nil,
		started = 0,
	}
end

-- Drops suites that turned out to hold no tests, once nothing is pending for them.
local function prune(state: State)
	local kept: { Suite } = {}
	for _, s in state.suites do
		local pending = false
		for _, j in state.queue do
			pending = pending or j.suite == s
		end
		if #s.files > 0 or s.problem ~= nil or pending or s.phase == "pending" or s.phase == "collecting"
			or (state.job ~= nil and state.job.suite == s) then
			table.insert(kept, s)
		end
	end
	state.suites = kept
end

pump = function(state: State)
	if state.job ~= nil then
		return
	end
	local job = table.remove(state.queue, 1)
	if job == nil then
		prune(state)
		if state.runStarted then
			state.lastRun = { at = os.time(), took = tern.now() - state.runStarted }
			state.runStarted = nil
			save_cache(state)
		end
		if state.focus then
			local s, f = nil, nil
			for _, suite in state.suites do
				local file = suite.byPath[state.focus]
				if file then
					s, f = suite, file
				end
			end
			if s and f then
				state.sel = f.ident
				state.open[f.ident] = true
			end
			state.focus = nil
		end
		return
	end
	start_job(state, job)
end

-- ---------------------------------------------------------------- actions

local function busy(state: State): boolean
	if state.job and state.job.kind == "run" then
		return true
	end
	for _, j in state.queue do
		if j.kind == "run" then
			return true
		end
	end
	return false
end

local function enqueue_run(state: State, s: Suite, target: model.Target?, sel: frameworks.Selection)
	if s.kind == "python" or s.phase == "collecting" or s.phase == "pending" or (s.problem and s.phase == "failed") then
		return
	end
	local job = new_job(state, "run", s)
	job.target = target
	job.sel = sel
	table.insert(state.queue, job)
end

local function run_all(state: State)
	if busy(state) then
		return
	end
	state.runStarted = tern.now()
	for _, s in state.suites do
		enqueue_run(state, s, nil, {})
	end
	pump(state)
end

local function run_tests(state: State, s: Suite, tests: { { test: Test, file: File } })
	if #tests == 0 then
		return
	end
	local ids: { [string]: boolean } = {}
	local sel: { { file: string, id: string, name: string } } = {}
	for _, it in tests do
		ids[it.test.id] = true
		table.insert(sel, { file = it.file.path, id = it.test.id, name = it.test.name })
	end
	enqueue_run(state, s, { ids = ids, files = nil }, { tests = sel })
end

local function run_files(state: State, s: Suite, files: { File })
	local set: { [string]: boolean } = {}
	local list: { string } = {}
	for _, f in files do
		set[f.path] = true
		table.insert(list, f.path)
	end
	if s.kind == "unittest" then
		-- unittest takes test ids, not files.
		local tests = {}
		for _, f in files do
			for _, t in f.tests do
				table.insert(tests, { test = t, file = f })
			end
		end
		local ids: { [string]: boolean } = {}
		local sel: { { file: string, id: string, name: string } } = {}
		for _, it in tests do
			ids[it.test.id] = true
			table.insert(sel, { file = it.file.path, id = it.test.id, name = it.test.name })
		end
		enqueue_run(state, s, { ids = nil, files = set }, { tests = sel })
		return
	end
	enqueue_run(state, s, { ids = nil, files = set }, { files = list })
end

local function run_selected(state: State)
	if busy(state) or state.sel == nil then
		return
	end
	local s, f, t = lookup(state, state.sel :: string)
	if s == nil then
		return
	end
	state.runStarted = tern.now()
	if t and f then
		run_tests(state, s, { { test = t, file = f } })
	elseif f then
		run_files(state, s, { f })
	else
		enqueue_run(state, s, nil, {})
	end
	pump(state)
end

local function rerun_failed(state: State)
	if busy(state) then
		return
	end
	state.runStarted = tern.now()
	for _, s in state.suites do
		local tests: { { test: Test, file: File } } = {}
		local broken: { File } = {}
		for _, f in s.files do
			if f.error then
				table.insert(broken, f)
			else
				for _, t in f.tests do
					if t.status == "failed" or t.status == "error" then
						table.insert(tests, { test = t, file = f })
					end
				end
			end
		end
		if #broken > 0 then
			run_files(state, s, broken)
		end
		run_tests(state, s, tests)
	end
	pump(state)
end

local function stop(state: State)
	local job = state.job
	-- Pending runs are dropped; a collection in the queue still happens.
	local kept: { Job } = {}
	for _, j in state.queue do
		if j.kind == "collect" then
			table.insert(kept, j)
		end
	end
	state.queue = kept
	if job == nil or job.kind ~= "run" then
		return
	end
	job.stopped = true
	local ok, pid = pcall(tern.fs.read, job.pidfile, 64)
	if ok then
		pid = string.match(pid, "%d+") or ""
		if pid ~= "" then
			spawn({ "/bin/sh", "-c", 'pkill -TERM -P "$0" 2>/dev/null; kill -TERM "$0" 2>/dev/null', pid }, "/", {}, 10000, nil, function() end)
		end
	end
	state.cx:toast("info", "Stopping the test run")
end

local function failure_text(t: Test): string
	local e = t.error
	if e == nil then
		return t.name
	end
	local parts: { string } = { t.name, "" }
	if e.text and e.text ~= "" then
		table.insert(parts, e.text)
	else
		table.insert(parts, (e.type or "Error") .. ": " .. (e.message or ""))
		for _, f in e.frames or ({} :: { model.Frame }) do
			table.insert(parts, string.format("    at %s (%s:%s)", f.fn or "?", f.file or "?", tostring(f.line or "?")))
		end
	end
	return table.concat(parts, "\n")
end

local function open_selected(state: State)
	if state.sel == nil then
		return
	end
	local _, f, t = lookup(state, state.sel :: string)
	if f == nil then
		return
	end
	local target = f.path
	if t and t.line then
		target ..= "#L" .. t.line
	end
	state.cx:open(target)
end

-- ---------------------------------------------------------------- scanning

scan = function(state: State)
	state.phase = "scanning"
	state.problem = nil
	local root = state.root
	local err = spawn(frameworks.scan_argv(root), root, { PATH = frameworks.path_env() }, SCAN_TIMEOUT_MS, nil, function(result)
		if not alive(state) then
			return
		end
		-- find exits non-zero for unreadable directories; what it printed still counts.
		if result.timed_out and result.stdout == "" then
			state.phase = "failed"
			state.problem = "Looking through " .. model.tilde(root, HOME) .. " took too long."
			state.cx:render()
			return
		end
		local found = frameworks.suites(result.stdout, root)
		if #found == 0 then
			found = { frameworks.bare_python(root) }
		end
		-- Keep the results the explorer already shows for suites still there.
		local old: { [string]: Suite } = {}
		for _, s in state.suites do
			old[s.dir .. "|" .. (if s.kind == "pytest" or s.kind == "unittest" then "python" else s.kind)] = s
		end
		local suites: { Suite } = {}
		for _, s in found do
			local prev = old[s.dir .. "|" .. s.kind]
			if prev and s.problem == nil then
				prev.python = s.python or prev.python
				prev.bin = s.bin or prev.bin
				prev.problem, prev.detail = nil, nil
				prev.phase = "pending"
				table.insert(suites, prev)
			else
				if state.cached and type(state.cached) == "table" then
					model.restore(s, state.cached[s.ident], root, HOME)
					if #s.files == 0 then
						-- A python suite's identity names the framework once collected.
						for _, k in { "pytest", "unittest" } do
							model.restore(s, state.cached["s|" .. s.dir .. "|" .. k], root, HOME)
						end
					end
				end
				table.insert(suites, s)
			end
		end
		state.suites = suites
		state.phase = "ready"
		for _, s in suites do
			if s.problem == nil then
				table.insert(state.queue, new_job(state, "collect", s))
			end
		end
		pump(state)
		state.cx:render()
	end)
	if err then
		state.phase = "failed"
		state.problem = err
	end
end

-- ---------------------------------------------------------------- moving

local function move(state: State, list: { Row }, delta: number)
	if #list == 0 then
		return
	end
	local at = 0
	for i, r in list do
		if ident_of(r) == state.sel then
			at = i
		end
	end
	local to = if at == 0 then 1 else math.clamp(at + delta, 1, #list)
	state.sel = ident_of(list[to])
end

local function fold(state: State, list: { Row }, openIt: boolean)
	local row = selected_row(state, list)
	if row == nil then
		return
	end
	if row.kind == "test" then
		if not openIt then
			state.sel = (row.file :: File).ident
		end
		return
	end
	local ident = ident_of(row)
	local isOpen = if row.kind == "suite" then state.open[ident] ~= false else state.open[ident] == true
	if openIt and not isOpen then
		state.open[ident] = true
	elseif not openIt and isOpen then
		state.open[ident] = false
	elseif not openIt and row.kind == "file" and #state.suites > 1 then
		state.sel = row.suite.ident
	end
end

local function toggle(state: State, row: Row)
	local ident = ident_of(row)
	if row.kind == "suite" then
		state.open[ident] = state.open[ident] == false
	elseif row.kind == "file" then
		state.open[ident] = not (state.open[ident] == true)
	end
end

-- ---------------------------------------------------------------- the block

local function failed_count(state: State): number
	local n = 0
	for _, s in state.suites do
		for _, f in s.files do
			if f.error then
				n += 1
			end
			for _, t in f.tests do
				if t.status == "failed" or t.status == "error" then
					n += 1
				end
			end
		end
	end
	return n
end

local function page(state: State, cx: BlockCx): view.Page
	local list = rows(state)
	index(state, list)
	local job = state.job
	local runningInfo = nil
	if job and job.kind == "run" then
		local queued = 0
		for _, j in state.queue do
			if j.kind == "run" then
				queued += 1
			end
		end
		local label = "Running " .. job.suite.kind .. (if job.suite.rel ~= "." then " in " .. job.suite.rel else "")
		if queued > 0 then
			label ..= " (+" .. queued .. " more)"
		end
		runningInfo = { label = label, done = job.finished, total = job.total, current = job.current }
	end
	return {
		root = state.root,
		home = HOME,
		phase = state.phase,
		problem = state.problem,
		suites = state.suites,
		rows = list,
		selected = selected_row(state, list),
		open = state.open,
		sizes = state.sizes,
		hidePassed = state.hidePassed,
		busy = busy(state),
		running = runningInfo,
		failed = failed_count(state),
		cols = cx.cols,
		rows_h = math.floor((cx.rows - 9) * 0.72),
		lastRun = state.lastRun,
		keyOf = function(ident: string): string
			return key_of(state, ident)
		end,
	}
end

local function is_dir(path: string): boolean
	local ok = pcall(tern.fs.list, path)
	return ok
end

tern.block.define("explorer", {
	font = "sans",

	init = function(cx: BlockCx, args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local start = args[1] or (if type(saved) == "table" then saved.start else nil) or cx.cwd or HOME
		start = model.norm(start)
		local focus = nil
		if not is_dir(start) and tern.fs.exists(start) then
			focus = start
			start = model.dirname(start)
		end
		local root = frameworks.root_of(start)
		local state: State = {
			cx = cx,
			root = root,
			focus = focus,
			phase = "scanning",
			problem = nil,
			suites = {},
			open = {},
			keys = {},
			byKey = {},
			keyCount = 0,
			sel = nil,
			sizes = nil,
			hidePassed = false,
			queue = {},
			job = nil,
			lastRun = nil,
			runStarted = nil,
			cached = load_cache(root),
			seq = 0,
		}
		if type(saved) == "table" and saved.root == root then
			if type(saved.open) == "table" then
				for k, v in saved.open do
					if type(k) == "string" and type(v) == "boolean" then
						state.open[k] = v
					end
				end
			end
			state.sel = if type(saved.sel) == "string" then saved.sel else nil
			if type(saved.sizes) == "table" and #saved.sizes == 2 then
				state.sizes = saved.sizes
			end
			state.hidePassed = saved.hidePassed == true
		end
		running[cx.pane] = state
		scan(state)
		return state
	end,

	title = function(state: State): string?
		local failed = failed_count(state)
		if busy(state) then
			return "Tests · running"
		elseif failed > 0 then
			return "Tests · " .. failed .. " failed"
		end
		return "Tests"
	end,

	view = function(state: State, cx: BlockCx): BlockView
		return view.render(page(state, cx))
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		local list = rows(state)
		index(state, list)
		if key.name == "up" or k == "k" then
			move(state, list, -1)
		elseif key.name == "down" or k == "j" then
			move(state, list, 1)
		elseif key.name == "page_up" then
			move(state, list, -10)
		elseif key.name == "page_down" then
			move(state, list, 10)
		elseif key.name == "home" or k == "g" then
			move(state, list, -#list)
		elseif key.name == "end" or k == "G" then
			move(state, list, #list)
		elseif key.name == "left" or k == "h" then
			fold(state, list, false)
		elseif key.name == "right" or k == "l" then
			fold(state, list, true)
		elseif key.name == "space" then
			local row = selected_row(state, list)
			if row then
				toggle(state, row)
			end
		elseif key.name == "enter" or k == "r" then
			run_selected(state)
		elseif k == "R" then
			run_all(state)
		elseif k == "f" or k == "F" then
			rerun_failed(state)
		elseif k == "o" or k == "O" then
			open_selected(state)
			return false
		elseif k == "c" or k == "C" then
			if state.sel then
				local _, _, t = lookup(state, state.sel :: string)
				if t and t.error then
					cx:copy(failure_text(t))
					cx:toast("success", "Copied the failure")
				end
			end
			return false
		elseif k == "p" or k == "P" then
			state.hidePassed = not state.hidePassed
		elseif k == "x" or k == "X" then
			stop(state)
		elseif k == "d" or k == "D" then
			if not busy(state) then
				scan(state)
			end
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if ev.ev == "select" or ev.ev == "activate" then
			local item = if type(ev.item) == "string" then string.match(ev.item, "([^%.]+)$") else nil
			local ident = if item then state.byKey[item] else nil
			if ident == nil then
				return
			end
			local fromTree = ev.id == view.TREE or ev.id == view.TREE_STACKED
			state.sel = ident
			if not fromTree then
				reveal(state, ident)
			end
			local list = rows(state)
			index(state, list)
			local row = selected_row(state, list)
			if ev.ev == "select" and fromTree and row and row.kind ~= "test" then
				toggle(state, row)
			elseif ev.ev == "activate" and row and row.kind == "test" then
				open_selected(state)
			end
		elseif ev.ev == "change" and ev.id == "main.split" and type(ev.value) == "table" then
			state.sizes = ev.value
		elseif ev.ev == "action" then
			local act = ev.act
			if act == "runall" then
				run_all(state)
			elseif act == "failed" then
				rerun_failed(state)
			elseif act == "run" then
				run_selected(state)
			elseif act == "stop" then
				stop(state)
			elseif act == "rescan" then
				if not busy(state) then
					scan(state)
				end
			elseif act == "open" then
				open_selected(state)
			elseif act == "copy" then
				if state.sel then
					local _, _, t = lookup(state, state.sel :: string)
					if t then
						cx:copy(failure_text(t))
						cx:toast("success", "Copied the failure")
					end
				end
			end
		end
	end,

	save = function(state: State): any
		local open: { [string]: boolean } = {}
		for k, v in state.open do
			open[k] = v
		end
		return {
			start = state.root,
			root = state.root,
			open = open,
			sel = state.sel,
			sizes = state.sizes,
			hidePassed = state.hidePassed,
		}
	end,
})
