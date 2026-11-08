--!strict
-- Ranking a candidate name against what was typed, case-insensitively.
--
-- Scores fall in bands, best first: exact (1000), prefix (900), substring starting at a
-- word (800), every typed run starting at a word, camel humps included (`fbn` →
-- `findByName`, 500), substring inside a word (450), any subsequence (200). Within a
-- band, shorter candidates and earlier matches rank higher; matching the typed case
-- exactly adds a little.

local fuzzy = {}

local find, sub, byte, lower = string.find, string.sub, string.byte, string.lower

export type Query = {
	text: string,
	lower: string,
	-- One-byte strings of `lower`.
	chars: { string },
	n: number,
}

function fuzzy.query(text: string): Query
	local l = lower(text)
	local chars = table.create(#l)
	for i = 1, #l do
		chars[i] = sub(l, i, i)
	end
	return { text = text, lower = l, chars = chars, n = #l }
end

-- Whether the query's characters occur in `l` (a lowercase candidate) in order.
function fuzzy.has(l: string, q: Query): boolean
	local p = 1
	local chars = q.chars
	for i = 1, q.n do
		local f = find(l, chars[i], p, true)
		if f == nil then
			return false
		end
		p = f + 1
	end
	return true
end

local function is_lower(b: number): boolean
	return b >= 97 and b <= 122
end

local function is_upper(b: number): boolean
	return b >= 65 and b <= 90
end

local function is_digit(b: number): boolean
	return b >= 48 and b <= 57
end

local function is_alnum(b: number): boolean
	return is_lower(b) or is_upper(b) or is_digit(b) or b >= 128
end

-- Whether byte `i` of `s` starts a word: the first byte, after a separator (`_`, `-`, `.`,
-- `/`, space), a camel hump (`aB`) or the first digit after letters.
local function word_start(s: string, i: number): boolean
	if i <= 1 then
		return true
	end
	local a, b = byte(s, i - 1, i)
	if not is_alnum(a) then
		return is_alnum(b)
	end
	if is_upper(b) and not is_upper(a) then
		return true
	end
	return is_digit(b) and not is_digit(a)
end

local function penalty(x: number): number
	return math.min(90, x)
end

local function range(from: number, n: number): { number }
	local t = table.create(n)
	for i = 1, n do
		t[i] = from + i - 1
	end
	return t
end

-- The score of `s` (`l` is `string.lower(s)`) for `q`, nil when it doesn't match; with
-- `want_positions`, also the matched byte positions in `s`.
function fuzzy.score(s: string, l: string, q: Query, want_positions: boolean?): (number?, { number }?)
	local n, m = q.n, #l
	if n == 0 then
		return 0, if want_positions then {} else nil
	end
	if n > m then
		return nil, nil
	end
	local case_bonus = if find(s, q.text, 1, true) then 5 else 0
	local at = find(l, q.lower, 1, true)
	-- A substring inside a word, kept in case a word-start match ranks higher.
	local inner: number? = nil
	if at then
		local band
		if m == n then
			band = 1000
		elseif at == 1 then
			band = 900
		elseif word_start(s, at) then
			band = 800
		end
		if band then
			local score = band - penalty((m - n) * 0.5 + at * 0.2) + case_bonus
			return score, if want_positions then range(at, n) else nil
		end
		inner = 450 - penalty((m - n) * 0.5 + at * 0.2) + case_bonus
	end
	local chars = q.chars

	-- Every run of consecutive typed characters starts at a word.
	local positions = table.create(n)
	local pos, last, runs = 1, 0, 0
	local ok = true
	for i = 1, n do
		local c = chars[i]
		if last > 0 and sub(l, last + 1, last + 1) == c then
			last += 1
		else
			local f = find(l, c, pos, true)
			while f and not word_start(s, f) do
				f = find(l, c, f + 1, true)
			end
			if f == nil then
				ok = false
				break
			end
			last = f
			runs += 1
		end
		positions[i] = last
		pos = last + 1
	end
	if ok then
		local score = 500 - penalty(runs * 6 + (m - n) * 0.3 + positions[1] * 0.2) + case_bonus
		return score, if want_positions then positions else nil
	end
	if inner then
		return inner, if want_positions then range(at :: number, n) else nil
	end

	-- Any subsequence: fewer and shorter gaps rank higher.
	pos = 1
	local gaps, prev = 0, 0
	for i = 1, n do
		local f = find(l, chars[i], pos, true)
		if f == nil then
			return nil, nil
		end
		if prev > 0 and f > prev + 1 then
			gaps += 1 + (f - prev - 1) * 0.1
		end
		positions[i] = f
		prev = f
		pos = f + 1
	end
	local score = 200 - penalty(gaps * 8 + (m - n) * 0.3 + positions[1] * 0.2) + case_bonus
	return score, if want_positions then positions else nil
end

return fuzzy
