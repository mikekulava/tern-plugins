--!strict
-- Drawing the explorer: a head row with the run controls, a summary, and a resizable
-- split of the test tree (left) and the selected row's details and trace (right).

local model = require("./model")

type Suite = model.Suite
type File = model.File
type Test = model.Test
type Row = model.Row
type Status = model.Status

local ui = tern.ui

local view = {}

-- What the view needs from the host's state.
export type Page = {
	root: string,
	home: string?,
	phase: "scanning" | "ready" | "failed",
	problem: string?,
	suites: { Suite },
	rows: { Row },
	selected: Row?,
	open: { [string]: boolean },
	sizes: { number }?,
	hidePassed: boolean,
	busy: boolean,
	running: {
		label: string,
		done: number,
		total: number,
		current: string?,
	}?,
	failed: number,
	cols: number,
	rows_h: number,
	lastRun: { at: number, took: number }?,
	-- The row key of an identity (failures in the details link back to the tree).
	keyOf: (ident: string) -> string,
}

-- The id prefix of the tree's rows: the list is keyed `tree` in the split, which is keyed
-- `split` side by side and `stack` when stacked.
view.TREE = "main.split.tree"
view.TREE_STACKED = "main.stack.tree"

local ICON: { [string]: { icon: string, tone: string } } = {
	passed = { icon = "check", tone = "success" },
	failed = { icon = "x", tone = "error" },
	error = { icon = "warn", tone = "error" },
	skipped = { icon = "slash-circle", tone = "muted" },
	running = { icon = "activity", tone = "accent" },
	queued = { icon = "clock", tone = "pending" },
	idle = { icon = "minus", tone = "muted" },
}

local WORD: { [string]: string } = {
	passed = "Passed",
	failed = "Failed",
	error = "Error",
	skipped = "Skipped",
	running = "Running",
	queued = "Queued",
	idle = "Not run",
}

local KIND_ICON: { [string]: string } = {
	pytest = "app-python",
	unittest = "app-python",
	python = "app-python",
	vitest = "app-node",
	jest = "app-node",
}

local LANG: { [string]: string } = {
	py = "python",
	ts = "typescript",
	tsx = "tsx",
	js = "javascript",
	jsx = "jsx",
	mjs = "javascript",
	cjs = "javascript",
	mts = "typescript",
	cts = "typescript",
	vue = "vue",
}

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function plural(n: number, word: string): string
	return n .. " " .. word .. (if n == 1 then "" else "s")
end

local function counts_line(c: model.Counts): { Span }
	local spans: { Span } = {}
	local function add(text: string, s: string?)
		if #spans > 0 then
			table.insert(spans, ui.span("  ·  ", "dim"))
		end
		table.insert(spans, ui.span(text, s))
	end
	if c.failed > 0 then
		add(c.failed .. " failed", "error")
	end
	if c.passed > 0 then
		add(c.passed .. " passed", "success")
	end
	if c.skipped > 0 then
		add(c.skipped .. " skipped", "muted")
	end
	if c.running + c.queued > 0 then
		add((c.running + c.queued) .. " pending", "pending")
	end
	if c.idle > 0 then
		add(c.idle .. " not run", "muted")
	end
	if #spans == 0 then
		add(plural(c.total, "test"), "muted")
	end
	if c.duration > 0 then
		add(model.duration(c.duration) or "", "muted mono")
	end
	return spans
end

local function kind_label(s: Suite): string
	return if s.kind == "python" then "python" else s.kind
end

-- ---------------------------------------------------------------- tree rows

local function item(row: Row, open: { [string]: boolean }): Node
	local label: { Span } = {}
	local value: { Span } = {}
	local icon, tone
	if row.kind == "suite" then
		local s = row.suite
		local c = model.suite_counts(s)
		local st = model.rollup(c, s.problem ~= nil)
		icon = KIND_ICON[s.kind] or "box"
		tone = if s.problem then "error" else ICON[st].tone
		local chev = if open[s.ident] ~= false then "▾ " else "▸ "
		table.insert(label, ui.span(chev, "dim"))
		table.insert(label, ui.span(kind_label(s), "strong"))
		table.insert(label, ui.span("  " .. s.rel, "muted mono"))
		if s.phase == "collecting" then
			table.insert(value, ui.span("collecting…", "muted"))
		elseif s.problem then
			table.insert(value, ui.span(s.problem, "error"))
		elseif c.failed > 0 then
			table.insert(value, ui.span(c.failed .. " failed", "error"))
		else
			table.insert(value, ui.span(plural(c.total, "test"), "muted"))
		end
	elseif row.kind == "file" then
		local f = row.file :: File
		local c = model.file_counts(f)
		local st = model.rollup(c)
		icon, tone = ICON[st].icon, ICON[st].tone
		local chev = if open[f.ident] == true then "▾ " else "▸ "
		local dir = model.dirname(f.rel)
		table.insert(label, ui.span(chev, "dim"))
		table.insert(label, ui.span(model.basename(f.rel)))
		if dir ~= "/" and dir ~= f.rel then
			table.insert(label, ui.span("  " .. dir, "muted"))
		end
		if f.error then
			table.insert(value, ui.span("load error", "error"))
		elseif c.failed > 0 then
			table.insert(value, ui.span(c.failed .. "/" .. c.total, "error mono"))
		elseif c.running + c.queued > 0 then
			table.insert(value, ui.span("…", "muted"))
		elseif c.total == 0 then
			table.insert(value, ui.span("not run", "muted"))
		elseif c.duration > 0 then
			table.insert(value, ui.span(model.duration(c.duration) or "", "muted mono"))
		else
			table.insert(value, ui.span(tostring(c.total), "muted mono"))
		end
	else
		local t = row.test :: Test
		icon, tone = ICON[t.status].icon, ICON[t.status].tone
		local path, own = model.split_name(t.name)
		if #path > 0 then
			table.insert(label, ui.span(table.concat(path, " › ") .. " › ", "muted"))
		end
		table.insert(label, ui.span(own))
		local d = model.duration(t.duration)
		if t.status == "running" then
			table.insert(value, ui.span("running", "accent"))
		elseif d and t.status ~= "skipped" then
			table.insert(value, ui.span(d, "muted mono"))
		end
	end
	return ui.node("item", {
		key = row.key,
		label = label,
		value = value,
		icon = icon,
		tone = tone,
		-- Depth in the tree, indented by testview.css.
		role = "testview.d" .. row.depth,
	})
end

local function tree(page: Page, sel: string?, id: string, stacked: boolean): Node
	local items: { Node } = {}
	for _, row in page.rows do
		table.insert(items, item(row, page.open))
	end
	return ui.node("list", {
		key = "tree",
		selected = if sel then id .. "." .. sel else nil,
		empty = { ui.span(if page.hidePassed then "No failing tests" else "No tests", "muted") },
		max = { lines = math.max(4, if stacked then math.floor(page.rows_h * 0.4) else page.rows_h) },
	}, items)
end

-- ---------------------------------------------------------------- details

local function lang_of(path: string?): string?
	if path == nil then
		return nil
	end
	local ext = string.match(path, "%.([%w]+)$")
	return if ext then LANG[string.lower(ext)] else nil
end

local function trace(e: model.TestError, key: string): Node?
	local frames = {}
	local has_code = false
	local lang = nil
	local all: { model.Frame } = e.frames or {}
	-- Frames outside the project past the outermost project frame are the runner's own.
	local last = #all
	for i = #all, 1, -1 do
		if all[i].app then
			break
		end
		last = i - 1
	end
	if last == 0 then
		last = #all
	end
	for i = 1, last do
		local f = all[i]
		local frame: { [string]: any } = {
			fn = f.fn or "",
			file = f.file or "",
			line = f.line,
			col = f.col,
			app = f.app == true,
		}
		if f.code and #f.code.lines > 0 then
			frame.code = { start = f.code.start or 1, lines = f.code.lines, line = f.line }
			has_code = true
			lang = lang or lang_of(f.file)
		end
		table.insert(frames, frame)
	end
	if #frames == 0 then
		return nil
	end
	return ui.node("stacktrace", {
		key = key,
		variant = if has_code then "split" else "frames",
		lang = lang,
		error = { type = e.type or "Error", message = e.message or "" },
		frames = frames,
	})
end

local function section(title: string, children: { Node }, key: string, collapsed: boolean?): Node
	return with(ui.section({ ui.span(title, "strong") }, children), {
		key = key,
		collapsible = true,
		collapsed = collapsed == true,
	})
end

local function button(text: string, act: string, icon: string, keys: { string }?, variant: ButtonVariant?, disabled: any?): Node
	return ui.button(text, {
		key = act,
		icon = icon,
		keys = keys,
		size = "sm",
		variant = variant,
		disabled = disabled,
		actions = { click = act },
	})
end

local function error_blocks(e: model.TestError, key: string, out: { Node })
	local message = e.message or ""
	local st = trace(e, key .. "-trace")
	-- The split trace shows the message on one line; a longer one (an assertion's
	-- explanation, a diff) gets its own block.
	if st == nil or string.find(message, "\n", 1, true) or #message > 140 then
		if st == nil then
			table.insert(out, ui.text({ ui.span(e.type or "Error", "error strong") }))
		end
		if message ~= "" then
			table.insert(out, with(ui.code(message), { key = key .. "-message" }))
		end
	end
	if st then
		table.insert(out, st)
	end
	if e.diff and e.diff ~= "" then
		table.insert(out, section("Diff", { ui.code(e.diff, "diff") }, key .. "-diff"))
	end
	if e.text and e.text ~= "" and e.text ~= message then
		table.insert(out, section("Full report", { ui.ansi(e.text) }, key .. "-report", true))
	end
end

local function location(f: File, line: number?): Span
	return ui.span(f.rel .. (if line then ":" .. line else ""), "mono muted")
end

local function head_line(title: { Span }, status: Status): Node
	return ui.node("row", { gap = "md", justify = "between", align = "center" }, {
		ui.text(title),
		ui.badge(WORD[status], ICON[status].tone),
	})
end

local function test_detail(page: Page, row: Row): { Node }
	local t = row.test :: Test
	local f = row.file :: File
	local out: { Node } = {}
	local path, own = model.split_name(t.name)
	local title: { Span } = {}
	if #path > 0 then
		table.insert(title, ui.span(table.concat(path, " › ") .. " › ", "muted"))
	end
	table.insert(title, ui.span(own, "strong"))
	table.insert(out, head_line(title, t.status))
	local meta: { Span } = { location(f, t.line) }
	local d = model.duration(t.duration)
	if d and t.status ~= "skipped" then
		table.insert(meta, ui.span("  ·  " .. d, "muted mono"))
	end
	if t.error and t.error.phase then
		table.insert(meta, ui.span("  ·  failed in " .. t.error.phase, "warning"))
	end
	table.insert(out, ui.text(meta))
	local actions: { Node } = {
		button("Run", "run", "play", { "enter" }, nil, if page.busy then "A run is in progress" else nil),
		button("Open", "open", "open", { "o" }),
	}
	if t.error then
		table.insert(actions, button("Copy failure", "copy", "copy", { "c" }))
	end
	table.insert(out, ui.row(actions))
	if t.status == "running" or t.status == "queued" then
		table.insert(out, ui.node("shimmer", { key = "wait", text = if t.status == "running" then "Running…" else "Waiting to run…" }))
	elseif t.error then
		error_blocks(t.error, "t", out)
	elseif t.status == "skipped" then
		table.insert(out, ui.text({ ui.span(if t.reason then "Skipped: " .. t.reason else "Skipped", "muted") }))
	elseif t.status == "passed" then
		table.insert(out, ui.text({ ui.span("Passed" .. (if d then " in " .. d else ""), "success") }))
	elseif t.status == "idle" then
		table.insert(out, ui.node("empty", {
			key = "idle",
			variant = "inline",
			icon = "play",
			title = "Not run yet",
			text = "Press Enter to run this test.",
		}))
	end
	if t.output and t.output ~= "" then
		table.insert(out, section("Output", { ui.ansi(t.output) }, "t-output"))
	end
	return out
end

local function file_detail(page: Page, row: Row): { Node }
	local f = row.file :: File
	local c = model.file_counts(f)
	local out: { Node } = {}
	local dir = model.dirname(f.rel)
	local title: { Span } = { ui.span(model.basename(f.rel), "strong") }
	if dir ~= "/" and dir ~= f.rel then
		table.insert(title, ui.span("  " .. dir, "muted mono"))
	end
	table.insert(out, head_line(title, if f.error then "error" else model.rollup(c)))
	table.insert(out, ui.text(counts_line(c)))
	table.insert(out, ui.row({
		button("Run file", "run", "play", { "enter" }, nil, if page.busy then "A run is in progress" else nil),
		button("Open", "open", "open", { "o" }),
	}))
	if f.error then
		table.insert(out, ui.rule("Could not load this file"))
		error_blocks(f.error, "f", out)
	end
	local failures: { Node } = {}
	for _, t in f.tests do
		if t.status == "failed" or t.status == "error" then
			local msg = if t.error then (string.match(t.error.message or "", "^[^\n]*") or "") else ""
			table.insert(failures, ui.node("item", {
				key = page.keyOf(t.ident),
				label = { ui.span((string.gsub(t.name, " > ", " › "))) },
				detail = { ui.span(msg, "muted") },
				icon = ICON[t.status].icon,
				tone = "error",
			}))
		end
	end
	if #failures > 0 then
		table.insert(out, ui.rule(plural(#failures, "failure")))
		table.insert(out, ui.node("list", { key = "failures" }, failures))
	elseif #f.tests == 0 and not f.error then
		table.insert(out, ui.node("empty", {
			key = "idle",
			variant = "inline",
			icon = "play",
			title = "No results yet",
			text = "Run the file to list its tests.",
		}))
	end
	if f.output and f.output ~= "" then
		table.insert(out, section("Output", { ui.ansi(f.output) }, "f-output"))
	end
	return out
end

local function suite_detail(page: Page, row: Row): { Node }
	local s = row.suite
	local c = model.suite_counts(s)
	local out: { Node } = {}
	table.insert(out, head_line({ ui.span(kind_label(s), "strong"), ui.span("  " .. s.rel, "muted mono") },
		if s.problem then "error" else model.rollup(c)))
	table.insert(out, ui.text(counts_line(c)))
	local function fact(k: string, v: string): { Spans }
		return { k, { ui.span(v, "mono") } }
	end
	local facts: { { Spans } } = { fact("Directory", model.tilde(s.dir, page.home)) }
	if s.python then
		table.insert(facts, fact("Python", model.tilde(s.python, page.home)))
	end
	if s.bin then
		table.insert(facts, fact("Runner", model.tilde(s.bin, page.home)))
	end
	if s.rootdir and s.rootdir ~= s.dir then
		table.insert(facts, fact("Root", model.tilde(s.rootdir, page.home)))
	end
	table.insert(facts, fact("Files", tostring(#s.files)))
	table.insert(out, ui.kv(facts))
	table.insert(out, ui.row({
		button("Run suite", "run", "play", { "enter" }, nil, if page.busy then "A run is in progress" else nil),
	}))
	if s.problem then
		local card = ui.card({ ui.span(s.problem, "strong") }, {
			if s.detail then ui.code(s.detail) else ui.text({ ui.span("No details", "muted") }),
		}, { key = "problem", icon = "warn" })
		table.insert(out, with(card, { tone = "error" }))
	end
	if s.output and s.output ~= "" then
		table.insert(out, section("Output", { ui.ansi(s.output) }, "s-output"))
	end
	return out
end

local function detail(page: Page): Node
	local row = page.selected
	local children: { Node }
	if row == nil then
		children = {
			ui.node("empty", {
				key = "none",
				icon = "list-checks",
				title = "Nothing selected",
				text = "Pick a test or a file to see its results.",
			}),
		}
	elseif row.kind == "test" then
		children = test_detail(page, row)
	elseif row.kind == "file" then
		children = file_detail(page, row)
	else
		children = suite_detail(page, row)
	end
	return ui.node("col", { key = "detail", gap = "md" }, children)
end

-- ---------------------------------------------------------------- page

local function head(page: Page): Node
	local kinds: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, s in page.suites do
		local k = kind_label(s)
		if not seen[k] then
			seen[k] = true
			table.insert(kinds, k)
		end
	end
	local left: { Span } = { ui.span("Tests", "title"), ui.span("  " .. model.tilde(page.root, page.home), "muted mono") }
	if #kinds > 0 then
		table.insert(left, ui.span("  ·  " .. table.concat(kinds, ", "), "muted"))
	end
	local busy = if page.busy then "A run is in progress" else nil
	local buttons: { Node } = {}
	if page.busy then
		table.insert(buttons, ui.button("Stop", { key = "stop", icon = "stop", keys = { "x" }, variant = "danger", actions = { click = "stop" } }))
	end
	table.insert(buttons, ui.button("Rerun failed", {
		key = "failed",
		icon = "repeat",
		keys = { "f" },
		disabled = busy or (if page.failed == 0 then "No failed tests" else nil),
		actions = { click = "failed" },
	}))
	table.insert(buttons, ui.button("Run all", {
		key = "runall",
		icon = "play",
		keys = { "shift", "r" },
		variant = "primary",
		disabled = busy or (if #page.suites == 0 then "No tests found" else nil),
		actions = { click = "runall" },
	}))
	table.insert(buttons, ui.button("", {
		key = "rescan",
		icon = "search",
		title = "Find tests again (d)",
		variant = "quiet",
		disabled = busy,
		actions = { click = "rescan" },
	}))
	return ui.node("row", { key = "head", gap = "md", justify = "between", align = "center", wrap = true }, {
		ui.text(left),
		ui.node("row", { gap = "sm" }, buttons),
	})
end

local function summary(page: Page): Node
	local r = page.running
	if r then
		local label: { Span } = { ui.span(r.label, "strong") }
		if r.total > 0 then
			table.insert(label, ui.span("  " .. r.done .. "/" .. r.total, "muted mono"))
		end
		if r.current then
			table.insert(label, ui.span("  " .. r.current, "muted"))
		end
		local value = if r.total > 0 then math.clamp(r.done / r.total, 0, 1) else nil
		return with(ui.progress(value, label), { key = "summary" })
	end
	local c = model.counts()
	for _, s in page.suites do
		local sc = model.suite_counts(s)
		c.total += sc.total
		c.passed += sc.passed
		c.failed += sc.failed
		c.skipped += sc.skipped
		c.idle += sc.idle
		c.duration += sc.duration
	end
	if c.passed + c.failed + c.skipped == 0 then
		return with(ui.text(counts_line(c)), { key = "summary" })
	end
	local took = if page.lastRun then model.duration(page.lastRun.took) else nil
	return with(ui.test_summary(c.passed, c.failed, c.skipped, took), { key = "summary" })
end

local function legend(page: Page): Node
	local spans: { Span } = {}
	local function k(key: string, what: string)
		table.insert(spans, ui.span(key, "key"))
		table.insert(spans, ui.span(" " .. what .. "   ", "muted"))
	end
	k("↑↓", "move")
	k("←→", "fold")
	k("⏎", "run")
	k("⇧R", "run all")
	k("F", "rerun failed")
	k("O", "open")
	k("P", if page.hidePassed then "show passed" else "hide passed")
	if page.busy then
		k("X", "stop")
	end
	k("D", "rescan")
	return ui.col({ ui.text(spans) })
end

function view.render(page: Page): BlockView
	local main: { Node } = { head(page) }
	if page.phase == "scanning" and #page.suites == 0 then
		table.insert(main, ui.node("shimmer", { key = "body", text = "Looking for tests under " .. model.tilde(page.root, page.home) .. "…" }))
		return { main = ui.node("col", { gap = "md" }, main) }
	end
	if page.phase == "failed" then
		table.insert(main, ui.node("empty", {
			key = "body",
			tone = "error",
			title = "Could not look for tests",
			text = page.problem or "",
			grow = 1,
		}, { ui.button("Try again", { icon = "repeat", keys = { "d" }, actions = { click = "rescan" } }) }))
		return { main = ui.node("col", { gap = "md" }, main) }
	end
	if #page.suites == 0 then
		table.insert(main, ui.node("empty", {
			key = "body",
			icon = "search",
			title = "No tests found",
			text = "Looked for pytest, unittest, vitest and jest projects under " .. model.tilde(page.root, page.home) .. ".",
			grow = 1,
		}, { ui.button("Look again", { icon = "search", keys = { "d" }, actions = { click = "rescan" } }) }))
		return { main = ui.node("col", { gap = "md" }, main) }
	end
	table.insert(main, summary(page))
	local sel = if page.selected then page.selected.key else nil
	-- Narrow panes stack the tree over the details instead of side by side.
	local stacked = page.cols < 100
	table.insert(main, ui.node("split", {
		key = if stacked then "stack" else "split",
		dir = if stacked then "col" else "row",
		sizes = if stacked then { 0.45, 0.55 } else (page.sizes or { 0.42, 0.58 }),
		min = if stacked then { "5lines", "8lines" } else { "24ch", "32ch" },
		grow = 1,
	}, { tree(page, sel, if stacked then view.TREE_STACKED else view.TREE, stacked), detail(page) }))
	return { main = ui.node("col", { gap = "md" }, main), dock = legend(page) }
end

return view
