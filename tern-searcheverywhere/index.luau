--!strict
-- The index of a folder: its files and the declarations in them.
--
-- Files come from `git ls-files` (tracked and untracked, minus ignored ones) when the folder
-- is in a git checkout, else from walking it (skipping hidden directories, dependencies
-- and build output). Then each source file is read and its declarations extracted, a
-- slice of files per timer tick so the host stays responsive; searches see the index
-- grow as it goes.
--
-- Indexes are kept per folder while the host runs. Opening the search again later than
-- `REFRESH_MS` after the last build starts a new build in the background; the old index
-- answers until the new one is done.

local symbols = require("./symbols")

local index = {}

local SLICE_MS = 25
local REFRESH_MS = 20 * 1000
local MAX_FILES = 200000
local MAX_SYMBOLS = 500000
local MAX_FILE_BYTES = 1024 * 1024
local MAX_DEPTH = 24
local KEEP_ROOTS = 4

-- Directories a walk never enters (hidden ones are skipped too).
local PRUNE: { [string]: boolean } = {}
for _, d in {
	"node_modules", "bower_components", "vendor", "venv", "env", "__pycache__", "site-packages",
	"dist", "build", "out", "target", "coverage", "Pods", "DerivedData", "Library", "bin", "obj",
} do
	PRUNE[d] = true
end

-- Files whose declarations are not worth reading (generated or bundled).
local function skip_parse(rel: string): boolean
	return string.find(rel, "%.min%.[jc]ss?$") ~= nil or string.find(rel, "%.bundle%.js$") ~= nil
end

export type Index = {
	root: string,
	phase: "listing" | "parsing" | "ready",
	-- Files, relative to `root`: path, lowercase path, base name, lowercase base name.
	paths: { string },
	lpaths: { string },
	bases: { string },
	lbases: { string },
	-- Declarations, as parallel arrays: name, lowercase name, lowercase `Container.name`,
	-- kind, file (index into `paths`), line, container ("" for none).
	names: { string },
	lnames: { string },
	lfulls: { string },
	kinds: { string },
	files: { number },
	lines: { number },
	owners: { string },
	-- Files visited by the reader so far, of `#paths`.
	parsed: number,
	-- Some files or declarations were left out at the limits.
	truncated: boolean,
	-- How the files were listed: "git" or "walk".
	source: string,
	-- Bumps whenever the contents change.
	version: number,
	started: number,
	finished: number?,
}

export type Entry = {
	root: string,
	-- What searches use: the last finished index, else the one being built.
	current: Index,
	-- A newer index being built while `current` answers.
	building: Index?,
	listeners: { [any]: () -> () },
	used: number,
}

local entries: { [string]: Entry } = {}

local function new_index(root: string): Index
	return {
		root = root,
		phase = "listing",
		paths = {},
		lpaths = {},
		bases = {},
		lbases = {},
		names = {},
		lnames = {},
		lfulls = {},
		kinds = {},
		files = {},
		lines = {},
		owners = {},
		parsed = 0,
		truncated = false,
		source = "git",
		version = 0,
		started = tern.now(),
		finished = nil,
	}
end

local function notify(entry: Entry)
	for _, fn in entry.listeners do
		local ok, err = pcall(fn)
		if not ok then
			tern.log.warn("searcheverywhere: listener failed", err)
		end
	end
end

local function add_file(idx: Index, rel: string)
	local n = #idx.paths + 1
	if n > MAX_FILES then
		idx.truncated = true
		return
	end
	local base = string.match(rel, "([^/]*)$") or rel
	idx.paths[n] = rel
	idx.lpaths[n] = string.lower(rel)
	idx.bases[n] = base
	idx.lbases[n] = string.lower(base)
end

-- Reads one file's declarations into the index.
local function parse_file(idx: Index, i: number)
	local rel = idx.paths[i]
	local lang = symbols.language(rel)
	if lang == nil or skip_parse(rel) then
		return
	end
	local ok, text = pcall(tern.fs.read, idx.root .. "/" .. rel, MAX_FILE_BYTES)
	if not ok or type(text) ~= "string" then
		return
	end
	if string.find(string.sub(text, 1, 4096), "\0", 1, true) then
		return
	end
	local names, lnames, lfulls, kinds, files, lines, owners =
		idx.names, idx.lnames, idx.lfulls, idx.kinds, idx.files, idx.lines, idx.owners
	symbols.extract(text, lang, function(name: string, kind: string, line: number, owner: string?)
		local n = #names + 1
		if n > MAX_SYMBOLS then
			idx.truncated = true
			return
		end
		local lname = string.lower(name)
		names[n] = name
		lnames[n] = lname
		kinds[n] = kind
		files[n] = i
		lines[n] = line
		if owner and owner ~= "" then
			owners[n] = owner
			lfulls[n] = string.lower(owner) .. "." .. lname
		else
			owners[n] = ""
			lfulls[n] = lname
		end
	end)
end

local function finish(entry: Entry, idx: Index)
	idx.phase = "ready"
	idx.finished = tern.now()
	idx.version += 1
	entry.current = idx
	if entry.building == idx then
		entry.building = nil
	end
	notify(entry)
end

local function parse_slice(entry: Entry, idx: Index, next_file: number)
	local t0 = tern.now()
	local i = next_file
	local total = #idx.paths
	while i <= total do
		parse_file(idx, i)
		idx.parsed += 1
		i += 1
		if #idx.names >= MAX_SYMBOLS then
			idx.truncated = true
			break
		end
		if tern.now() - t0 > SLICE_MS then
			break
		end
	end
	idx.version += 1
	if i > total or #idx.names >= MAX_SYMBOLS then
		finish(entry, idx)
		return
	end
	if entry.current == idx then
		notify(entry)
	end
	tern.timer(0, function()
		parse_slice(entry, idx, i)
	end)
end

local function start_parsing(entry: Entry, idx: Index)
	idx.phase = "parsing"
	idx.version += 1
	local any = false
	for _, rel in idx.paths do
		if symbols.language(rel) then
			any = true
			break
		end
	end
	if not any then
		idx.parsed = #idx.paths
		finish(entry, idx)
		return
	end
	if entry.current == idx then
		notify(entry)
	end
	tern.timer(0, function()
		parse_slice(entry, idx, 1)
	end)
end

-- Walks the folder breadth-first, a slice of directories per tick.
local function walk(entry: Entry, idx: Index)
	idx.source = "walk"
	type Dir = { rel: string, depth: number }
	local queue: { Dir } = { { rel = "", depth = 0 } }
	local head = 1
	local function step()
		local t0 = tern.now()
		while head <= #queue do
			local dir = queue[head]
			head += 1
			local abs = if dir.rel == "" then idx.root else idx.root .. "/" .. dir.rel
			local ok, names = pcall(tern.fs.list, abs)
			if ok and type(names) == "table" then
				for _, name in names do
					if string.sub(name, 1, 1) ~= "." then
						local rel = if dir.rel == "" then name else dir.rel .. "/" .. name
						-- A directory lists; a file raises.
						local is_dir = pcall(tern.fs.list, idx.root .. "/" .. rel)
						if is_dir then
							if not PRUNE[name] and dir.depth < MAX_DEPTH then
								table.insert(queue, { rel = rel, depth = dir.depth + 1 })
							end
						else
							add_file(idx, rel)
						end
					end
				end
			end
			if #idx.paths >= MAX_FILES then
				idx.truncated = true
				break
			end
			if tern.now() - t0 > SLICE_MS then
				idx.version += 1
				if entry.current == idx then
					notify(entry)
				end
				tern.timer(0, step)
				return
			end
		end
		start_parsing(entry, idx)
	end
	step()
end

local function list(entry: Entry, idx: Index)
	local ok, err = pcall(function()
		tern.process.run(
			{ "git", "-c", "core.quotepath=off", "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
			{ cwd = idx.root, timeout_ms = 60 * 1000 },
			function(r: ProcessResult)
				if r.status ~= 0 then
					walk(entry, idx)
					return
				end
				local seen: { [string]: boolean } = {}
				for rel in string.gmatch(r.stdout, "([^%z]+)") do
					-- Deleted files stay in the index until committed; untracked and
					-- modified files can repeat.
					if not seen[rel] then
						seen[rel] = true
						add_file(idx, rel)
					end
				end
				start_parsing(entry, idx)
			end
		)
	end)
	if not ok then
		tern.log.warn("searcheverywhere: git ls-files failed, walking instead", err)
		walk(entry, idx)
	end
end

-- Starts building a fresh index: as the entry's current one (first build), else in the
-- background while the current one answers.
local function build(entry: Entry, as_current: boolean)
	local idx = new_index(entry.root)
	if as_current then
		entry.current = idx
	else
		entry.building = idx
	end
	list(entry, idx)
end

-- Forgets the least recently used folders past `KEEP_ROOTS`.
local function evict()
	local roots: { string } = {}
	for root in entries do
		table.insert(roots, root)
	end
	if #roots <= KEEP_ROOTS then
		return
	end
	table.sort(roots, function(a: string, b: string): boolean
		return entries[a].used > entries[b].used
	end)
	for i = KEEP_ROOTS + 1, #roots do
		local e = entries[roots[i]]
		if next(e.listeners) == nil then
			entries[roots[i]] = nil
		end
	end
end

-- The index entry of `root`, building it, or rebuilding it when stale.
function index.get(root: string): Entry
	local entry = entries[root]
	if entry == nil then
		local e: Entry = { root = root, current = new_index(root), building = nil, listeners = {}, used = tern.now() }
		entries[root] = e
		evict()
		build(e, true)
		return e
	end
	entry.used = tern.now()
	local cur = entry.current
	if entry.building == nil and cur.phase == "ready" and cur.finished and tern.now() - cur.finished > REFRESH_MS then
		build(entry, false)
	end
	return entry
end

-- Calls `fn` whenever the entry's current index changes, until `unsubscribe(entry, key)`.
function index.subscribe(entry: Entry, key: any, fn: () -> ())
	entry.listeners[key] = fn
end

function index.unsubscribe(entry: Entry, key: any)
	entry.listeners[key] = nil
end

return index
