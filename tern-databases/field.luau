--!strict
-- A text field the block owns: its text, caret and selection anchor (counted in characters)
-- and its own undo history. Tern draws the field from `text`/`cursor`/`anchor` (UTF-16 offsets,
-- see `field.props`) and never edits it. With the block's "edit" feature Tern keeps a native
-- selection and sends `edit` events (`field.apply_edit`) and ⌘Z as `undo`; every other key
-- reaches `field.key`: typing, deletes without a selection, word and line moves, Enter.

export type Snap = { text: string, cur: number }
export type Field = {
	text: string,
	cur: number,
	anchor: number?,
	undo: { Snap },
	redo: { Snap },
	-- The last change was typing, so the next typed character joins its undo step.
	typing: boolean,
	multiline: boolean,
}

local field = {}

local HISTORY = 300

-- Invalid UTF-8 (a binary paste) becomes U+FFFD, so the offset helpers never meet it.
function field.clean(s: string): string
	if utf8.len(s) then
		return s
	end
	local out: { string } = {}
	local i, n = 1, #s
	while i <= n do
		local c = string.byte(s, i)
		local size = if c < 0x80 then 1 elseif c < 0xE0 then 2 elseif c < 0xF0 then 3 else 4
		local piece = string.sub(s, i, i + size - 1)
		if utf8.len(piece) == 1 then
			table.insert(out, piece)
			i += size
		else
			table.insert(out, "\u{FFFD}")
			i += 1
		end
	end
	return table.concat(out)
end

function field.chars(s: string): { string }
	local out: { string } = {}
	for _, cp in utf8.codes(s) do
		table.insert(out, utf8.char(cp))
	end
	return out
end

function field.len(s: string): number
	return utf8.len(s) or #s
end

-- UTF-16 units before the first `n` characters.
function field.utf16(s: string, n: number): number
	local units, i = 0, 0
	for _, cp in utf8.codes(s) do
		if i >= n then
			break
		end
		units += if cp > 0xFFFF then 2 else 1
		i += 1
	end
	return units
end

-- Characters wholly inside the first `off` UTF-16 units (inside a surrogate pair rounds down).
function field.index(s: string, off: number): number
	local units, n = 0, 0
	for _, cp in utf8.codes(s) do
		local w = if cp > 0xFFFF then 2 else 1
		if units + w > off then
			break
		end
		units += w
		n += 1
	end
	return n
end

-- Bytes before the first `n` characters.
function field.byte(s: string, n: number): number
	if n <= 0 then
		return 0
	end
	local at = utf8.offset(s, n + 1)
	return if at then at - 1 else #s
end

-- Characters in the first `b` bytes.
function field.char_of_byte(s: string, b: number): number
	if b <= 0 then
		return 0
	end
	return utf8.len(s, 1, math.min(b, #s)) or b
end

-- UTF-16 units in the first `b` bytes.
function field.utf16_of_byte(s: string, b: number): number
	local units = 0
	for pos, cp in utf8.codes(s) do
		if pos > b then
			break
		end
		units += if cp > 0xFFFF then 2 else 1
	end
	return units
end

function field.new(text: string, multiline: boolean): Field
	local t = field.clean(text)
	return { text = t, cur = field.len(t), anchor = nil, undo = {}, redo = {}, typing = false, multiline = multiline }
end

-- Replaces the text with no undo step (a field filled in from elsewhere).
function field.reset(f: Field, text: string)
	f.text = field.clean(text)
	f.cur, f.anchor = field.len(f.text), nil
	f.undo, f.redo, f.typing = {}, {}, false
end

local function remember(f: Field)
	table.insert(f.undo, { text = f.text, cur = f.cur })
	if #f.undo > HISTORY then
		table.remove(f.undo, 1)
	end
	f.redo = {}
end

-- Replaces characters [from, to) by `ins`, the caret after it: one undo step (typing joins
-- the open one). Returns whether the text changed.
function field.replace(f: Field, from: number, to: number, ins: string, typing: boolean?): boolean
	local chars = field.chars(f.text)
	from = math.clamp(from, 0, #chars)
	to = math.clamp(to, from, #chars)
	local text = table.concat(chars, "", 1, from) .. ins .. table.concat(chars, "", to + 1)
	if text == f.text then
		f.cur, f.anchor = from + field.len(ins), nil
		return false
	end
	if not (typing and f.typing) then
		remember(f)
	end
	f.redo = {}
	f.typing = typing == true
	f.text, f.cur, f.anchor = text, from + field.len(ins), nil
	return true
end

-- Replaces the whole text as one undo step, the caret at `cur` (default the end).
function field.set(f: Field, text: string, cur: number?): boolean
	local t = field.clean(text)
	if t == f.text then
		return false
	end
	remember(f)
	f.typing = false
	f.text, f.anchor = t, nil
	f.cur = math.clamp(cur or field.len(t), 0, field.len(t))
	return true
end

function field.undo_step(f: Field, redo: boolean): boolean
	local from = if redo then f.redo else f.undo
	local snap = table.remove(from)
	if not snap then
		return false
	end
	table.insert(if redo then f.undo else f.redo, { text = f.text, cur = f.cur })
	f.text, f.cur, f.anchor, f.typing = snap.text, snap.cur, nil, false
	return true
end

-- Selection bounds, ordered; equal without a selection.
function field.bounds(f: Field): (number, number)
	local a = f.anchor
	if a == nil or a == f.cur then
		return f.cur, f.cur
	end
	return math.min(a, f.cur), math.max(a, f.cur)
end

-- Applies Tern's `edit` event: UTF-16 [from, to) becomes `text`, the caret at `cursor`.
-- Returns "text", "caret", or nil when the event is stale (its `len` is not our length).
function field.apply_edit(f: Field, ev: { [string]: any }): string?
	if tonumber(ev.len) ~= field.utf16(f.text, math.huge) then
		return nil
	end
	local from = field.index(f.text, tonumber(ev.from) or 0)
	local to = field.index(f.text, tonumber(ev.to) or 0)
	local ins = field.clean(if type(ev.text) == "string" then ev.text else "")
	if not f.multiline then
		ins = string.gsub(ins, "[\r\n]+", " ")
	else
		ins = string.gsub(ins, "\r\n?", "\n")
	end
	local changed = from ~= to or ins ~= ""
	if changed then
		field.replace(f, from, to, ins, false)
	end
	f.cur = field.index(f.text, tonumber(ev.cursor) or 0)
	f.anchor, f.typing = nil, false
	return if changed then "text" else "caret"
end

local function line_start(chars: { string }, cur: number): number
	local i = cur
	while i > 0 and chars[i] ~= "\n" do
		i -= 1
	end
	return i
end

local function line_end(chars: { string }, cur: number): number
	local i = cur
	while i < #chars and chars[i + 1] ~= "\n" do
		i += 1
	end
	return i
end

field.line_start = line_start
field.line_end = line_end

-- Letters, digits, `_` and everything non-ASCII belong to words.
local function is_word(c: string): boolean
	return #c > 1 or string.find(c, "^[%w_$]$") ~= nil
end

local function word_left(chars: { string }, cur: number): number
	local i = cur
	while i > 0 and not is_word(chars[i]) do
		i -= 1
	end
	while i > 0 and is_word(chars[i]) do
		i -= 1
	end
	return i
end

local function word_right(chars: { string }, cur: number): number
	local n, i = #chars, cur
	while i < n and not is_word(chars[i + 1]) do
		i += 1
	end
	while i < n and is_word(chars[i + 1]) do
		i += 1
	end
	return i
end

-- The leading spaces and tabs of the line holding `cur`.
function field.indent_of(chars: { string }, cur: number): string
	local i = line_start(chars, cur) + 1
	local out: { string } = {}
	while i <= #chars and (chars[i] == " " or chars[i] == "\t") do
		table.insert(out, chars[i])
		i += 1
	end
	return table.concat(out)
end

-- Applies a key. Returns "text" (changed), "caret" (moved or selected), "submit" (Enter in a
-- one-line field) or nil: the key is not the field's (Tab, Escape, chords), so the caller
-- decides. Tern turns keys acting on its own selection into `edit` events, so this sees the
-- rest: typing and deleting without a selection, word and line moves, ↑ on the first line.
function field.key(f: Field, key: Key, cx: BlockCx?): string?
	local chars = field.chars(f.text)
	local n = #chars
	f.cur = math.clamp(f.cur, 0, n)
	local lo, hi = field.bounds(f)
	local name = key.name
	local function remove(from: number, to: number): string
		return if field.replace(f, from, to, "", false) then "text" else "caret"
	end
	local function go(to: number): string
		to = math.clamp(to, 0, n)
		if key.shift then
			f.anchor = f.anchor or f.cur
		else
			f.anchor = nil
		end
		f.cur, f.typing = to, false
		return "caret"
	end
	local function vertical(step: number): string
		local start = line_start(chars, f.cur)
		local col = f.cur - start
		if step < 0 then
			if start == 0 then
				return go(0)
			end
			local prev = line_start(chars, start - 1)
			return go(math.min(prev + col, start - 1))
		end
		local stop = line_end(chars, f.cur)
		if stop >= n then
			return go(n)
		end
		local next_end = line_end(chars, stop + 1)
		return go(math.min(stop + 1 + col, next_end))
	end
	if (key.meta or key.ctrl) and not key.alt and name == "z" then
		return if field.undo_step(f, key.shift) then "text" else "caret"
	elseif key.ctrl and name == "y" then
		return if field.undo_step(f, true) then "text" else "caret"
	elseif key.meta and not key.ctrl and name == "a" then
		f.anchor, f.cur, f.typing = 0, n, false
		return "caret"
	elseif (key.meta or key.ctrl) and (name == "c" or name == "x") and lo ~= hi then
		if cx then
			cx:copy(table.concat(chars, "", lo + 1, hi))
		end
		return if name == "x" then remove(lo, hi) else "caret"
	elseif name == "backspace" or (key.ctrl and (name == "h" or name == "u" or name == "w")) then
		if lo ~= hi then
			return remove(lo, hi)
		end
		local to = f.cur - 1
		if key.meta or (key.ctrl and name == "u") then
			-- ⌘⌫ reaches a program as ctrl+u: delete to the line's start.
			to = line_start(chars, f.cur)
			if to == f.cur then
				to = f.cur - 1
			end
		elseif key.alt or (key.ctrl and name == "w") then
			to = word_left(chars, f.cur)
		end
		return remove(math.max(0, to), f.cur)
	elseif name == "delete" or (key.ctrl and (name == "d" or name == "k")) then
		if lo ~= hi then
			return remove(lo, hi)
		end
		local to = f.cur + 1
		if key.meta or (key.ctrl and name == "k") then
			to = line_end(chars, f.cur)
			if to == f.cur then
				to = f.cur + 1
			end
		elseif key.alt then
			to = word_right(chars, f.cur)
		end
		return remove(f.cur, math.min(n, to))
	elseif name == "left" or (key.ctrl and name == "b") then
		if not key.shift and lo ~= hi and not key.alt and not key.meta then
			return go(lo)
		end
		if key.alt then
			return go(word_left(chars, f.cur))
		elseif key.meta then
			return go(line_start(chars, f.cur))
		end
		return go(f.cur - 1)
	elseif name == "right" or (key.ctrl and name == "f") then
		if not key.shift and lo ~= hi and not key.alt and not key.meta then
			return go(hi)
		end
		if key.alt then
			return go(word_right(chars, f.cur))
		elseif key.meta then
			return go(line_end(chars, f.cur))
		end
		return go(f.cur + 1)
	elseif name == "home" or (key.ctrl and not key.meta and name == "a") then
		-- ⌘← reaches a program as ctrl+a, ⌘→ as ctrl+e.
		return go(if key.meta or (key.ctrl and name == "home") then 0 else line_start(chars, f.cur))
	elseif name == "end" or (key.ctrl and not key.meta and name == "e") then
		return go(if key.meta or (key.ctrl and name == "end") then n else line_end(chars, f.cur))
	elseif name == "up" and not (key.ctrl or key.alt) then
		return if key.meta then go(0) else vertical(-1)
	elseif name == "down" and not (key.ctrl or key.alt) then
		return if key.meta then go(n) else vertical(1)
	elseif name == "enter" and not (key.ctrl or key.meta or key.alt) then
		if not f.multiline then
			return "submit"
		end
		local indent = field.indent_of(chars, lo)
		return if field.replace(f, lo, hi, "\n" .. indent, false) then "text" else "caret"
	end
	local typed = key.text
	if name == "space" and (typed == nil or typed == "") then
		typed = " "
	end
	if name == "paste" then
		local ins = field.clean(typed or "")
		ins = if f.multiline then string.gsub(ins, "\r\n?", "\n") else string.gsub(ins, "[\r\n]+", " ")
		return if field.replace(f, lo, hi, ins, false) then "text" else "caret"
	end
	if typed and typed ~= "" and not (key.ctrl or key.meta) and string.byte(typed, 1) >= 32 and name ~= "tab"
		and name ~= "escape" and name ~= "enter" then
		return if field.replace(f, lo, hi, field.clean(typed), true) then "text" else "caret"
	end
	return nil
end

-- The props that draw `f` in an `input` or `editor` node: text, caret and selection.
function field.props(f: Field, p: { [string]: any }): { [string]: any }
	p.text = f.text
	p.cursor = field.utf16(f.text, f.cur)
	if f.anchor and f.anchor ~= f.cur then
		p.anchor = field.utf16(f.text, f.anchor)
	end
	return p
end

-- Inserts or removes `prefix` at the start of each line from `from` to `to` (characters):
-- removes it when every non-blank line has it. Returns whether the text changed.
function field.toggle_prefix(f: Field, from: number, to: number, prefix: string): boolean
	local chars = field.chars(f.text)
	local first = line_start(chars, from)
	local last = line_end(chars, to)
	local lines: { string } = {}
	local block = table.concat(chars, "", first + 1, last)
	for line in string.gmatch(block .. "\n", "(.-)\n") do
		table.insert(lines, line)
	end
	local all = true
	for _, line in lines do
		if string.find(line, "%S") and string.sub(string.match(line, "^%s*(.*)$") or "", 1, #prefix) ~= prefix then
			all = false
		end
	end
	local trimmed = string.gsub(prefix, "%s+$", "")
	for i, line in lines do
		if all then
			local lead, rest = string.match(line, "^(%s*)(.*)$")
			if string.sub(rest or "", 1, #prefix) == prefix then
				lines[i] = (lead or "") .. string.sub(rest :: string, #prefix + 1)
			elseif string.sub(rest or "", 1, #trimmed) == trimmed then
				lines[i] = (lead or "") .. string.sub(rest :: string, #trimmed + 1)
			end
		elseif string.find(line, "%S") then
			local lead, rest = string.match(line, "^(%s*)(.*)$")
			lines[i] = (lead or "") .. prefix .. (rest or "")
		end
	end
	local before = f.cur - first
	local changed = field.replace(f, first, last, table.concat(lines, "\n"), false)
	f.cur = math.clamp(first + before + (if all then -#prefix else #prefix), first, field.len(f.text))
	return changed
end

return field
