--!strict
-- Asking the session's agent for a query: the prompt (the request, the query it changes, the
-- connection and an excerpt of its schema), and the query read back out of the answer.

local conns = require("./conns")
local complete = require("./complete")

local ask = {}

-- Characters of schema the prompt carries at most; tables the request names go first.
local SCHEMA_BUDGET = 9000

local LANGS: { [string]: boolean } = {
	sql = true, postgres = true, postgresql = true, pgsql = true, psql = true, plpgsql = true, sqlite = true,
	sqlite3 = true, trino = true, presto = true, redis = true, ["redis-cli"] = true, [""] = true,
}

local function words_of(s: string): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for w in string.gmatch(string.lower(s), "[%a_][%w_]+") do
		out[w] = true
		-- users ↔ user, categories ↔ category
		out[(string.gsub(w, "ies$", "y"))] = true
		out[(string.gsub(w, "s$", ""))] = true
	end
	return out
end

local function relevance(t: complete.Table, words: { [string]: boolean }): number
	local name = string.lower(t.name)
	local score = 0
	if words[name] or words[(string.gsub(name, "s$", ""))] or words[(string.gsub(name, "ies$", "y"))] then
		score += 10
	end
	for part in string.gmatch(name, "[^_%s]+") do
		if #part > 2 and words[part] then
			score += 2
		end
	end
	for _, c in t.columns do
		if words[string.lower(c.name)] then
			score += 1
		end
	end
	return score
end

local function describe_table(t: complete.Table): string
	local cols: { string } = {}
	for i, c in t.columns do
		if i > 60 then
			table.insert(cols, "… " .. tostring(#t.columns - 60) .. " more")
			break
		end
		local piece = c.name .. " " .. (c.type or "")
		if c.pk then
			piece ..= " primary key"
		end
		table.insert(cols, piece)
	end
	local name = (if t.schema and t.schema ~= "" then t.schema .. "." else "") .. t.name
	local kind = if t.kind ~= "table" then " (" .. t.kind .. ")" else ""
	return "- " .. name .. kind .. ": " .. table.concat(cols, ", ")
end

local function schema_text(s: complete.Schema?, hint: string): string
	if not s or #s.tables == 0 then
		return "(The schema has not loaded, or the database has no tables.)"
	end
	local words = words_of(hint)
	local order: { { t: complete.Table, r: number } } = {}
	for _, t in s.tables do
		table.insert(order, { t = t, r = relevance(t, words) })
	end
	table.sort(order, function(a, b)
		if a.r ~= b.r then
			return a.r > b.r
		end
		local sa, sb = a.t.schema or "", b.t.schema or ""
		if sa ~= sb then
			return sa < sb
		end
		return a.t.name < b.t.name
	end)
	local lines: { string } = {}
	local used = 0
	for i, entry in order do
		local line = describe_table(entry.t)
		if used + #line > SCHEMA_BUDGET then
			table.insert(lines, "- … " .. tostring(#order - i + 1) .. " more tables not listed")
			break
		end
		used += #line + 1
		table.insert(lines, line)
	end
	local head = ""
	if s.default_schema then
		head = "Unqualified names resolve in schema " .. s.default_schema .. ".\n"
	end
	return head .. table.concat(lines, "\n")
end

-- Key families of a Redis sample: `user:*` for user:1 … user:40, with their types.
local function keys_text(keys: { complete.RedisKey }?): string
	if not keys or #keys == 0 then
		return "(No keys were sampled.)"
	end
	local families: { [string]: { count: number, types: { [string]: boolean } } } = {}
	local order: { string } = {}
	for _, k in keys do
		local pattern = string.gsub(string.gsub(k.key, "%x%x%x%x%x%x%x%x%-[%x%-]+", "*"), "%d+", "*")
		local f = families[pattern]
		if not f then
			f = { count = 0, types = {} }
			families[pattern] = f
			table.insert(order, pattern)
		end
		f.count += 1
		f.types[k.type] = true
	end
	table.sort(order, function(a, b)
		return families[a].count > families[b].count
	end)
	local lines: { string } = {}
	for i, p in order do
		if i > 80 then
			table.insert(lines, "- … " .. tostring(#order - 80) .. " more key patterns")
			break
		end
		local types: { string } = {}
		for t in families[p].types do
			table.insert(types, t)
		end
		table.sort(types)
		table.insert(lines, "- " .. p .. " (" .. table.concat(types, ", ") .. ", " .. tostring(families[p].count) .. " sampled)")
	end
	return table.concat(lines, "\n")
end

export type Request = {
	conn: conns.Conn,
	server: string?,
	requests: { string },
	current: string?,
	failure: string?,
	schema: complete.Schema?,
	keys: { complete.RedisKey }?,
}

function ask.prompt(r: Request): string
	local kind = conns.kind(r.conn.kind)
	local redis = r.conn.kind == "redis"
	local lang = if redis then "redis" else "sql"
	local what = if redis then "Redis commands" else kind.label .. " SQL"
	local parts: { string } = {}
	table.insert(parts, string.format(
		"Write %s for me. I'm in Tern's Databases block, connected to %q (%s%s).",
		what, r.conn.name, r.server or kind.label, " at " .. conns.detail(r.conn)))
	if #r.requests > 0 then
		table.insert(parts, "\nWhat I want:\n" .. table.concat(r.requests, "\n"))
	end
	if r.failure then
		table.insert(parts, "\nIt failed with:\n" .. r.failure)
	end
	if r.current and r.current ~= "" then
		table.insert(parts, "\nThe editor holds this; change it as asked:\n```" .. lang .. "\n" .. r.current .. "\n```")
	end
	if redis then
		table.insert(parts, "\nKeys in the database (patterns from a sample):\n" .. keys_text(r.keys))
	else
		local hint = table.concat(r.requests, " ") .. " " .. (r.current or "") .. " " .. (r.failure or "")
		table.insert(parts, "\nSchema:\n" .. schema_text(r.schema, hint))
	end
	table.insert(parts, string.format(
		"\nAnswer with the %s alone in one ```%s block%s. Don't run it and don't change any files: the block puts it in its editor for me to read and run.",
		if redis then "commands" else "query", lang, if redis then ", one command per line" else ""))
	return table.concat(parts, "\n")
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

local STARTS: { [string]: boolean } = {}
for w in string.gmatch("SELECT WITH INSERT UPDATE DELETE CREATE ALTER DROP EXPLAIN SHOW VALUES MERGE TRUNCATE DESCRIBE", "%S+") do
	STARTS[w] = true
end

-- The query in an agent's answer: its last fenced SQL (or Redis, or unlabelled) block, else
-- the whole answer when it reads like a query. Nil when there is none.
function ask.extract(text: string, redis: boolean): string?
	local best: string? = nil
	local any: string? = nil
	for lang, body in string.gmatch(text .. "\n", "```[ \t]*([%w_%-]*)[^\n]*\n(.-)\n[ \t]*```") do
		any = body
		if LANGS[string.lower(lang)] then
			best = body
		end
	end
	local out = best or any
	if not out then
		local plain = trim(text)
		local first = string.upper(string.match(plain, "^[%a_]+") or "")
		if redis then
			if complete.COMMANDS[first] then
				out = plain
			end
		elseif STARTS[first] then
			out = plain
		end
	end
	if not out then
		return nil
	end
	if redis then
		-- `redis-cli> GET k` and `127.0.0.1:6379> GET k` prompts are not part of the command.
		local lines: { string } = {}
		for line in string.gmatch(out .. "\n", "(.-)\n") do
			line = string.gsub(line, "^%s*[%w%.%-]*:?%d*>%s*", "")
			line = string.gsub(line, "^%s*redis%-cli%s+", "")
			table.insert(lines, line)
		end
		out = table.concat(lines, "\n")
	end
	out = trim(out)
	return if out ~= "" then out else nil
end

return ask
