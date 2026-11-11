--!strict
-- Reading the editor's text: SQL tokens, the statements `;` separates, Redis command lines,
-- and the requests for the agent (lines starting with `?`). Offsets are bytes, 1-based and
-- inclusive, as Luau's string functions take them.
--
-- Dialects: "postgres" adds $tag$ quotes, E'…' escapes and nested /* */; "sqlite" adds `…`
-- and […] identifiers; "trino" is plain SQL. Redis text is lines, one command each, blank
-- lines separating blocks; `#`, `--` and `//` lines are comments there.

export type Token = {
	kind: string,
	from: number,
	to: number,
	-- A string, quoted identifier or comment that runs to the end of the text.
	open: boolean?,
	-- A `--` comment: it goes on to the end of its line.
	line: boolean?,
}

export type Unit = {
	-- Bytes of the whole unit, its `?` lines and the `;` that ends it included.
	from: number,
	to: number,
	-- What runs: one statement for SQL, the command lines of a block for Redis.
	commands: { string },
	-- Where each command starts in the text.
	starts: { number },
	-- The requests for the agent, without their `?`.
	asks: { string },
}

local sqltext = {}

local function is_word_byte(b: number): boolean
	return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b == 36 or b >= 128
end
sqltext.is_word_byte = is_word_byte

local function is_word_start(b: number): boolean
	return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b >= 128
end

-- Whether byte `i` starts its line after nothing but spaces and tabs.
local function at_line_start(s: string, i: number): boolean
	local j = i - 1
	while j >= 1 do
		local b = string.byte(s, j)
		if b == 10 then
			return true
		elseif b ~= 32 and b ~= 9 then
			return false
		end
		j -= 1
	end
	return true
end

local OPERATORS = { "::", "<>", "<=", ">=", "!=", "||", "->>", "->", "#>>", "#>", "@>", "<@", "=>", "**", "~*", "!~*", "!~" }
table.sort(OPERATORS, function(a, b)
	return #a > #b
end)

function sqltext.lex(s: string, dialect: string): { Token }
	local out: { Token } = {}
	local i, n = 1, #s
	local pg = dialect == "postgres"
	local lite = dialect == "sqlite"
	while i <= n do
		local b = string.byte(s, i)
		if b == 32 or b == 9 or b == 10 or b == 13 or b == 12 then
			i += 1
		elseif b == 45 and string.byte(s, i + 1) == 45 then -- --
			local e = string.find(s, "\n", i, true)
			local stop = if e then e - 1 else n
			table.insert(out, { kind = "comment", from = i, to = stop, line = true })
			i = stop + 1
		elseif b == 47 and string.byte(s, i + 1) == 42 then -- /*
			local depth, j, open = 1, i + 2, true
			while j <= n do
				if pg and string.byte(s, j) == 47 and string.byte(s, j + 1) == 42 then
					depth += 1
					j += 2
				elseif string.byte(s, j) == 42 and string.byte(s, j + 1) == 47 then
					depth -= 1
					j += 2
					if depth == 0 then
						open = false
						break
					end
				else
					j += 1
				end
			end
			local stop = math.min(j - 1, n)
			table.insert(out, { kind = "comment", from = i, to = stop, open = if open then true else nil })
			i = stop + 1
		elseif b == 63 and at_line_start(s, i) then -- ? request line
			local e = string.find(s, "\n", i, true)
			local stop = if e then e - 1 else n
			table.insert(out, { kind = "ask", from = i, to = stop })
			i = stop + 1
		elseif b == 39 then -- 'string'
			local backslash = false
			local prev = out[#out]
			if pg and prev and prev.kind == "word" and prev.to == i - 1 then
				local w = string.lower(string.sub(s, prev.from, prev.to))
				if w == "e" then
					backslash = true
					table.remove(out)
				end
			end
			local start = if backslash then i - 1 else i
			local j, open = i + 1, true
			while j <= n do
				local c = string.byte(s, j)
				if backslash and c == 92 then
					j += 2
				elseif c == 39 then
					if string.byte(s, j + 1) == 39 then
						j += 2
					else
						open = false
						break
					end
				else
					j += 1
				end
			end
			local stop = math.min(j, n)
			table.insert(out, { kind = "string", from = start, to = stop, open = if open then true else nil })
			i = stop + 1
		elseif b == 34 or (lite and b == 96) then -- "identifier" or `identifier`
			local j, open = i + 1, true
			while j <= n do
				if string.byte(s, j) == b then
					if string.byte(s, j + 1) == b then
						j += 2
					else
						open = false
						break
					end
				else
					j += 1
				end
			end
			local stop = math.min(j, n)
			table.insert(out, { kind = "qident", from = i, to = stop, open = if open then true else nil })
			i = stop + 1
		elseif lite and b == 91 then -- [identifier]
			local e = string.find(s, "]", i + 1, true)
			local stop = e or n
			table.insert(out, { kind = "qident", from = i, to = stop, open = if e then nil else true })
			i = stop + 1
		elseif pg and b == 36 then -- $tag$ … $tag$ or $1
			local tag = string.match(s, "^%$[%a_][%w_]*%$", i) or string.match(s, "^%$%$", i)
			if tag then
				local e = string.find(s, tag, i + #tag, true)
				local stop = if e then e + #tag - 1 else n
				table.insert(out, { kind = "string", from = i, to = stop, open = if e then nil else true })
				i = stop + 1
			else
				local digits = string.match(s, "^%$%d+", i)
				local stop = i + (if digits then #digits - 1 else 0)
				table.insert(out, { kind = if digits then "param" else "punct", from = i, to = stop })
				i = stop + 1
			end
		elseif b >= 48 and b <= 57 then
			local num = string.match(s, "^%d+%.?%d*[eE][%+%-]?%d+", i) or string.match(s, "^%d+%.?%d*", i) or "0"
			table.insert(out, { kind = "number", from = i, to = i + #num - 1 })
			i += #num
		elseif is_word_start(b) then
			local j = i + 1
			while j <= n and is_word_byte(string.byte(s, j) :: number) do
				j += 1
			end
			table.insert(out, { kind = "word", from = i, to = j - 1 })
			i = j
		else
			local op: string? = nil
			for _, candidate in OPERATORS do
				if string.sub(s, i, i + #candidate - 1) == candidate then
					op = candidate
					break
				end
			end
			local len = if op then #op else 1
			table.insert(out, { kind = if op then "op" else "punct", from = i, to = i + len - 1 })
			i += len
		end
	end
	return out
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end
sqltext.trim = trim

local function ask_text(s: string, t: Token): string
	return trim(string.sub(s, t.from + 1, t.to))
end

-- The statements of SQL text: each runs from the end of the previous one to its `;`.
function sqltext.statements(s: string, dialect: string): { Unit }
	local toks = sqltext.lex(s, dialect)
	local units: { Unit } = {}
	local unit_from = 1
	local first, last = nil :: number?, nil :: number?
	local asks: { string } = {}
	local function close(stop: number)
		if first or #asks > 0 then
			local commands: { string } = {}
			local starts: { number } = {}
			if first and last then
				local sql = trim(string.sub(s, first, last))
				if sql ~= "" then
					table.insert(commands, sql)
					table.insert(starts, first)
				end
			end
			if #commands > 0 or #asks > 0 then
				table.insert(units, { from = unit_from, to = stop, commands = commands, starts = starts, asks = asks })
			end
		end
		unit_from, first, last, asks = stop + 1, nil, nil, {}
	end
	for _, t in toks do
		if t.kind == "punct" and string.byte(s, t.from) == 59 then
			close(t.to)
		elseif t.kind == "ask" then
			table.insert(asks, ask_text(s, t))
		elseif t.kind ~= "comment" then
			first = first or t.from
			last = t.to
		end
	end
	close(#s)
	-- A unit's range starts at its first token, not in the blank space before it.
	for _, u in units do
		local start = string.find(s, "%S", u.from)
		u.from = if start and start <= u.to then start else u.from
	end
	return units
end

-- The blocks of Redis text: runs of non-blank lines.
function sqltext.blocks(s: string): { Unit }
	local units: { Unit } = {}
	local cur: Unit? = nil
	local pos = 1
	for line in string.gmatch(s .. "\n", "(.-)\n") do
		local from, stop = pos, pos + #line - 1
		pos += #line + 1
		local text = trim(line)
		if text == "" then
			cur = nil
			continue
		end
		if not cur then
			local fresh: Unit = { from = from, to = stop, commands = {}, starts = {}, asks = {} }
			table.insert(units, fresh)
			cur = fresh
		end
		local u = cur :: Unit
		u.to = stop
		if string.sub(text, 1, 1) == "?" then
			table.insert(u.asks, trim(string.sub(text, 2)))
		elseif not (string.sub(text, 1, 1) == "#" or string.sub(text, 1, 2) == "--" or string.sub(text, 1, 2) == "//") then
			table.insert(u.commands, text)
			table.insert(u.starts, from + (string.find(line, "%S") or 1) - 1)
		end
	end
	return units
end

function sqltext.units(s: string, dialect: string): { Unit }
	return if dialect == "redis" then sqltext.blocks(s) else sqltext.statements(s, dialect)
end

-- The unit the caret (a byte offset: the caret sits before byte `pos + 1`) is in: the one
-- holding it, else the last one ending before it on its line, else the next one.
function sqltext.at(units: { Unit }, s: string, pos: number): Unit?
	for _, u in units do
		if pos + 1 >= u.from and pos <= u.to then
			return u
		end
	end
	local line_start = pos
	while line_start > 0 and string.byte(s, line_start) ~= 10 do
		line_start -= 1
	end
	local before: Unit? = nil
	for _, u in units do
		if u.to <= pos and u.to > line_start then
			before = u
		end
	end
	if before then
		return before
	end
	for _, u in units do
		if u.from > pos then
			return u
		end
	end
	return units[#units]
end

-- Whether the caret (between bytes pos and pos + 1) is inside a string, a comment, a `?`
-- line or an unclosed quoted identifier of SQL text: completion stays quiet there.
function sqltext.inside_literal(toks: { Token }, pos: number): boolean
	for _, t in toks do
		if t.from > pos then
			return false
		end
		if t.kind == "string" or t.kind == "comment" or t.kind == "ask" or (t.kind == "qident" and t.open) then
			if t.open or pos < t.to then
				return true
			end
			-- A line comment or request goes on at its end of line.
			if pos == t.to and (t.kind == "ask" or t.line) then
				return true
			end
		end
	end
	return false
end

-- Decorations for the editor: `?` request lines in the accent. Returns byte ranges.
function sqltext.ask_ranges(s: string, dialect: string): { { number } }
	local out: { { number } } = {}
	if dialect == "redis" then
		local pos = 1
		for line in string.gmatch(s .. "\n", "(.-)\n") do
			local lead = string.find(line, "%S")
			if lead and string.sub(line, lead, lead) == "?" then
				table.insert(out, { pos + lead - 1, pos + #line - 1 })
			end
			pos += #line + 1
		end
		return out
	end
	for _, t in sqltext.lex(s, dialect) do
		if t.kind == "ask" then
			table.insert(out, { t.from, t.to })
		end
	end
	return out
end

return sqltext
