--!strict

local results = require("./results")
local tree = require("./tree")
local detail = require("./detail")

type Launch = results.Launch
type Row = tree.Row
type Status = results.Status

local ui = tern.ui

local view = {}

export type Tab = "suites" | "behaviors" | "packages" | "categories" | "launches"

local TABS: { Tab } = { "suites", "behaviors", "packages", "categories", "launches" }
view.TABS = TABS

local STATUS_ORDER: { Status } = { "failed", "broken", "passed", "skipped", "unknown" }

local TAB_LABEL: { [string]: string } = {
	suites = "Suites",
	behaviors = "Behaviors",
	packages = "Packages",
	categories = "Categories",
	launches = "Launches",
}

export type Page = {
	phase: string,
	problem: string?,
	root: string,
	home: string?,
	pinned: boolean,
	sources: { results.Source },
	launches: { Launch },
	launch: Launch?,
	launchKey: (Launch) -> string,
	launchName: (Launch) -> string,
	tab: Tab,
	query: string,
	filtering: boolean,
	statuses: { [string]: boolean },
	rows: { Row },
	selected: Row?,
	rowKey: (string) -> string,
	isOpen: (string, number) -> boolean,
	shown: number,
	categoryCount: number,
	cols: number,
	rows_h: number,
	sizes: { number }?,
	progress: { done: number, total: number }?,
	live: boolean,
	model: detail.Model?,
	ctx: detail.Ctx,
}

view.TREE = "main.split.tree"
view.TREE_STACKED = "main.stack.tree"
view.FILTER = "main.bar.filter"

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

local function fact(k: string, v: Spans): { Spans }
	return { k, v }
end

local function utf16_len(s: string): number
	local n = 0
	for _, code in utf8.codes(s) do
		n += if code > 0xFFFF then 2 else 1
	end
	return n
end

function view.span_of(l: Launch): number?
	if l.start and l.stop then
		return (l.stop :: number) - (l.start :: number)
	end
	return nil
end

local function counts_line(c: results.Counts): { Span }
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
	if c.broken > 0 then
		add(c.broken .. " broken", "warning")
	end
	if c.passed > 0 then
		add(c.passed .. " passed", "success")
	end
	if c.skipped > 0 then
		add(c.skipped .. " skipped", "muted")
	end
	if c.unknown > 0 then
		add(c.unknown .. " unknown", "muted")
	end
	if #spans == 0 then
		add("No tests", "muted")
	end
	return spans
end

local function head(page: Page): Node
	local spans: { Span } = { ui.span("Allure", "title") }
	local meta: { string } = {}
	local l = page.launch
	if l then
		table.insert(meta, l.source.rel)
		table.insert(meta, page.launchName(l))
		table.insert(meta, results.when(l.start))
		local d = results.duration(view.span_of(l))
		if d then
			table.insert(meta, d)
		end
	else
		table.insert(meta, results.tilde(page.root, page.home))
	end
	table.insert(spans, ui.span("   " .. table.concat(meta, " · "), "muted"))
	local right: { Node } = {}
	if page.live then
		table.insert(right, with(ui.badge("Live", "accent"), { key = "live", title = "New results arrived in the last few seconds" }))
	end
	if #page.launches > 1 and l then
		local multi = #page.sources > 1
		local options: { { [string]: any } } = {}
		for _, launch in page.launches do
			local c = launch.counts
			local bad = c.failed + c.broken
			table.insert(options, {
				value = page.launchKey(launch),
				label = page.launchName(launch) .. " · " .. results.when(launch.start),
				detail = plural(c.total, "test") .. (if bad > 0 then " · " .. bad .. " failed" else ""),
				group = if multi then launch.source.rel else nil,
			})
		end
		table.insert(right, ui.node("select", {
			key = "launch",
			variant = "quiet",
			label = "Launch",
			value = page.launchKey(l),
			options = options,
			title = "Switch launch ([ and ])",
		}))
	end
	table.insert(right, ui.button("Refresh", {
		key = "refresh",
		icon = "repeat",
		keys = { "r" },
		busy = page.phase == "scanning" or page.phase == "loading",
		actions = { click = "refresh" },
	}))
	return ui.node("row", { key = "head", gap = "md", justify = "between", align = "center", wrap = true }, {
		ui.text(spans),
		ui.node("row", { key = "end", gap = "sm", align = "center" }, right),
	})
end

local function stats(l: Launch): Node
	local c = l.counts
	local sub: { string } = {}
	if c.skipped > 0 then
		table.insert(sub, c.skipped .. " skipped")
	end
	if c.unknown > 0 then
		table.insert(sub, c.unknown .. " unknown")
	end
	local d = results.duration(view.span_of(l))
	if d then
		table.insert(sub, d :: string)
	end
	local retried = #l.results - #l.tests
	if retried > 0 then
		table.insert(sub, retried .. (if retried == 1 then " retry" else " retries"))
	end
	local rate = if c.total > 0 then string.format("%d%% of tests", math.floor(c.passed * 100 / c.total + 0.5)) else nil
	local items: { { [string]: any } } = {
		{ label = "Tests", value = tostring(c.total), sub = table.concat(sub, " · ") },
		{ label = "Passed", value = tostring(c.passed), sub = rate, tone = if c.passed > 0 then "success" else nil },
		{ label = "Failed", value = tostring(c.failed), sub = "product defects", tone = if c.failed > 0 then "error" else nil },
		{ label = "Broken", value = tostring(c.broken), sub = "test defects", tone = if c.broken > 0 then "warning" else nil },
	}
	return ui.node("stats", { key = "stats", items = items })
end

local function tabs(page: Page): Node
	local items: { { [string]: any } } = {}
	for _, id in view.TABS do
		local label: { Span } = { ui.span(TAB_LABEL[id]) }
		if id == "categories" and page.categoryCount > 0 then
			table.insert(label, ui.span(" " .. page.categoryCount, "muted"))
		elseif id == "launches" then
			table.insert(label, ui.span(" " .. #page.launches, "muted"))
		end
		table.insert(items, { id = id, label = label })
	end
	return ui.node("tabs", { key = "tabs", active = page.tab, items = items })
end

local function toolbar(page: Page, l: Launch): Node
	local field = ui.node("input", {
		key = "filter",
		text = page.query,
		cursor = utf16_len(page.query),
		placeholder = "Filter by name, suite, feature or tag",
		icon = "search",
		keys = if page.filtering or page.query ~= "" then nil else { "/" },
		clear = page.query ~= "",
		variant = "field",
		grow = 1,
		max = { w = "64ch" },
	})
	local toggles: { Node } = {}
	for _, status in STATUS_ORDER do
		local n = results.of(l.counts, (status :: any) :: Status)
		if n > 0 or status ~= "unknown" then
			local look = detail.STATUS[status]
			local on = page.statuses[status] ~= false
			table.insert(toggles, ui.button(tostring(n), {
				key = status,
				icon = look.icon,
				on = on,
				title = (if on then "Hide " else "Show ") .. string.lower(look.word) .. " tests",
				actions = { click = "status=" .. status },
			}))
		end
	end
	return ui.node("row", { key = "bar", gap = "md", justify = "between", align = "center", wrap = true }, {
		field,
		ui.node("buttons", { key = "statuses", size = "sm", label = "Statuses" }, toggles),
	})
end

local GLYPH: { [string]: string } = {
	passed = "\u{f00c}",
	failed = "\u{f00d}",
	broken = "\u{f071}",
	skipped = "\u{f05e}",
	unknown = "\u{f128}",
}

local INDENT = "\u{2003}\u{2002}"

local function item(page: Page, row: Row): Node
	local label: { Span } = {}
	local value: { Span } = {}
	if row.depth > 0 then
		table.insert(label, ui.span(string.rep(INDENT, row.depth)))
	end
	if row.group then
		local g = row.group :: tree.Group
		local c = g.counts
		local st = results.rollup(c)
		local look = detail.STATUS[st]
		local open = page.isOpen(g.ident, row.depth)
		table.insert(label, ui.span(if open then "▾ " else "▸ ", "dim"))
		table.insert(label, ui.span(GLYPH[st], "icon " .. look.tone))
		table.insert(label, ui.span(g.name, if row.depth == 0 then "strong" else nil))
		local bad = c.failed + c.broken
		if bad > 0 then
			table.insert(value, ui.span(bad .. "/" .. c.total, (if c.failed > 0 then "error" else "warning") .. " mono"))
		else
			table.insert(value, ui.span(tostring(c.total), "muted mono"))
		end
	else
		local leaf = row.leaf :: tree.Leaf
		local r = leaf.result
		local look = detail.STATUS[r.status]
		table.insert(label, ui.span("\u{2002}\u{2002}"))
		table.insert(label, ui.span(GLYPH[r.status], "icon " .. look.tone))
		table.insert(label, ui.span(r.name))
		if r.flaky then
			table.insert(value, ui.span("flaky  ", "warning"))
		end
		if r.attempts and #(r.attempts :: { results.Result }) > 1 then
			table.insert(value, ui.span("×" .. #(r.attempts :: { results.Result }) .. "  ", "muted"))
		end
		local d = results.duration(if r.start and r.stop then (r.stop :: number) - (r.start :: number) else nil)
		if d and r.status ~= "skipped" then
			table.insert(value, ui.span(d :: string, "muted mono"))
		end
	end
	return ui.node("item", {
		key = page.rowKey(row.ident),
		label = label,
		value = value,
	})
end

local function tree_list(page: Page, stacked: boolean, list_rows: number): Node
	local items: { Node } = {}
	for _, row in page.rows do
		table.insert(items, item(page, row))
	end
	local id = if stacked then view.TREE_STACKED else view.TREE
	local sel = page.selected
	local empty: string
	if page.query ~= "" then
		empty = "No test matches the filter"
	elseif page.tab == "categories" then
		empty = "No failed or broken tests"
	else
		empty = "No test has the statuses shown"
	end
	return ui.node("list", {
		key = "tree",
		selected = if sel then id .. "." .. page.rowKey(sel.ident) else nil,
		filter = if page.query ~= "" then page.query else nil,
		empty = { ui.span(empty, "muted") },
		max = { lines = list_rows },
	}, items)
end

local function leaves_under(g: tree.Group, into: { tree.Leaf }, limit: number)
	for _, leaf in g.tests do
		if #into >= limit then
			return
		end
		if leaf.result.status == "failed" or leaf.result.status == "broken" then
			table.insert(into, leaf)
		end
	end
	for _, child in g.groups do
		leaves_under(child, into, limit)
	end
end

local function group_detail(page: Page, row: Row): { Node }
	local g = row.group :: tree.Group
	local c = g.counts
	local st = results.rollup(c)
	local look = detail.STATUS[st]
	local out: { Node } = {}
	table.insert(out, ui.node("row", { key = "head", gap = "md", justify = "between", align = "center" }, {
		ui.text({ ui.span(g.name, "strong") }),
		ui.badge(look.word, look.tone),
	}))
	table.insert(out, with(ui.test_summary(c.passed, c.failed + c.broken, c.skipped), { key = "summary" }))
	table.insert(out, with(ui.text(counts_line(c)), { key = "counts" }))
	local open = page.isOpen(g.ident, row.depth)
	table.insert(out, ui.node("row", { key = "actions", gap = "sm" }, {
		ui.button(if open then "Collapse" else "Expand", {
			key = "toggle",
			icon = if open then "chev-up" else "chev",
			keys = { "space" },
			size = "sm",
			actions = { click = "toggle" },
		}),
	}))
	local failing: { tree.Leaf } = {}
	leaves_under(g, failing, 60)
	if #failing > 0 then
		local items: { Node } = {}
		for _, leaf in failing do
			local r = leaf.result
			local lk = detail.STATUS[r.status]
			table.insert(items, ui.node("item", {
				key = page.rowKey(leaf.ident),
				label = { ui.span(r.name) },
				detail = { ui.span(results.first_line(r.message) or "", "muted") },
				icon = lk.icon,
				tone = lk.tone,
			}))
		end
		table.insert(out, ui.rule(plural(#failing, "problem")))
		table.insert(out, ui.node("list", { key = "failures" }, items))
	end
	return out
end

local function detail_col(page: Page): Node
	local row = page.selected
	local children: { Node }
	if row == nil then
		children = {
			ui.node("empty", {
				key = "none",
				icon = "list-checks",
				title = "Nothing selected",
				text = "Pick a test to see its steps, attachments and history.",
			}),
		}
	elseif row.group then
		children = group_detail(page, row)
	elseif page.model then
		children = detail.render(page.model :: detail.Model, page.ctx)
	else
		children = { ui.node("shimmer", { key = "reading", text = "Reading the result…" }) }
	end
	local scope = "none"
	if row and row.leaf then
		scope = page.rowKey(row.ident) .. (if page.model then "-" .. (page.model :: detail.Model).result.uuid else "")
	elseif row then
		scope = page.rowKey(row.ident)
	end
	return ui.node("col", { key = "detail", gap = "md" }, {
		ui.node("col", { key = scope, gap = "md" }, children),
	})
end

local function meter(c: results.Counts): MeterCell
	if c.total == 0 then
		return ui.meter_parts_cell({})
	end
	return ui.meter_parts_cell({
		{ c.passed / c.total, "success" },
		{ c.failed / c.total, "error" },
		{ c.broken / c.total, "warning" },
		{ (c.skipped + c.unknown) / c.total, "muted" },
	})
end

local function launch_card(page: Page, l: Launch): Node
	local c = l.counts
	local src = l.source
	local children: { Node } = {}
	local d = results.duration(view.span_of(l))
	table.insert(children, with(ui.test_summary(c.passed, c.failed + c.broken, c.skipped, d), { key = "summary" }))
	local facts: { { Spans } } = {
		fact("Folder", { ui.span(results.tilde(src.dir, page.home), "mono") }),
	}
	if l.start then
		table.insert(facts, fact("Started", { ui.span(results.clock(l.start) :: string, "mono") }))
	end
	if l.stop then
		table.insert(facts, fact("Finished", { ui.span(results.clock(l.stop) :: string, "mono") }))
	end
	local retried = #l.results - #l.tests
	if retried > 0 then
		table.insert(facts, fact("Retries", { ui.span(tostring(retried), "mono") }))
	end
	local ex = if l.index == #src.launches then src.executor else nil
	if ex then
		local name = if type(ex.buildName) == "string" then ex.buildName elseif type(ex.name) == "string" then ex.name else nil
		if name then
			local url = if type(ex.buildUrl) == "string" then ex.buildUrl elseif type(ex.url) == "string" then ex.url else nil
			table.insert(facts, fact("Executor", { if url then ui.link(name, url) else ui.span(name) }))
		end
	end
	if src.unreadable > 0 then
		table.insert(facts, fact("Unreadable", { ui.span(plural(src.unreadable, "file"), "warning") }))
	end
	table.insert(children, with(ui.kv(facts), { key = "facts" }))
	local cats: { [string]: number } = {}
	for _, r in l.tests do
		local names: { string } = r.categories or {}
		for _, name in names do
			cats[name] = (cats[name] or 0) + 1
		end
	end
	local cat_rows: { { Spans } } = {}
	for _, name in results.category_names(src) do
		if cats[name] then
			table.insert(cat_rows, fact(name, { ui.span(tostring(cats[name]), "mono") }))
		end
	end
	if #cat_rows > 0 then
		table.insert(children, with(ui.section({ ui.span("Categories") }, { ui.kv(cat_rows) }), { key = "cats" }))
	end
	local broken = results.broken_categories(src)
	if #broken > 0 then
		table.insert(children, with(ui.text({
			ui.span("categories.json: ", "muted"),
			ui.span(table.concat(broken, ", "), "warning"),
			ui.span(" use patterns this viewer can't read, so they match nothing", "muted"),
		}), { key = "badcats" }))
	end
	if #src.environment > 0 then
		local env: { { Spans } } = {}
		for _, pair in src.environment do
			table.insert(env, fact(pair[1], { ui.span(pair[2], "mono") }))
		end
		table.insert(children, with(ui.section({ ui.span("Environment") }, { ui.kv(env) }), { key = "env" }))
	end
	table.insert(children, ui.node("row", { key = "actions", gap = "sm" }, {
		ui.button("Show tests", { key = "show", icon = "list-checks", size = "sm", keys = { "enter" }, actions = { click = "show-tests" } }),
		ui.button("Copy folder path", { key = "copy", icon = "copy", size = "sm", variant = "quiet", actions = { click = "copy-folder" } }),
	}))
	return ui.node("card", {
		key = "card",
		head = { ui.span(page.launchName(l), "strong") },
		meta = results.when(l.start),
		icon = "history",
		min = { w = "44ch" },
		max = { w = "64ch" },
	}, children)
end

local function launches_view(page: Page): Node
	local multi = #page.sources > 1
	local cols: { Col } = {
		{ id = "run", head = "Launch", grow = 1, priority = 9 },
	}
	if multi then
		table.insert(cols, { id = "folder", head = "Folder", priority = 3, truncate = "middle", mono = true })
	end
	table.insert(cols, { id = "started", head = "Started", priority = 6 })
	table.insert(cols, { id = "duration", head = "Duration", align = "end", mono = true, priority = 5 })
	table.insert(cols, { id = "tests", head = "Tests", align = "end", mono = true, priority = 8 })
	table.insert(cols, { id = "result", head = "Result", priority = 4 })
	table.insert(cols, { id = "failed", head = "Failed", align = "end", mono = true, priority = 7 })
	local rows: { TableRow } = {}
	for _, l in page.launches do
		local c = l.counts
		local look = detail.STATUS[results.rollup(c)]
		local bad = c.failed + c.broken
		local cells: { Cell } = { { text = page.launchName(l), dot = look.tone } }
		if multi then
			table.insert(cells, l.source.rel)
		end
		table.insert(cells, results.when(l.start))
		table.insert(cells, results.duration(view.span_of(l)) or "")
		table.insert(cells, tostring(c.total))
		table.insert(cells, meter(c))
		table.insert(cells, { ui.span(tostring(bad), if bad > 0 then "error" else "muted") })
		table.insert(rows, { id = page.launchKey(l), cells = cells })
	end
	local selected = if page.launch then page.launchKey(page.launch :: Launch) else nil
	local list = with(ui.table(cols, rows, {
		selectable = true,
		selected = selected,
		empty = { ui.span("No launches yet", "muted") },
	}), { key = "table", grow = 1, basis = 0 })
	local parts: { Node } = { list }
	if page.launch then
		table.insert(parts, launch_card(page, page.launch :: Launch))
	end
	if page.cols < 110 then
		return ui.node("col", { key = "launches-stack", gap = "lg" }, parts)
	end
	return ui.node("row", { key = "launches", gap = "lg", align = "start" }, parts)
end

local function legend(page: Page): Node
	local spans: { Span } = {}
	local function k(key: string, what: string)
		table.insert(spans, ui.span(key, "key"))
		table.insert(spans, ui.span(" " .. what .. "   ", "muted"))
	end
	if page.filtering then
		k("⏎", "done")
		k("esc", "clear")
		k("↑↓", "move")
		return ui.col({ ui.text(spans) })
	end
	k("↑↓", "move")
	if page.tab == "launches" then
		k("⏎", "show tests")
	else
		k("←→", "fold")
		k("/", "filter")
		k("F", "failures only")
		k("C", "copy failure")
		k("O", "open result")
	end
	k("⇥", "next tab")
	k("[ ]", "launch")
	k("R", "refresh")
	return ui.col({ ui.text(spans) })
end

local function empty(key: string, icon: string, title: string, text: string, tone: string?, buttons: { Node }?): Node
	return ui.node("empty", { key = key, icon = icon, title = title, text = text, tone = tone, grow = 1 }, buttons or {})
end

function view.render(page: Page): BlockView
	local main: { Node } = { head(page) }
	local where = results.tilde(page.root, page.home)
	local function done(): BlockView
		return { main = ui.node("col", { gap = "md" }, main) }
	end
	if page.phase == "failed" then
		table.insert(main, empty("body", "warn", "Could not look for Allure results", page.problem or "", "error", {
			ui.button("Try again", { icon = "repeat", keys = { "r" }, actions = { click = "refresh" } }),
		}))
		return done()
	end
	if #page.sources == 0 then
		if page.phase == "scanning" then
			table.insert(main, ui.node("shimmer", { key = "body", text = "Looking for allure-results folders under " .. where .. "…" }))
		else
			table.insert(main, empty("body", "search", "No Allure results found", "Looked for allure-results folders under " .. where
				.. ". Run your tests with an Allure adapter (for example pytest --alluredir=allure-results) and they show up here.", nil, {
				ui.button("Look again", { icon = "search", keys = { "r" }, actions = { click = "refresh" } }),
			}))
		end
		return done()
	end
	local progress = page.progress
	if progress and page.launch == nil then
		local value = if progress.total > 0 then math.clamp(progress.done / progress.total, 0, 1) else nil
		table.insert(main, with(ui.progress(value, {
			ui.span("Reading results", "strong"),
			ui.span(string.format("  %d of %d files", progress.done, progress.total), "muted mono"),
		}), { key = "body" }))
		return done()
	end
	local l = page.launch
	if l == nil then
		local names: { string } = {}
		for _, src in page.sources do
			table.insert(names, src.rel)
		end
		table.insert(main, empty("body", "clock", "No test results yet", "Watching " .. table.concat(names, ", ")
			.. ". Results show up here as your tests write them.", nil, nil))
		return done()
	end
	table.insert(main, stats(l))
	table.insert(main, tabs(page))
	if page.tab == "launches" then
		table.insert(main, launches_view(page))
	else
		table.insert(main, toolbar(page, l))
		local stacked = page.cols < 100
		local split_lines = math.max(14, math.floor(page.rows_h * 0.96) - (if stacked then 22 else 15))
		local list_rows = math.max(4, math.floor((if stacked then split_lines * 0.45 else split_lines) * 0.75) - 1)
		table.insert(main, ui.node("split", {
			key = if stacked then "stack" else "split",
			dir = if stacked then "col" else "row",
			sizes = if stacked then { 0.45, 0.55 } else (page.sizes or { 0.4, 0.6 }),
			min = if stacked then { "6lines", "8lines" } else { "28ch", "40ch" },
			h = split_lines .. "lines",
		}, { tree_list(page, stacked, list_rows), detail_col(page) }))
	end
	return { main = ui.node("col", { gap = "md" }, main), dock = legend(page) }
end

return view
