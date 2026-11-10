--!strict
-- Declarations in a source file: classes, functions, methods, variables and constants.
--
-- There is no parser: each language has line patterns for what a declaration starts like.
-- Brace languages track `{}` depth (strings and comments blanked first) so only top-level
-- declarations and direct members of a class-like body count, not locals inside function
-- bodies. Python and Ruby use indentation for the same.

export type Emit = (name: string, kind: string, line: number, container: string?) -> ()

local symbols = {}

local find, match, gsub, sub, byte = string.find, string.match, string.gsub, string.sub, string.byte

-- Language of each file extension (lowercase).
local LANG: { [string]: string } = {
	py = "python", pyi = "python", pyw = "python",
	js = "js", jsx = "js", mjs = "js", cjs = "js", ts = "js", tsx = "js", mts = "js", cts = "js",
	go = "go",
	rs = "rust",
	lua = "lua", luau = "lua",
	rb = "ruby", rake = "ruby",
	java = "java", cs = "java", dart = "java",
	kt = "kotlin", kts = "kotlin", scala = "kotlin", sc = "kotlin",
	swift = "swift",
	c = "c", h = "c", cc = "c", cpp = "c", cxx = "c", hpp = "c", hh = "c", hxx = "c", m = "c", mm = "c",
	php = "php",
	sh = "shell", bash = "shell", zsh = "shell",
}

function symbols.language(path: string): string?
	local ext = match(path, "%.([%w]+)$")
	if ext == nil then
		return nil
	end
	return LANG[string.lower(ext)]
end

local function is_constant(name: string): boolean
	return #name > 1 and match(name, "^[A-Z][A-Z0-9_]*$") ~= nil
end

-- Whether `w` occurs in `s` as a whole word.
local function has_word(s: string, w: string): boolean
	return find(" " .. s .. " ", "[^%w_]" .. w .. "[^%w_]") ~= nil
end

-- Whether the text after a JS name (`= async () =>`, `= function`, `: T = (a) =>`) is a function.
local function js_fn_value(after: string): boolean
	return match(after, "=%s*async[%s(]") ~= nil
		or match(after, "=%s*function") ~= nil
		or match(after, "=%s*%b()%s*[:=]") ~= nil
		or match(after, "=%s*[%a_$][%w_$]*%s*=>") ~= nil
end

local function set(words: string): { [string]: boolean }
	local s = {}
	for w in string.gmatch(words, "%S+") do
		s[w] = true
	end
	return s
end

-- Words that look like a declared name in a call or statement line.
local NOT_A_NAME = set([[
	if else elif for while do switch case return new delete throw catch try finally with
	await yield sizeof typeof instanceof in of not and or is as import from export
	function fn func def var let const static public private protected super this self
	break continue goto pass raise assert del lambda match when where defer go select
	print require include using namespace template typename operator package
]])

-- Strips `prefix` words (a set) from the start of `s`, as often as they repeat.
local function strip_words(s: string, words: { [string]: boolean }): string
	while true do
		local w, rest = match(s, "^([%a_]+)%s+(.*)$")
		if w == nil or not words[w] then
			return s
		end
		s = rest :: string
	end
end

-- Lines longer than this hold no declaration worth listing (minified or generated code),
-- and the line patterns can take quadratic time on them: they are skipped.
local LONG_LINE = 2000

-- Calls `fn` with each line and its 1-based number (a trailing `\r` dropped). A line over
-- LONG_LINE goes to `long(first, last)` instead, as a byte range of `text`, when given.
local function each_line(text: string, fn: (line: string, n: number) -> (), long: ((first: number, last: number) -> ())?)
	local pos, n, len = 1, 0, #text
	while pos <= len do
		local e = find(text, "\n", pos, true)
		local stop = if e then e - 1 else len
		if stop >= pos and byte(text, stop) == 13 then
			stop -= 1
		end
		n += 1
		if stop - pos < LONG_LINE then
			fn(sub(text, pos, stop), n)
		elseif long then
			long(pos, stop)
		end
		if e == nil then
			break
		end
		pos = e + 1
	end
end

-- ---------------------------------------------------------------- brace languages

type Container = { name: string, kind: string, depth: number }

type Ctx = {
	-- Depth of `{` at the start of the line.
	depth: number,
	-- The class-like body the line is directly in, else nil.
	inside: Container?,
	-- Whether the line is at file (or namespace/module body) level.
	top: boolean,
	line: number,
	emit: Emit,
	-- Set by a matcher to make the line's `{` (or the next one) open this container.
	open: { name: string, kind: string }?,
	-- Per-file matcher state.
	group: string?,
}

-- Kinds whose bodies hold members (methods, fields).
local CLASSY = set("class interface struct enum trait impl object extension module record protocol")

-- Blanks strings (contents) so braces and comment markers in them don't count.
local function blank_strings(code: string, single: boolean, backtick: boolean): string
	if find(code, "\\", 1, true) then
		code = gsub(code, "\\.", "")
	end
	if find(code, '"', 1, true) then
		code = gsub(code, '"[^"]*"', '""')
	end
	if single and find(code, "'", 1, true) then
		code = gsub(code, "'[^']*'", "''")
	end
	if backtick and find(code, "`", 1, true) then
		code = gsub(code, "`[^`]*`", "``")
	end
	return code
end

-- Occurrences of the byte `ch` in `s` from `first` to `last` (default: all of it).
local function count(s: string, ch: string, first: number?, last: number?): number
	local n, stop = 0, last or #s
	local at = find(s, ch, first or 1, true)
	while at and at <= stop do
		n += 1
		at = find(s, ch, at + 1, true)
	end
	return n
end

-- Runs `matcher` over each code line of a brace language with depth and container tracking.
-- `opts.single`: single quotes delimit strings; `opts.backtick`: so do backticks;
-- `opts.hash`: `#` starts a line comment.
local function brace_lang(
	text: string,
	emit: Emit,
	opts: { single: boolean, backtick: boolean, hash: boolean },
	matcher: (s: string, ctx: Ctx) -> ()
)
	local stack: { Container } = {}
	local depth = 0
	local in_comment = false
	local pending: { name: string, kind: string, depth: number }? = nil
	local ctx: Ctx = { depth = 0, inside = nil, top = true, line = 0, emit = emit, open = nil, group = nil }
	each_line(text, function(raw: string, n: number)
		local code = raw
		if in_comment then
			local e = find(code, "*/", 1, true)
			if e == nil then
				return
			end
			in_comment = false
			code = sub(code, e + 2)
		end
		code = blank_strings(code, opts.single, opts.backtick)
		if find(code, "/*", 1, true) then
			code = gsub(code, "/%*.-%*/", " ")
			local s = find(code, "/*", 1, true)
			if s then
				in_comment = true
				code = sub(code, 1, s - 1)
			end
		end
		local c = find(code, "//", 1, true)
		if c then
			code = sub(code, 1, c - 1)
		end
		if opts.hash and match(code, "^%s*#") and not match(code, "^%s*#%s*define") then
			code = ""
		end
		local s = match(code, "^%s*(.-)%s*$") or ""
		if s ~= "" then
			local top = stack[#stack]
			ctx.depth = depth
			ctx.line = n
			ctx.inside = if top and top.depth == depth - 1 and CLASSY[top.kind] then top else nil
			ctx.top = depth == 0 or (top ~= nil and top.depth == depth - 1 and top.kind == "namespace")
			ctx.open = nil
			matcher(s, ctx)
			if ctx.open then
				pending = { name = ctx.open.name, kind = ctx.open.kind, depth = depth }
			end
		end
		local opens, closes = count(code, "{"), count(code, "}")
		if opens > 0 and pending then
			table.insert(stack, { name = pending.name, kind = pending.kind, depth = pending.depth })
			pending = nil
		elseif pending and find(code, ";", 1, true) then
			-- A forward declaration (`class Foo;`) opens nothing.
			pending = nil
		end
		depth = math.max(0, depth + opens - closes)
		while #stack > 0 and stack[#stack].depth >= depth do
			table.remove(stack)
		end
	end, function(first: number, last: number)
		-- A long line declares nothing we list; its braces still move the depth.
		if not in_comment then
			depth = math.max(0, depth + count(text, "{", first, last) - count(text, "}", first, last))
			while #stack > 0 and stack[#stack].depth >= depth do
				table.remove(stack)
			end
		end
	end)
end

-- Emits a function-like name: a method in a class-like body, else a function at top level.
local function emit_fn(ctx: Ctx, name: string)
	if ctx.inside then
		ctx.emit(name, "method", ctx.line, ctx.inside.name)
	elseif ctx.top then
		ctx.emit(name, "function", ctx.line)
	end
end

-- Emits a variable-like name: a field in a class-like body, else a variable at top level.
local function emit_var(ctx: Ctx, name: string, constant: boolean?)
	if NOT_A_NAME[name] then
		return
	end
	local kind = if constant or is_constant(name) then "constant" else "variable"
	if ctx.inside then
		ctx.emit(name, if kind == "constant" then "constant" else "field", ctx.line, ctx.inside.name)
	elseif ctx.top then
		ctx.emit(name, kind, ctx.line)
	end
end

local function emit_type(ctx: Ctx, name: string, kind: string, opens: boolean?)
	if ctx.top or ctx.inside then
		ctx.emit(name, kind, ctx.line, if ctx.inside then ctx.inside.name else nil)
	end
	if opens then
		ctx.open = { name = name, kind = kind }
	end
end

-- JavaScript and TypeScript.
local JS_PREFIX = set("export default declare abstract async")
local JS_MEMBER = set("public private protected static readonly override abstract async get set declare accessor")
local ID = "[%a_$][%w_$]*"

local function js(s: string, ctx: Ctx)
	s = strip_words(s, JS_PREFIX)
	local name = match(s, "^function%s*%*?%s*(" .. ID .. ")")
	if name then
		return emit_fn(ctx, name)
	end
	name = match(s, "^class%s+(" .. ID .. ")")
	if name then
		return emit_type(ctx, name, "class", true)
	end
	name = match(s, "^interface%s+(" .. ID .. ")")
	if name then
		return emit_type(ctx, name, "interface", true)
	end
	name = match(s, "^type%s+(" .. ID .. ")%s*[=<]")
	if name then
		return emit_type(ctx, name, "type")
	end
	name = match(s, "^enum%s+(" .. ID .. ")") or match(s, "^const%s+enum%s+(" .. ID .. ")")
	if name then
		return emit_type(ctx, name, "enum")
	end
	name = match(s, "^namespace%s+([%w_$.]+)") or match(s, "^module%s+([%w_$.]+)")
	if name then
		emit_type(ctx, name, "module")
		ctx.open = { name = name, kind = "namespace" }
		return
	end
	local decl, rest = match(s, "^(%a+)%s+(.*)$")
	if (decl == "const" or decl == "let" or decl == "var") and rest and ctx.top and not ctx.inside then
		local n, after = match(rest :: string, "^(" .. ID .. ")(.*)$")
		if n then
			if js_fn_value(after or "") then
				return emit_fn(ctx, n)
			end
			return emit_var(ctx, n, decl == "const" and is_constant(n))
		end
		return
	end
	if ctx.inside and (ctx.inside.kind == "class") then
		local m = strip_words(s, JS_MEMBER)
		local mname = match(m, "^%*?(#?" .. ID .. ")%s*%??%s*%b<>%s*%(") or match(m, "^%*?(#?" .. ID .. ")%s*%??%s*%(")
		if mname then
			if not NOT_A_NAME[mname] or mname == "constructor" then
				return emit_fn(ctx, mname)
			end
			return
		end
		local fname, after = match(m, "^(#?" .. ID .. ")%s*[?!]?%s*([:=;].*)$")
		if fname and not NOT_A_NAME[fname] then
			if js_fn_value(after :: string) then
				return emit_fn(ctx, fname)
			end
			return emit_var(ctx, fname)
		end
	end
end

-- Go: `func`, `type`, `var`/`const` (also in `( … )` groups) and struct fields.
local function go(s: string, ctx: Ctx)
	if ctx.group then
		if match(s, "^%)") then
			ctx.group = nil
			return
		end
		local name = match(s, "^([%a_][%w_]*)")
		if name and name ~= "_" then
			if ctx.group == "type" then
				emit_type(ctx, name, "type")
			else
				emit_var(ctx, name, ctx.group == "const")
			end
		end
		return
	end
	if not ctx.top then
		if ctx.inside and ctx.inside.kind == "struct" then
			local field = match(s, "^([%a_][%w_]*)%s+[%*%[%]%w_.]")
			if field then
				ctx.emit(field, "field", ctx.line, ctx.inside.name)
			end
		elseif ctx.inside and ctx.inside.kind == "interface" then
			local m = match(s, "^([%a_][%w_]*)%s*%(")
			if m then
				ctx.emit(m, "method", ctx.line, ctx.inside.name)
			end
		end
		return
	end
	local recv, name = match(s, "^func%s*(%b())%s*([%a_][%w_]*)")
	if recv and name then
		local owner = match(recv :: string, "^%(%s*[%w_]+%s+%*?%s*([%a_][%w_]*)")
			or match(recv :: string, "^%(%s*%*?%s*([%a_][%w_]*)")
		ctx.emit(name, "method", ctx.line, owner)
		return
	end
	name = match(s, "^func%s+([%a_][%w_]*)")
	if name then
		ctx.emit(name, "function", ctx.line)
		return
	end
	local tname, what = match(s, "^type%s+([%a_][%w_]*)%s*%b[]%s*(%a*)")
	if tname == nil then
		tname, what = match(s, "^type%s+([%a_][%w_]*)%s+(%a*)")
	end
	if tname then
		if what == "struct" then
			emit_type(ctx, tname, "struct", true)
		elseif what == "interface" then
			emit_type(ctx, tname, "interface", true)
		else
			emit_type(ctx, tname, "type")
		end
		return
	end
	local kw = match(s, "^(%a+)%s*%($")
	if kw == "var" or kw == "const" or kw == "type" then
		ctx.group = kw
		return
	end
	local decl, vname = match(s, "^(%a+)%s+([%a_][%w_]*)")
	if (decl == "var" or decl == "const") and vname and vname ~= "_" then
		emit_var(ctx, vname, decl == "const")
	end
end

-- Rust.
local RUST_PREFIX = set("pub async unsafe extern default")
local function rust(s: string, ctx: Ctx)
	s = gsub(s, "^pub%s*%b()%s*", "")
	s = gsub(s, '^extern%s+""%s*', "")
	s = strip_words(s, RUST_PREFIX)
	s = gsub(s, "^const%s+(fn%s)", "%1")
	s = gsub(s, "^const%s+unsafe%s+(fn%s)", "%1")
	local name = match(s, "^fn%s+([%a_][%w_]*)")
	if name then
		if ctx.inside then
			ctx.emit(name, "method", ctx.line, ctx.inside.name)
		elseif ctx.top then
			ctx.emit(name, "function", ctx.line)
		end
		return
	end
	if match(s, "^impl[%s<]") then
		local owner = match(s, "%sfor%s+([%w_:]+)") or match(s, "^impl%s*%b<>%s*([%w_:]+)") or match(s, "^impl%s+([%w_:]+)")
		if owner and (ctx.top or ctx.inside) then
			ctx.open = { name = match(owner, "([%w_]+)$") or owner, kind = "impl" }
		end
		return
	end
	local kw, tname = match(s, "^(%a+)%s+([%a_][%w_]*)")
	if kw == "struct" or kw == "union" then
		return emit_type(ctx, tname :: string, "struct", true)
	elseif kw == "enum" then
		return emit_type(ctx, tname :: string, "enum")
	elseif kw == "trait" then
		return emit_type(ctx, tname :: string, "interface", true)
	elseif kw == "type" then
		return emit_type(ctx, tname :: string, "type")
	elseif kw == "mod" then
		emit_type(ctx, tname :: string, "module")
		ctx.open = { name = tname :: string, kind = "namespace" }
		return
	elseif kw == "static" then
		local sname = match(s, "^static%s+mut%s+([%a_][%w_]*)") or tname
		return emit_var(ctx, sname :: string, true)
	end
	local cname = match(s, "^const%s+([%a_][%w_]*)")
	if cname then
		return emit_var(ctx, cname, true)
	end
	local macro = match(s, "^macro_rules!%s*([%a_][%w_]*)")
	if macro then
		return emit_fn(ctx, macro)
	end
	if ctx.inside and ctx.inside.kind == "struct" then
		local field = match(s, "^([%a_][%w_]*)%s*:[^:]")
		if field then
			ctx.emit(field, "field", ctx.line, ctx.inside.name)
		end
	end
end

-- Java, C# and Dart.
local JAVA_MODS = set([[
	public private protected internal static final abstract sealed partial readonly virtual
	override async extern unsafe new synchronized native transient volatile default const
	required late external factory non-sealed strictfp
]])
local function java(s: string, ctx: Ctx)
	s = gsub(s, "^@[%w_.]+%b()%s*", "")
	s = gsub(s, "^@[%w_.]+%s+", "")
	if match(s, "^%[") then
		return
	end
	local is_const = has_word(s, "const") or (has_word(s, "static") and has_word(s, "final"))
	s = strip_words(s, JAVA_MODS)
	s = gsub(s, "^%b<>%s*", "")
	local var = match(s, "^var%s+([%a_][%w_]*)") or match(s, "^final%s+([%a_][%w_]*)%s*=")
	if var then
		return emit_var(ctx, var, is_const)
	end
	local kw, name = match(s, "^(@?%a+)%s+([%a_][%w_]*)")
	if kw == "class" or kw == "record" or kw == "mixin" then
		return emit_type(ctx, name :: string, "class", true)
	elseif kw == "interface" or kw == "@interface" then
		return emit_type(ctx, name :: string, "interface", true)
	elseif kw == "struct" then
		return emit_type(ctx, name :: string, "struct", true)
	elseif kw == "enum" then
		return emit_type(ctx, name :: string, "enum", true)
	elseif kw == "namespace" then
		ctx.open = { name = name :: string, kind = "namespace" }
		return
	elseif kw == "typedef" then
		return emit_type(ctx, name :: string, "type")
	end
	local first = match(s, "^([%a_][%w_]*)")
	if first == nil or NOT_A_NAME[first] then
		return
	end
	if ctx.inside or ctx.top then
		-- `Type name(` or a constructor `Name(`; calls (`foo(x);`) end with `;`.
		local mname = match(s, "^[%w_<>%[%],.?%s]-[%w_>%]?]%s+([%a_][%w_]*)%s*%b<>%s*%(")
			or match(s, "^[%w_<>%[%],.?%s]-[%w_>%]?]%s+([%a_][%w_]*)%s*%(")
			or (if ctx.inside and match(s, "^([%a_][%w_]*)%s*%(") == ctx.inside.name then ctx.inside.name else nil)
		if mname then
			if not NOT_A_NAME[mname] and (not match(s, ";$") or (ctx.inside and ctx.inside.kind == "interface")) then
				emit_fn(ctx, mname)
			end
			return
		end
		local fname = match(s, "^[%w_<>%[%],.?]+%s+([%a_][%w_]*)%s*[=;,]")
			or match(s, "^[%w_<>%[%],.?]+%s+([%a_][%w_]*)%s*{%s*get")
		if fname and ctx.inside then
			emit_var(ctx, fname, is_const)
		elseif fname and ctx.top and first ~= "return" then
			emit_var(ctx, fname, is_const)
		end
	end
end

-- Kotlin and Scala.
local KOTLIN_MODS = set([[
	public private protected internal open override abstract final data sealed inline suspend
	operator infix tailrec lateinit const inner value annotation companion implicit lazy case
	external expect actual noinline crossinline
]])
local function kotlin(s: string, ctx: Ctx)
	s = gsub(s, "^@[%w_.:]+%b()%s*", "")
	s = gsub(s, "^@[%w_.:]+%s+", "")
	local const = has_word(s, "const")
	s = strip_words(s, KOTLIN_MODS)
	if match(s, "^enum%s+class") then
		s = sub(s, 6)
	end
	local rest = match(s, "^fun%s*(%b<>.*)$") or match(s, "^fun%s+(.*)$")
	local name = if rest then match(gsub(rest, "^%b<>%s*", ""), "([%a_][%w_]*)%s*%(") else nil
	name = name or match(s, "^def%s+([%a_][%w_]*)")
	if name then
		return emit_fn(ctx, name)
	end
	local kw, tname = match(s, "^(%a+)%s+([%a_][%w_]*)")
	if kw == "class" or kw == "object" then
		return emit_type(ctx, tname :: string, "class", true)
	elseif kw == "interface" or kw == "trait" then
		return emit_type(ctx, tname :: string, "interface", true)
	elseif kw == "typealias" or kw == "type" then
		return emit_type(ctx, tname :: string, "type")
	elseif kw == "val" or kw == "var" then
		return emit_var(ctx, tname :: string, const)
	elseif kw == "package" then
		return
	end
end

-- Swift.
local SWIFT_MODS = set([[
	public private fileprivate internal open final static override mutating nonmutating lazy
	weak unowned required convenience dynamic indirect nonisolated optional prefix postfix infix
]])
local function swift(s: string, ctx: Ctx)
	s = gsub(s, "^@[%w_]+%b()%s*", "")
	s = gsub(s, "^@[%w_]+%s+", "")
	s = gsub(s, "^private%b()%s*", "")
	s = gsub(s, "^public%b()%s*", "")
	s = strip_words(s, SWIFT_MODS)
	s = gsub(s, "^class%s+(func%s)", "%1")
	s = gsub(s, "^class%s+(var%s)", "%1")
	local kw, name = match(s, "^(%a+)%s+([%a_][%w_]*)")
	if kw == "func" then
		return emit_fn(ctx, name :: string)
	elseif kw == "class" or kw == "actor" then
		return emit_type(ctx, name :: string, "class", true)
	elseif kw == "struct" then
		return emit_type(ctx, name :: string, "struct", true)
	elseif kw == "enum" then
		return emit_type(ctx, name :: string, "enum", true)
	elseif kw == "protocol" then
		return emit_type(ctx, name :: string, "interface", true)
	elseif kw == "typealias" then
		return emit_type(ctx, name :: string, "type")
	elseif kw == "extension" then
		ctx.open = { name = name :: string, kind = "extension" }
		return
	elseif kw == "let" then
		return emit_var(ctx, name :: string, true)
	elseif kw == "var" then
		return emit_var(ctx, name :: string)
	end
end

-- PHP.
local PHP_MODS = set("public private protected static abstract final readonly")
local function php(s: string, ctx: Ctx)
	s = strip_words(s, PHP_MODS)
	local name = match(s, "^function%s+&?%s*([%a_][%w_]*)")
	if name then
		return emit_fn(ctx, name)
	end
	local kw, tname = match(s, "^(%a+)%s+([%a_][%w_]*)")
	if kw == "class" then
		return emit_type(ctx, tname :: string, "class", true)
	elseif kw == "interface" then
		return emit_type(ctx, tname :: string, "interface", true)
	elseif kw == "trait" then
		return emit_type(ctx, tname :: string, "interface", true)
	elseif kw == "enum" then
		return emit_type(ctx, tname :: string, "enum", true)
	elseif kw == "const" then
		return emit_var(ctx, tname :: string, true)
	end
	local var = match(s, "^%??[%w_|\\]*%s*%$([%a_][%w_]*)%s*[=;]")
	if var then
		emit_var(ctx, var)
	end
end

-- C, C++ and Objective-C.
local C_SKIP = set("return if else while for switch case do goto using static_assert public private protected friend")
local C_MODS = set("static inline extern const constexpr virtual explicit unsigned signed volatile struct enum class union typename mutable")
-- Whether what follows `struct name` can start its body: nothing (the brace comes on the
-- next line), `{`, a base list (`: Base`) or `final`.
local function opens_body(rest: string): boolean
	return rest == "" or rest == "final" or match(rest, "^{") ~= nil or match(rest, "^:[^:]") ~= nil
		or match(rest, "^final[%s{]") ~= nil
end
local function c(s: string, ctx: Ctx)
	local macro = match(s, "^#%s*define%s+([%a_][%w_]*)")
	if macro then
		ctx.emit(macro, if match(s, "^#%s*define%s+[%a_][%w_]*%(") then "function" else "constant", ctx.line)
		return
	end
	if match(s, "^[%a_]+:$") or match(s, "^template%s*<") then
		return
	end
	local kw, name = match(s, "^(%a+)%s+([%a_][%w_]*)")
	if kw == "namespace" then
		ctx.open = { name = name :: string, kind = "namespace" }
		return
	end
	-- `struct foo`, `struct foo {` or `class Foo : Base`, not a use such as a parameter
	-- (`struct foo *bar)`), which is common enough in C to crowd out real declarations.
	if kw == "struct" or kw == "class" or kw == "union" then
		if opens_body(match(s, "^%a+%s+[%a_][%w_]*%s*(.-)%s*$") or "") then
			return emit_type(ctx, name :: string, if kw == "class" then "class" else "struct", true)
		end
	end
	if kw == "enum" then
		local ename, rest = match(s, "^enum%s+class%s+([%a_][%w_]*)%s*(.-)%s*$")
		if ename == nil then
			ename, rest = match(s, "^enum%s+struct%s+([%a_][%w_]*)%s*(.-)%s*$")
		end
		if ename == nil then
			ename, rest = name, match(s, "^enum%s+[%a_][%w_]*%s*(.-)%s*$")
		end
		if opens_body(rest or "") then
			return emit_type(ctx, ename :: string, "enum")
		end
	end
	if kw == "typedef" then
		local tname = match(s, "([%a_][%w_]*)%s*;$") or match(s, "%(%s*%*%s*([%a_][%w_]*)%s*%)")
		if tname then
			emit_type(ctx, tname, "type")
		end
		return
	end
	local closing = match(s, "^}%s*([%a_][%w_]*)%s*;")
	if closing then
		-- `typedef struct { … } Name;` closing at file level.
		if ctx.depth == 1 then
			ctx.emit(closing, "type", ctx.line)
		end
		return
	end
	local first = match(s, "^[%a_~][%w_]*")
	if first == nil or C_SKIP[first] then
		return
	end
	local t = strip_words(s, C_MODS)
	local fname = match(t, "^[%a_][%w_:<>,%s%*&]-[%s%*&]+([%a_~][%w_:~]*)%s*%(")
	if fname then
		if NOT_A_NAME[fname] then
			return
		end
		local owner, own = match(fname, "^(.-)::([^:]+)$")
		if owner and own and ctx.top then
			ctx.emit(own, "method", ctx.line, match(owner, "([%w_]+)$"))
		elseif ctx.inside then
			ctx.emit(fname, "method", ctx.line, ctx.inside.name)
		elseif ctx.top and not match(s, ";$") then
			ctx.emit(fname, "function", ctx.line)
		end
		return
	end
	local vname = match(t, "^[%a_][%w_:<>,%s%*&]-[%s%*&]+([%a_][%w_]*)%s*[=;%[{]")
	if vname and not find(t, "(", 1, true) then
		emit_var(ctx, vname, has_word(s, "const"))
	end
end

-- ---------------------------------------------------------------- indentation languages

local PY_KEYWORDS = set("if elif else for while try except finally with return pass break continue import from global nonlocal raise assert del print match case async await lambda yield")

local function python(text: string, emit: Emit)
	type Scope = { name: string?, indent: number, body: number? }
	local stack: { Scope } = {}
	local in_doc: string? = nil
	each_line(text, function(line: string, n: number)
		if in_doc then
			if find(line, in_doc, 1, true) then
				in_doc = nil
			end
			return
		end
		local ws, s = match(line, "^(%s*)(.-)%s*$")
		if s == nil or s == "" or byte(s :: string, 1) == 35 then
			return
		end
		local code: string = s :: string
		local indent = #(ws :: string)
		for _, q in { '"""', "'''" } do
			local _, k = gsub(code, q, "")
			if k % 2 == 1 then
				in_doc = q
			end
		end
		while #stack > 0 and indent <= stack[#stack].indent do
			table.remove(stack)
		end
		local top = stack[#stack]
		if top and top.body == nil then
			top.body = indent
		end
		-- The class whose body this line is directly in.
		local cls = if top and top.name and top.body == indent then top.name else nil
		local nested = top ~= nil and cls == nil
		code = gsub(code, "^async%s+", "")
		local name = match(code, "^def%s+([%a_][%w_]*)")
		if name then
			if cls then
				emit(name, "method", n, cls)
			elseif not nested then
				emit(name, "function", n)
			end
			table.insert(stack, { name = nil, indent = indent, body = nil })
			return
		end
		name = match(code, "^class%s+([%a_][%w_]*)")
		if name then
			if not nested then
				emit(name, "class", n, cls)
			end
			table.insert(stack, { name = if nested then nil else name, indent = indent, body = nil })
			return
		end
		if nested then
			return
		end
		local v = match(code, "^([%a_][%w_]*)%s*:[^=]*=") or match(code, "^([%a_][%w_]*)%s*=[^=]")
			or match(code, "^([%a_][%w_]*)%s*:%s*[%w_%[%]., |\"']+$")
		if v and not PY_KEYWORDS[v] and (cls or indent == 0) then
			local kind = if is_constant(v) then "constant" elseif cls then "field" else "variable"
			emit(v, kind, n, cls)
		end
	end)
end

local function ruby(text: string, emit: Emit)
	type Scope = { name: string, indent: number }
	local stack: { Scope } = {}
	each_line(text, function(line: string, n: number)
		local ws, s = match(line, "^(%s*)(.-)%s*$")
		if s == nil or s == "" or byte(s :: string, 1) == 35 then
			return
		end
		local code: string = s :: string
		local indent = #(ws :: string)
		if code == "end" then
			return
		end
		while #stack > 0 and indent <= stack[#stack].indent do
			table.remove(stack)
		end
		local owner = if #stack > 0 then stack[#stack].name else nil
		local name = match(code, "^def%s+self%.([%w_]+[?!=]?)") or match(code, "^def%s+([%w_]+[?!=]?)")
		if name then
			emit(name, if owner then "method" else "function", n, owner)
			return
		end
		local kw, tname = match(code, "^(%a+)%s+([%w_:]+)")
		if (kw == "class" or kw == "module") and tname and tname ~= "<<" then
			local short = match(tname :: string, "([%w_]+)$") or tname
			emit(short :: string, if kw == "class" then "class" else "module", n, owner)
			table.insert(stack, { name = short :: string, indent = indent })
			return
		end
		local const = match(code, "^([A-Z][%w_]*)%s*=[^=~]")
		if const then
			emit(const, "constant", n, owner)
			return
		end
		local attrs = match(code, "^attr_%a+%s+(.*)$")
		if attrs and owner then
			for a in string.gmatch(attrs, ":([%w_]+)") do
				emit(a, "field", n, owner)
			end
		end
	end)
end

local function lua(text: string, emit: Emit)
	local in_comment = false
	each_line(text, function(line: string, n: number)
		if in_comment then
			if find(line, "]]", 1, true) then
				in_comment = false
			end
			return
		end
		if match(line, "^%s*%-%-%[=*%[") then
			in_comment = not find(line, "]]", 1, true)
			return
		end
		local name = match(line, "^local%s+function%s+([%a_][%w_]*)")
		if name then
			return emit(name, "function", n)
		end
		local path = match(line, "^function%s+([%w_.:]+)%s*%(")
		if path then
			local owner, own = match(path, "^(.*)[.:]([%w_]+)$")
			if owner then
				return emit(own :: string, "method", n, owner)
			end
			return emit(path, "function", n)
		end
		name = match(line, "^export%s+type%s+([%a_][%w_]*)") or match(line, "^type%s+([%a_][%w_]*)%s*[=<]")
		if name then
			return emit(name, "type", n)
		end
		local owner, field, rest = match(line, "^([%a_][%w_]*)%.([%a_][%w_]*)%s*=([^=].*)$")
		if owner and field then
			local is_fn = match(rest :: string, "^%s*function") ~= nil
			return emit(field, if is_fn then "method" elseif is_constant(field) then "constant" else "field", n, owner)
		end
		local lname, lrest = match(line, "^local%s+([%a_][%w_]*)%s*[:=](.*)$")
		if lname == nil then
			lname, lrest = match(line, "^([%a_][%w_]*)%s*=([^=].*)$")
		end
		if lname then
			local is_fn = match(lrest :: string, "^%s*function") ~= nil or match(lrest :: string, "^[^=]*=%s*function") ~= nil
			emit(lname, if is_fn then "function" elseif is_constant(lname) then "constant" else "variable", n)
		end
	end)
end

local function shell(text: string, emit: Emit)
	each_line(text, function(line: string, n: number)
		local name = match(line, "^%s*function%s+([%w_:.%-]+)") or match(line, "^%s*([%w_:.%-]+)%s*%(%)%s*{?%s*$")
		if name then
			return emit(name, "function", n)
		end
		local var = match(line, "^export%s+([%a_][%w_]*)=") or match(line, "^readonly%s+([%a_][%w_]*)=")
			or match(line, "^([%a_][%w_]*)=")
		if var then
			emit(var, if is_constant(var) then "constant" else "variable", n)
		end
	end)
end

local BRACE: { [string]: { opts: { single: boolean, backtick: boolean, hash: boolean }, fn: (s: string, ctx: Ctx) -> () } } = {
	js = { opts = { single = true, backtick = true, hash = false }, fn = js },
	go = { opts = { single = true, backtick = true, hash = false }, fn = go },
	rust = { opts = { single = false, backtick = false, hash = false }, fn = rust },
	java = { opts = { single = true, backtick = false, hash = false }, fn = java },
	kotlin = { opts = { single = true, backtick = false, hash = false }, fn = kotlin },
	swift = { opts = { single = false, backtick = false, hash = false }, fn = swift },
	php = { opts = { single = true, backtick = false, hash = true }, fn = php },
	c = { opts = { single = true, backtick = false, hash = false }, fn = c },
}

-- Calls `emit` for each declaration in `text`, written in `lang` (from `symbols.language`).
function symbols.extract(text: string, lang: string, emit: Emit)
	local brace = BRACE[lang]
	if brace then
		brace_lang(text, emit, brace.opts, brace.fn)
	elseif lang == "python" then
		python(text, emit)
	elseif lang == "ruby" then
		ruby(text, emit)
	elseif lang == "lua" then
		lua(text, emit)
	elseif lang == "shell" then
		shell(text, emit)
	end
end

return symbols
