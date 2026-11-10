--!strict
-- The index of a folder: its files and the declarations in them.
--
-- Files come from `git ls-files` (tracked and untracked, minus ignored ones) inside a git
-- checkout, else from `find`, else from a walk in Luau; the last two skip hidden folders,
-- dependencies and build output. Then source files are read, shallowest first, and their
-- declarations extracted, a slice of files per timer tick, so the overlay stays responsive
-- and searches see the index grow.
--
-- Memory. A plugin's Luau heap holds 256 MiB, garbage included, and nothing can force a
-- collection: an index has to stay well under that whatever the folder. So
-- - each file is its name string plus 4 bytes (folder id) in a buffer, each declaration
--   its name string plus 13 bytes (file, line, owner, kind); folder paths and owner names
--   are stored once, and nothing is kept twice in another case;
-- - all indexes together stay under `budget` (estimated bytes): past it, folders no
--   overlay shows go first, least recently used, then a rebuild's previous index, and then
--   the index stops growing and says so;
-- - a listing too big for one read is listed again shallower, so the files nearest the
--   folder are the ones kept, and the same order decides which files are read;
-- - an index that runs out of memory anyway keeps what it has (counts only move once an
--   entry is whole), stops, and lowers the budget for the next ones.
--
-- Indexes are kept per folder while the host runs. Opening the search again once the
-- index is old enough rebuilds it in the background while the old one answers.

local symbols = require("./symbols")

local index = {}

local find, sub, lower, readu32, writeu32 = string.find, string.sub, string.lower, buffer.readu32, buffer.writeu32

local SLICE_MS = 25
local REFRESH_MS = 20 * 1000
local MAX_ROOTS = 6
local MAX_FILES = 300000
local MAX_FILE_BYTES = 1024 * 1024
-- Declarations kept per file: generated tables don't crowd out the rest.
local MAX_FILE_SYMBOLS = 2000
local MAX_WALK_DEPTH = 24
-- Listing output read at once: `find` is cut there; git's output is capped at 16 MiB.
local FIND_BYTES = 12 * 1024 * 1024
local GIT_BYTES = 16 * 1024 * 1024 - 1
local LIST_TIMEOUT_MS = 60 * 1000
-- Shallower listings to try, in turn, when the whole one is too big.
local DEPTHS = { 8, 5, 3, 2, 1 }

-- Estimated bytes per stored item: an array slot (growth included), a string's overhead
-- and a map entry, measured on Tern's Luau. Shared strings are counted every time, so
-- the estimate errs high.
local SLOT = 28
local STRING = 48
local MAP_ENTRY = 40
-- All indexes together: about a quarter of the heap, which leaves room for the garbage
-- reading files makes before it is collected, and for searches.
local BUDGET = 72 * 1024 * 1024
local MIN_BUDGET = 16 * 1024 * 1024
local budget = BUDGET

-- Directories the walk and `find` never enter (hidden ones are skipped too).
local PRUNE_LIST = {
	"node_modules", "bower_components", "vendor", "venv", "env", "__pycache__", "site-packages",
	"dist", "build", "out", "target", "coverage", "Pods", "DerivedData", "Library", "bin", "obj",
}
local PRUNE: { [string]: boolean } = {}
for _, d in PRUNE_LIST do
	PRUNE[d] = true
end

-- Declaration kinds, by the code stored in a record's low bits.
index.KINDS = {
	"class", "struct", "interface", "enum", "type", "module",
	"function", "method", "variable", "field", "constant",
}
local KIND_CODE: { [string]: number } = {}
for i, k in index.KINDS do
	KIND_CODE[k] = i
end

-- A record's flag byte: the kind code, plus this bit when the name has an uppercase letter
-- (searches then match both cases). Files keep the same bit at the top of their folder id.
index.CASED = 0x80
index.FILE_CASED = 0x80000000
-- Bytes per declaration record: file u32, line u32, owner u32 (0: none), flags u8.
index.RECORD = 13

local function is_files_skipped(base: string): boolean
	return find(base, "%.min%.[jc]ss?$") ~= nil or find(base, "%.bundle%.js$") ~= nil
end

export type Index = {
	root: string,
	phase: "listing" | "parsing" | "ready",
	-- How the files were listed: "git", "find" or "walk".
	source: string,
	-- Folders holding files, relative to `root` ("" for itself): as is, lowercase, depth.
	dirs: { string },
	ldirs: { string },
	depths: { number },
	-- Folder ids by path, while listing.
	dirIds: { [string]: number }?,
	-- Files: name, and folder id (with FILE_CASED) as u32s.
	fbase: { string },
	fdir: buffer,
	nfiles: number,
	-- Declarations: name, and RECORD bytes each in `srec`.
	sname: { string },
	srec: buffer,
	nsyms: number,
	-- Owner (class, struct, module) names by id, from 1.
	owners: { string },
	ownerIds: { [string]: number },
	-- File ids, shallowest first, in the order they are read; dropped once read.
	order: buffer?,
	-- Files read so far, of `nfiles`.
	parsed: number,
	-- Estimated bytes held.
	bytes: number,
	-- Files or declarations were left out (limits, memory), and why when it wasn't a limit.
	truncated: boolean,
	note: string?,
	-- Dropped: its build stops at the next step.
	cancelled: boolean,
	-- Bumps whenever the contents change.
	version: number,
	started: number,
	finished: number?,
	took: number?,
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

local function cost(s: string): number
	return STRING + #s
end

local function is_oom(err: any): boolean
	return type(err) == "string" and find(err, "not enough memory", 1, true) ~= nil
end
index.is_oom = is_oom

local function new_index(root: string): Index
	return {
		root = root,
		phase = "listing",
		source = "git",
		dirs = {},
		ldirs = {},
		depths = {},
		dirIds = {},
		fbase = {},
		fdir = buffer.create(4096),
		nfiles = 0,
		sname = {},
		srec = buffer.create(index.RECORD * 1024),
		nsyms = 0,
		owners = {},
		ownerIds = {},
		order = nil,
		parsed = 0,
		bytes = 4096 + index.RECORD * 1024,
		truncated = false,
		note = nil,
		cancelled = false,
		version = 0,
		started = tern.now(),
		finished = nil,
		took = nil,
	}
end

-- `b` with room for `size` bytes: a copy twice as big when it is full.
local function room_for(idx: Index, b: buffer, size: number): buffer
	local len = buffer.len(b)
	if size <= len then
		return b
	end
	local grown = buffer.create(math.max(size, len * 2))
	buffer.copy(grown, 0, b, 0, len)
	idx.bytes += buffer.len(grown) - len
	return grown
end

-- ---------------------------------------------------------------- reading the index

-- A file's path relative to the folder.
function index.file_path(idx: Index, i: number): string
	local d = bit32.band(readu32(idx.fdir, (i - 1) * 4), 0x7FFFFFFF)
	local dir = idx.dirs[d]
	return if dir == "" then idx.fbase[i] else dir .. "/" .. idx.fbase[i]
end

-- ---------------------------------------------------------------- building it

local function notify(entry: Entry)
	for _, fn in entry.listeners do
		local ok, err = pcall(fn)
		if not ok then
			tern.log.warn("searcheverywhere: listener failed", err)
		end
	end
end

local function used_bytes(): number
	local n = 0
	for _, e in entries do
		n += e.current.bytes
		local b = e.building
		if b and b ~= e.current then
			n += b.bytes
		end
	end
	return n
end

local function drop(e: Entry)
	e.current.cancelled = true
	if e.building then
		(e.building :: Index).cancelled = true
	end
	if entries[e.root] == e then
		entries[e.root] = nil
	end
end

-- Frees memory for `entry` to grow: drops the least recently used folders no overlay
-- shows, then, while it rebuilds, its previous index (searches move to the new one).
-- Returns how many bytes the index being built may hold.
local function make_room(entry: Entry, idx: Index): number
	while used_bytes() > budget do
		local victim: Entry? = nil
		for _, e in entries do
			if e ~= entry and next(e.listeners) == nil and (victim == nil or e.used < (victim :: Entry).used) then
				victim = e
			end
		end
		if victim then
			drop(victim)
		elseif entry.building == idx and entry.current ~= idx then
			entry.current.cancelled = true
			entry.current = idx
			notify(entry)
		else
			break
		end
	end
	return budget - (used_bytes() - idx.bytes)
end

local function add_dir(idx: Index, dir: string): number
	local ids = idx.dirIds :: { [string]: number }
	local id = ids[dir]
	if id then
		return id
	end
	id = #idx.dirs + 1
	local ldir = lower(dir)
	local depth = 0
	if dir ~= "" then
		depth = 1
		local at = find(dir, "/", 1, true)
		while at do
			depth += 1
			at = find(dir, "/", at + 1, true)
		end
	end
	idx.dirs[id] = dir
	idx.ldirs[id] = ldir
	idx.depths[id] = depth
	ids[dir] = id
	idx.bytes += 3 * SLOT + MAP_ENTRY + cost(dir) + (if ldir ~= dir then cost(ldir) else 0)
	return id
end

local function add_file(idx: Index, dir: string, base: string)
	local n = idx.nfiles + 1
	local d = add_dir(idx, dir)
	if find(base, "%u") then
		d = bit32.bor(d, index.FILE_CASED)
	end
	local fdir = room_for(idx, idx.fdir, n * 4)
	idx.fdir = fdir
	writeu32(fdir, (n - 1) * 4, d)
	idx.fbase[n] = base
	idx.nfiles = n
	idx.bytes += SLOT + cost(base)
end

local function owner_id(idx: Index, owner: string?): number
	if owner == nil or owner == "" then
		return 0
	end
	local id = idx.ownerIds[owner]
	if id == nil then
		id = #idx.owners + 1
		idx.owners[id] = owner
		idx.ownerIds[owner] = id
		idx.bytes += SLOT + MAP_ENTRY + cost(owner)
	end
	return id
end

local function add_symbol(idx: Index, file: number, name: string, kind: string, line: number, owner: string?)
	local n = idx.nsyms + 1
	local off = (n - 1) * index.RECORD
	local srec = room_for(idx, idx.srec, off + index.RECORD)
	idx.srec = srec
	local flags = KIND_CODE[kind] or KIND_CODE.variable
	if find(name, "%u") then
		flags += index.CASED
	end
	writeu32(srec, off, file)
	writeu32(srec, off + 4, line)
	writeu32(srec, off + 8, owner_id(idx, owner))
	buffer.writeu8(srec, off + 12, flags)
	idx.sname[n] = name
	idx.nsyms = n
	idx.bytes += SLOT + cost(name)
end

local function finish(entry: Entry, idx: Index)
	idx.phase = "ready"
	if idx.order then
		idx.bytes -= buffer.len(idx.order :: buffer)
		idx.order = nil
	end
	idx.dirIds = nil
	idx.finished = tern.now()
	idx.took = (idx.finished :: number) - idx.started
	idx.version += 1
	if entries[entry.root] ~= entry or idx.cancelled then
		return
	end
	if entry.current ~= idx then
		entry.current.cancelled = true
	end
	entry.current = idx
	if entry.building == idx then
		entry.building = nil
	end
	notify(entry)
end

-- Runs one step of a build. An error past the budget, out of memory included, ends the
-- build with what it has: every count moves only once its entry is whole.
local function step(entry: Entry, idx: Index, fn: () -> ())
	if idx.cancelled then
		return
	end
	local ok, err = pcall(fn)
	if ok or idx.cancelled then
		return
	end
	idx.truncated = true
	if is_oom(err) then
		idx.note = "out of memory"
		budget = math.max(MIN_BUDGET, math.floor(budget * 0.7))
	else
		idx.note = "indexing failed"
		tern.log.warn("searcheverywhere: indexing", idx.root, "failed", err)
	end
	pcall(finish, entry, idx)
end

local STOP = {}

-- Reads one file's declarations into the index.
local function parse_file(idx: Index, file: number, room: number)
	local base = idx.fbase[file]
	local lang = symbols.language(base)
	if lang == nil or is_files_skipped(base) then
		return
	end
	local rel = index.file_path(idx, file)
	local path = if idx.root == "/" then "/" .. rel else idx.root .. "/" .. rel
	local ok, text = pcall(tern.fs.read, path, MAX_FILE_BYTES)
	if not ok then
		if is_oom(text) then
			error(text, 0)
		end
		return
	end
	if type(text) ~= "string" or find(text, "\0", 1, true) then
		return
	end
	local count = 0
	local done, err = pcall(symbols.extract, text, lang, function(name: string, kind: string, line: number, owner: string?)
		if count >= MAX_FILE_SYMBOLS or idx.bytes >= room then
			if idx.bytes >= room then
				idx.truncated = true
			end
			error(STOP, 0)
		end
		count += 1
		add_symbol(idx, file, name, kind, line, owner)
	end)
	if not done and err ~= STOP then
		if is_oom(err) then
			error(err, 0)
		end
		tern.log.warn("searcheverywhere: skipped", path, err)
	end
end

local function parse_slice(entry: Entry, idx: Index, k: number)
	local room = make_room(entry, idx)
	local t0 = tern.now()
	local n = idx.nfiles
	local order = idx.order :: buffer
	while k < n do
		if idx.bytes >= room then
			idx.truncated = true
			k = n
			break
		end
		parse_file(idx, readu32(order, k * 4), room)
		k += 1
		idx.parsed = k
		if tern.now() - t0 > SLICE_MS then
			break
		end
	end
	idx.version += 1
	if k >= n then
		idx.parsed = n
		finish(entry, idx)
		return
	end
	if entry.current == idx then
		notify(entry)
	end
	tern.timer(0, function()
		step(entry, idx, function()
			parse_slice(entry, idx, k)
		end)
	end)
end

-- Orders the files shallowest first (counting sort by folder depth), then reads them.
local function start_parsing(entry: Entry, idx: Index)
	idx.phase = "parsing"
	idx.dirIds = nil
	local n = idx.nfiles
	local counts: { number } = {}
	local fdir, depths = idx.fdir, idx.depths
	local maxd = 0
	for i = 0, n - 1 do
		local d = depths[bit32.band(readu32(fdir, i * 4), 0x7FFFFFFF)] + 1
		counts[d] = (counts[d] or 0) + 1
		if d > maxd then
			maxd = d
		end
	end
	local at: { number } = {}
	local sum = 0
	for d = 1, maxd do
		at[d] = sum
		sum += counts[d] or 0
	end
	local order = buffer.create(math.max(4, n * 4))
	for i = 0, n - 1 do
		local d = depths[bit32.band(readu32(fdir, i * 4), 0x7FFFFFFF)] + 1
		writeu32(order, at[d] * 4, i + 1)
		at[d] += 1
	end
	idx.order = order
	idx.bytes += buffer.len(order)
	idx.version += 1
	if entry.current == idx then
		notify(entry)
	end
	tern.timer(0, function()
		step(entry, idx, function()
			parse_slice(entry, idx, 0)
		end)
	end)
end

-- ---------------------------------------------------------------- listing

-- A position in a NUL-separated listing: the next path starts at `pos`; `slash` is the
-- first "/" at or after it.
type Cursor = { pos: number, slash: number }

local function cursor(out: string): Cursor
	return { pos = 1, slash = find(out, "/", 1, true) or #out + 1 }
end

-- The next path of a listing: its byte range (after `skip` leading bytes such as "./"), its
-- last slash (0: none) and how many slashes it has; nil at the end. A last path cut off by
-- the output cap is left out.
local function next_path(out: string, skip: number, at: Cursor): (number?, number, number, number)
	local len = #out
	while at.pos <= len do
		local nul = find(out, "\0", at.pos, true)
		if nul == nil then
			break
		end
		local first = at.pos + skip
		local depth, last = 0, 0
		local slash = at.slash
		while slash < nul do
			if slash >= first then
				depth += 1
				last = slash
			end
			slash = find(out, "/", slash + 1, true) or len + 1
		end
		at.slash = slash
		at.pos = nul + 1
		if nul > first then
			return first, nul - 1, last, depth
		end
	end
	at.pos = len + 1
	return nil, 0, 0, 0
end

-- Adds a listing's files to the index, a slice per tick, then starts reading them. When
-- they don't all fit, the shallowest go in.
local function add_listing(entry: Entry, idx: Index, out: string, skip: number, cut: boolean)
	local room = make_room(entry, idx)
	-- At most half the room goes to the file list; the rest is for declarations.
	local per_file = SLOT + 4 + STRING + 16
	local allowed = math.min(MAX_FILES, math.floor(room / 2 / per_file))
	local counts: { number } = {}
	local total = 0
	local at = cursor(out)
	while true do
		local first, _, _, depth = next_path(out, skip, at)
		if first == nil then
			break
		end
		counts[depth + 1] = (counts[depth + 1] or 0) + 1
		total += 1
	end
	-- Every path down to `full` slashes goes in, and the first `extra` with one more.
	local full, extra = math.huge, 0
	if total > allowed then
		cut = true
		local sum, d = 0, 1
		while sum + (counts[d] or 0) <= allowed do
			sum += counts[d] or 0
			d += 1
		end
		full, extra = d - 2, allowed - sum
	end
	idx.truncated = idx.truncated or cut
	local taken = 0
	at = cursor(out)
	local function slice()
		local t0 = tern.now()
		while true do
			local first, last, slash, depth = next_path(out, skip, at)
			if first == nil then
				start_parsing(entry, idx)
				return
			end
			if depth <= full or (depth == full + 1 and taken < extra) then
				if depth > full then
					taken += 1
				end
				if slash > 0 then
					add_file(idx, sub(out, first, slash - 1), sub(out, slash + 1, last))
				else
					add_file(idx, "", sub(out, first, last))
				end
			end
			if tern.now() - t0 > SLICE_MS then
				break
			end
		end
		idx.version += 1
		tern.timer(0, function()
			step(entry, idx, slice)
		end)
	end
	slice()
end

local has_find = tern.runtime.os ~= "windows"
	and tern.fs.exists("/bin/sh")
	and (tern.fs.exists("/usr/bin/find") or tern.fs.exists("/bin/find"))

local function find_command(depth: number?): string
	local names = { "-name '.*'" }
	for _, d in PRUNE_LIST do
		table.insert(names, "-name " .. d)
	end
	return "find . -mindepth 1"
		.. (if depth then " -maxdepth " .. depth else "")
		.. " \\( " .. table.concat(names, " -o ") .. " \\) -prune -o -type f -print0 | head -c " .. FIND_BYTES
end

local function git_argv(depth: number?): { string }
	local argv = { "git", "-c", "core.quotepath=off", "ls-files", "-z", "--cached", "--others", "--exclude-standard" }
	if depth then
		-- `*` doesn't cross `/` in glob pathspecs: one pattern per level.
		table.insert(argv, "--")
		local pattern = "*"
		for _ = 1, depth do
			table.insert(argv, ":(glob)" .. pattern)
			pattern = "*/" .. pattern
		end
	end
	return argv
end

local walk: (Entry, Index) -> ()

-- Lists the files with git, else find, else the walk; a listing that doesn't fit is
-- listed again shallower (DEPTHS), keeping the files nearest the folder.
local function list(entry: Entry, idx: Index)
	local ways = { "git" }
	if has_find then
		table.insert(ways, "find")
	end
	local function attempt(way: number, level: number)
		if idx.cancelled then
			return
		end
		local kind = ways[way]
		if kind == nil then
			step(entry, idx, function()
				walk(entry, idx)
			end)
			return
		end
		local depth = if level == 0 then nil else DEPTHS[level]
		local argv = if kind == "git" then git_argv(depth) else { "/bin/sh", "-c", find_command(depth) }
		local ok = pcall(function()
			tern.process.run(argv, { cwd = idx.root, timeout_ms = LIST_TIMEOUT_MS }, function(r: ProcessResult)
				if idx.cancelled then
					return
				end
				if (kind == "git" and r.status ~= 0) or (r.stdout == "" and r.status ~= 0) then
					attempt(way + 1, 0)
					return
				end
				local cut = r.timed_out or #r.stdout >= (if kind == "git" then GIT_BYTES else FIND_BYTES)
				if cut and level < #DEPTHS then
					attempt(way, level + 1)
					return
				end
				step(entry, idx, function()
					idx.source = kind
					add_listing(entry, idx, r.stdout, if kind == "find" then 2 else 0, cut or depth ~= nil)
				end)
			end)
		end)
		if not ok then
			attempt(way + 1, 0)
		end
	end
	attempt(1, 0)
end

-- Walks the folder breadth-first when there is neither git nor find (Windows), a slice of
-- entries per tick; a big directory is picked up where the last slice left it. Names that
-- `find` would prune are skipped unlooked, files included, as `find` does.
walk = function(entry: Entry, idx: Index)
	idx.source = "walk"
	type Dir = { rel: string, depth: number }
	local queue: { [number]: Dir } = { { rel = "", depth = 0 } }
	local head, tail = 1, 1
	-- The directory being read: its listing and the next name.
	local cur: Dir? = nil
	local abs = ""
	local names: { string } = {}
	local at = 1
	local per_file = SLOT + 4 + STRING + 16
	local function slice()
		local room = make_room(entry, idx)
		local allowed = math.min(MAX_FILES, math.floor(room / 2 / per_file))
		local t0 = tern.now()
		while true do
			if cur == nil then
				if head > tail then
					break
				end
				local dir = queue[head] :: Dir
				queue[head] = nil
				head += 1
				cur = dir
				abs = if dir.rel == "" then idx.root elseif idx.root == "/" then "/" .. dir.rel else idx.root .. "/" .. dir.rel
				local ok, listed = pcall(tern.fs.list, abs)
				names = if ok and type(listed) == "table" then listed else {}
				at = 1
			end
			local dir = cur :: Dir
			local name = names[at]
			if name == nil then
				cur, names = nil, {}
			else
				at += 1
				if sub(name, 1, 1) ~= "." and not PRUNE[name] then
					-- A directory lists; a file raises.
					if pcall(tern.fs.list, abs .. "/" .. name) then
						if dir.depth < MAX_WALK_DEPTH then
							tail += 1
							queue[tail] = { rel = if dir.rel == "" then name else dir.rel .. "/" .. name, depth = dir.depth + 1 }
						end
					elseif idx.nfiles < allowed then
						add_file(idx, dir.rel, name)
					else
						idx.truncated = true
						break
					end
				end
			end
			if tern.now() - t0 > SLICE_MS then
				idx.version += 1
				if entry.current == idx then
					notify(entry)
				end
				tern.timer(0, function()
					step(entry, idx, slice)
				end)
				return
			end
		end
		start_parsing(entry, idx)
	end
	slice()
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

-- Keeps at most MAX_ROOTS folders, dropping the least recently used no overlay shows.
local function trim(keep: Entry)
	while true do
		local count, victim = 0, nil :: Entry?
		for _, e in entries do
			count += 1
			if e ~= keep and next(e.listeners) == nil and (victim == nil or e.used < (victim :: Entry).used) then
				victim = e
			end
		end
		if count <= MAX_ROOTS or victim == nil then
			return
		end
		drop(victim :: Entry)
	end
end

-- The index entry of `root`, building it, or rebuilding it when stale (a big index is
-- rebuilt less often: after ten times what its last build took).
function index.get(root: string): Entry
	local entry = entries[root]
	if entry == nil then
		local e: Entry = { root = root, current = new_index(root), building = nil, listeners = {}, used = tern.now() }
		entries[root] = e
		trim(e)
		build(e, true)
		return e
	end
	entry.used = tern.now()
	local cur = entry.current
	if entry.building == nil and cur.phase == "ready" and cur.finished
		and tern.now() - (cur.finished :: number) > math.max(REFRESH_MS, 10 * (cur.took or 0))
	then
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
