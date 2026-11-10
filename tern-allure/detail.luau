--!strict

local results = require("./results")

type Result = results.Result
type Status = results.Status
type Source = results.Source

local ui = tern.ui

local detail = {}

export type Attachment = {
	source: string,
	name: string,
	type: string?,
	path: string,
}

export type Preview = {
	kind: string,
	text: string?,
	lang: string?,
	truncated: boolean?,
	rows: { { string } }?,
	links: { string }?,
	blobs: { { label: string, blob: string } }?,
	problem: string?,
}

export type Model = {
	result: Result,
	raw: { [string]: any }?,
	problem: string?,
	befores: { results.Fixture },
	afters: { results.Fixture },
	history: { Result },
	attempt: boolean,
}

export type Ctx = {
	attKey: (Attachment) -> string,
	expanded: { [string]: boolean },
	previews: { [string]: Preview },
	launchName: (results.Launch) -> string,
	launch: results.Launch?,
	multiSource: boolean,
}

export type Look = { icon: string, tone: string, word: string }

detail.STATUS = {
	passed = { icon = "check", tone = "success", word = "Passed" },
	failed = { icon = "x", tone = "error", word = "Failed" },
	broken = { icon = "warn", tone = "warning", word = "Broken" },
	skipped = { icon = "slash-circle", tone = "muted", word = "Skipped" },
	unknown = { icon = "help", tone = "muted", word = "Unknown" },
} :: { [string]: Look }

local MAX_STEP_DEPTH = 10

local STEP_SUFFIX: { [string]: { string } } = {
	broken = { "  broken", "warning" },
	skipped = { "  skipped", "muted" },
	unknown = { "  unknown", "muted" },
}

local MIME_KIND: { [string]: string } = {
	["application/vnd.allure.image.diff"] = "diff",
	["application/json"] = "json",
	["text/json"] = "json",
	["application/xml"] = "xml",
	["text/xml"] = "xml",
	["text/html"] = "html",
	["application/xhtml+xml"] = "html",
	["text/csv"] = "csv",
	["text/tab-separated-values"] = "tsv",
	["text/uri-list"] = "uri",
	["application/x-yaml"] = "yaml",
	["application/yaml"] = "yaml",
	["text/yaml"] = "yaml",
	["text/plain"] = "text",
	["application/pdf"] = "pdf",
	["application/javascript"] = "code",
	["text/javascript"] = "code",
	["application/x-sh"] = "code",
}

local EXT_KIND: { [string]: string } = {
	png = "image",
	jpg = "image",
	jpeg = "image",
	gif = "image",
	webp = "image",
	svg = "image",
	bmp = "image",
	mp4 = "video",
	webm = "video",
	mov = "video",
	mp3 = "video",
	wav = "video",
	pdf = "pdf",
	json = "json",
	xml = "xml",
	html = "html",
	htm = "html",
	csv = "csv",
	tsv = "tsv",
	uri = "uri",
	yaml = "yaml",
	yml = "yaml",
	txt = "text",
	log = "text",
	md = "text",
	properties = "text",
	js = "code",
	ts = "code",
	py = "code",
	java = "code",
	kt = "code",
	sql = "code",
	sh = "code",
	css = "code",
}

local KIND_ICON: { [string]: string } = {
	image = "file-image",
	diff = "image",
	video = "reel",
	pdf = "file-pdf",
	json = "file-code",
	xml = "file-code",
	html = "file-code",
	yaml = "file-code",
	code = "file-code",
	csv = "grid",
	tsv = "grid",
	uri = "link",
	text = "doc",
	binary = "file",
}

local KIND_LANG: { [string]: string } = {
	json = "json",
	xml = "xml",
	html = "html",
	yaml = "yaml",
}

local CODE_EXT_LANG: { [string]: string } = {
	js = "javascript",
	ts = "typescript",
	py = "python",
	java = "java",
	kt = "kotlin",
	sql = "sql",
	sh = "bash",
	css = "css",
}

local function str(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	elseif type(v) == "number" or type(v) == "boolean" then
		return tostring(v)
	end
	return nil
end

local function num(v: any): number?
	if type(v) == "number" and v == v then
		return v
	end
	return nil
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function plural(n: number, word: string, many: string?): string
	return n .. " " .. (if n == 1 then word else many or (word .. "s"))
end

local function button(text: string, act: string, icon: string, keys: { string }?, variant: ButtonVariant?): Node
	return ui.button(text, {
		key = (string.match(act, "^[^=]+") or act),
		icon = icon,
		keys = keys,
		size = "sm",
		variant = variant,
		actions = { click = act },
	})
end

local function section(title: { Span | string }, key: string, children: { Node }, collapsed: boolean?): Node
	return with(ui.section(title, children), { key = key, collapsible = true, collapsed = collapsed == true })
end

local function ext_of(path: string): string?
	local ext = string.match(path, "%.([%w]+)$")
	return if ext then string.lower(ext) else nil
end

function detail.kind_of(att: Attachment): string
	local mime = if att.type then string.lower(string.match(att.type :: string, "^[^;%s]+") or "") else ""
	local known = MIME_KIND[mime]
	if known then
		return known
	end
	if string.sub(mime, 1, 6) == "image/" then
		return "image"
	elseif string.sub(mime, 1, 6) == "video/" or string.sub(mime, 1, 6) == "audio/" then
		return "video"
	end
	local ext = ext_of(att.source) or ext_of(att.name)
	local by_ext = if ext then EXT_KIND[ext] else nil
	if by_ext then
		return by_ext
	end
	if string.sub(mime, 1, 5) == "text/" then
		return "text"
	end
	return "binary"
end

function detail.lang_of(att: Attachment, kind: string): string?
	local lang = KIND_LANG[kind]
	if lang then
		return lang
	end
	if kind == "code" then
		local ext = ext_of(att.source) or ext_of(att.name)
		return if ext then CODE_EXT_LANG[ext] else nil
	end
	return nil
end

function detail.is_media(kind: string): boolean
	return kind == "image" or kind == "video" or kind == "pdf"
end

function detail.is_text(kind: string): boolean
	return kind == "json" or kind == "xml" or kind == "html" or kind == "yaml" or kind == "code" or kind == "csv"
		or kind == "tsv" or kind == "uri" or kind == "text"
end

function detail.params(list: any): { { string } }
	local out: { { string } } = {}
	if type(list) ~= "table" then
		return out
	end
	for _, p in list do
		if type(p) == "table" and p.mode ~= "hidden" then
			local name = str(p.name) or "?"
			local value = if p.mode == "masked" then "******" else (str(p.value) or "")
			table.insert(out, { name, value })
		end
	end
	return out
end

function detail.attachments(src: Source, list: any): { Attachment }
	local out: { Attachment } = {}
	if type(list) ~= "table" then
		return out
	end
	for _, a in list do
		if type(a) == "table" then
			local source = str(a.source)
			if source then
				table.insert(out, {
					source = source,
					name = str(a.name) or source,
					type = str(a.type),
					path = results.attachment_path(src, source),
				})
			end
		end
	end
	return out
end

local function took(step: { [string]: any }): number?
	local start, stop = num(step.start), num(step.stop)
	if start and stop and stop >= start then
		return stop - start
	end
	return nil
end

local function trace_status(s: Status): string
	if s == "passed" then
		return "done"
	elseif s == "failed" or s == "broken" then
		return "error"
	end
	return "pending"
end

local function inline_params(params: { { string } }): string
	local parts: { string } = {}
	for _, p in params do
		table.insert(parts, p[1] .. " = " .. p[2])
	end
	return table.concat(parts, ", ")
end

local function strip_html(html: string): string
	local t = string.gsub(html, "<[Bb][Rr]%s*/?>", "\n")
	t = string.gsub(t, "</[Pp]>", "\n\n")
	t = string.gsub(t, "<[Ll][Ii][^>]*>", "\n- ")
	t = string.gsub(t, "</?[Hh](%d)[^>]*>", "\n")
	t = string.gsub(t, "<[^>]+>", "")
	t = string.gsub(t, "&nbsp;", " ")
	t = string.gsub(t, "&lt;", "<")
	t = string.gsub(t, "&gt;", ">")
	t = string.gsub(t, "&quot;", '"')
	t = string.gsub(t, "&#39;", "'")
	t = string.gsub(t, "&amp;", "&")
	t = string.gsub(t, "\n\n\n+", "\n\n")
	return (string.match(t, "^%s*(.-)%s*$") or t)
end

local function rest_lines(message: string): string?
	local rest = string.match(message, "^[^\n]*\n(.*)$")
	if rest == nil then
		return nil
	end
	local trimmed = string.match(rest :: string, "^%s*(.-)%s*$") or ""
	if trimmed == "" then
		return nil
	end
	return (string.gsub(rest :: string, "%s+$", ""))
end

local function trace_lang(trace: string): string?
	if string.find(trace, 'File "', 1, true) or string.find(trace, "Traceback", 1, true) then
		return "python"
	elseif string.find(trace, "\n%s*at [%w%.$_]+%(") then
		return "java"
	end
	return nil
end

local function preview_nodes(att: Attachment, kind: string, preview: Preview?): { Node }
	if detail.is_media(kind) then
		return { ui.node("media", { key = "media", path = att.path, max = { h = "18lines" } }) }
	end
	if preview == nil or preview.kind == "loading" then
		return { ui.node("shimmer", { key = "loading", text = "Reading " .. att.name .. "…" }) }
	end
	if preview.kind == "error" then
		return { ui.text({ ui.span(preview.problem or "Could not read the attachment", "muted") }) }
	end
	if preview.kind == "diff" then
		local cells: { Node } = {}
		local blobs: { { label: string, blob: string } } = preview.blobs or {}
		for i, b in blobs do
			table.insert(cells, ui.node("col", { key = "d" .. i, gap = "xs", grow = 1, basis = 0 }, {
				ui.text({ ui.span(b.label, "muted") }),
				ui.node("image", { blob = b.blob, alt = att.name .. " · " .. b.label, max = { h = "16lines" } }),
			}))
		end
		if #cells == 0 then
			return { ui.text({ ui.span("The screenshot diff holds no images", "muted") }) }
		end
		return { ui.node("row", { key = "diff", gap = "md", align = "start" }, cells) }
	end
	local out: { Node } = {}
	if preview.kind == "table" and preview.rows and #(preview.rows :: { { string } }) > 0 then
		local rows = preview.rows :: { { string } }
		local cols: { Col } = {}
		for i, h in rows[1] do
			table.insert(cols, { id = "c" .. i, head = h, grow = if i == 1 then 1 else nil, priority = #rows[1] - i })
		end
		local body: { TableRow } = {}
		for r = 2, #rows do
			local cells: { Cell } = {}
			for i = 1, #rows[1] do
				cells[i] = rows[r][i] or ""
			end
			table.insert(body, { id = "r" .. r, cells = cells })
		end
		table.insert(out, with(ui.table(cols, body, { empty = { ui.span("No rows", "muted") } }), { key = "table" }))
	elseif preview.kind == "links" and preview.links then
		local spans: { Node } = {}
		for i, url in preview.links :: { string } do
			table.insert(spans, with(ui.text({ ui.link(url, url) }), { key = "l" .. i }))
		end
		table.insert(out, ui.node("col", { key = "links", gap = "xs" }, spans))
	elseif preview.kind == "text" and preview.text then
		local text = preview.text :: string
		if string.find(text, "\27[", 1, true) then
			table.insert(out, with(ui.ansi(text), { key = "text", preview = { lines = 24 } }))
		else
			table.insert(out, with(ui.code(text, preview.lang), { key = "text", wrap = true, preview = { lines = 24 } }))
		end
	else
		table.insert(out, ui.text({ ui.span("No preview for this kind of file. Open it to see it in Tern.", "muted") }))
	end
	if preview.truncated then
		table.insert(out, ui.text({ ui.span("Showing the start of a long file. Open it to see all of it.", "dim") }))
	end
	return out
end

local function attachment_node(att: Attachment, ctx: Ctx): Node
	local key = ctx.attKey(att)
	local open = ctx.expanded[key] == true
	local kind = detail.kind_of(att)
	local meta = att.type or (ext_of(att.source) or "file")
	local body: { Node } = {}
	if open then
		body = preview_nodes(att, kind, ctx.previews[key])
		table.insert(body, ui.node("row", { key = "acts", gap = "sm" }, {
			button("Open", "open-att=" .. key, "open"),
			button("Copy path", "copy-att=" .. key, "copy", nil, "quiet"),
		}))
	end
	return ui.node("card", {
		key = key,
		head = { ui.span(att.name) },
		meta = meta,
		icon = KIND_ICON[kind] or "file",
		variant = "bare",
		collapsible = true,
		collapsed = not open,
	}, body)
end

local function failed(s: Status): boolean
	return s == "failed" or s == "broken"
end

local steps_trace: (key: string, steps: any, src: Source, ctx: Ctx, depth: number) -> Node?

steps_trace = function(key: string, steps: any, src: Source, ctx: Ctx, depth: number): Node?
	if type(steps) ~= "table" or #steps == 0 then
		return nil
	end
	local lines: { { [string]: any } } = {}
	local kids: { Node } = {}
	for i, st in steps do
		if type(st) == "table" then
			local id = "s" .. i
			local status: Status = results.status_of(st.status)
			local bad = failed(status)
			local params = detail.params(st.parameters)
			local atts = detail.attachments(src, st.attachments)
			local sd = if type(st.statusDetails) == "table" then st.statusDetails else {}
			local message = str(sd.message)
			local trace = str(sd.trace)
			local title: { Span | string } = { ui.span(str(st.name) or "Unnamed step") }
			local suffix = STEP_SUFFIX[status]
			if suffix then
				table.insert(title, ui.span(suffix[1], suffix[2]))
			end
			if #atts > 0 then
				table.insert(title, ui.span("  " .. plural(#atts, "attachment"), "dim"))
			end
			local line: { [string]: any } = { id = id, title = title, status = trace_status(status), took = took(st) }
			if #params > 0 then
				line.target = inline_params(params)
			end
			if bad and message then
				line.detail = results.first_line(message)
			end
			local content: { Node } = {}
			if #params > 0 then
				table.insert(content, with(ui.kv(params), { key = "params" }))
			end
			local sub: Node? = nil
			local child_failed = false
			if type(st.steps) == "table" and #st.steps > 0 then
				for _, child in st.steps do
					if type(child) == "table" and failed(results.status_of(child.status)) then
						child_failed = true
					end
				end
				if depth < MAX_STEP_DEPTH then
					sub = steps_trace("steps", st.steps, src, ctx, depth + 1)
				else
					table.insert(content, ui.text({ ui.span(plural(#st.steps, "more nested step"), "muted") }))
				end
			end
			if sub then
				table.insert(content, sub)
			end
			for _, att in atts do
				table.insert(content, attachment_node(att, ctx))
			end
			if bad and not child_failed then
				local rest = if message then rest_lines(message :: string) else nil
				if rest then
					table.insert(content, with(ui.code(rest :: string), { key = "message", wrap = true }))
				end
				if trace then
					table.insert(content, section({ ui.span("Stack trace", "muted") }, "trace", {
						with(ui.code(trace :: string, trace_lang(trace :: string)), { wrap = true, preview = { lines = 12 } }),
					}, true))
				end
			end
			if #content > 0 then
				line.open = bad
				table.insert(kids, ui.node("col", { key = id, gap = "sm" }, content))
			end
			table.insert(lines, line)
		end
	end
	if #lines == 0 then
		return nil
	end
	return ui.node("trace", { key = key, lines = lines }, kids)
end

local function fixtures_trace(key: string, list: { results.Fixture }, src: Source, ctx: Ctx): Node?
	local steps: { any } = {}
	for _, f in list do
		table.insert(steps, f.step)
	end
	return steps_trace(key, steps, src, ctx, 1)
end

local function error_card(raw: { [string]: any }, status: Status): Node?
	local sd = if type(raw.statusDetails) == "table" then raw.statusDetails else {}
	local message = str(sd.message)
	local trace = str(sd.trace)
	if message == nil and trace == nil then
		return nil
	end
	local look = detail.STATUS[status]
	local body: { Node } = {}
	local rest = if message then rest_lines(message :: string) else nil
	if rest then
		table.insert(body, with(ui.code(rest :: string), { key = "message", wrap = true }))
	end
	if trace then
		table.insert(body, with(ui.text({ ui.span("Stack trace", "muted") }), { key = "trace-head" }))
		table.insert(body, with(ui.code(trace :: string, trace_lang(trace :: string)), {
			key = "trace",
			wrap = true,
			preview = { lines = if failed(status) then 8 else 3 },
		}))
	end
	local head = results.first_line(message) or "No message"
	return ui.node("card", {
		key = "error",
		head = { ui.span(head, "strong") },
		icon = if status == "failed" then "x-circle" elseif status == "broken" then "warn" else "info",
		tone = if failed(status) then look.tone else nil,
	}, body)
end

local function labels_of(raw: { [string]: any }): { [string]: { string } }
	local out: { [string]: { string } } = {}
	if type(raw.labels) == "table" then
		for _, l in raw.labels do
			if type(l) == "table" and type(l.name) == "string" then
				local v = str(l.value)
				if v then
					local list = out[l.name]
					if list == nil then
						list = {}
						out[l.name] = list
					end
					table.insert(list, v)
				end
			end
		end
	end
	return out
end

local SHOWN_LABELS = {
	{ "severity", "Severity" },
	{ "owner", "Owner" },
	{ "epic", "Epic" },
	{ "feature", "Feature" },
	{ "story", "Story" },
	{ "package", "Package" },
	{ "framework", "Framework" },
	{ "language", "Language" },
	{ "host", "Host" },
	{ "thread", "Thread" },
}

local HIDDEN_LABELS: { [string]: boolean } = {
	severity = true,
	owner = true,
	epic = true,
	feature = true,
	story = true,
	package = true,
	framework = true,
	language = true,
	host = true,
	thread = true,
	tag = true,
	parentSuite = true,
	suite = true,
	subSuite = true,
}

local function fact(k: string, v: Spans): { Spans }
	return { k, v }
end

local function facts(labels: { [string]: { string } }): ({ { Spans } }, { { Spans } })
	local shown: { { Spans } } = {}
	local suite: { string } = {}
	for _, key in { "parentSuite", "suite", "subSuite" } do
		local values: { string } = labels[key] or {}
		for _, v in values do
			table.insert(suite, v)
		end
	end
	if #suite > 0 then
		table.insert(shown, fact("Suite", { ui.span(table.concat(suite, " › ")) }))
	end
	if labels.tag and #labels.tag > 0 then
		table.insert(shown, fact("Tags", { ui.span(table.concat(labels.tag, ", "), "mono") }))
	end
	for _, pair in SHOWN_LABELS do
		local values = labels[pair[1]]
		if values and #values > 0 then
			local style = if pair[1] == "package" or pair[1] == "thread" or pair[1] == "host" then "mono" else nil
			table.insert(shown, fact(pair[2], { ui.span(table.concat(values, ", "), style) }))
		end
	end
	local rest: { { Spans } } = {}
	local names: { string } = {}
	for name in labels do
		if not HIDDEN_LABELS[name] then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for _, name in names do
		table.insert(rest, fact(name, { ui.span(table.concat(labels[name], ", "), "mono") }))
	end
	return shown, rest
end

local LINK_WORD: { [string]: string } = {
	issue = "Issue",
	tms = "Test case",
	link = "Link",
}

local function links_kv(raw: { [string]: any }): { { Spans } }
	local out: { { Spans } } = {}
	if type(raw.links) ~= "table" then
		return out
	end
	for _, l in raw.links do
		if type(l) == "table" then
			local url = str(l.url)
			local name = str(l.name) or url
			if name then
				local kind = string.lower(str(l.type) or "link")
				local word = LINK_WORD[kind] or (string.upper(string.sub(kind, 1, 1)) .. string.sub(kind, 2))
				local span = if url and string.match(url :: string, "^%a[%w+.-]*://") then ui.link(name :: string, url :: string) else ui.span(name :: string, "mono")
				table.insert(out, fact(word, { span }))
			end
		end
	end
	return out
end

function detail.failure_text(r: Result, raw: { [string]: any }?): string
	local parts: { string } = { r.fullName or r.name }
	local sd = if raw and type(raw.statusDetails) == "table" then raw.statusDetails else nil
	local message = if sd then str(sd.message) else r.message
	local trace = if sd then str(sd.trace) else r.trace
	if message then
		table.insert(parts, message :: string)
	end
	if trace then
		table.insert(parts, trace :: string)
	end
	return table.concat(parts, "\n\n")
end

local function attempts_list(model: Model): Node?
	local list = model.result.attempts
	if list == nil or #list < 2 then
		return nil
	end
	local items: { Node } = {}
	local selected: string? = nil
	for i = #list, 1, -1 do
		local a = list[i]
		local look = detail.STATUS[a.status]
		local key = "u" .. i
		if a == model.result then
			selected = key
		end
		local value: { Span } = {}
		local d = results.duration(if a.start and a.stop then (a.stop :: number) - (a.start :: number) else nil)
		table.insert(value, ui.span(results.when(a.start), "muted"))
		if d then
			table.insert(value, ui.span("  " .. d, "muted mono"))
		end
		table.insert(items, ui.node("item", {
			key = key,
			label = { ui.span("Attempt " .. i), ui.span(if i == #list then "  latest" else "", "muted") },
			detail = { ui.span(results.first_line(a.message) or look.word, "muted") },
			value = value,
			icon = look.icon,
			tone = look.tone,
		}))
	end
	return section({ ui.span("Retries"), ui.span("  " .. #list - 1, "muted") }, "s-retries", {
		ui.node("list", { key = "retries", selected = selected }, items),
	})
end

local function history_list(model: Model, ctx: Ctx): Node?
	if #model.history < 2 then
		return nil
	end
	local items: { Node } = {}
	local selected: string? = nil
	for i, r in model.history do
		local l = r.launch
		if l then
			local look = detail.STATUS[r.status]
			local key = "h" .. i
			if l == ctx.launch then
				selected = key
			end
			local d = results.duration(if r.start and r.stop then (r.stop :: number) - (r.start :: number) else nil)
			table.insert(items, ui.node("item", {
				key = key,
				label = { ui.span(ctx.launchName(l)), ui.span("  " .. results.when(l.start), "muted") },
				detail = { ui.span(if ctx.multiSource then l.source.rel else (results.first_line(r.message) or ""), "muted") },
				value = { ui.span(look.word, look.tone), ui.span(if d then "  " .. d else "", "muted mono") },
				icon = look.icon,
				tone = look.tone,
			}))
		end
	end
	local pass = 0
	for _, r in model.history do
		if r.status == "passed" then
			pass += 1
		end
	end
	return section({
		ui.span("History"),
		ui.span(string.format("  %d of %d passed", pass, #model.history), "muted"),
	}, "s-history", {
		ui.node("list", { key = "history", selected = selected }, items),
	})
end

function detail.render(model: Model, ctx: Ctx): { Node }
	local r = model.result
	local src = r.source
	local look = detail.STATUS[r.status]
	local out: { Node } = {}
	local badges: { Node } = {}
	if r.flaky then
		table.insert(badges, ui.badge("Flaky", "warning"))
	end
	if r.known then
		table.insert(badges, ui.badge("Known issue", "muted"))
	end
	if r.muted then
		table.insert(badges, ui.badge("Muted", "muted"))
	end
	if model.attempt and r.attempts then
		local at = table.find(r.attempts :: { Result }, r) or 0
		table.insert(badges, ui.badge(string.format("Attempt %d of %d", at, #(r.attempts :: { Result })), "pending"))
	end
	table.insert(badges, ui.badge(look.word, look.tone))
	table.insert(out, ui.node("row", { key = "head", gap = "md", justify = "between", align = "start" }, {
		ui.node("row", { key = "title", gap = "sm", align = "start" }, {
			ui.node("icon", { name = look.icon, tone = look.tone }),
			ui.text({ ui.span(r.name, "strong") }),
		}),
		ui.node("row", { key = "badges", gap = "xs" }, badges),
	}))
	local meta: { Span } = {}
	if r.fullName and r.fullName ~= r.name then
		table.insert(meta, ui.span(r.fullName :: string, "mono muted"))
	end
	if #meta > 0 then
		table.insert(out, with(ui.text(meta), { key = "full" }))
	end
	local summary: { { Spans } } = {}
	local d = results.duration(if r.start and r.stop then (r.stop :: number) - (r.start :: number) else nil)
	if d then
		table.insert(summary, fact("Duration", { ui.span(d :: string, "mono") }))
	end
	if r.start then
		table.insert(summary, fact("Started", { ui.span(results.clock(r.start) :: string, "mono") }))
	end
	if #summary > 0 then
		local line = ui.kv(summary)
		table.insert(out, with(line, { key = "when", layout = "inline" }))
	end
	local actions: { Node } = {}
	if r.message or r.trace then
		table.insert(actions, button("Copy failure", "copy-failure", "copy", { "c" }))
	end
	table.insert(actions, button("Open result file", "open-result", "open", { "o" }))
	if model.attempt then
		table.insert(actions, button("Show latest attempt", "latest", "history", nil, "quiet"))
	end
	table.insert(out, ui.node("row", { key = "actions", gap = "sm", wrap = true }, actions))
	local raw = model.raw
	if raw == nil then
		table.insert(out, ui.node("empty", {
			key = "unreadable",
			variant = "inline",
			tone = "error",
			icon = "warn",
			title = "Could not read this result",
			text = model.problem or r.file,
		}))
		return out
	end
	local err = error_card(raw, r.status)
	if err then
		table.insert(out, err)
	end
	local description = str(raw.description)
	local html = str(raw.descriptionHtml)
	if description or html then
		local text = if description then description :: string else strip_html(html :: string)
		table.insert(out, section({ ui.span("Description") }, "s-description", {
			with(ui.md(text), { max = { w = "80ch" } }),
		}))
	end
	local labels = labels_of(raw)
	local shown, rest = facts(labels)
	local links = links_kv(raw)
	for _, l in links do
		table.insert(shown, l)
	end
	if #shown > 0 then
		table.insert(out, with(ui.kv(shown), { key = "facts" }))
	end
	local params = detail.params(raw.parameters)
	if #params > 0 then
		table.insert(out, section({ ui.span("Parameters"), ui.span("  " .. #params, "muted") }, "s-params", {
			ui.kv(params),
		}))
	end
	local befores = fixtures_trace("before", model.befores, src, ctx)
	if befores then
		table.insert(out, section({ ui.span("Set up"), ui.span("  " .. #model.befores, "muted") }, "s-setup", { befores }))
	end
	local body: { Node } = {}
	local steps = steps_trace("steps", raw.steps, src, ctx, 1)
	if steps then
		table.insert(body, steps)
	end
	for _, att in detail.attachments(src, raw.attachments) do
		table.insert(body, attachment_node(att, ctx))
	end
	local step_count = if type(raw.steps) == "table" then #raw.steps else 0
	if #body == 0 then
		table.insert(body, ui.text({ ui.span("No steps were reported", "muted") }))
	end
	table.insert(out, section({ ui.span("Test body"), ui.span("  " .. plural(step_count, "step"), "muted") }, "s-body", body))
	local afters = fixtures_trace("after", model.afters, src, ctx)
	if afters then
		table.insert(out, section({ ui.span("Tear down"), ui.span("  " .. #model.afters, "muted") }, "s-teardown", { afters }))
	end
	local attempts = attempts_list(model)
	if attempts then
		table.insert(out, attempts)
	end
	local history = history_list(model, ctx)
	if history then
		table.insert(out, history)
	end
	if #rest > 0 then
		table.insert(out, section({ ui.span("All labels"), ui.span("  " .. #rest, "muted") }, "s-labels", { ui.kv(rest) }, true))
	end
	return out
end

return detail
