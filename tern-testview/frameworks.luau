--!strict
-- Finding test suites under a workspace and the command lines that collect and run them:
-- pytest and unittest (through helpers/testview_py.py), vitest and jest (through the
-- reporters in helpers/). Everything here is synchronous and cheap; the host runs the
-- processes.

local model = require("./model")

type Suite = model.Suite

local frameworks = {}

local HOME = tern.getenv("HOME") or ""

-- Directories the scan never enters.
local PRUNE = {
	"node_modules", ".*", "__pycache__", "venv", "env", "dist", "build", "target", "site-packages", "coverage",
}

local PY_MARKERS: { [string]: boolean } = {
	["pyproject.toml"] = true,
	["pytest.ini"] = true,
	["setup.py"] = true,
	["setup.cfg"] = true,
	["tox.ini"] = true,
}

local SCAN_DEPTH = "4"

-- The daemon's PATH often lacks what a login shell adds (Homebrew, nvm, volta), and a
-- `#!/usr/bin/env node` runner needs node on it.
function frameworks.path_env(): string
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	local function add(dir: string?)
		if dir and dir ~= "" and not seen[dir] then
			seen[dir] = true
			table.insert(out, dir)
		end
	end
	for dir in string.gmatch(tern.getenv("PATH") or "", "[^:]+") do
		add(dir)
	end
	if HOME ~= "" then
		add(HOME .. "/.local/bin")
		add(HOME .. "/.volta/bin")
		add(HOME .. "/.bun/bin")
		local nvm = HOME .. "/.nvm/versions/node"
		local ok, versions = pcall(tern.fs.list, nvm)
		if ok and #versions > 0 then
			table.sort(versions, function(a: string, b: string): boolean
				local function parts(v: string): { number }
					local p = {}
					for n in string.gmatch(v, "%d+") do
						table.insert(p, tonumber(n :: string) :: number)
					end
					return p
				end
				local pa, pb = parts(a), parts(b)
				for i = 1, math.max(#pa, #pb) do
					local x, y = pa[i] or 0, pb[i] or 0
					if x ~= y then
						return x > y
					end
				end
				return a > b
			end)
			add(nvm .. "/" .. versions[1] .. "/bin")
		end
	end
	for _, dir in { "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin" } do
		add(dir)
	end
	return table.concat(out, ":")
end

-- The workspace a directory belongs to: the nearest enclosing git checkout, else itself.
function frameworks.root_of(dir: string): string
	local d = dir
	while d ~= "/" and d ~= "" and d ~= HOME do
		if tern.fs.exists(d .. "/.git") then
			return d
		end
		d = model.dirname(d)
	end
	return dir
end

function frameworks.scan_argv(root: string): { string }
	local argv = { "find", root, "-mindepth", "1", "-maxdepth", SCAN_DEPTH, "(" }
	for i, name in PRUNE do
		if i > 1 then
			table.insert(argv, "-o")
		end
		table.insert(argv, "-name")
		table.insert(argv, name)
	end
	for _, part in { ")", "-prune", "-o", "(", "-name", "package.json" } do
		table.insert(argv, part)
	end
	for name in PY_MARKERS do
		table.insert(argv, "-o")
		table.insert(argv, "-name")
		table.insert(argv, name)
	end
	for _, part in { ")", "-type", "f", "-print" } do
		table.insert(argv, part)
	end
	return argv
end

local function read_json(path: string): any
	local ok, text = pcall(tern.fs.read, path, 1024 * 1024)
	if not ok then
		return nil
	end
	local ok2, data = pcall(tern.json.decode, text)
	return if ok2 then data else nil
end

-- The JS runner a package.json uses, if any.
local function js_kind(dir: string, pkg: any): model.Kind?
	if type(pkg) ~= "table" then
		return nil
	end
	local deps: { [string]: any } = {}
	for _, field in { "dependencies", "devDependencies", "peerDependencies" } do
		local t = pkg[field]
		if type(t) == "table" then
			for k, v in t do
				deps[k] = v
			end
		end
	end
	local script = if type(pkg.scripts) == "table" and type(pkg.scripts.test) == "string" then pkg.scripts.test else ""
	if deps.vitest or string.find(script, "vitest", 1, true) then
		return "vitest"
	end
	if deps.jest or deps["ts-jest"] or deps["babel-jest"] or pkg.jest ~= nil or string.find(script, "jest", 1, true) then
		return "jest"
	end
	for _, name in { "vitest.config.ts", "vitest.config.js", "vitest.config.mts", "vitest.config.mjs" } do
		if tern.fs.exists(dir .. "/" .. name) then
			return "vitest"
		end
	end
	for _, name in { "jest.config.js", "jest.config.ts", "jest.config.cjs", "jest.config.mjs", "jest.config.json" } do
		if tern.fs.exists(dir .. "/" .. name) then
			return "jest"
		end
	end
	return nil
end

-- `name` in `dir` or the nearest directory above it, up to `root`.
local function find_up(dir: string, root: string, names: { string }): string?
	local d = dir
	while true do
		for _, name in names do
			local p = d .. "/" .. name
			if tern.fs.exists(p) then
				return p
			end
		end
		if d == root or d == "/" or #d < #root then
			return nil
		end
		d = model.dirname(d)
	end
end

local PYTHONS = { ".venv/bin/python", "venv/bin/python", ".env/bin/python", "env/bin/python" }

function frameworks.python_for(dir: string, root: string): string
	return find_up(dir, root, PYTHONS) or "python3"
end

-- Suites from the scan's output (one marker file per line), in path order; a project
-- nested in another one of the same family is left to the outer one, which runs it too.
function frameworks.suites(scan: string, root: string): { Suite }
	local js: { [string]: model.Kind } = {}
	local py: { [string]: boolean } = {}
	for line in string.gmatch(scan, "[^\n]+") do
		local name = model.basename(line)
		local dir = model.dirname(line)
		if name == "package.json" then
			local kind = js_kind(dir, read_json(line))
			if kind then
				js[dir] = kind :: model.Kind
			end
		elseif PY_MARKERS[name] then
			py[dir] = true
		end
	end
	if tern.fs.exists(root .. "/package.json") and js[root] == nil then
		local kind = js_kind(root, read_json(root .. "/package.json"))
		if kind then
			js[root] = kind :: model.Kind
		end
	end
	for name in PY_MARKERS do
		if tern.fs.exists(root .. "/" .. (name :: string)) then
			py[root] = true
		end
	end
	local entries: { { dir: string, kind: model.Kind } } = {}
	for dir, kind in js do
		table.insert(entries, { dir = dir, kind = kind :: model.Kind })
	end
	for dir in py do
		table.insert(entries, { dir = dir, kind = "python" :: model.Kind })
	end
	table.sort(entries, function(a, b)
		if a.dir ~= b.dir then
			return a.dir < b.dir
		end
		return a.kind < b.kind
	end)
	local taken: { { dir: string, family: string } } = {}
	local suites: { Suite } = {}
	for _, e in entries do
		local family = if e.kind == "python" then "py" else e.kind
		local nested = false
		for _, t in taken do
			if t.family == family and string.sub(e.dir, 1, #t.dir + 1) == t.dir .. "/" then
				nested = true
			end
		end
		if not nested then
			table.insert(taken, { dir = e.dir, family = family })
			local s = model.suite(e.kind, e.dir, root, HOME)
			if e.kind == "python" then
				s.python = frameworks.python_for(e.dir, root)
			else
				s.bin = find_up(e.dir, root, { "node_modules/.bin/" .. e.kind })
				if s.bin == nil then
					s.problem = e.kind .. " is not installed"
					s.detail = "package.json in " .. s.rel .. " uses " .. e.kind .. ", but node_modules/.bin/" .. e.kind
						.. " is missing. Install the dependencies (npm install), then rescan."
					s.phase = "failed"
				end
			end
			table.insert(suites, s)
		end
	end
	return suites
end

-- A fallback suite for a workspace with test files but no project markers.
function frameworks.bare_python(root: string): Suite
	local s = model.suite("python", root, root, HOME)
	s.python = frameworks.python_for(root, root)
	return s
end

-- ---------------------------------------------------------------- commands

export type Command = {
	argv: { string },
	cwd: string,
	-- How the result arrives: as events in the out file, or in stdout.
	via: "events" | "vitest-list" | "jest-list",
}

local function helper(name: string): string
	return tern.plugin.dir .. "/helpers/" .. name
end

function frameworks.collect(s: Suite, out: string): Command
	if s.kind == "vitest" then
		return { argv = { s.bin :: string, "list", "--json" }, cwd = s.dir, via = "vitest-list" }
	elseif s.kind == "jest" then
		return { argv = { s.bin :: string, "--listTests" }, cwd = s.dir, via = "jest-list" }
	end
	local framework = if s.kind == "python" then "auto" else s.kind
	return {
		argv = { s.python or "python3", helper("testview_py.py"), "collect", "--out", out, "--framework", framework },
		cwd = s.dir,
		via = "events",
	}
end

-- A run limited to `tests` (each `{file, id, name}`) or to `files`; neither runs everything.
export type Selection = {
	tests: { { file: string, id: string, name: string } }?,
	files: { string }?,
}

-- JS regex source matching `s` literally.
local function rx(s: string): string
	return (string.gsub(s, "[%^%$%(%)%%%.%[%]%*%+%-%?{}|\\/]", function(c: string): string
		return "\\" .. c
	end))
end

-- A -t pattern matching exactly these full names, describe blocks joined by `sep`.
local function name_pattern(names: { string }, sep: string): string
	local alts: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, name in names do
		local parts: { string } = {}
		local norm = string.gsub(name, " > ", "\0")
		for part in string.gmatch(norm, "[^%z]+") do
			table.insert(parts, rx(part))
		end
		local alt = table.concat(parts, sep)
		if not seen[alt] then
			seen[alt] = true
			table.insert(alts, alt)
		end
	end
	return "^(?:" .. table.concat(alts, "|") .. ")$"
end

local function unique_files(sel: Selection): { string }
	local files: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(f: string)
		if not seen[f] then
			seen[f] = true
			table.insert(files, f)
		end
	end
	local tests = sel.tests
	if tests then
		for _, t in tests do
			add(t.file)
		end
	end
	local files_ = sel.files
	if files_ then
		for _, f in files_ do
			add(f)
		end
	end
	return files
end

function frameworks.run(s: Suite, out: string, sel: Selection): Command
	local kind = s.kind
	if kind == "vitest" or kind == "jest" then
		local argv: { string } = { s.bin :: string }
		if kind == "vitest" then
			table.insert(argv, "run")
			table.insert(argv, "--reporter=" .. helper("vitest-reporter.mjs"))
		else
			table.insert(argv, "--reporters=" .. helper("jest-reporter.cjs"))
			table.insert(argv, "--testLocationInResults")
		end
		local files = unique_files(sel)
		if #files > 0 then
			if kind == "jest" then
				table.insert(argv, "--runTestsByPath")
			end
			for _, f in files do
				table.insert(argv, model.rel(f, s.dir))
			end
		end
		if sel.tests and #sel.tests > 0 then
			local names: { string } = {}
			for _, t in sel.tests do
				table.insert(names, t.name)
			end
			table.insert(argv, "-t")
			table.insert(argv, name_pattern(names, if kind == "vitest" then "(?: > | )" else " "))
		end
		return { argv = argv, cwd = s.dir, via = "events" }
	end
	local argv: { string } = {
		s.python or "python3",
		helper("testview_py.py"),
		"run",
		"--out",
		out,
		"--framework",
		if kind == "unittest" then "unittest" else "pytest",
	}
	if sel.tests then
		for _, t in sel.tests do
			table.insert(argv, t.id)
		end
	elseif sel.files then
		for _, f in sel.files do
			table.insert(argv, f)
		end
	end
	return { argv = argv, cwd = if kind == "pytest" then (s.rootdir or s.dir) else s.dir, via = "events" }
end

function frameworks.env(out: string): { [string]: string }
	return {
		PATH = frameworks.path_env(),
		TESTVIEW_OUT = out,
		PYTHONUNBUFFERED = "1",
		NO_COLOR = "1",
		FORCE_COLOR = "0",
	}
end

-- Tests from `vitest list --json`; nil when stdout holds no list.
function frameworks.parse_vitest_list(stdout: string): { model.Collected }?
	local start = string.find(stdout, "[", 1, true)
	if start == nil then
		return nil
	end
	local ok, data = pcall(tern.json.decode, string.sub(stdout, start))
	if not ok or type(data) ~= "table" then
		return nil
	end
	local items: { model.Collected } = {}
	for _, it in data do
		if type(it) == "table" and type(it.file) == "string" and type(it.name) == "string" then
			local file = model.norm(it.file)
			table.insert(items, {
				id = model.js_id(file, it.name),
				file = file,
				name = it.name,
				line = if type(it.location) == "table" then tonumber(it.location.line) else nil,
			})
		end
	end
	return items
end

-- Files from `jest --listTests`.
function frameworks.parse_jest_list(stdout: string): { model.Collected }
	local items: { model.Collected } = {}
	for line in string.gmatch(stdout, "[^\n]+") do
		if string.sub(line, 1, 1) == "/" then
			table.insert(items, { file = model.norm(line) })
		end
	end
	return items
end

frameworks.HOME = HOME

return frameworks
