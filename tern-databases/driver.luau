--!strict
-- Runs the plugin's Python driver (drivers/tdb.py): one process per request, the request (the
-- password included) on its stdin, one JSON answer on its stdout. A running request can be
-- cancelled: the driver writes its pid to a file, and SIGTERM makes it stop the statement the
-- way the database allows (PostgreSQL's cancel request, Trino's DELETE), then answer.

local driver = {}

local SCRIPT = tern.plugin.dir .. "/drivers/tdb.py"
local RUNS = tern.plugin.data .. "/runs"
-- Extra time the process gets past the driver's own deadline before it is killed.
local GRACE_MS = 15000

local PYTHONS = { "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3" }

local python_path: string? = nil
function driver.python(): string
	if python_path then
		return python_path
	end
	for _, p in PYTHONS do
		if tern.fs.exists(p) then
			python_path = p
			return p
		end
	end
	python_path = "python3"
	return "python3"
end

local function path_env(): string
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	local function add(dir: string)
		if dir ~= "" and not seen[dir] then
			seen[dir] = true
			table.insert(out, dir)
		end
	end
	for dir in string.gmatch(tern.getenv("PATH") or "", "[^:]+") do
		add(dir)
	end
	for _, dir in { "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin" } do
		add(dir)
	end
	return table.concat(out, ":")
end

export type Handle = { pid_file: string?, done: boolean, cancelled: boolean }

local runs = 0

-- Starts `req`; `cb(answer, err)` runs once with the decoded answer or why there is none.
function driver.start(req: { [string]: any }, timeout_ms: number, cb: (answer: any, err: string?) -> ()): Handle
	runs += 1
	local handle: Handle = { done = false, cancelled = false }
	if req.op == "run" or req.op == "schema" or req.op == "keys" then
		pcall(tern.fs.mkdir, RUNS)
		handle.pid_file = string.format("%s/%d-%d.pid", RUNS, math.floor(tern.now()), runs)
		req.pid_file = handle.pid_file
	end
	req.timeout_ms = timeout_ms
	local function done(r: ProcessResult, _cx: WindowCx?)
		handle.done = true
		if handle.pid_file then
			pcall(tern.fs.remove, handle.pid_file)
		end
		if r.timed_out then
			cb(nil, "The driver took longer than " .. tostring(math.floor((timeout_ms + GRACE_MS) / 1000)) .. " s and was stopped")
			return
		end
		local decoded_ok, answer = pcall(tern.json.decode, r.stdout)
		if decoded_ok and type(answer) == "table" then
			cb(answer, nil)
			return
		end
		local why = string.match(r.stderr, "([^\n]+)\n*$") or ""
		if string.find(r.stderr, "No such file", 1, true) or r.status == 127 then
			why = "Python 3 was not found: install it (Xcode's command line tools include it)"
		end
		cb(nil, "The driver failed (exit " .. tostring(r.status) .. ")" .. (if why ~= "" then ": " .. why else ""))
	end
	local ok, err = pcall(function(): any
		tern.process.run({ driver.python(), SCRIPT }, {
			stdin = tern.json.encode(req),
			timeout_ms = timeout_ms + GRACE_MS,
			env = { PATH = path_env(), PYTHONIOENCODING = "utf-8", PYTHONDONTWRITEBYTECODE = "1" },
		}, done)
		return nil
	end)
	if not ok then
		handle.done = true
		cb(nil, "Cannot start Python 3 (" .. driver.python() .. "): " .. tostring(err))
	end
	return handle
end

-- Asks a running request to stop; its callback still runs with what finished. The driver may
-- not have written its pid yet, so a missing file is looked for again a few times.
function driver.cancel(handle: Handle)
	if handle.done or handle.cancelled or not handle.pid_file then
		return
	end
	handle.cancelled = true
	local tries = 0
	local function kill()
		if handle.done then
			return
		end
		local ok, raw = pcall(tern.fs.read, handle.pid_file :: string, 32)
		local pid: string? = if ok and type(raw) == "string" then string.match(raw, "^%s*(%d+)%s*$") else nil
		if pid then
			pcall(tern.process.run, { "/bin/kill", "-TERM", pid :: string }, { timeout_ms = 5000 }, function(_r: ProcessResult, _cx: WindowCx?) end)
		elseif tries < 10 then
			tries += 1
			tern.timer(200, function(_cx: WindowCx?)
				kill()
			end)
		end
	end
	kill()
end

return driver
