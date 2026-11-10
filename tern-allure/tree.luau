--!strict

local results = require("./results")

type Result = results.Result
type Counts = results.Counts

local tree = {}

export type Kind = "suites" | "behaviors" | "packages" | "categories"

export type Group = {
	ident: string,
	name: string,
	depth: number,
	groups: { Group },
	byName: { [string]: Group },
	tests: { Leaf },
	seen: { [string]: boolean },
	counts: Counts,
}

export type Leaf = {
	ident: string,
	result: Result,
	group: Group,
}

export type Row = {
	ident: string,
	depth: number,
	parent: string?,
	group: Group?,
	leaf: Leaf?,
}

export type Tree = {
	kind: Kind,
	root: Group,
	groups: { [string]: Group },
	leaves: { [string]: Leaf },
	byHistory: { [string]: Leaf },
	parentOf: { [string]: string },
	size: number,
}

local GROUP_SEP = "\31"
local LEAF_SEP = "\30"
local MESSAGE_CHARS = 140

function tree.clip(s: string, chars: number): string
	local n = utf8.len(s)
	if n == nil or n <= chars then
		return s
	end
	local cut = utf8.offset(s, chars) or (chars + 1)
	return string.sub(s, 1, cut - 1) .. "…"
end

local function first(r: Result, label: string): string?
	local list = r.labels[label]
	return if list then list[1] else nil
end

local function distinct(list: { string }?): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local values: { string } = list or {}
	for _, v in values do
		if not seen[v] then
			seen[v] = true
			table.insert(out, v)
		end
	end
	return out
end

local function split_dots(s: string, into: { string })
	for seg in string.gmatch(s, "[^%.]+") do
		table.insert(into, seg)
	end
end

local function suite_paths(r: Result): { { string } }
	local path: { string } = {}
	for _, label in { "parentSuite", "suite", "subSuite" } do
		local v = first(r, label)
		if v then
			table.insert(path, v)
		end
	end
	return { path }
end

local function behavior_paths(r: Result): { { string } }
	local out: { { string } } = { {} }
	for _, label in { "epic", "feature", "story" } do
		local values = distinct(r.labels[label])
		if #values > 0 then
			local nxt: { { string } } = {}
			for _, path in out do
				for _, v in values do
					local p = table.clone(path)
					table.insert(p, v)
					table.insert(nxt, p)
				end
			end
			out = nxt
		end
	end
	return out
end

local function package_paths(r: Result): { { string } }
	local segments: { string } = {}
	local pkg = first(r, "package")
	local cls = first(r, "testClass")
	if pkg then
		split_dots(pkg, segments)
		if cls and cls ~= pkg then
			local simple = if string.sub(cls, 1, #pkg + 1) == pkg .. "." then string.sub(cls, #pkg + 2) else cls
			split_dots(simple, segments)
		end
	elseif cls then
		split_dots(cls, segments)
	elseif r.fullName then
		local full = r.fullName :: string
		local base = string.match(full, "^([^#]+)#") or string.match(full, "^(.+)%.[^%.]+$")
		if base then
			split_dots(base, segments)
		end
	end
	return { segments }
end

local function category_paths(r: Result): { { string } }
	local out: { { string } } = {}
	local message = tree.clip(results.first_line(r.message) or "No message", MESSAGE_CHARS)
	local names: { string } = r.categories or {}
	for _, name in names do
		table.insert(out, { name, message })
	end
	return out
end

local PATHS: { [string]: (Result) -> { { string } } } = {
	suites = suite_paths,
	behaviors = behavior_paths,
	packages = package_paths,
	categories = category_paths,
}

local function new_group(name: string): Group
	return {
		ident = "",
		name = name,
		depth = 0,
		groups = {},
		byName = {},
		tests = {},
		seen = {},
		counts = results.counts(),
	}
end

local function compress(g: Group)
	for i, child in g.groups do
		local merged = child
		while #merged.tests == 0 and #merged.groups == 1 do
			local only = merged.groups[1]
			only.name = merged.name .. "." .. only.name
			merged = only
		end
		g.groups[i] = merged
		compress(merged)
	end
end

local function lower_name(a: Group, b: Group): boolean
	local la, lb = string.lower(a.name), string.lower(b.name)
	if la ~= lb then
		return la < lb
	end
	return a.name < b.name
end

local function by_start(a: Leaf, b: Leaf): boolean
	local sa, sb = a.result.start or math.huge, b.result.start or math.huge
	if sa ~= sb then
		return sa < sb
	end
	return a.result.name < b.result.name
end

function tree.build(kind: Kind, tests: { Result }, keep: (Result) -> boolean, order: { string }?): Tree
	local root = new_group("")
	root.ident = kind .. ":"
	local paths_of = PATHS[kind]
	for _, r in tests do
		if keep(r) then
			for _, path in paths_of(r) do
				local g = root
				for _, name in path do
					local child = g.byName[name]
					if child == nil then
						local made = new_group(name)
						g.byName[name] = made
						table.insert(g.groups, made)
						child = made
					end
					g = child :: Group
				end
				if not g.seen[r.historyId] then
					g.seen[r.historyId] = true
					table.insert(g.tests, { ident = "", result = r, group = g })
				end
			end
		end
	end
	if kind == "packages" then
		compress(root)
	end
	local rank: { [string]: number } = {}
	local ordered: { string } = order or {}
	for i, name in ordered do
		rank[name] = i
	end
	local t: Tree = {
		kind = kind,
		root = root,
		groups = {},
		leaves = {},
		byHistory = {},
		parentOf = {},
		size = 0,
	}
	local function index(g: Group, depth: number)
		g.counts = results.counts()
		for _, child in g.groups do
			child.ident = g.ident .. GROUP_SEP .. child.name
			child.depth = depth
			t.groups[child.ident] = child
			if g ~= root then
				t.parentOf[child.ident] = g.ident
			end
			index(child, depth + 1)
			results.add(g.counts, child.counts)
		end
		for _, leaf in g.tests do
			leaf.ident = g.ident .. LEAF_SEP .. leaf.result.historyId
			t.leaves[leaf.ident] = leaf
			if g ~= root then
				t.parentOf[leaf.ident] = g.ident
			end
			if t.byHistory[leaf.result.historyId] == nil then
				t.byHistory[leaf.result.historyId] = leaf
			end
			results.count(g.counts, leaf.result.status)
			t.size += 1
		end
		if kind == "categories" and depth == 0 then
			table.sort(g.groups, function(a: Group, b: Group): boolean
				local ra, rb = rank[a.name] or math.huge, rank[b.name] or math.huge
				if ra ~= rb then
					return ra < rb
				end
				return lower_name(a, b)
			end)
		elseif kind == "categories" then
			table.sort(g.groups, function(a: Group, b: Group): boolean
				if a.counts.total ~= b.counts.total then
					return a.counts.total > b.counts.total
				end
				return lower_name(a, b)
			end)
		else
			table.sort(g.groups, lower_name)
		end
		table.sort(g.tests, by_start)
	end
	index(root, 0)
	return t
end

function tree.rows(t: Tree, is_open: (ident: string, depth: number) -> boolean): { Row }
	local rows: { Row } = {}
	local function walk(g: Group, depth: number, parent: string?)
		for _, child in g.groups do
			table.insert(rows, { ident = child.ident, depth = depth, parent = parent, group = child })
			if is_open(child.ident, depth) then
				walk(child, depth + 1, child.ident)
			end
		end
		for _, leaf in g.tests do
			table.insert(rows, { ident = leaf.ident, depth = depth, parent = parent, leaf = leaf })
		end
	end
	walk(t.root, 0, nil)
	return rows
end

function tree.ancestors(t: Tree, ident: string): { string }
	local out: { string } = {}
	local at = t.parentOf[ident]
	while at do
		table.insert(out, 1, at)
		at = t.parentOf[at]
	end
	return out
end

function tree.history_of(ident: string): string?
	return string.match(ident, LEAF_SEP .. "(.*)$")
end

return tree
