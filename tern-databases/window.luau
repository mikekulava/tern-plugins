--!strict
-- The Databases plugin's window half: the keychain and the session's agents, which a block
-- (the host half) can't reach. A block asks over "databases:" links (link.luau): `secret`
-- reads a connection's password, `store` saves the one typed in the block's form (read from the
-- block's own masked field, so it never travels in a link), `forget` deletes it, and `ask`
-- hands a prompt to an agent in the block's session (starting one beside the block when
-- there is none) and sends back its answer. Answers are events to the asking block's pane.
-- Also: the palette command that opens the block.

local link = require("./link")

local KIND = "databases.console"
-- Pane ids of a remote host carry its tag above 2^44; a block knows only its own part.
local HOST_IDS = 17592186044416
local AGENT_WAIT_MS = 25 * 60 * 1000

type Query = { [string]: string }

-- The window's id for the Databases block on host pane `pane`; nil when it is not one.
local function block_pane(cx: WindowCx, pane: number): number?
	for _, p in cx.session:panes() do
		if p.block == KIND and (p.pane == pane or p.pane % HOST_IDS == pane) then
			return p.pane
		end
	end
	return nil
end

local function answer(cx: WindowCx?, pane: number, op: string, q: Query, data: { [string]: any })
	if not cx then
		return
	end
	data.op = op
	data.req = tonumber(q.req)
	pcall(function()
		cx.session:event(pane, { ev = "action", act = link.ACT, json = tern.json.encode(data) })
	end)
end

local function secret_name(q: Query): string?
	local id = q.conn
	if type(id) ~= "string" or not string.match(id, "^[a-z0-9][a-z0-9_-]*$") or #id > 58 then
		return nil
	end
	return "conn." .. id
end

-- The text of the password field under node `root` of the block's form.
local function typed_password(cx: WindowCx, pane: number, root: string?): string?
	if type(root) ~= "string" or root == "" then
		return nil
	end
	local ok, tree = pcall(function()
		return cx.session:surface(pane, { as = "table", root = root })
	end)
	if not ok or type(tree) ~= "table" then
		return nil
	end
	local function find(node: any): string?
		if type(node) ~= "table" then
			return nil
		end
		local p = node.p
		if type(p) == "table" and p.role == "databases.password" and type(p.text) == "string" then
			return p.text
		end
		for _, region in { "main", "dock", "layer" } do
			local found = find(node[region])
			if found then
				return found
			end
		end
		if type(node.c) == "table" then
			for _, child in node.c do
				local found = find(child)
				if found then
					return found
				end
			end
		end
		return nil
	end
	return find(tree)
end

local function tab_name(cx: WindowCx, pane: number): string?
	local tab = cx.session:tab_of(pane)
	for _, t in cx.session:tabs() do
		if t.id == tab then
			local name = if type(t.name) == "string" and t.name ~= "" then t.name else t.title
			return if name ~= "" then name else nil
		end
	end
	return nil
end

-- How the block names the agent: its program, and its tab when that is not the block's.
local function agent_label(cx: WindowCx, a: AgentBlock, block: number): string
	local command = if type(a.command) == "string" then a.command else nil
	if not command then
		local info = cx.session:pane(a.pane)
		command = if info and type(info.program) == "string" then info.program else nil
	end
	local program = string.match(command or "", "^%s*([^%s]+)") or "agent"
	program = string.match(program, "([^/]+)$") or program
	if cx.session:tab_of(a.pane) == cx.session:tab_of(block) then
		return program
	end
	local tab = tab_name(cx, a.pane)
	return if tab then program .. " in “" .. tab .. "”" else program
end

-- The agent of the block's session to ask: the one asked last, one in the block's tab, an idle
-- one. Agents of other sessions are never picked.
local function choose_agent(cx: WindowCx, block: number, preferred: number?): AgentBlock?
	local ok, agents = pcall(function()
		return cx.agents:list()
	end)
	if not ok or type(agents) ~= "table" then
		return nil
	end
	local tab = cx.session:tab_of(block)
	local mine: { [number]: boolean } = {}
	for _, s in cx.session:sessions() do
		if tab and table.find(s.tabs, tab) then
			for _, t in s.tabs do
				mine[t] = true
			end
		end
	end
	local best: AgentBlock? = nil
	local best_score = -1
	for _, a in agents do
		local at = if a.state ~= "exited" then cx.session:tab_of(a.pane) else nil
		if at and mine[at] then
			local score = 0
			if a.pane == preferred then
				score += 100
			end
			if at == tab then
				score += 20
			end
			if a.state == "idle" then
				score += 5
			elseif a.state == "working" then
				score += 2
			end
			if score > best_score then
				best, best_score = a, score
			end
		end
	end
	return best
end

type Op = (cx: WindowCx, pane: number, q: Query, host_pane: number) -> ()
local ops: { [string]: Op } = {}

ops.secret = function(cx, pane, q)
	local name = secret_name(q)
	if not name then
		answer(cx, pane, "secret", q, { error = "bad connection id" })
		return
	end
	tern.secrets.get(name):next(function(value: string?, err: string?, fresh: WindowCx?)
		answer(fresh, pane, "secret", q, { secret = value, error = err })
	end)
end

ops.store = function(cx, pane, q)
	local name = secret_name(q)
	local typed = typed_password(cx, pane, q.field)
	if not name or not typed or typed == "" then
		answer(cx, pane, "store", q, { error = "the password field could not be read" })
		return
	end
	tern.secrets.set(name, typed):next(function(_: any, err: string?, fresh: WindowCx?)
		answer(fresh, pane, "store", q, { ok = err == nil, error = err })
	end)
end

ops.forget = function(cx, pane, q)
	local name = secret_name(q)
	if not name then
		answer(cx, pane, "forget", q, { error = "bad connection id" })
		return
	end
	tern.secrets.set(name, nil):next(function(_: any, err: string?, fresh: WindowCx?)
		answer(fresh, pane, "forget", q, { ok = err == nil, error = err })
	end)
end

ops.ask = function(cx, pane, q, host_pane)
	local key = link.payload_key(host_pane)
	local ok, payload = pcall(tern.kv.get, key)
	if not ok or type(payload) ~= "table" or tonumber(payload.req) ~= tonumber(q.req) or type(payload.prompt) ~= "string" then
		answer(cx, pane, "ask", q, { error = "the request didn't reach this window" })
		return
	end
	pcall(tern.kv.set, key, nil)
	local agent = choose_agent(cx, pane, tonumber(payload.agent))
	local target: number
	local label: string
	if agent then
		target, label = agent.pane, agent_label(cx, agent, pane)
		local sent, err = pcall(function()
			cx.agents:ask(agent.pane, payload.prompt)
		end)
		if not sent then
			answer(cx, pane, "ask", q, { error = "couldn't hand the request to " .. label .. ": " .. tostring(err) })
			return
		end
	else
		local cwd = if type(payload.cwd) == "string" and payload.cwd ~= "" then payload.cwd else "~"
		local started, result = pcall(function(): number
			return cx.agents:start({ prompt = payload.prompt, cwd = cwd, how = "split" })
		end)
		if not started or type(result) ~= "number" then
			answer(cx, pane, "ask", q, { error = "there is no agent in this session and none could start: " .. tostring(result) })
			return
		end
		target, label = result, "a new agent"
	end
	answer(cx, pane, "ask", q, { progress = true, label = label, agent = target })
	cx.agents:wait(target, { timeout = AGENT_WAIT_MS }):next(function(text: string?, err: string?, fresh: WindowCx?)
		answer(fresh, pane, "ask", q, { text = text, error = err, agent = target, label = label })
	end)
end

tern.route.link(function(req: LinkRequest, cx: WindowCx): RouteDecision?
	local op, q = link.parse(req.url)
	if not op then
		return nil
	end
	local host_pane = tonumber(q.pane)
	local pane = if host_pane then block_pane(cx, host_pane) else nil
	local handler = ops[op]
	-- Only a Databases block gets answers: a link printed elsewhere can't read a password.
	if pane and host_pane and handler then
		handler(cx, pane, q, host_pane)
	end
	return { handled = true }
end)

tern.command({
	id = "open",
	title = "Databases",
	icon = "database",
	keys = { "cmd+alt+shift+d" },
	run = function(cx: WindowCx)
		local focused = cx.session:focused()
		local tab = if focused then cx.session:tab_of(focused) else nil
		local elsewhere: PaneInfo? = nil
		for _, p in cx.session:panes() do
			if p.block == KIND then
				if p.tab == tab and not p.parked then
					cx.layout:focus(p.pane)
					return
				end
				elsewhere = elsewhere or p
			end
		end
		if elsewhere then
			if elsewhere.parked then
				cx.layout:unpark(elsewhere.pane)
			else
				cx.layout:focus(elsewhere.pane)
			end
			return
		end
		cx:new_block(KIND, {}, "beside")
	end,
})
