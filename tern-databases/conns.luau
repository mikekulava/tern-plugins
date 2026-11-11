--!strict
-- Saved connections: everything but the password, in tern.kv "connections", shared by every
-- Databases block and window. A connection's password lives in the system keychain as the
-- plugin secret "conn.<id>" (see window.luau); `secret` says one is stored.

export type Conn = {
	id: string,
	name: string,
	kind: string,
	host: string?,
	port: number?,
	database: string?,
	user: string?,
	sslmode: string?,
	path: string?,
	catalog: string?,
	schema: string?,
	db: number?,
	tls: boolean?,
	insecure: boolean?,
	secret: boolean?,
}

export type Kind = {
	id: string,
	label: string,
	icon: string,
	port: number?,
	dialect: string,
	-- The form's fields, in order.
	fields: { string },
}

local conns = {}

local KEY = "connections"

conns.KINDS = {
	{ id = "postgres", label = "PostgreSQL", icon = "database", port = 5432, dialect = "postgres",
		fields = { "name", "host", "port", "database", "user", "password", "sslmode" } },
	{ id = "sqlite", label = "SQLite", icon = "file", dialect = "sqlite", fields = { "name", "path" } },
	{ id = "trino", label = "Trino", icon = "server", port = 8080, dialect = "trino",
		fields = { "name", "host", "port", "catalog", "schema", "user", "password", "tls" } },
	{ id = "redis", label = "Redis", icon = "key", port = 6379, dialect = "redis",
		fields = { "name", "host", "port", "user", "password", "db", "tls" } },
} :: { Kind }

conns.SSLMODES = { "disable", "prefer", "require", "verify-full" }

function conns.kind(id: string): Kind
	for _, k in conns.KINDS do
		if k.id == id then
			return k
		end
	end
	return conns.KINDS[1]
end

local function str(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

local function num(v: any): number?
	local n = tonumber(v)
	if n and n == math.floor(n) and n >= 0 then
		return n
	end
	return nil
end

-- A stored entry as a Conn; nil for anything malformed.
function conns.read(v: any): Conn?
	if type(v) ~= "table" or not str(v.id) or not string.match(v.id, "^[a-z0-9][a-z0-9_-]*$") then
		return nil
	end
	local kind = str(v.kind)
	if kind ~= "postgres" and kind ~= "sqlite" and kind ~= "trino" and kind ~= "redis" then
		return nil
	end
	return {
		id = v.id,
		name = str(v.name) or v.id,
		kind = kind :: string,
		host = str(v.host),
		port = num(v.port),
		database = str(v.database),
		user = str(v.user),
		sslmode = str(v.sslmode),
		path = str(v.path),
		catalog = str(v.catalog),
		schema = str(v.schema),
		db = num(v.db),
		tls = if v.tls == true then true else nil,
		insecure = if v.insecure == true then true else nil,
		secret = if v.secret == true then true else nil,
	}
end

function conns.load(): { Conn }
	local ok, raw = pcall(tern.kv.get, KEY)
	local out: { Conn } = {}
	if ok and type(raw) == "table" then
		for _, v in raw do
			local c = conns.read(v)
			if c then
				table.insert(out, c)
			end
		end
	end
	return out
end

function conns.store(list: { Conn }): string?
	local ok, err = pcall(function(): any
		tern.kv.set(KEY, tern.json.array(list))
		return nil
	end)
	return if ok then nil else tostring(err)
end

function conns.find(list: { Conn }, id: string?): Conn?
	for _, c in list do
		if c.id == id then
			return c
		end
	end
	return nil
end

-- Replaces the entry with `c.id` (or appends it) in the stored list, read fresh so another
-- window's edits survive. Returns the stored list, or nil and the error.
function conns.put(c: Conn): ({ Conn }?, string?)
	local list = conns.load()
	local done = false
	for i, old in list do
		if old.id == c.id then
			list[i] = c
			done = true
		end
	end
	if not done then
		table.insert(list, c)
	end
	local err = conns.store(list)
	return if err then nil else list, err
end

function conns.remove(id: string): ({ Conn }?, string?)
	local list = conns.load()
	local kept: { Conn } = {}
	for _, c in list do
		if c.id ~= id then
			table.insert(kept, c)
		end
	end
	local err = conns.store(kept)
	return if err then nil else kept, err
end

local seq = 0
function conns.new_id(): string
	seq += 1
	return string.format("c%x%x%03x", os.time(), seq, math.random(0, 4095))
end

function conns.secret_name(id: string): string
	return "conn." .. id
end

local function home_short(path: string): string
	local home = tern.getenv("HOME")
	if home and home ~= "" and string.sub(path, 1, #home + 1) == home .. "/" then
		return "~" .. string.sub(path, #home + 1)
	end
	return path
end
conns.home_short = home_short

-- Where it points, in one line: host:port/database, the file, catalog.schema.
function conns.detail(c: Conn): string
	if c.kind == "sqlite" then
		return home_short(c.path or "no file")
	end
	local k = conns.kind(c.kind)
	local host = c.host or "localhost"
	local where = host
	if c.port and c.port ~= k.port and not (c.kind == "trino" and c.tls and c.port == 443) then
		where ..= ":" .. tostring(c.port)
	end
	if c.kind == "postgres" and c.database then
		where ..= "/" .. c.database
	elseif c.kind == "trino" and c.catalog then
		where ..= "/" .. c.catalog .. (if c.schema then "." .. c.schema else "")
	elseif c.kind == "redis" and c.db and c.db ~= 0 then
		where ..= "/" .. tostring(c.db)
	end
	if c.user and c.kind ~= "redis" then
		where = c.user .. "@" .. where
	end
	return where
end

-- What the driver needs to connect: the connection without its name and id.
function conns.wire(c: Conn): { [string]: any }
	return {
		kind = c.kind,
		host = c.host,
		port = c.port,
		database = c.database,
		user = c.user,
		sslmode = c.sslmode,
		path = c.path,
		catalog = c.catalog,
		schema = c.schema,
		db = c.db,
		tls = c.tls,
		insecure = c.insecure,
	}
end

local function unescape(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h: string): string
		return string.char(tonumber(h, 16) :: number)
	end))
end

export type Parsed = {
	kind: string,
	host: string?,
	port: number?,
	database: string?,
	user: string?,
	password: string?,
	sslmode: string?,
	path: string?,
	catalog: string?,
	schema: string?,
	db: number?,
	tls: boolean?,
}

-- A connection URL as fields: postgres://user:pass@host:5432/db?sslmode=require,
-- redis://user:pass@host:6379/0, rediss://… (TLS), trino://user@host:443/catalog/schema,
-- sqlite:///path/to/file.db. Nil when `text` is not such a URL.
function conns.parse_url(text: string): Parsed?
	local scheme, rest = string.match(string.gsub(text, "^%s+", ""), "^(%a[%w+.-]*)://(.*)$")
	if not scheme or not rest then
		return nil
	end
	scheme = string.lower(scheme)
	rest = string.gsub(rest, "%s+$", "")
	if scheme == "sqlite" or scheme == "file" then
		local path = unescape(string.match(rest, "^([^?#]*)") or "")
		if string.sub(path, 1, 1) ~= "/" then
			path = "/" .. path
		end
		return { kind = "sqlite", path = path }
	end
	local kind = if scheme == "postgres" or scheme == "postgresql" then "postgres"
		elseif scheme == "redis" or scheme == "rediss" then "redis"
		elseif scheme == "trino" or scheme == "presto" then "trino"
		else nil
	if not kind then
		return nil
	end
	local out: Parsed = { kind = kind :: string }
	local query = string.match(rest, "%?(.*)$") or ""
	rest = string.match(rest, "^([^?#]*)") or ""
	local auth, hostpart = string.match(rest, "^(.*)@([^@]*)$")
	if not auth then
		hostpart = rest
	end
	if auth then
		local user, pass = string.match(auth, "^([^:]*):(.*)$")
		if user then
			out.user = if user ~= "" then unescape(user) else nil
			out.password = if pass ~= "" then unescape(pass :: string) else nil
		else
			out.user = if auth ~= "" then unescape(auth) else nil
		end
	end
	local hostport, path = string.match(hostpart or "", "^([^/]*)/?(.*)$")
	local host, port = string.match(hostport or "", "^%[(.-)%]:?(%d*)$")
	if not host then
		host, port = string.match(hostport or "", "^([^:]*):?(%d*)$")
	end
	out.host = if host and host ~= "" then unescape(host) else nil
	out.port = tonumber(port)
	local parts: { string } = {}
	for p in string.gmatch(path or "", "[^/]+") do
		table.insert(parts, unescape(p))
	end
	if kind == "postgres" then
		out.database = parts[1]
	elseif kind == "redis" then
		out.db = tonumber(parts[1])
		out.tls = scheme == "rediss" or nil
	else
		out.catalog, out.schema = parts[1], parts[2]
	end
	for k, v in string.gmatch(query, "([^&=]+)=([^&]*)") do
		k = unescape(k)
		v = unescape(v :: string)
		if k == "sslmode" then
			out.sslmode = v
		elseif (k == "ssl" or k == "tls" or k == "SSL") and (v == "true" or v == "1") then
			out.tls = true
		elseif k == "user" then
			out.user = v
		elseif k == "password" then
			out.password = v
		elseif k == "dbname" then
			out.database = v
		elseif k == "catalog" then
			out.catalog = v
		elseif k == "schema" then
			out.schema = v
		end
	end
	if kind == "trino" and out.port == 443 then
		out.tls = true
	end
	return out
end

return conns
