--!strict
-- The protocol between a Databases block (host.luau) and the window half (window.luau).
--
-- Host halves have no keychain and no agents, so the window does that work: the block asks
-- with cx:open(link.build(op, query)), a "databases:<op>?<query>" link that only this plugin's
-- window claims, and the window answers with cx.session:event(pane, { ev = "action",
-- act = link.ACT, json = … }). Every query names the block's pane and its request number
-- `req`, echoed in the answer, so the block drops stale answers and a second window's copies.
--
-- Links never carry a secret. To store a password the window reads it from the block's own
-- masked field (its surface); a stored password goes back only inside the answer event.

local link = {}

link.SCHEME = "databases:"
link.ACT = "databases.answer"

function link.encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end))
end

function link.decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h: string): string
		return string.char(tonumber(h, 16) :: number)
	end))
end

function link.build(op: string, query: { [string]: string | number }): string
	local keys: { string } = {}
	for k in query do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, k in keys do
		table.insert(parts, link.encode(k) .. "=" .. link.encode(tostring(query[k])))
	end
	return link.SCHEME .. op .. (if #parts > 0 then "?" .. table.concat(parts, "&") else "")
end

-- The op and query of one of our links; nil for any other URL.
function link.parse(url: string): (string?, { [string]: string })
	local query: { [string]: string } = {}
	if string.sub(url, 1, #link.SCHEME) ~= link.SCHEME then
		return nil, query
	end
	local op, rest = string.match(string.sub(url, #link.SCHEME + 1), "^([%w%-]+)%??(.*)$")
	if not op then
		return nil, query
	end
	for pair in string.gmatch(rest or "", "[^&]+") do
		local k, v = string.match(pair, "^([^=]*)=?(.*)$")
		if k and k ~= "" then
			query[link.decode(k)] = link.decode(v or "")
		end
	end
	return op, query
end

-- The tern.kv key holding a block's request text for the window (an agent prompt).
function link.payload_key(pane: number): string
	return "request." .. tostring(pane)
end

return link
