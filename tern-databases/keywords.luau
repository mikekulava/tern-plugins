--!strict
-- What completion offers besides the schema: SQL keywords and functions by dialect, and Redis
-- commands with their arguments.

local keywords = {}

local function words(s: string): { string }
	local out: { string } = {}
	for w in string.gmatch(s, "%S+") do
		table.insert(out, w)
	end
	return out
end

-- Keywords that begin a statement, offered first at its start.
keywords.STARTS = {
	common = words("SELECT WITH INSERT UPDATE DELETE CREATE ALTER DROP EXPLAIN SHOW VALUES"),
	postgres = words("TRUNCATE BEGIN COMMIT ROLLBACK GRANT REVOKE COPY VACUUM ANALYZE SET RESET REFRESH COMMENT DO CALL MERGE LISTEN NOTIFY DISCARD"),
	sqlite = words("REPLACE PRAGMA BEGIN COMMIT ROLLBACK ATTACH DETACH VACUUM ANALYZE REINDEX SAVEPOINT RELEASE"),
	trino = words("DESCRIBE USE MERGE PREPARE EXECUTE DEALLOCATE TRUNCATE GRANT REVOKE CALL START COMMIT ROLLBACK RESET SET"),
}

keywords.SQL = words([[
	SELECT FROM WHERE AND OR NOT IN IS NULL LIKE ILIKE BETWEEN EXISTS AS ON JOIN INNER LEFT RIGHT FULL
	OUTER CROSS NATURAL USING GROUP BY ORDER HAVING LIMIT OFFSET FETCH FIRST NEXT ROWS ROW ONLY UNION ALL
	INTERSECT EXCEPT DISTINCT CASE WHEN THEN ELSE END ASC DESC NULLS LAST INSERT INTO VALUES DEFAULT
	UPDATE SET DELETE RETURNING WITH RECURSIVE CREATE TABLE VIEW INDEX UNIQUE PRIMARY KEY FOREIGN
	REFERENCES CHECK CONSTRAINT ALTER ADD COLUMN RENAME TO DROP IF CASCADE RESTRICT TRUE FALSE CAST
	OVER PARTITION WINDOW FILTER LATERAL TEMPORARY TEMP SCHEMA DATABASE EXPLAIN ANALYZE BEGIN COMMIT
	ROLLBACK TRANSACTION CONFLICT DO NOTHING TRUNCATE MATERIALIZED GRANT REVOKE ESCAPE SIMILAR ANY SOME
	INTERVAL DATE TIME TIMESTAMP ZONE AT
]])

keywords.FUNCTIONS = {
	common = words([[
		count sum avg min max coalesce nullif greatest least abs round ceil floor mod power sqrt
		length lower upper trim ltrim rtrim substr substring replace concat position
		row_number rank dense_rank lag lead first_value last_value ntile cume_dist percent_rank
		cast current_date current_timestamp
	]]),
	postgres = words([[
		now date_trunc date_part extract age to_char to_date to_timestamp to_number make_date
		make_interval generate_series string_agg array_agg json_agg jsonb_agg json_build_object
		jsonb_build_object jsonb_set jsonb_array_elements jsonb_each jsonb_object_keys json_extract_path_text
		to_jsonb row_to_json array_length array_to_string string_to_array unnest regexp_replace regexp_match
		regexp_matches split_part left right lpad rpad initcap md5 gen_random_uuid format quote_ident
		quote_literal pg_size_pretty pg_total_relation_size pg_relation_size pg_database_size pg_sleep
		pg_cancel_backend pg_terminate_backend current_setting set_config version current_user
		current_schema current_database clock_timestamp statement_timestamp bool_and bool_or every
		percentile_cont percentile_disc mode stddev variance corr width_bucket random trunc
	]]),
	sqlite = words([[
		ifnull iif instr printf format hex unhex quote random randomblob zeroblob typeof unicode char
		date time datetime julianday unixepoch strftime group_concat total json json_extract json_array
		json_object json_each json_tree json_group_array json_group_object json_insert json_set json_remove
		json_type json_valid last_insert_rowid changes total_changes sqlite_version likelihood glob
	]]),
	trino = words([[
		approx_distinct approx_percentile arbitrary array_agg map_agg histogram count_if bool_and bool_or
		date_trunc date_add date_diff date_format date_parse from_unixtime to_unixtime from_iso8601_timestamp
		current_timezone localtime localtimestamp now year month day hour minute second day_of_week week
		cardinality contains element_at filter transform reduce zip array_join array_distinct sequence
		split split_part regexp_like regexp_extract regexp_replace json_extract json_extract_scalar
		json_format json_parse json_array_length try try_cast typeof format format_datetime to_hex
		from_hex md5 sha256 xxhash64 uuid random rand truncate strpos starts_with levenshtein_distance
		map map_keys map_values listagg max_by min_by stddev variance corr
	]]),
}

-- Data types, offered after CAST(… AS, ::, and in CREATE TABLE.
keywords.TYPES = {
	postgres = words([[
		integer bigint smallint numeric decimal real double text varchar char boolean date time timestamp
		timestamptz interval uuid json jsonb bytea serial bigserial inet cidr money
	]]),
	sqlite = words("INTEGER REAL TEXT BLOB NUMERIC"),
	trino = words([[
		boolean tinyint smallint integer bigint real double decimal varchar char varbinary json date time
		timestamp array map row uuid ipaddress
	]]),
}

export type Command = { name: string, args: string, group: string, key: number? }

-- Redis commands: `args` is the syntax shown beside the name; `key` is the position of the
-- first key argument (1 for most), nil for commands that take none.
local function cmd(name: string, args: string, group: string, key: number?): Command
	return { name = name, args = args, group = group, key = key }
end

local REDIS: { Command } = {
	cmd("GET", "key", "string", 1),
	cmd("SET", "key value [EX seconds | PX ms | KEEPTTL] [NX | XX] [GET]", "string", 1),
	cmd("MGET", "key [key …]", "string", 1),
	cmd("MSET", "key value [key value …]", "string", 1),
	cmd("SETNX", "key value", "string", 1),
	cmd("SETEX", "key seconds value", "string", 1),
	cmd("GETSET", "key value", "string", 1),
	cmd("GETDEL", "key", "string", 1),
	cmd("GETEX", "key [EX seconds | PX ms | PERSIST]", "string", 1),
	cmd("GETRANGE", "key start end", "string", 1),
	cmd("SETRANGE", "key offset value", "string", 1),
	cmd("APPEND", "key value", "string", 1),
	cmd("STRLEN", "key", "string", 1),
	cmd("INCR", "key", "string", 1),
	cmd("INCRBY", "key increment", "string", 1),
	cmd("INCRBYFLOAT", "key increment", "string", 1),
	cmd("DECR", "key", "string", 1),
	cmd("DECRBY", "key decrement", "string", 1),
	cmd("DEL", "key [key …]", "keys", 1),
	cmd("UNLINK", "key [key …]", "keys", 1),
	cmd("EXISTS", "key [key …]", "keys", 1),
	cmd("TYPE", "key", "keys", 1),
	cmd("TTL", "key", "keys", 1),
	cmd("PTTL", "key", "keys", 1),
	cmd("EXPIRE", "key seconds [NX | XX | GT | LT]", "keys", 1),
	cmd("PEXPIRE", "key ms [NX | XX | GT | LT]", "keys", 1),
	cmd("EXPIREAT", "key unix-time", "keys", 1),
	cmd("PERSIST", "key", "keys", 1),
	cmd("RENAME", "key newkey", "keys", 1),
	cmd("RENAMENX", "key newkey", "keys", 1),
	cmd("COPY", "source destination [DB db] [REPLACE]", "keys", 1),
	cmd("DUMP", "key", "keys", 1),
	cmd("TOUCH", "key [key …]", "keys", 1),
	cmd("OBJECT", "ENCODING | FREQ | IDLETIME | REFCOUNT key", "keys", 2),
	cmd("MEMORY", "USAGE key [SAMPLES count]", "server", 2),
	cmd("KEYS", "pattern", "keys"),
	cmd("SCAN", "cursor [MATCH pattern] [COUNT count] [TYPE type]", "keys"),
	cmd("RANDOMKEY", "", "keys"),
	cmd("HGET", "key field", "hash", 1),
	cmd("HSET", "key field value [field value …]", "hash", 1),
	cmd("HSETNX", "key field value", "hash", 1),
	cmd("HMGET", "key field [field …]", "hash", 1),
	cmd("HMSET", "key field value [field value …]", "hash", 1),
	cmd("HGETALL", "key", "hash", 1),
	cmd("HDEL", "key field [field …]", "hash", 1),
	cmd("HEXISTS", "key field", "hash", 1),
	cmd("HINCRBY", "key field increment", "hash", 1),
	cmd("HINCRBYFLOAT", "key field increment", "hash", 1),
	cmd("HKEYS", "key", "hash", 1),
	cmd("HVALS", "key", "hash", 1),
	cmd("HLEN", "key", "hash", 1),
	cmd("HSTRLEN", "key field", "hash", 1),
	cmd("HRANDFIELD", "key [count [WITHVALUES]]", "hash", 1),
	cmd("HSCAN", "key cursor [MATCH pattern] [COUNT count]", "hash", 1),
	cmd("LPUSH", "key element [element …]", "list", 1),
	cmd("RPUSH", "key element [element …]", "list", 1),
	cmd("LPUSHX", "key element [element …]", "list", 1),
	cmd("RPUSHX", "key element [element …]", "list", 1),
	cmd("LPOP", "key [count]", "list", 1),
	cmd("RPOP", "key [count]", "list", 1),
	cmd("LRANGE", "key start stop", "list", 1),
	cmd("LLEN", "key", "list", 1),
	cmd("LINDEX", "key index", "list", 1),
	cmd("LSET", "key index element", "list", 1),
	cmd("LINSERT", "key BEFORE | AFTER pivot element", "list", 1),
	cmd("LREM", "key count element", "list", 1),
	cmd("LTRIM", "key start stop", "list", 1),
	cmd("LPOS", "key element [RANK rank] [COUNT n] [MAXLEN len]", "list", 1),
	cmd("LMOVE", "source destination LEFT | RIGHT LEFT | RIGHT", "list", 1),
	cmd("BLPOP", "key [key …] timeout", "list", 1),
	cmd("BRPOP", "key [key …] timeout", "list", 1),
	cmd("SADD", "key member [member …]", "set", 1),
	cmd("SREM", "key member [member …]", "set", 1),
	cmd("SMEMBERS", "key", "set", 1),
	cmd("SISMEMBER", "key member", "set", 1),
	cmd("SMISMEMBER", "key member [member …]", "set", 1),
	cmd("SCARD", "key", "set", 1),
	cmd("SPOP", "key [count]", "set", 1),
	cmd("SRANDMEMBER", "key [count]", "set", 1),
	cmd("SINTER", "key [key …]", "set", 1),
	cmd("SUNION", "key [key …]", "set", 1),
	cmd("SDIFF", "key [key …]", "set", 1),
	cmd("SINTERSTORE", "destination key [key …]", "set", 1),
	cmd("SUNIONSTORE", "destination key [key …]", "set", 1),
	cmd("SDIFFSTORE", "destination key [key …]", "set", 1),
	cmd("SMOVE", "source destination member", "set", 1),
	cmd("SSCAN", "key cursor [MATCH pattern] [COUNT count]", "set", 1),
	cmd("ZADD", "key [NX | XX] [GT | LT] [CH] [INCR] score member [score member …]", "sorted set", 1),
	cmd("ZRANGE", "key start stop [BYSCORE | BYLEX] [REV] [LIMIT offset count] [WITHSCORES]", "sorted set", 1),
	cmd("ZREVRANGE", "key start stop [WITHSCORES]", "sorted set", 1),
	cmd("ZRANGEBYSCORE", "key min max [WITHSCORES] [LIMIT offset count]", "sorted set", 1),
	cmd("ZREVRANGEBYSCORE", "key max min [WITHSCORES] [LIMIT offset count]", "sorted set", 1),
	cmd("ZSCORE", "key member", "sorted set", 1),
	cmd("ZMSCORE", "key member [member …]", "sorted set", 1),
	cmd("ZRANK", "key member [WITHSCORE]", "sorted set", 1),
	cmd("ZREVRANK", "key member [WITHSCORE]", "sorted set", 1),
	cmd("ZINCRBY", "key increment member", "sorted set", 1),
	cmd("ZREM", "key member [member …]", "sorted set", 1),
	cmd("ZCARD", "key", "sorted set", 1),
	cmd("ZCOUNT", "key min max", "sorted set", 1),
	cmd("ZPOPMIN", "key [count]", "sorted set", 1),
	cmd("ZPOPMAX", "key [count]", "sorted set", 1),
	cmd("ZREMRANGEBYSCORE", "key min max", "sorted set", 1),
	cmd("ZREMRANGEBYRANK", "key start stop", "sorted set", 1),
	cmd("ZSCAN", "key cursor [MATCH pattern] [COUNT count]", "sorted set", 1),
	cmd("XADD", "key [NOMKSTREAM] [MAXLEN | MINID [= | ~] threshold] * | id field value [field value …]", "stream", 1),
	cmd("XRANGE", "key start end [COUNT count]", "stream", 1),
	cmd("XREVRANGE", "key end start [COUNT count]", "stream", 1),
	cmd("XLEN", "key", "stream", 1),
	cmd("XREAD", "[COUNT count] STREAMS key [key …] id [id …]", "stream"),
	cmd("XDEL", "key id [id …]", "stream", 1),
	cmd("XTRIM", "key MAXLEN | MINID [= | ~] threshold", "stream", 1),
	cmd("XINFO", "STREAM | GROUPS | CONSUMERS key", "stream", 2),
	cmd("XGROUP", "CREATE | DESTROY | SETID key group …", "stream", 2),
	cmd("XACK", "key group id [id …]", "stream", 1),
	cmd("XPENDING", "key group [start end count]", "stream", 1),
	cmd("PFADD", "key [element …]", "hyperloglog", 1),
	cmd("PFCOUNT", "key [key …]", "hyperloglog", 1),
	cmd("PFMERGE", "destkey [sourcekey …]", "hyperloglog", 1),
	cmd("SETBIT", "key offset value", "bitmap", 1),
	cmd("GETBIT", "key offset", "bitmap", 1),
	cmd("BITCOUNT", "key [start end [BYTE | BIT]]", "bitmap", 1),
	cmd("GEOADD", "key [NX | XX] longitude latitude member [… ]", "geo", 1),
	cmd("GEOPOS", "key member [member …]", "geo", 1),
	cmd("GEODIST", "key member1 member2 [M | KM | FT | MI]", "geo", 1),
	cmd("GEOSEARCH", "key FROMMEMBER member | FROMLONLAT lon lat BYRADIUS r unit | BYBOX w h unit", "geo", 1),
	cmd("JSON.GET", "key [path …]", "json", 1),
	cmd("JSON.SET", "key path value [NX | XX]", "json", 1),
	cmd("PUBLISH", "channel message", "pubsub"),
	cmd("PUBSUB", "CHANNELS | NUMSUB | NUMPAT [pattern]", "pubsub"),
	cmd("MULTI", "", "transactions"),
	cmd("EXEC", "", "transactions"),
	cmd("DISCARD", "", "transactions"),
	cmd("WATCH", "key [key …]", "transactions", 1),
	cmd("EVAL", "script numkeys [key …] [arg …]", "scripting"),
	cmd("EVALSHA", "sha1 numkeys [key …] [arg …]", "scripting"),
	cmd("FCALL", "function numkeys [key …] [arg …]", "scripting"),
	cmd("PING", "[message]", "connection"),
	cmd("ECHO", "message", "connection"),
	cmd("SELECT", "index", "connection"),
	cmd("CLIENT", "LIST | INFO | KILL | SETNAME | GETNAME …", "connection"),
	cmd("INFO", "[section …]", "server"),
	cmd("DBSIZE", "", "server"),
	cmd("TIME", "", "server"),
	cmd("LASTSAVE", "", "server"),
	cmd("CONFIG", "GET parameter | SET parameter value | RESETSTAT", "server"),
	cmd("SLOWLOG", "GET [count] | LEN | RESET", "server"),
	cmd("LATENCY", "LATEST | HISTORY event | RESET", "server"),
	cmd("COMMAND", "[COUNT | DOCS | INFO | LIST …]", "server"),
	cmd("FLUSHDB", "[ASYNC | SYNC]", "server"),
	cmd("FLUSHALL", "[ASYNC | SYNC]", "server"),
	cmd("BGSAVE", "[SCHEDULE]", "server"),
	cmd("SAVE", "", "server"),
	cmd("ACL", "WHOAMI | LIST | USERS | CAT …", "server"),
	cmd("MODULE", "LIST", "server"),
}
keywords.REDIS = REDIS

-- Option words a command takes after its key, offered after it.
local REDIS_OPTIONS: { [string]: { string } } = {
	SET = words("EX PX EXAT PXAT NX XX KEEPTTL GET"),
	GETEX = words("EX PX EXAT PXAT PERSIST"),
	EXPIRE = words("NX XX GT LT"),
	PEXPIRE = words("NX XX GT LT"),
	SCAN = words("MATCH COUNT TYPE"),
	HSCAN = words("MATCH COUNT NOVALUES"),
	SSCAN = words("MATCH COUNT"),
	ZSCAN = words("MATCH COUNT"),
	ZRANGE = words("BYSCORE BYLEX REV LIMIT WITHSCORES"),
	ZREVRANGE = words("WITHSCORES"),
	ZRANGEBYSCORE = words("WITHSCORES LIMIT"),
	ZREVRANGEBYSCORE = words("WITHSCORES LIMIT"),
	ZADD = words("NX XX GT LT CH INCR"),
	XRANGE = words("COUNT"),
	XREVRANGE = words("COUNT"),
	XREAD = words("COUNT BLOCK STREAMS"),
	LINSERT = words("BEFORE AFTER"),
	LPOS = words("RANK COUNT MAXLEN"),
	OBJECT = words("ENCODING FREQ IDLETIME REFCOUNT"),
	MEMORY = words("USAGE STATS DOCTOR"),
	CLIENT = words("LIST INFO KILL SETNAME GETNAME ID PAUSE UNPAUSE"),
	CONFIG = words("GET SET RESETSTAT REWRITE"),
	INFO = words("server clients memory persistence stats replication cpu commandstats keyspace all everything"),
	SLOWLOG = words("GET LEN RESET"),
	XINFO = words("STREAM GROUPS CONSUMERS"),
	FLUSHDB = words("ASYNC SYNC"),
	FLUSHALL = words("ASYNC SYNC"),
	ACL = words("WHOAMI LIST USERS CAT GETUSER"),
	HRANDFIELD = words("WITHVALUES"),
	COPY = words("DB REPLACE"),
	BITCOUNT = words("BYTE BIT"),
}
keywords.REDIS_OPTIONS = REDIS_OPTIONS

-- SQL words that are reserved: a column or table with such a name is quoted on insert.
keywords.RESERVED = {} :: { [string]: boolean }
for _, w in words([[
	ALL AND ANY ARRAY AS ASC BETWEEN BOTH CASE CAST CHECK COLLATE COLUMN CONSTRAINT CREATE CROSS CURRENT_DATE
	CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER DEFAULT DESC DISTINCT DO ELSE END EXCEPT FALSE FETCH FOR
	FOREIGN FROM FULL GRANT GROUP HAVING IN INNER INTERSECT INTO IS JOIN LEADING LEFT LIKE LIMIT LOCALTIME
	NATURAL NOT NULL OFFSET ON ONLY OR ORDER OUTER PRIMARY REFERENCES RIGHT SELECT SESSION_USER SOME TABLE
	THEN TO TRAILING TRUE UNION UNIQUE USER USING VALUES WHEN WHERE WINDOW WITH
]]) do
	keywords.RESERVED[w] = true
end

return keywords
