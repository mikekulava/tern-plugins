--!strict

local regex = {}

type Node = {
	t: string,
	c: number?,
	neg: boolean?,
	ranges: { number }?,
	classes: { string }?,
	items: { Node }?,
	node: Node?,
	min: number?,
	max: number?,
	lazy: boolean?,
}

export type Regex = {
	root: Node,
	ci: boolean,
}

local STEP_LIMIT = 400000
local INF = math.huge

local BYTE = string.byte
local LOWER_A, LOWER_Z = BYTE("a"), BYTE("z")
local UPPER_A, UPPER_Z = BYTE("A"), BYTE("Z")
local DIGIT_0, DIGIT_9 = BYTE("0"), BYTE("9")
local UNDERSCORE = BYTE("_")

local function is_digit(c: number): boolean
	return c >= DIGIT_0 and c <= DIGIT_9
end

local function is_word(c: number?): boolean
	if c == nil then
		return false
	end
	return is_digit(c) or (c >= LOWER_A and c <= LOWER_Z) or (c >= UPPER_A and c <= UPPER_Z) or c == UNDERSCORE
end

local function is_space(c: number): boolean
	return c == 32 or (c >= 9 and c <= 13)
end

local function in_class(class: string, c: number): boolean
	if class == "d" then
		return is_digit(c)
	elseif class == "D" then
		return not is_digit(c)
	elseif class == "w" then
		return is_word(c)
	elseif class == "W" then
		return not is_word(c)
	elseif class == "s" then
		return is_space(c)
	elseif class == "S" then
		return not is_space(c)
	end
	return false
end

local function swap_case(c: number): number
	if c >= LOWER_A and c <= LOWER_Z then
		return c - 32
	elseif c >= UPPER_A and c <= UPPER_Z then
		return c + 32
	end
	return c
end

local function lower(c: number): number
	if c >= UPPER_A and c <= UPPER_Z then
		return c + 32
	end
	return c
end

local ESCAPES: { [string]: number } = {
	n = 10,
	t = 9,
	r = 13,
	f = 12,
	v = 11,
	a = 7,
	e = 27,
	["0"] = 0,
}

local function parse(src: string, ci: boolean): Node
	local pos = 1
	local len = #src

	local function fail(why: string): never
		error("regex: " .. why .. " at " .. pos, 0)
	end

	local function char_node(c: number): Node
		return { t = "char", c = if ci then lower(c) else c }
	end

	local function read_escape(in_set: boolean): (number?, string?)
		pos += 1
		if pos > len then
			fail("trailing backslash")
		end
		local ch = string.sub(src, pos, pos)
		pos += 1
		if string.find(ch, "^[dDwWsS]$") then
			return nil, ch
		end
		local code = ESCAPES[ch]
		if code then
			return code, nil
		end
		if ch == "x" then
			local hex = string.match(src, "^%x%x", pos)
			if hex == nil then
				fail("bad \\x escape")
			end
			pos += 2
			return tonumber(hex :: string, 16), nil
		end
		if not in_set and (ch == "b" or ch == "B" or ch == "A" or ch == "z" or ch == "Z" or ch == "G") then
			return nil, "anchor:" .. ch
		end
		if string.find(ch, "^%a$") then
			fail("unsupported escape \\" .. ch)
		end
		return BYTE(ch), nil
	end

	local function parse_set(): Node
		pos += 1
		local node: Node = { t = "set", neg = false, ranges = {}, classes = {} }
		local ranges = node.ranges :: { number }
		local classes = node.classes :: { string }
		if string.sub(src, pos, pos) == "^" then
			node.neg = true
			pos += 1
		end
		local first = true
		while true do
			if pos > len then
				fail("unclosed [")
			end
			local ch = string.sub(src, pos, pos)
			if ch == "]" and not first then
				pos += 1
				break
			end
			first = false
			local lo: number?
			if ch == "\\" then
				local code, class = read_escape(true)
				if class then
					table.insert(classes, class)
				else
					lo = code
				end
			elseif ch == "[" then
				fail("nested classes are not supported")
			else
				lo = BYTE(ch)
				pos += 1
			end
			if lo then
				local hi = lo
				if string.sub(src, pos, pos) == "-" and string.sub(src, pos + 1, pos + 1) ~= "]" and pos + 1 <= len then
					pos += 1
					local nch = string.sub(src, pos, pos)
					if nch == "\\" then
						local code, class = read_escape(true)
						if class or code == nil then
							fail("bad range")
						end
						hi = code :: number
					else
						hi = BYTE(nch)
						pos += 1
					end
				end
				if (hi :: number) < lo then
					fail("bad range")
				end
				table.insert(ranges, lo)
				table.insert(ranges, hi :: number)
			end
		end
		return node
	end

	local parse_alt: () -> Node

	local function parse_group(): Node
		pos += 1
		if string.sub(src, pos, pos) == "?" then
			local nxt = string.sub(src, pos + 1, pos + 1)
			if nxt == ":" or nxt == ">" then
				pos += 2
			elseif nxt == "<" and not string.find(string.sub(src, pos + 2, pos + 2), "^[=!]$") then
				local close = string.find(src, ">", pos, true)
				if close == nil then
					fail("unclosed group name")
				end
				pos = (close :: number) + 1
			elseif string.find(nxt, "^[imsux%-]$") then
				local flags, rest = string.match(src, "^%?([imsux%-]+)([:%)])", pos)
				if flags == nil then
					fail("bad flags")
				end
				pos += #(flags :: string) + 2
				if rest == ")" then
					return { t = "seq", items = {} }
				end
			else
				fail("lookaround is not supported")
			end
		end
		local inner = parse_alt()
		if string.sub(src, pos, pos) ~= ")" then
			fail("unclosed (")
		end
		pos += 1
		return { t = "group", node = inner }
	end

	local function parse_atom(): Node?
		local ch = string.sub(src, pos, pos)
		if ch == "(" then
			return parse_group()
		elseif ch == "[" then
			return parse_set()
		elseif ch == "." then
			pos += 1
			return { t = "any" }
		elseif ch == "^" then
			pos += 1
			return { t = "bol" }
		elseif ch == "$" then
			pos += 1
			return { t = "eol" }
		elseif ch == "\\" then
			if string.sub(src, pos + 1, pos + 1) == "Q" then
				local close = string.find(src, "\\E", pos + 2, true)
				local text = string.sub(src, pos + 2, if close then close - 1 else len)
				pos = if close then close + 2 else len + 1
				local items: { Node } = {}
				for i = 1, #text do
					table.insert(items, char_node(BYTE(text, i) :: number))
				end
				return { t = "seq", items = items }
			end
			local code, class = read_escape(false)
			if class then
				if string.sub(class, 1, 7) == "anchor:" then
					local which = string.sub(class, 8)
					if which == "b" then
						return { t = "wordb", neg = false }
					elseif which == "B" then
						return { t = "wordb", neg = true }
					elseif which == "A" or which == "G" then
						return { t = "bol" }
					end
					return { t = "eol" }
				end
				return { t = "set", neg = false, ranges = {}, classes = { class } }
			end
			return char_node(code :: number)
		elseif ch == ")" or ch == "|" then
			return nil
		elseif ch == "*" or ch == "+" or ch == "?" then
			fail("nothing to repeat")
		end
		pos += 1
		return char_node(BYTE(ch) :: number)
	end

	local function parse_quantified(atom: Node): Node
		local node = atom
		while pos <= len do
			local ch = string.sub(src, pos, pos)
			local min, max
			if ch == "*" then
				min, max = 0, INF
				pos += 1
			elseif ch == "+" then
				min, max = 1, INF
				pos += 1
			elseif ch == "?" then
				min, max = 0, 1
				pos += 1
			elseif ch == "{" then
				local a, b, close = string.match(src, "^{(%d*),?(%d*)()}", pos)
				local whole = string.match(src, "^{[%d,]*}", pos)
				if a == nil or whole == nil or a == "" then
					return node
				end
				min = tonumber(a :: string) :: number
				if string.find(whole :: string, ",", 1, true) then
					max = if b == "" then INF else tonumber(b :: string) :: number
				else
					max = min
				end
				pos = (close :: number) + 1
				if max < min then
					fail("bad repeat bounds")
				end
			else
				return node
			end
			local lazy = false
			local suffix = string.sub(src, pos, pos)
			if suffix == "?" then
				lazy = true
				pos += 1
			elseif suffix == "+" then
				pos += 1
			end
			node = { t = "rep", node = node, min = min, max = max, lazy = lazy }
		end
		return node
	end

	local function parse_seq(): Node
		local items: { Node } = {}
		while pos <= len do
			local atom = parse_atom()
			if atom == nil then
				break
			end
			table.insert(items, parse_quantified(atom))
		end
		if #items == 1 then
			return items[1]
		end
		return { t = "seq", items = items }
	end

	parse_alt = function(): Node
		local options: { Node } = { parse_seq() }
		while string.sub(src, pos, pos) == "|" do
			pos += 1
			table.insert(options, parse_seq())
		end
		if #options == 1 then
			return options[1]
		end
		return { t = "alt", items = options }
	end

	local root = parse_alt()
	if pos <= len then
		fail("unbalanced )")
	end
	return root
end

function regex.compile(pattern: string): Regex?
	local ci = false
	local body = pattern
	local flags = string.match(body, "^%(%?([imsux%-]+)%)")
	if flags then
		local on = string.match(flags, "^[^%-]*") or ""
		ci = string.find(on, "i", 1, true) ~= nil
		body = string.sub(body, #flags + 4)
	end
	local ok, root = pcall(parse, body, ci)
	if not ok then
		return nil
	end
	return { root = root :: Node, ci = ci }
end

function regex.matches(re: Regex, text: string): boolean
	local s = if re.ci then string.lower(text) else text
	local n = #s
	local ci = re.ci
	local steps = 0

	local function one(node: Node, i: number): boolean
		if i > n then
			return false
		end
		local c = BYTE(s, i) :: number
		local t = node.t
		if t == "any" then
			return true
		elseif t == "char" then
			return c == node.c
		end
		local hit = false
		local ranges = node.ranges :: { number }
		for r = 1, #ranges, 2 do
			local lo, hi = ranges[r], ranges[r + 1]
			if (c >= lo and c <= hi) or (ci and swap_case(c) >= lo and swap_case(c) <= hi) then
				hit = true
				break
			end
		end
		if not hit then
			for _, class in node.classes :: { string } do
				if in_class(class, c) then
					hit = true
					break
				end
			end
		end
		return if node.neg then not hit else hit
	end

	local m: (node: Node, i: number, k: (number) -> boolean) -> boolean

	local function seq(items: { Node }, idx: number, i: number, k: (number) -> boolean): boolean
		if idx > #items then
			return k(i)
		end
		return m(items[idx], i, function(j: number): boolean
			return seq(items, idx + 1, j, k)
		end)
	end

	local function rep(node: Node, i: number, k: (number) -> boolean): boolean
		local inner = node.node :: Node
		local min = node.min :: number
		local max = node.max :: number
		local lazy = node.lazy == true
		local t = inner.t
		if t == "any" or t == "char" or t == "set" then
			local count = 0
			local limit = math.min(max, n - i + 1)
			while count < limit and one(inner, i + count) do
				count += 1
			end
			if count < min then
				return false
			end
			if lazy then
				for c = min, count do
					if k(i + c) then
						return true
					end
				end
			else
				for c = count, min, -1 do
					if k(i + c) then
						return true
					end
				end
			end
			return false
		end
		local function step(j: number, count: number): boolean
			steps += 1
			if steps > STEP_LIMIT then
				error("regex: step limit", 0)
			end
			local function more(): boolean
				if count >= max then
					return false
				end
				return m(inner, j, function(j2: number): boolean
					if j2 == j and count >= min then
						return false
					end
					return step(j2, count + 1)
				end)
			end
			if lazy then
				if count >= min and k(j) then
					return true
				end
				return more()
			end
			if more() then
				return true
			end
			return count >= min and k(j)
		end
		return step(i, 0)
	end

	m = function(node: Node, i: number, k: (number) -> boolean): boolean
		steps += 1
		if steps > STEP_LIMIT then
			error("regex: step limit", 0)
		end
		local t = node.t
		if t == "char" or t == "any" or t == "set" then
			return one(node, i) and k(i + 1)
		elseif t == "seq" then
			return seq(node.items :: { Node }, 1, i, k)
		elseif t == "alt" then
			for _, option in node.items :: { Node } do
				if m(option, i, k) then
					return true
				end
			end
			return false
		elseif t == "group" then
			return m(node.node :: Node, i, k)
		elseif t == "rep" then
			return rep(node, i, k)
		elseif t == "bol" then
			return i == 1 and k(i)
		elseif t == "eol" then
			return (i == n + 1 or (i == n and BYTE(s, n) == 10)) and k(i)
		elseif t == "wordb" then
			local at = is_word(BYTE(s, i - 1)) ~= is_word(BYTE(s, i))
			if node.neg then
				at = not at
			end
			return at and k(i)
		end
		return false
	end

	local ok, result = pcall(m, re.root, 1, function(j: number): boolean
		return j == n + 1
	end)
	return ok and result == true
end

return regex
