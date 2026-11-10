--!strict
local ui = tern.ui

local KV_KEY = "identities"
local LIST_ID = "main.ids."
local NAME_ID = "main.form.name"
local EMAIL_ID = "main.form.email"

local READ = [[
cd "$1" || exit 1
top=$(git rev-parse --show-toplevel) || exit 1
echo "T $top"
echo "B $(git symbolic-ref --short -q HEAD)"
git config --local --get user.name | sed 's/^/LN /'
git config --local --get user.email | sed 's/^/LE /'
git config --show-scope --get user.name | sed 's/^/EN /'
git config --show-scope --get user.email | sed 's/^/EE /'
for scope in system global; do
	n=$(git config --$scope --get user.name)
	e=$(git config --$scope --get user.email)
	[ -n "$n$e" ] && printf 'I %s\t%s\t%s\n' "$scope" "$n" "$e"
done
git config --global --get-regexp '^includeif\..*\.path$' | while read -r key file; do
	case $file in
		"~/"*) file="$HOME/${file#"~/"}" ;;
		/*) ;;
		*) file="$HOME/$file" ;;
	esac
	n=$(git config -f "$file" --get user.name)
	e=$(git config -f "$file" --get user.email)
	cond=${key#includeif.}
	[ -n "$n$e" ] && printf 'I %s\t%s\t%s\n' "includeIf ${cond%.path}" "$n" "$e"
done
exit 0
]]

local WRITE = [[
cd "$1" || exit 1
git config --local user.name "$2" && git config --local user.email "$3"
]]

local RESET = [[
cd "$1" || exit 1
git config --local --unset-all user.name
git config --local --unset-all user.email
exit 0
]]

type Identity = { name: string, email: string, sources: { string }, saved: boolean }

type Form = { name: string, email: string, field: string, error: string? }

type State = {
	cx: BlockCx,
	path: string?,
	top: string?,
	branch: string?,
	local_name: string?,
	local_email: string?,
	name: string?,
	email: string?,
	name_scope: string?,
	email_scope: string?,
	identities: { Identity },
	cursor: number,
	want: string?,
	placed: boolean,
	form: Form?,
	loaded: boolean,
	busy: boolean,
	error: string?,
}

local function alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or s
end

local function basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

local function shorten(path: string): string
	local home = tern.getenv("HOME")
	if home and (path == home or string.sub(path, 1, #home + 1) == home .. "/") then
		return "~" .. string.sub(path, #home + 1)
	end
	return path
end

local function utf16_len(s: string): number
	local n = 0
	for _, c in utf8.codes(s) do
		n += if c > 0xFFFF then 2 else 1
	end
	return n
end

local function ident_key(name: string, email: string): string
	return string.lower(trim(name)) .. " <" .. string.lower(trim(email)) .. ">"
end

local function node_key(it: Identity): string
	return tern.base64.encode(ident_key(it.name, it.email), { url = true })
end

local function saved_list(): { { name: string, email: string } }
	local out: { { name: string, email: string } } = {}
	local ok, v = pcall(tern.kv.get, KV_KEY)
	if ok and type(v) == "table" then
		for _, it in v do
			if type(it) == "table" and type(it.name) == "string" and type(it.email) == "string" then
				table.insert(out, { name = it.name, email = it.email })
			end
		end
	end
	return out
end

local function store(list: { { name: string, email: string } })
	tern.kv.set(KV_KEY, tern.json.array(list))
end

local function is_current(state: State, it: Identity): boolean
	return it.name == (state.name or "") and it.email == (state.email or "")
end

local function is_local(state: State, it: Identity): boolean
	return it.name == (state.local_name or "") and it.email == (state.local_email or "")
end

local function parse(state: State, out: string)
	state.branch, state.local_name, state.local_email = nil, nil, nil
	state.name, state.email, state.name_scope, state.email_scope = nil, nil, nil, nil
	local others: { { string } } = {}
	for line in string.gmatch(out, "[^\n]+") do
		local tag, rest = string.match(line, "^(%u+) ?(.*)$")
		if tag == "T" then
			state.top = rest
		elseif tag == "B" then
			state.branch = if rest ~= "" then rest else nil
		elseif tag == "LN" then
			state.local_name = rest
		elseif tag == "LE" then
			state.local_email = rest
		elseif tag == "EN" then
			state.name_scope, state.name = string.match(rest :: string, "^(%S+)\t(.*)$")
		elseif tag == "EE" then
			state.email_scope, state.email = string.match(rest :: string, "^(%S+)\t(.*)$")
		elseif tag == "I" then
			local source, n, e = string.match(rest :: string, "^(.-)\t(.-)\t(.*)$")
			if source then
				table.insert(others, { source, n :: string, e :: string })
			end
		end
	end

	local found: { Identity } = {}
	local by: { [string]: Identity } = {}
	local function add(name: string, email: string, source: string, saved: boolean)
		if name == "" and email == "" then
			return
		end
		local k = ident_key(name, email)
		local it = by[k]
		if it == nil then
			it = { name = name, email = email, sources = {}, saved = false }
			by[k] = it
			table.insert(found, it)
		end
		if table.find(it.sources, source) == nil then
			table.insert(it.sources, source)
		end
		if saved then
			it.saved = true
		end
	end
	add(state.local_name or "", state.local_email or "", "this repo", false)
	for _, o in others do
		add(o[2], o[3], o[1], false)
	end
	for _, s in saved_list() do
		add(s.name, s.email, "saved", true)
	end
	state.identities = found

	local target: string? = state.want
	if target == nil and not state.placed and (state.name or state.email) then
		target = ident_key(state.name or "", state.email or "")
	end
	if target then
		for i, it in found do
			if ident_key(it.name, it.email) == target then
				state.cursor = i
			end
		end
	end
	state.want = nil
	state.placed = true
	state.cursor = math.clamp(state.cursor, 1, math.max(1, #found))
end

local function run(state: State, argv: { string }, done: (ProcessResult) -> ())
	local cx = state.cx
	state.busy = true
	local ok, err = pcall(function()
		tern.process.run(argv, { timeout_ms = 10000 }, function(r: ProcessResult, _)
			if not alive(cx.pane) then
				return
			end
			state.busy = false
			done(r)
			cx:render()
		end)
	end)
	if not ok then
		state.busy = false
		state.error = tostring(err)
	end
end

local function failure(r: ProcessResult): string
	local text = trim(r.stderr)
	if text ~= "" then
		return text
	end
	return if r.timed_out then "git timed out" else "git exited with status " .. r.status
end

local function load(state: State)
	local path = state.path
	if path == nil then
		state.error = "No repository was given"
		return
	end
	run(state, { "/bin/sh", "-c", READ, "sh", path }, function(r)
		if r.status ~= 0 then
			state.error = failure(r)
			return
		end
		state.error = nil
		parse(state, r.stdout)
		state.loaded = true
	end)
end

local function apply(state: State, name: string, email: string)
	local repo = state.top
	if repo == nil or name == "" or email == "" then
		return
	end
	state.want = ident_key(name, email)
	run(state, { "/bin/sh", "-c", WRITE, "sh", repo, name, email }, function(r)
		if r.status ~= 0 then
			state.cx:toast("error", "Could not set the git identity", failure(r))
			return
		end
		state.cx:toast("success", basename(repo) .. " now commits as " .. name, email)
		load(state)
	end)
end

local function reset(state: State)
	local repo = state.top
	if repo == nil or (state.local_name == nil and state.local_email == nil) then
		return
	end
	run(state, { "/bin/sh", "-c", RESET, "sh", repo }, function(r)
		if r.status ~= 0 then
			state.cx:toast("error", "Could not reset the git identity", failure(r))
			return
		end
		state.cx:toast("info", basename(repo) .. " uses the default identity again")
		state.placed = false
		load(state)
	end)
end

local function focus(state: State, id: string?)
	local cx = state.cx
	tern.timer(1, function()
		if alive(cx.pane) then
			cx:frame({ { "focus", if id then id else tern.json.null } })
		end
	end)
end

local function open_form(state: State)
	state.form = { name = "", email = "", field = "name", error = nil }
	focus(state, NAME_ID)
end

local function close_form(state: State)
	state.form = nil
	focus(state, nil)
end

local function set_field(state: State, field: string)
	local form = state.form
	if form then
		form.field = field
		focus(state, if field == "name" then NAME_ID else EMAIL_ID)
	end
end

local function submit(state: State, use: boolean)
	local form = state.form
	if form == nil then
		return
	end
	local name, email = trim(form.name), trim(form.email)
	if name == "" then
		form.error = "Enter a name"
		set_field(state, "name")
		return
	end
	if string.find(email, "^[^%s@]+@[^%s@]+$") == nil then
		form.error = "Enter an email like name@example.com"
		set_field(state, "email")
		return
	end
	local list = saved_list()
	local k = ident_key(name, email)
	local exists = false
	for _, it in list do
		if ident_key(it.name, it.email) == k then
			exists = true
		end
	end
	if not exists then
		table.insert(list, { name = name, email = email })
		store(list)
	end
	close_form(state)
	if use then
		apply(state, name, email)
	else
		state.want = k
		load(state)
	end
end

local function remove(state: State, it: Identity?)
	if it == nil or not it.saved then
		return
	end
	local k = ident_key(it.name, it.email)
	local kept: { { name: string, email: string } } = {}
	for _, s in saved_list() do
		if ident_key(s.name, s.email) ~= k then
			table.insert(kept, s)
		end
	end
	store(kept)
	load(state)
end

local function use_selected(state: State)
	local it = state.identities[state.cursor]
	if it and not is_local(state, it) then
		apply(state, it.name, it.email)
	end
end

local function scope_label(scope: string?): string
	if scope == "local" then
		return "this repo (.git/config)"
	elseif scope == "global" then
		return "global default (~/.gitconfig)"
	elseif scope == "system" then
		return "system git config"
	end
	return scope or "not set"
end

local function button(text: string, act: string, props: { [string]: any }?): Node
	local p: { [string]: any } = props or {}
	p.size = "sm"
	p.actions = { click = act }
	return ui.button(text, p)
end

local function header(state: State): Node
	local who: { Span | string }
	if state.name or state.email then
		who = {
			ui.span(state.name or "(no name)", "strong"),
			ui.span("  " .. (state.email or "(no email)"), "mono"),
		}
	else
		who = { ui.span("No identity is set, so commits will fail", "warning") }
	end
	local from = if state.name_scope == state.email_scope
		then scope_label(state.name_scope)
		else "name: " .. scope_label(state.name_scope) .. " · email: " .. scope_label(state.email_scope)
	local card = ui.card({ ui.span("Git identity", "strong") }, {
		ui.kv({
			{ "Repository", { ui.span(shorten(state.top or ""), "path") } },
			{ "Branch", { ui.span(state.branch or "detached HEAD", "mono") } },
			{ "Commits as", who },
			{ "Set in", { ui.span(from, "muted") } },
		}),
	}, { icon = "branch" })
	local p: { [string]: any } = card.p or {}
	p.key = "head"
	card.p = p
	return card
end

local function input(state: State, field: string, placeholder: string): Node
	local form = state.form :: Form
	local text = if field == "name" then form.name else form.email
	return ui.node("input", {
		key = field,
		text = text,
		cursor = utf16_len(text),
		placeholder = placeholder,
		variant = "field",
		mono = field == "email",
	})
end

local function form_view(state: State): Node
	local form = state.form :: Form
	local children: { Node } = {
		input(state, "name", "Name, e.g. Misha Kulava"),
		input(state, "email", "Email, e.g. misha@example.com"),
	}
	if form.error then
		table.insert(children, ui.text({ ui.span(form.error, "error") }))
	end
	table.insert(children, ui.row({
		button("Save and use", "save=use", { icon = "check", variant = "primary", keys = { "enter" } }),
		button("Save", "save"),
		button("Cancel", "cancel", { variant = "quiet", keys = { "escape" } }),
	}))
	local card = ui.card({ ui.span("New identity", "strong") }, children, { icon = "plus" })
	local p: { [string]: any } = card.p or {}
	p.key = "form"
	card.p = p
	return card
end

local function identity_list(state: State): Node
	local items: { Item } = {}
	for i, it in state.identities do
		local current = is_current(state, it)
		items[i] = {
			label = { ui.span(if it.name ~= "" then it.name else "(no name)", if current then "strong" else nil) },
			detail = { ui.span(if it.email ~= "" then it.email else "(no email)", "mono") },
			value = { ui.span(table.concat(it.sources, " · "), "muted") },
			icon = if current then "check" else "user",
			tone = if current then "success" else nil,
		}
	end
	local list = ui.list(items)
	local kids = list.c or {}
	for i, it in state.identities do
		local p: { [string]: any } = kids[i].p or {}
		p.key = node_key(it)
		kids[i].p = p
	end
	local sel = state.identities[state.cursor]
	local p: { [string]: any } = list.p or {}
	p.key = "ids"
	p.selected = if sel then LIST_ID .. node_key(sel) else nil
	p.empty = { ui.span("No identities found yet: add one", "muted") }
	list.p = p
	return list
end

local function use_disabled(state: State, it: Identity?): string?
	if it == nil then
		return "Select an identity"
	elseif it.name == "" or it.email == "" then
		return "An identity needs a name and an email"
	elseif is_local(state, it) then
		return "This repo already uses it"
	end
	return nil
end

local function dock_view(state: State, cx: BlockCx): Node
	if state.form then
		return ui.col({ ui.text({ ui.span("tab next field · ⏎ save and use · esc cancel", "dim") }) })
	end
	local sel = state.identities[state.cursor]
	local main: { Node } = {
		button("Use for this repo", "use", {
			icon = "check",
			variant = "primary",
			keys = { "enter" },
			disabled = use_disabled(state, sel),
		}),
		button("Add identity", "add", { icon = "plus", keys = { "a" } }),
	}
	local more: { Node } = {
		button("Remove", "remove", {
			icon = "trash",
			keys = { "d" },
			disabled = if sel and sel.saved then nil else "Only identities you added can be removed",
		}),
		button("Reset to default", "reset", {
			icon = "undo",
			disabled = if state.local_name or state.local_email then nil else "This repo has no identity of its own",
		}),
		button("", "refresh", { icon = "repeat", variant = "quiet", busy = state.busy, title = "Reload (r)" }),
	}
	local rows: { Node }
	if cx.cols >= 80 then
		table.move(more, 1, #more, #main + 1, main)
		rows = { ui.row(main) }
	else
		rows = { ui.row(main), ui.row(more) }
	end
	table.insert(rows, ui.text({ ui.span("↑↓ select · ⏎ use for this repo · a add · d remove · r reload", "dim") }))
	return ui.col(rows)
end

local function error_view(state: State): Node
	local card = ui.card({ ui.span("Could not read the git settings", "strong") }, {
		ui.text({ ui.span(state.error or "", "muted") }),
		ui.row({ button("Retry", "refresh", { icon = "repeat" }) }),
	})
	local p: { [string]: any } = card.p or {}
	p.tone = "error"
	card.p = p
	return card
end

local function form_key(state: State, key: Key): boolean?
	local form = state.form :: Form
	local name = key.name
	if name == "escape" then
		close_form(state)
	elseif name == "tab" or name == "up" or name == "down" then
		set_field(state, if form.field == "name" then "email" else "name")
	elseif name == "enter" then
		if form.field == "name" and trim(form.email) == "" then
			set_field(state, "email")
		else
			submit(state, true)
		end
	elseif name == "backspace" then
		local text = if form.field == "name" then form.name else form.email
		if text == "" then
			return false
		end
		local cut = utf8.offset(text, -1) or 1
		text = string.sub(text, 1, cut - 1)
		if form.field == "name" then
			form.name = text
		else
			form.email = text
		end
	else
		local text: string? = nil
		if name == "paste" then
			text = (string.gsub(key.text or "", "%c+", " "))
		elseif key.text and key.text ~= "" and string.find(key.text, "%c") == nil then
			text = key.text
		end
		if text == nil or text == "" then
			return false
		end
		if form.field == "name" then
			form.name ..= text
		else
			form.email ..= text
		end
		form.error = nil
	end
	return true
end

tern.block.define("identity", {
	font = "sans",

	init = function(cx: BlockCx, args: { string }, _saved: any): State
		local state: State = {
			cx = cx,
			path = args[1] or cx.cwd,
			top = nil,
			branch = nil,
			local_name = nil,
			local_email = nil,
			name = nil,
			email = nil,
			name_scope = nil,
			email_scope = nil,
			identities = {},
			cursor = 1,
			want = nil,
			placed = false,
			form = nil,
			loaded = false,
			busy = false,
			error = nil,
		}
		load(state)
		return state
	end,

	title = function(state: State): string?
		local repo = state.top or state.path
		return if repo then "Git identity · " .. basename(repo) else "Git identity"
	end,

	view = function(state: State, cx: BlockCx): BlockView
		if not state.loaded then
			if state.error then
				return { main = ui.col({ error_view(state) }) }
			end
			return { main = ui.col({ ui.progress(nil, "Reading git settings…") }) }
		end
		local main: { Node } = { header(state) }
		if state.error then
			table.insert(main, error_view(state))
		end
		if state.form then
			table.insert(main, form_view(state))
		end
		table.insert(main, ui.rule("Identities"))
		table.insert(main, identity_list(state))
		return { main = ui.col(main), dock = dock_view(state, cx) }
	end,

	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		if key.meta or key.ctrl then
			return false
		end
		if state.form then
			return form_key(state, key)
		end
		local name = key.name
		local k = key.text or key.name
		if name == "up" then
			state.cursor = math.max(1, state.cursor - 1)
		elseif name == "down" then
			state.cursor = math.min(math.max(1, #state.identities), state.cursor + 1)
		elseif name == "enter" then
			use_selected(state)
		elseif k == "a" then
			open_form(state)
		elseif k == "d" or name == "delete" then
			remove(state, state.identities[state.cursor])
		elseif k == "r" then
			load(state)
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			local key = string.sub(ev.item, #LIST_ID + 1)
			for i, it in state.identities do
				if node_key(it) == key then
					state.cursor = i
					if ev.ev == "activate" then
						use_selected(state)
					end
				end
			end
		elseif ev.ev == "focus" then
			if ev.id == NAME_ID then
				set_field(state, "name")
			elseif ev.id == EMAIL_ID then
				set_field(state, "email")
			end
		elseif ev.ev == "action" then
			local act = ev.act
			if act == "use" then
				use_selected(state)
			elseif act == "add" then
				open_form(state)
			elseif act == "remove" then
				remove(state, state.identities[state.cursor])
			elseif act == "reset" then
				reset(state)
			elseif act == "refresh" then
				load(state)
			elseif act == "save" then
				submit(state, ev.value == "use")
			elseif act == "cancel" then
				close_form(state)
			end
		end
	end,
})
