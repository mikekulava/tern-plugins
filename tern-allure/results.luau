--!strict

local regex = require("./regex")

local results = {}

export type Status = "passed" | "failed" | "broken" | "skipped" | "unknown"

export type Counts = {
	total: number,
	passed: number,
	failed: number,
	broken: number,
	skipped: number,
	unknown: number,
}

export type Category = {
	name: string,
	statuses: { [string]: boolean }?,
	message: regex.Regex?,
	trace: regex.Regex?,
	wantsMessage: boolean,
	wantsTrace: boolean,
	flaky: boolean,
	broken: boolean,
}

export type Container = {
	uuid: string,
	file: string,
	children: { string },
}

export type Result = {
	uuid: string,
	file: string,
	name: string,
	fullName: string?,
	historyId: string,
	status: Status,
	message: string?,
	trace: string?,
	start: number?,
	stop: number?,
	labels: { [string]: { string } },
	hay: string,
	pid: string?,
	known: boolean,
	muted: boolean,
	flakyMark: boolean,
	flaky: boolean,
	retry: boolean,
	attempts: { Result }?,
	categories: { string }?,
	catVersion: number,
	launch: Launch?,
	source: Source,
}

export type Launch = {
	id: string,
	source: Source,
	index: number,
	results: { Result },
	tests: { Result },
	byHistory: { [string]: Result },
	start: number?,
	stop: number?,
	counts: Counts,
	pids: { [string]: boolean },
}

export type Source = {
	dir: string,
	rel: string,
	names: { [string]: boolean },
	tries: { [string]: number },
	results: { Result },
	byUuid: { [string]: Result },
	containers: { [string]: Container },
	parents: { [string]: { string } }?,
	executor: { [string]: any }?,
	environment: { { string } },
	categories: { Category },
	catVersion: number,
	launches: { Launch },
	unreadable: number,
	missing: boolean,
	version: number,
	arrived: number?,
}

local MAX_RESULT_BYTES = 16 * 1024 * 1024
local MAX_META_BYTES = 1024 * 1024
local MAX_MESSAGE = 16 * 1024
local MAX_TRACE = 8 * 1024
local RETRIES = 3

local SHORT_GAP_MS = 3 * 1000
local LONG_GAP_MS = 5 * 60 * 1000
local HOUR_MS = 60 * 60 * 1000

results.PRODUCT_DEFECTS = "Product defects"
results.TEST_DEFECTS = "Test defects"

local STATUSES: { Status } = { "failed", "broken", "passed", "skipped", "unknown" }
results.STATUSES = STATUSES

local KNOWN_STATUS: { [string]: Status } = {
	passed = "passed",
	failed = "failed",
	broken = "broken",
	skipped = "skipped",
	unknown = "unknown",
}

local KEEP_LABELS: { [string]: boolean } = {
	parentSuite = true,
	suite = true,
	subSuite = true,
	epic = true,
	feature = true,
	story = true,
	package = true,
	testClass = true,
	tag = true,
	severity = true,
	owner = true,
}

local HAY_LABELS = { "parentSuite", "suite", "subSuite", "epic", "feature", "story", "package", "tag", "owner" }

local META: { [string]: boolean } = {
	["executor.json"] = true,
	["environment.properties"] = true,
	["environment.xml"] = true,
	["categories.json"] = true,
}

local PRUNE = {
	"node_modules", ".git", ".hg", ".svn", ".venv", "venv", ".tox", ".nox", "__pycache__", ".mypy_cache",
	".pytest_cache", ".ruff_cache", ".gradle", ".idea", ".vscode", ".cache", "site-packages", "bower_components",
	"allure-report", ".next", ".nuxt", ".turbo", ".yarn", ".pnpm-store", "Pods", "DerivedData", ".terraform",
}

local FIND = [[
root=$1
shift
find "$root" -maxdepth 7 \( "$@" \) -prune -o -type d -name 'allure-results*' -print -o -type f -name '*-result.json' -print 2>/dev/null | awk '
/-result\.json$/ { d = $0; sub(/\/[^\/]*$/, "", d); n[d]++; next }
{ n[$0] += 0 }
END { for (d in n) printf "%d\t%s\n", n[d], d }'
]]

local function str(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	elseif type(v) == "number" then
		return tostring(v)
	end
	return nil
end

local function num(v: any): number?
	if type(v) == "number" and v == v then
		return v
	end
	return nil
end

local function cap(s: string?, n: number): string?
	if s == nil then
		return nil
	end
	if #s > n then
		return string.sub(s, 1, n)
	end
	return s
end

function results.ends(s: string, suffix: string): boolean
	return #s >= #suffix and string.sub(s, -#suffix) == suffix
end

function results.basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

function results.dirname(path: string): string
	local d = string.match(path, "^(.*)/[^/]*$")
	if d == nil or d == "" then
		return "/"
	end
	return d
end

function results.norm(path: string): string
	local p = string.gsub(path, "/+$", "")
	if p == "" then
		return "/"
	end
	if string.sub(p, 1, 13) == "/private/tmp/" or string.sub(p, 1, 13) == "/private/var/" then
		p = string.sub(p, 9)
	end
	return p
end

function results.tilde(path: string, home: string?): string
	if home and home ~= "" and (path == home or string.sub(path, 1, #home + 1) == home .. "/") then
		return "~" .. string.sub(path, #home + 1)
	end
	return path
end

function results.under(path: string, root: string): boolean
	return path == root or root == "/" or string.sub(path, 1, #root + 1) == root .. "/"
end

function results.status_of(v: any): Status
	if type(v) == "string" then
		return KNOWN_STATUS[string.lower(v)] or "unknown"
	end
	return "unknown"
end

function results.first_line(s: string?): string?
	if s == nil then
		return nil
	end
	local line = string.match(s, "^%s*([^\n]*)")
	if line == nil or line == "" then
		return nil
	end
	return (string.gsub(line, "%s+$", ""))
end

function results.duration(ms: number?): string?
	if ms == nil or ms < 0 then
		return nil
	end
	if ms < 1000 then
		return string.format("%d ms", math.floor(ms + 0.5))
	end
	local s = ms / 1000
	if s < 60 then
		return (string.gsub(string.format("%.1f s", s), "%.0 s$", " s"))
	end
	local total = math.floor(s + 0.5)
	local m = total // 60
	if m < 60 then
		return string.format("%dm %02ds", m, total % 60)
	end
	return string.format("%dh %02dm", m // 60, m % 60)
end

function results.when(ms: number?): string
	if ms == nil then
		return "unknown time"
	end
	local t = math.floor(ms / 1000)
	if os.date("%Y-%m-%d", t) == os.date("%Y-%m-%d") then
		return "today " .. (os.date("%H:%M", t) :: string)
	elseif os.date("%Y", t) == os.date("%Y") then
		return os.date("%b %d, %H:%M", t) :: string
	end
	return os.date("%b %d %Y, %H:%M", t) :: string
end

function results.clock(ms: number?): string?
	if ms == nil then
		return nil
	end
	return os.date("%Y-%m-%d %H:%M:%S", math.floor(ms / 1000)) :: string
end

function results.counts(): Counts
	return { total = 0, passed = 0, failed = 0, broken = 0, skipped = 0, unknown = 0 }
end

function results.count(c: Counts, status: Status)
	c.total += 1
	if status == "passed" then
		c.passed += 1
	elseif status == "failed" then
		c.failed += 1
	elseif status == "broken" then
		c.broken += 1
	elseif status == "skipped" then
		c.skipped += 1
	else
		c.unknown += 1
	end
end

function results.of(c: Counts, status: Status): number
	if status == "passed" then
		return c.passed
	elseif status == "failed" then
		return c.failed
	elseif status == "broken" then
		return c.broken
	elseif status == "skipped" then
		return c.skipped
	end
	return c.unknown
end

function results.add(into: Counts, from: Counts)
	into.total += from.total
	into.passed += from.passed
	into.failed += from.failed
	into.broken += from.broken
	into.skipped += from.skipped
	into.unknown += from.unknown
end

function results.rollup(c: Counts): Status
	if c.failed > 0 then
		return "failed"
	elseif c.broken > 0 then
		return "broken"
	elseif c.passed > 0 then
		return "passed"
	elseif c.unknown > 0 then
		return "unknown"
	elseif c.skipped > 0 then
		return "skipped"
	end
	return "unknown"
end

function results.read_json(path: string, max: number?): (any, string?)
	local ok, text = pcall(tern.fs.read, path, max or MAX_RESULT_BYTES)
	if not ok then
		return nil, tostring(text)
	end
	local decoded, value = pcall(tern.json.decode, text)
	if not decoded then
		return nil, "not valid JSON"
	end
	return value, nil
end

function results.root_of(dir: string): string
	local home = tern.getenv("HOME")
	local d = dir
	while d ~= "/" and d ~= "" and d ~= home do
		if tern.fs.exists(d .. "/.git") then
			return d
		end
		d = results.dirname(d)
	end
	return dir
end

function results.is_results_dir(path: string): boolean
	if string.match(results.basename(path), "^allure%-results") then
		return true
	end
	local ok, names = pcall(tern.fs.list, path)
	if not ok then
		return false
	end
	for _, name in names do
		if results.ends(name, "-result.json") or results.ends(name, "-container.json") then
			return true
		end
	end
	return false
end

function results.find_argv(root: string): { string }
	local argv = { "/bin/sh", "-c", FIND, "sh", root }
	for i, name in PRUNE do
		if i > 1 then
			table.insert(argv, "-o")
		end
		table.insert(argv, "-name")
		table.insert(argv, name)
	end
	return argv
end

function results.parse_find(out: string): { { dir: string, count: number } }
	local found: { { dir: string, count: number } } = {}
	for line in string.gmatch(out, "[^\n]+") do
		local n, dir = string.match(line, "^(%d+)\t(.+)$")
		if n and dir then
			table.insert(found, { dir = results.norm(dir :: string), count = tonumber(n :: string) :: number })
		end
	end
	table.sort(found, function(a, b)
		return a.dir < b.dir
	end)
	return found
end

function results.source(dir: string, rel: string): Source
	return {
		dir = dir,
		rel = rel,
		names = {},
		tries = {},
		results = {},
		byUuid = {},
		containers = {},
		parents = nil,
		executor = nil,
		environment = {},
		categories = {},
		catVersion = 0,
		launches = {},
		unreadable = 0,
		missing = false,
		version = 0,
		arrived = nil,
	}
end

local function reset(src: Source)
	src.names = {}
	src.tries = {}
	src.results = {}
	src.byUuid = {}
	src.containers = {}
	src.parents = nil
	src.launches = {}
	src.unreadable = 0
	src.version += 1
end

function results.listing(src: Source): { string }?
	local ok, names = pcall(tern.fs.list, src.dir)
	if not ok then
		if not src.missing then
			src.missing = true
			reset(src)
		end
		return nil
	end
	src.missing = false
	local present: { [string]: boolean } = {}
	local fresh: { string } = {}
	local meta: { string } = {}
	for _, name in names do
		if results.ends(name, "-result.json") or results.ends(name, "-container.json") then
			present[name] = true
			if not src.names[name] then
				table.insert(fresh, name)
			end
		elseif META[name] then
			present[name] = true
			if not src.names[name] then
				table.insert(meta, name)
			end
		end
	end
	for name in src.names do
		if not present[name] then
			reset(src)
			return results.listing(src)
		end
	end
	for i = #meta, 1, -1 do
		table.insert(fresh, 1, meta[i])
	end
	return fresh
end

local function thread_pid(v: string?): string?
	if v == nil then
		return nil
	end
	return string.match(v, "^(%d+)%-") or string.match(v, "^(%d+)@")
end

local function summarize(src: Source, path: string, name: string, raw: any): Result?
	if type(raw) ~= "table" then
		return nil
	end
	local uuid = str(raw.uuid) or string.match(name, "^(.*)%-result%.json$") or name
	local labels: { [string]: { string } } = {}
	local thread: string? = nil
	if type(raw.labels) == "table" then
		for _, l in raw.labels do
			if type(l) == "table" and type(l.name) == "string" then
				local value = str(l.value)
				if value then
					if KEEP_LABELS[l.name] then
						local list = labels[l.name]
						if list == nil then
							list = {}
							labels[l.name] = list
						end
						table.insert(list, value)
					elseif l.name == "thread" then
						thread = value
					end
				end
			end
		end
	end
	local sd = if type(raw.statusDetails) == "table" then raw.statusDetails else {}
	local test_name = str(raw.name) or str(raw.fullName) or uuid
	local full = str(raw.fullName)
	local hay = { string.lower(test_name) }
	if full then
		table.insert(hay, string.lower(full))
	end
	for _, key in HAY_LABELS do
		local values: { string } = labels[key] or {}
		for _, v in values do
			table.insert(hay, string.lower(v))
		end
	end
	return {
		uuid = uuid,
		file = path,
		name = test_name,
		fullName = full,
		historyId = str(raw.historyId) or str(raw.testCaseId) or full or uuid,
		status = results.status_of(raw.status),
		message = cap(str(sd.message), MAX_MESSAGE),
		trace = cap(str(sd.trace), MAX_TRACE),
		start = num(raw.start),
		stop = num(raw.stop),
		labels = labels,
		hay = table.concat(hay, "\n"),
		pid = thread_pid(thread),
		known = sd.known == true,
		muted = sd.muted == true,
		flakyMark = sd.flaky == true,
		flaky = sd.flaky == true,
		retry = false,
		attempts = nil,
		categories = nil,
		catVersion = -1,
		launch = nil,
		source = src,
	}
end

local function parse_properties(text: string): { { string } }
	local out: { { string } } = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		local trimmed = string.match(line, "^%s*(.-)%s*$") or ""
		local first = string.sub(trimmed, 1, 1)
		if trimmed ~= "" and first ~= "#" and first ~= "!" then
			local key, value = string.match(trimmed, "^(.-)%s*[=:]%s*(.*)$")
			if key == nil then
				key, value = trimmed, ""
			end
			key = string.gsub(key :: string, "\\(.)", "%1")
			value = string.gsub(value :: string, "\\(.)", "%1")
			if key ~= "" then
				table.insert(out, { key :: string, value :: string })
			end
		end
	end
	return out
end

local function xml_text(s: string): string
	local t = string.gsub(s, "<!%[CDATA%[(.-)%]%]>", "%1")
	t = string.gsub(t, "&lt;", "<")
	t = string.gsub(t, "&gt;", ">")
	t = string.gsub(t, "&quot;", '"')
	t = string.gsub(t, "&apos;", "'")
	t = string.gsub(t, "&amp;", "&")
	return (string.match(t, "^%s*(.-)%s*$") or t)
end

local function parse_environment_xml(text: string): { { string } }
	local out: { { string } } = {}
	for body in string.gmatch(text, "<parameter>(.-)</parameter>") do
		local key = string.match(body, "<key>(.-)</key>")
		local value = string.match(body, "<value>(.-)</value>")
		if key then
			table.insert(out, { xml_text(key), xml_text(value or "") })
		end
	end
	return out
end

local function parse_categories(raw: any): { Category }
	local out: { Category } = {}
	if type(raw) ~= "table" then
		return out
	end
	for _, c in raw do
		if type(c) == "table" and type(c.name) == "string" then
			local statuses: { [string]: boolean }? = nil
			if type(c.matchedStatuses) == "table" and #c.matchedStatuses > 0 then
				local set: { [string]: boolean } = {}
				for _, s in c.matchedStatuses do
					if type(s) == "string" then
						set[string.lower(s)] = true
					end
				end
				statuses = set
			end
			local wantsMessage = type(c.messageRegex) == "string"
			local wantsTrace = type(c.traceRegex) == "string"
			local message = if wantsMessage then regex.compile(c.messageRegex) else nil
			local trace = if wantsTrace then regex.compile(c.traceRegex) else nil
			table.insert(out, {
				name = c.name,
				statuses = statuses,
				message = message,
				trace = trace,
				wantsMessage = wantsMessage,
				wantsTrace = wantsTrace,
				flaky = c.flaky == true,
				broken = (wantsMessage and message == nil) or (wantsTrace and trace == nil),
			})
		end
	end
	return out
end

local function load_meta(src: Source, name: string)
	local path = src.dir .. "/" .. name
	if name == "executor.json" then
		local raw = results.read_json(path, MAX_META_BYTES)
		src.executor = if type(raw) == "table" then raw else nil
	elseif name == "categories.json" then
		local raw = results.read_json(path, MAX_META_BYTES)
		src.categories = parse_categories(raw)
		src.catVersion += 1
	else
		local ok, text = pcall(tern.fs.read, path, MAX_META_BYTES)
		if ok then
			if name == "environment.xml" then
				src.environment = parse_environment_xml(text)
			else
				src.environment = parse_properties(text)
			end
		end
	end
end

function results.load(src: Source, name: string): boolean
	if META[name] then
		load_meta(src, name)
		src.names[name] = true
		src.version += 1
		return true
	end
	local path = src.dir .. "/" .. name
	local raw, problem = results.read_json(path, MAX_RESULT_BYTES)
	if raw == nil then
		local tries = (src.tries[name] or 0) + 1
		src.tries[name] = tries
		if problem ~= "not valid JSON" or tries >= RETRIES then
			src.names[name] = true
			src.unreadable += 1
			return true
		end
		return false
	end
	src.names[name] = true
	src.tries[name] = nil
	if results.ends(name, "-container.json") then
		if type(raw) == "table" then
			local children: { string } = {}
			if type(raw.children) == "table" then
				for _, child in raw.children do
					if type(child) == "string" then
						table.insert(children, child)
					end
				end
			end
			local uuid = str(raw.uuid) or string.match(name, "^(.*)%-container%.json$") or name
			src.containers[uuid] = { uuid = uuid, file = path, children = children }
			src.parents = nil
		end
		return true
	end
	local r = summarize(src, path, name, raw)
	if r == nil then
		src.unreadable += 1
		return true
	end
	local previous = src.byUuid[r.uuid]
	if previous then
		for i, old in src.results do
			if old == previous then
				src.results[i] = r
				break
			end
		end
	else
		table.insert(src.results, r)
	end
	src.byUuid[r.uuid] = r
	src.version += 1
	src.arrived = tern.now()
	return true
end

function results.reload_meta(src: Source)
	for name in META do
		if src.names[name] then
			load_meta(src, name)
		end
	end
end

local function category_matches(cat: Category, r: Result): boolean
	if cat.broken then
		return false
	end
	if cat.statuses and not cat.statuses[r.status] then
		return false
	end
	if cat.wantsMessage then
		if r.message == nil or cat.message == nil or not regex.matches(cat.message :: regex.Regex, r.message :: string) then
			return false
		end
	end
	if cat.wantsTrace then
		if r.trace == nil or cat.trace == nil or not regex.matches(cat.trace :: regex.Regex, r.trace :: string) then
			return false
		end
	end
	return cat.flaky == r.flaky
end

local function categorize(src: Source, r: Result)
	local version = src.catVersion * 2 + (if r.flaky then 1 else 0)
	if r.catVersion == version then
		return
	end
	r.catVersion = version
	local names: { string } = {}
	if r.status ~= "passed" then
		for _, cat in src.categories do
			if category_matches(cat, r) then
				table.insert(names, cat.name)
			end
		end
	end
	if #names == 0 then
		if r.status == "failed" then
			table.insert(names, results.PRODUCT_DEFECTS)
		elseif r.status == "broken" then
			table.insert(names, results.TEST_DEFECTS)
		end
	end
	r.categories = if #names > 0 then names else nil
end

local function finalize(src: Source, l: Launch)
	local by: { [string]: { Result } } = {}
	local order: { string } = {}
	for _, r in l.results do
		local list = by[r.historyId]
		if list == nil then
			list = {}
			by[r.historyId] = list
			table.insert(order, r.historyId)
		end
		table.insert(list, r)
	end
	l.tests = {}
	l.byHistory = {}
	for _, hid in order do
		local list = by[hid]
		table.sort(list, function(a: Result, b: Result): boolean
			local sa, sb = a.start or 0, b.start or 0
			if sa ~= sb then
				return sa < sb
			end
			return (a.stop or 0) < (b.stop or 0)
		end)
		local latest = list[#list]
		local failedBefore = false
		for i, r in list do
			r.launch = l
			r.retry = i < #list
			r.attempts = if #list > 1 then list else nil
			r.flaky = r.flakyMark
			if i < #list and (r.status == "failed" or r.status == "broken") then
				failedBefore = true
			end
		end
		if failedBefore and latest.status == "passed" then
			latest.flaky = true
		end
		table.insert(l.tests, latest)
		l.byHistory[hid] = latest
	end
	table.sort(l.tests, function(a: Result, b: Result): boolean
		local sa, sb = a.start or math.huge, b.start or math.huge
		if sa ~= sb then
			return sa < sb
		end
		return a.name < b.name
	end)
	local c = results.counts()
	for _, r in l.tests do
		results.count(c, r.status)
		categorize(src, r)
	end
	l.counts = c
	l.id = src.dir .. "|" .. (if l.start then tostring(l.start) else "untimed")
end

local function new_launch(src: Source, start: number?): Launch
	return {
		id = "",
		source = src,
		index = 0,
		results = {},
		tests = {},
		byHistory = {},
		start = start,
		stop = start,
		counts = results.counts(),
		pids = {},
	}
end

function results.finish(src: Source)
	local timed: { Result } = {}
	local untimed: { Result } = {}
	for _, r in src.results do
		if r.start then
			table.insert(timed, r)
		else
			table.insert(untimed, r)
		end
	end
	table.sort(timed, function(a: Result, b: Result): boolean
		if a.start ~= b.start then
			return (a.start :: number) < (b.start :: number)
		end
		return a.uuid < b.uuid
	end)
	local pids: { [string]: boolean } = {}
	local distinct, with_pid = 0, 0
	for _, r in timed do
		if r.pid then
			with_pid += 1
			if not pids[r.pid :: string] then
				pids[r.pid :: string] = true
				distinct += 1
			end
		end
	end
	local use_pids = distinct <= math.max(16, with_pid / 2)
	local launches: { Launch } = {}
	local current: Launch? = nil
	for _, r in timed do
		local start = r.start :: number
		local pid = if use_pids then r.pid else nil
		local split = current == nil
		if current then
			local gap = start - (current.stop or start)
			if gap > HOUR_MS then
				split = true
			elseif pid and current.pids[pid :: string] then
				split = false
			elseif pid and gap > SHORT_GAP_MS then
				split = true
			elseif gap > LONG_GAP_MS then
				split = true
			end
		end
		if split then
			current = new_launch(src, start)
			table.insert(launches, current :: Launch)
		end
		local l = current :: Launch
		table.insert(l.results, r)
		l.stop = math.max(l.stop or start, r.stop or start)
		if pid then
			l.pids[pid :: string] = true
		end
	end
	if #untimed > 0 then
		if current == nil then
			current = new_launch(src, nil)
			table.insert(launches, current :: Launch)
		end
		for _, r in untimed do
			table.insert((current :: Launch).results, r)
		end
	end
	for i, l in launches do
		l.index = i
		finalize(src, l)
	end
	src.launches = launches
end

function results.category_names(src: Source): { string }
	local names: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, cat in src.categories do
		if not seen[cat.name] then
			seen[cat.name] = true
			table.insert(names, cat.name)
		end
	end
	for _, name in { results.PRODUCT_DEFECTS, results.TEST_DEFECTS } do
		if not seen[name] then
			table.insert(names, name)
		end
	end
	return names
end

function results.broken_categories(src: Source): { string }
	local names: { string } = {}
	for _, cat in src.categories do
		if cat.broken then
			table.insert(names, cat.name)
		end
	end
	return names
end

function results.attachment_path(src: Source, source: string): string
	if string.sub(source, 1, 1) == "/" then
		return source
	end
	return src.dir .. "/" .. source
end

export type Fixture = {
	step: { [string]: any },
	container: string,
}

function results.fixtures(src: Source, uuid: string): ({ Fixture }, { Fixture })
	local parents = src.parents
	if parents == nil then
		local built: { [string]: { string } } = {}
		for cuuid, c in src.containers do
			for _, child in c.children do
				local list = built[child]
				if list == nil then
					list = {}
					built[child] = list
				end
				table.insert(list, cuuid)
			end
		end
		src.parents = built
		parents = built
	end
	local befores: { Fixture } = {}
	local afters: { Fixture } = {}
	local seen: { [string]: boolean } = {}
	local queue: { string } = table.clone((parents :: { [string]: { string } })[uuid] or {})
	local at = 1
	while at <= #queue do
		local cuuid = queue[at]
		at += 1
		if not seen[cuuid] then
			seen[cuuid] = true
			local c = src.containers[cuuid]
			if c then
				local raw = results.read_json(c.file, MAX_RESULT_BYTES)
				if type(raw) == "table" then
					for _, field in { "befores", "afters" } do
						local list = raw[field]
						if type(list) == "table" then
							for _, step in list do
								if type(step) == "table" then
									table.insert(if field == "befores" then befores else afters, { step = step, container = cuuid })
								end
							end
						end
					end
				end
			end
			local ups: { string } = (parents :: { [string]: { string } })[cuuid] or {}
			for _, up in ups do
				table.insert(queue, up)
			end
		end
	end
	local function by_start(a: Fixture, b: Fixture): boolean
		local sa, sb = num(a.step.start) or 0, num(b.step.start) or 0
		if sa ~= sb then
			return sa < sb
		end
		return (str(a.step.name) or "") < (str(b.step.name) or "")
	end
	table.sort(befores, by_start)
	table.sort(afters, by_start)
	return befores, afters
end

return results
