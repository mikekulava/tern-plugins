--!strict
-- Completion for the editor. SQL: what the caret's place in its statement asks for — tables
-- after FROM/JOIN/INTO/UPDATE, a table's columns after `alias.`, a schema's tables after
-- `schema.`, the statement's columns, functions and keywords in expressions, statement
-- keywords at its start. Redis: commands on a line's first word, then key names (from the key
-- browser) and the command's options. Items are ranked: prefix matches, then word-initial
-- matches (`ui` → user_id), then substrings, then subsequences.

local sqltext = require("./sqltext")
local keywords = require("./keywords")

export type Column = { name: string, type: string?, pk: boolean?, notnull: boolean? }
export type Table = { schema: string?, name: string, kind: string, columns: { Column } }
export type Schema = {
	server: string?,
	database: string?,
	default_schema: string?,
	search_path: { string }?,
	catalog: string?,
	catalogs: { string }?,
	schemas: { string },
	tables: { Table },
	functions: { string },
	truncated: boolean?,
	-- Built by `complete.index`: lowercased names to their tables.
	by_name: { [string]: { Table } }?,
	by_schema: { [string]: { Table } }?,
}
export type RedisKey = { key: string, type: string, ttl: number }

export type Item = {
	label: string,
	insert: string,
	kind: string,
	detail: string?,
	-- Characters the caret moves back after inserting (into a function's parentheses).
	back: number?,
	score: number,
}
export type Popup = {
	-- The characters [from, to) the chosen item replaces: the word at the caret.
	from: number,
	to: number,
	prefix: string,
	items: { Item },
}

local complete = {}

local MAX_ITEMS = 60

function complete.index(s: Schema)
	local by_name: { [string]: { Table } } = {}
	local by_schema: { [string]: { Table } } = {}
	for _, t in s.tables do
		local k = string.lower(t.name)
		by_name[k] = by_name[k] or {}
		table.insert(by_name[k], t)
		local sk = string.lower(t.schema or "")
		by_schema[sk] = by_schema[sk] or {}
		table.insert(by_schema[sk], t)
	end
	s.by_name, s.by_schema = by_name, by_schema
end

local function quote_name(name: string, dialect: string): string
	local plain = if dialect == "postgres"
		then string.match(name, "^[a-z_][a-z0-9_$]*$") ~= nil
		else string.match(name, "^[%a_][%w_]*$") ~= nil
	if plain and not keywords.RESERVED[string.upper(name)] then
		return name
	end
	if dialect == "sqlite" and string.find(name, '"', 1, true) == nil and plain then
		return '"' .. name .. '"'
	end
	return '"' .. string.gsub(name, '"', '""') .. '"'
end
complete.quote_name = quote_name

-- A keyword in the case the user types: lower when the typed prefix is all lower case.
local function cased(word: string, prefix: string): string
	if prefix ~= "" and string.lower(prefix) == prefix then
		return string.lower(word)
	end
	return word
end

-- How well `name` matches `prefix` (both lowered): 0 for no match.
local function match_score(name: string, prefix: string): number
	if prefix == "" then
		return 1
	end
	if string.sub(name, 1, #prefix) == prefix then
		return 4 - math.min(#name - #prefix, 30) / 100
	end
	-- Initials of words split by `_`, `.` or case: `ui` → user_id.
	local initials = string.sub(name, 1, 1)
	for c in string.gmatch(name, "[_%.%s]+(%w)") do
		initials ..= c
	end
	if string.sub(initials, 1, #prefix) == prefix then
		return 3
	end
	local at = string.find(name, prefix, 1, true)
	if at then
		return 2 - math.min(at, 50) / 100
	end
	local i = 1
	for p = 1, #prefix do
		local c = string.sub(prefix, p, p)
		local found = string.find(name, c, i, true)
		if not found then
			return 0
		end
		i = found + 1
	end
	return 1
end

local function add(out: { Item }, seen: { [string]: boolean }, prefix: string, item: Item)
	local key = item.kind .. "\0" .. item.label
	if seen[key] then
		return
	end
	local m = match_score(string.lower(item.label), string.lower(prefix))
	if m <= 0 then
		return
	end
	seen[key] = true
	item.score += m * 1000
	table.insert(out, item)
end

local function finish(out: { Item }, prefix: string, from: number, to: number): Popup?
	table.sort(out, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.label < b.label
	end)
	while #out > MAX_ITEMS do
		table.remove(out)
	end
	if #out == 0 then
		return nil
	end
	-- Nothing left to type: the only item is what is already there.
	if #out == 1 and string.lower(out[1].insert) == string.lower(prefix) then
		return nil
	end
	return { from = from, to = to, prefix = prefix, items = out }
end

-- SQL ----------------------------------------------------------------------

type Relation = { schema: string?, name: string, alias: string?, cte: boolean? }

local CLAUSES: { [string]: boolean } = {}
for _, w in { "SELECT", "FROM", "JOIN", "WHERE", "ON", "USING", "GROUP", "ORDER", "HAVING", "SET", "VALUES", "INTO",
	"UPDATE", "LIMIT", "OFFSET", "RETURNING", "WITH", "TABLE", "DELETE", "INSERT", "BY", "WINDOW", "PARTITION",
	"UNION", "INTERSECT", "EXCEPT", "DESCRIBE", "USE", "SHOW", "CASE", "WHEN", "THEN", "ELSE", "AND", "OR", "NOT" } do
	CLAUSES[w] = true
end

-- Words after which a table name comes.
local RELATION_BEFORE: { [string]: boolean } = {
	FROM = true, JOIN = true, INTO = true, UPDATE = true, TABLE = true, DESCRIBE = true, TRUNCATE = true,
	ANALYZE = true, REFRESH = true, VIEW = true,
}

-- Words after a table that never name its alias.
local NOT_ALIAS: { [string]: boolean } = {}
for _, w in { "WHERE", "ON", "USING", "JOIN", "LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL", "OUTER", "GROUP",
	"ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT", "SET", "VALUES", "RETURNING", "WINDOW",
	"AS", "FETCH", "FOR", "LATERAL", "SELECT", "DEFAULT", "TABLESAMPLE", "WITH" } do
	NOT_ALIAS[w] = true
end

local function unquote(s: string, t: sqltext.Token): string
	local text = string.sub(s, t.from, t.to)
	if t.kind == "qident" then
		local q = string.sub(text, 1, 1)
		local inner = string.sub(text, 2, if t.open then #text else #text - 1)
		if q == "[" then
			return inner
		end
		return (string.gsub(inner, q .. q, q))
	end
	return text
end

local function is_name(t: sqltext.Token?): boolean
	return t ~= nil and (t.kind == "word" or t.kind == "qident")
end

-- The tables a statement reads or writes, with their aliases, and its CTE names.
local function relations(s: string, toks: { sqltext.Token }): { Relation }
	local out: { Relation } = {}
	local i = 1
	local in_from = false
	local depth = 0
	local from_depth = -1
	while i <= #toks do
		local t = toks[i]
		local up = if t.kind == "word" then string.upper(string.sub(s, t.from, t.to)) else ""
		local ch = if t.kind == "punct" then string.sub(s, t.from, t.to) else ""
		if ch == "(" then
			depth += 1
		elseif ch == ")" then
			depth -= 1
			if depth < from_depth then
				in_from = false
			end
		end
		-- WITH name AS ( … ), name AS ( … )
		if is_name(t) and toks[i + 1] and toks[i + 1].kind == "word"
			and string.upper(string.sub(s, toks[i + 1].from, toks[i + 1].to)) == "AS"
			and toks[i + 2] and string.sub(s, toks[i + 2].from, toks[i + 2].to) == "(" then
			local before = toks[i - 1]
			local b = if before then string.upper(string.sub(s, before.from, before.to)) else ""
			if b == "WITH" or b == "," or b == "RECURSIVE" then
				table.insert(out, { name = unquote(s, t), cte = true })
			end
		end
		local starts = RELATION_BEFORE[up] or (in_from and ch == "," and depth == from_depth)
		if up == "FROM" or up == "JOIN" then
			in_from, from_depth = true, depth
		elseif CLAUSES[up] and up ~= "FROM" and up ~= "JOIN" and up ~= "AS" and depth == from_depth then
			in_from = false
		end
		if starts and is_name(toks[i + 1]) then
			local parts: { string } = {}
			local j = i + 1
			while is_name(toks[j]) do
				table.insert(parts, unquote(s, toks[j]))
				local dot = toks[j + 1]
				if dot and dot.kind == "punct" and string.sub(s, dot.from, dot.to) == "." and is_name(toks[j + 2]) then
					j += 2
				else
					break
				end
			end
			local name = parts[#parts]
			local schema = if #parts >= 2 then parts[#parts - 1] else nil
			local alias: string? = nil
			local k = j + 1
			local nxt = toks[k]
			if nxt and nxt.kind == "word" and string.upper(string.sub(s, nxt.from, nxt.to)) == "AS" then
				k += 1
				nxt = toks[k]
			end
			if is_name(nxt) then
				local w = string.upper(string.sub(s, (nxt :: sqltext.Token).from, (nxt :: sqltext.Token).to))
				if not NOT_ALIAS[w] or (nxt :: sqltext.Token).kind == "qident" then
					alias = unquote(s, nxt :: sqltext.Token)
				end
			end
			if name and string.upper(name) ~= "SELECT" and string.upper(name) ~= "LATERAL" then
				table.insert(out, { schema = schema, name = name, alias = alias })
			end
			i = j
		end
		i += 1
	end
	return out
end
complete.relations = relations

local function resolve(schema: Schema, rel: Relation): Table?
	local list = (schema.by_name or {})[string.lower(rel.name)]
	if not list then
		return nil
	end
	if rel.schema then
		for _, t in list do
			if string.lower(t.schema or "") == string.lower(rel.schema) then
				return t
			end
		end
		return nil
	end
	local preferred = string.lower(schema.default_schema or "")
	for _, t in list do
		if string.lower(t.schema or "") == preferred then
			return t
		end
	end
	local path: { string } = schema.search_path or {}
	for _, p in path do
		for _, t in list do
			if string.lower(t.schema or "") == string.lower(p) then
				return t
			end
		end
	end
	return list[1]
end
complete.resolve = resolve

local function table_item(t: Table, schema: Schema, dialect: string, qualified: boolean, bonus: number): Item
	local name = quote_name(t.name, dialect)
	local insert = name
	local default = schema.default_schema
	local search = false
	local path: { string } = schema.search_path or {}
	for _, p in path do
		if string.lower(p) == string.lower(t.schema or "") then
			search = true
		end
	end
	if not qualified and t.schema and t.schema ~= "" and string.lower(t.schema) ~= string.lower(default or "") and not search then
		insert = quote_name(t.schema, dialect) .. "." .. name
	end
	local detail = t.kind
	if t.schema and t.schema ~= "" then
		detail ..= " · " .. t.schema
	end
	return {
		label = t.name,
		insert = insert,
		kind = if string.find(t.kind, "view") then "view" else "table",
		detail = detail,
		score = 200 + bonus,
	}
end

local function column_items(out: { Item }, seen: { [string]: boolean }, prefix: string, t: Table, dialect: string, via: string?)
	for i, c in t.columns do
		local detail = c.type or ""
		if c.pk then
			detail ..= " · key"
		end
		detail ..= " · " .. (via or t.name)
		add(out, seen, prefix, {
			label = c.name,
			insert = quote_name(c.name, dialect),
			kind = "column",
			detail = detail,
			-- Earlier columns first, as the table declares them.
			score = 300 - math.min(i, 99) / 1000,
		})
	end
end

local function keyword_items(out: { Item }, seen: { [string]: boolean }, prefix: string, list: { string }, score: number)
	for _, w in list do
		add(out, seen, prefix, { label = w, insert = cased(w, prefix), kind = "keyword", score = score })
	end
end

local function function_items(out: { Item }, seen: { [string]: boolean }, prefix: string, dialect: string, schema: Schema?)
	local lists = { keywords.FUNCTIONS.common, (keywords.FUNCTIONS :: any)[dialect] or {} }
	if schema then
		table.insert(lists, schema.functions)
	end
	for li, list in lists do
		for _, f in list do
			add(out, seen, prefix, {
				label = f,
				insert = (if prefix ~= "" and string.upper(prefix) == prefix and li < 3 then string.upper(f) else f) .. "()",
				kind = "function",
				back = 1,
				detail = if li == 3 then "function" else nil,
				score = 150,
			})
		end
	end
end

local PHRASES_AFTER_TABLE = {
	"WHERE", "JOIN", "LEFT JOIN", "INNER JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN", "ON", "AS", "GROUP BY",
	"ORDER BY", "HAVING", "LIMIT", "UNION", "UNION ALL", "SET", "VALUES", "RETURNING", "USING",
}
local PHRASES_EXPR = {
	"AND", "OR", "NOT", "IN", "IS NULL", "IS NOT NULL", "LIKE", "ILIKE", "BETWEEN", "EXISTS", "CASE", "WHEN",
	"THEN", "ELSE", "END", "AS", "DISTINCT", "FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "ASC",
	"DESC", "NULLS FIRST", "NULLS LAST", "NULL", "TRUE", "FALSE", "OVER", "PARTITION BY", "FILTER", "INTERVAL",
	"UNION", "UNION ALL", "JOIN", "LEFT JOIN", "ON", "CAST",
}

-- The completion popup for SQL text with the caret before character `cur`.
function complete.sql(s: string, cur: number, dialect: string, schema: Schema?, explicit: boolean?): Popup?
	local field = require("./field")
	local pos = field.byte(s, cur)
	local toks = sqltext.lex(s, dialect)
	if sqltext.inside_literal(toks, pos) then
		return nil
	end
	-- The word being typed: [wstart, pos].
	local wstart = pos + 1
	while wstart > 1 and sqltext.is_word_byte(string.byte(s, wstart - 1) :: number) do
		wstart -= 1
	end
	local prefix = string.sub(s, wstart, pos)
	if string.match(prefix, "^%d") then
		return nil
	end
	-- This statement's tokens, the word itself left out.
	local stmt: { sqltext.Token } = {}
	local before: { sqltext.Token } = {}
	for _, t in toks do
		if t.kind == "punct" and string.byte(s, t.from) == 59 then
			if t.to < wstart then
				stmt, before = {}, {}
			else
				break
			end
		elseif t.kind ~= "comment" and t.kind ~= "ask" then
			if t.to < wstart then
				table.insert(stmt, t)
				table.insert(before, t)
			elseif t.from > pos then
				table.insert(stmt, t)
			end
		end
	end
	-- The qualifier chain before the word: `a.b.` → { "a", "b" }.
	local quals: { string } = {}
	local k = #before
	while k >= 2 do
		local dot = before[k]
		if dot.kind == "punct" and string.sub(s, dot.from, dot.to) == "." and dot.to == wstart - 1
			and is_name(before[k - 1]) then
			table.insert(quals, 1, unquote(s, before[k - 1]))
			wstart = before[k - 1].from
			k -= 2
		else
			break
		end
	end
	local prev = before[k]
	local prev_up = if prev and prev.kind == "word" then string.upper(string.sub(s, prev.from, prev.to)) else ""
	local prev_ch = if prev and prev.kind ~= "word" then string.sub(s, prev.from, prev.to) else ""
	local from = field.char_of_byte(s, pos - #prefix)
	local out: { Item } = {}
	local seen: { [string]: boolean } = {}
	local rels = relations(s, stmt)
	local sch = schema
	if sch and not sch.by_name then
		complete.index(sch)
	end
	if prefix == "" and not explicit and #quals == 0 then
		return nil
	end

	if #quals > 0 then
		local q = quals[#quals]
		local lq = string.lower(q)
		-- An alias or table of this statement: its columns.
		for _, r in rels do
			if (r.alias and string.lower(r.alias) == lq) or (not r.alias and string.lower(r.name) == lq) then
				local t = if sch then resolve(sch, r) else nil
				if t then
					column_items(out, seen, prefix, t, dialect, r.alias and t.name or nil)
				end
			end
		end
		if sch then
			-- A schema: its tables. (Trino: catalog.schema. names tables too.)
			for _, t in (sch.by_schema or {})[lq] or {} do
				add(out, seen, prefix, table_item(t, sch, dialect, true, 0))
			end
			if #quals == 1 and #out == 0 then
				local list = (sch.by_name or {})[lq]
				local t = if list then list[1] else nil
				if t then
					column_items(out, seen, prefix, t, dialect, nil)
				end
			end
			if dialect == "trino" and sch.catalog and string.lower(sch.catalog) == string.lower(quals[1]) and #quals == 1 then
				for _, sname in sch.schemas do
					add(out, seen, prefix, { label = sname, insert = quote_name(sname, dialect), kind = "schema", detail = "schema", score = 250 })
				end
			end
		end
		return finish(out, prefix, from, cur)
	end

	local stmt_start = #before == 0
	if stmt_start then
		keyword_items(out, seen, prefix, keywords.STARTS.common, 120)
		keyword_items(out, seen, prefix, (keywords.STARTS :: any)[dialect] or {}, 110)
		return finish(out, prefix, from, cur)
	end

	-- Inside FROM a comma brings another table.
	local clause = ""
	local depth = 0
	for idx = #before, 1, -1 do
		local t = before[idx]
		local text = string.sub(s, t.from, t.to)
		if t.kind == "punct" and text == ")" then
			depth += 1
		elseif t.kind == "punct" and text == "(" then
			if depth == 0 then
				break
			end
			depth -= 1
		elseif depth == 0 and t.kind == "word" then
			local up = string.upper(text)
			if CLAUSES[up] or RELATION_BEFORE[up] then
				clause = up
				break
			end
		end
	end

	local wants_relation = RELATION_BEFORE[prev_up] or (prev_ch == "," and (clause == "FROM" or clause == "JOIN"))
		or (prev_up == "USE" and dialect == "trino")
	if wants_relation and sch then
		if prev_up == "USE" then
			local catalogs: { string } = sch.catalogs or {}
			for _, c in catalogs do
				add(out, seen, prefix, { label = c, insert = quote_name(c, dialect), kind = "schema", detail = "catalog", score = 260 })
			end
			for _, sname in sch.schemas do
				add(out, seen, prefix, { label = sname, insert = quote_name(sname, dialect), kind = "schema", detail = "schema", score = 250 })
			end
			return finish(out, prefix, from, cur)
		end
		for _, t in sch.tables do
			local default = string.lower(t.schema or "") == string.lower(sch.default_schema or "")
			add(out, seen, prefix, table_item(t, sch, dialect, false, if default then 10 else 0))
		end
		for _, sname in sch.schemas do
			add(out, seen, prefix, { label = sname, insert = quote_name(sname, dialect) .. ".", kind = "schema", detail = "schema", score = 180 })
		end
		if dialect == "trino" then
			local catalogs: { string } = sch.catalogs or {}
			for _, c in catalogs do
				add(out, seen, prefix, { label = c, insert = quote_name(c, dialect) .. ".", kind = "schema", detail = "catalog", score = 170 })
			end
		end
		for _, r in rels do
			if r.cte then
				add(out, seen, prefix, { label = r.name, insert = quote_name(r.name, dialect), kind = "table", detail = "WITH query", score = 230 })
			end
		end
		return finish(out, prefix, from, cur)
	elseif wants_relation then
		return nil
	end

	if prev_ch == "::" or (prev_up == "AS" and clause == "CAST") then
		keyword_items(out, seen, prefix, (keywords.TYPES :: any)[dialect] or keywords.TYPES.postgres, 300)
		return finish(out, prefix, from, cur)
	end

	-- Right after a table in FROM or JOIN: the clause's keywords.
	if (clause == "FROM" or clause == "JOIN" or clause == "UPDATE" or clause == "INTO") and prev and is_name(prev)
		and not CLAUSES[prev_up] then
		keyword_items(out, seen, prefix, PHRASES_AFTER_TABLE, 300)
		return finish(out, prefix, from, cur)
	end

	-- An expression: the statement's columns, its aliases, functions and keywords.
	if sch then
		for _, r in rels do
			local t = resolve(sch, r)
			if t then
				column_items(out, seen, prefix, t, dialect, r.alias and t.name or nil)
				add(out, seen, prefix, {
					label = r.alias or t.name,
					insert = quote_name(r.alias or t.name, dialect),
					kind = "alias",
					detail = if r.alias then "alias · " .. t.name else t.kind,
					score = 240,
				})
			end
		end
		if #rels == 0 then
			for _, t in sch.tables do
				add(out, seen, prefix, table_item(t, sch, dialect, false, -60))
			end
		end
	end
	function_items(out, seen, prefix, dialect, sch)
	keyword_items(out, seen, prefix, PHRASES_EXPR, 100)
	return finish(out, prefix, from, cur)
end

-- Redis ---------------------------------------------------------------------

local COMMANDS: { [string]: keywords.Command } = {}
for _, c in keywords.REDIS do
	COMMANDS[c.name] = c
end
complete.COMMANDS = COMMANDS

-- The completion popup for Redis text with the caret before character `cur`.
function complete.redis(s: string, cur: number, keys: { RedisKey }?, explicit: boolean?): Popup?
	local field = require("./field")
	local pos = field.byte(s, cur)
	local line_from = pos
	while line_from > 0 and string.byte(s, line_from) ~= 10 do
		line_from -= 1
	end
	local line = string.sub(s, line_from + 1, pos)
	local lead = string.match(line, "^%s*(.?)")
	if lead == "?" or lead == "#" or string.match(line, "^%s*%-%-") or string.match(line, "^%s*//") then
		return nil
	end
	local quotes = select(2, string.gsub(line, '"', "")) :: number
	if quotes % 2 == 1 then
		return nil
	end
	local prefix = string.match(line, "(%S*)$") or ""
	local words: { string } = {}
	for w in string.gmatch(string.sub(line, 1, #line - #prefix), "%S+") do
		table.insert(words, w)
	end
	local from = field.char_of_byte(s, pos - #prefix)
	if prefix == "" and not explicit then
		return nil
	end
	local out: { Item } = {}
	local seen: { [string]: boolean } = {}
	if #words == 0 then
		for _, c in keywords.REDIS do
			add(out, seen, prefix, {
				label = c.name,
				insert = cased(c.name, prefix),
				kind = "command",
				detail = if c.args ~= "" then c.args else c.group,
				score = 100,
			})
		end
		return finish(out, prefix, from, cur)
	end
	local name = string.upper(words[1])
	local c = COMMANDS[name]
	local arg = #words
	if c and c.key and arg >= c.key then
		local multi = string.find(c.args, "key [key", 1, true) ~= nil or string.find(c.args, "[key …]", 1, true) ~= nil
		if arg == c.key or multi then
			local known: { RedisKey } = keys or {}
			for _, k in known do
				add(out, seen, prefix, { label = k.key, insert = k.key, kind = "key", detail = k.type, score = 300 })
			end
		end
	end
	local options: { string } = keywords.REDIS_OPTIONS[name] or {}
	for _, o in options do
		add(out, seen, prefix, { label = o, insert = cased(o, prefix), kind = "keyword", score = 200 })
	end
	return finish(out, prefix, from, cur)
end

return complete
