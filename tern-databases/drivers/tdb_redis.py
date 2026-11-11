"""Redis over RESP2 with the standard library only.

A run sends one command per line, parsed the way redis-cli parses its
arguments ("double quotes" with escapes, 'single quotes' literally), and
shows each reply: scalars as text, collections as tables, a few commands
(HGETALL, ZRANGE … WITHSCORES, XRANGE, INFO, SCAN) in their own columns.
Commands that never return (SUBSCRIBE, MONITOR) are refused."""

import json
import socket
import ssl
import time

from tdb_common import MAX_CELL, Cancel, Cancelled, DriverError, column, elapsed_since, result, wait_readable

CONNECT_TIMEOUT = 10
REFUSED = {"SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR", "SYNC", "PSYNC", "RESET"}
MAX_ITEMS = 2000


class ReplyError(Exception):
    pass


def text(value):
    """Bytes as text: UTF-8 when it is, else redis-cli's escapes."""
    if value is None:
        return None
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        out = value
    else:
        try:
            out = value.decode("utf-8")
        except UnicodeDecodeError:
            out = "".join(chr(b) if 32 <= b < 127 and b != 92 else "\\x%02x" % b for b in value)
    return out if len(out) <= MAX_CELL else out[:MAX_CELL] + "…"


def tokenize(line):
    """redis-cli's argument rules: whitespace splits, "…" takes \\n \\r \\t
    \\b \\a \\\\ \\" and \\xHH, '…' takes only \\'."""
    args, i, n = [], 0, len(line)
    while True:
        while i < n and line[i].isspace():
            i += 1
        if i >= n:
            return args
        buf = bytearray()
        if line[i] == '"':
            i += 1
            while True:
                if i >= n:
                    raise DriverError("Unbalanced quotes in: " + line)
                ch = line[i]
                if ch == "\\" and i + 1 < n:
                    nxt = line[i + 1]
                    if nxt == "x" and i + 3 < n and all(c in "0123456789abcdefABCDEF" for c in line[i + 2:i + 4]):
                        buf.append(int(line[i + 2:i + 4], 16))
                        i += 4
                        continue
                    buf += {"n": b"\n", "r": b"\r", "t": b"\t", "b": b"\b", "a": b"\a"}.get(nxt, nxt.encode())
                    i += 2
                    continue
                if ch == '"':
                    i += 1
                    break
                buf += ch.encode("utf-8")
                i += 1
        elif line[i] == "'":
            i += 1
            while True:
                if i >= n:
                    raise DriverError("Unbalanced quotes in: " + line)
                ch = line[i]
                if ch == "\\" and i + 1 < n and line[i + 1] == "'":
                    buf += b"'"
                    i += 2
                    continue
                if ch == "'":
                    i += 1
                    break
                buf += ch.encode("utf-8")
                i += 1
        else:
            while i < n and not line[i].isspace():
                buf += line[i].encode("utf-8")
                i += 1
            args.append(bytes(buf))
            continue
        if i < n and not line[i].isspace():
            raise DriverError("A closing quote must be followed by a space in: " + line)
        args.append(bytes(buf))


class Client:
    def __init__(self, cfg, password):
        self.host = (cfg.get("host") or "localhost").strip()
        self.port = int(cfg.get("port") or 6379)
        self.tls = bool(cfg.get("tls"))
        try:
            sock = socket.create_connection((self.host, self.port), timeout=CONNECT_TIMEOUT)
        except OSError as e:
            raise DriverError("Cannot reach %s:%d: %s" % (self.host, self.port, e.strerror or e))
        if self.tls:
            ctx = ssl.create_default_context()
            if cfg.get("insecure"):
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
            try:
                sock = ctx.wrap_socket(sock, server_hostname=self.host)
            except ssl.SSLCertVerificationError as e:
                raise DriverError("The server's certificate is not trusted: %s" % (e.verify_message or e),
                                  hint="Turn off certificate checks for this connection only if you trust the network")
            except (ssl.SSLError, OSError) as e:
                raise DriverError("The TLS handshake failed: %s" % e)
        sock.settimeout(None)
        self.sock = sock
        self.buf = bytearray()
        self.pos = 0
        user = (cfg.get("user") or "").strip()
        if password:
            try:
                self.call(*(["AUTH", user, password] if user else ["AUTH", password]))
            except ReplyError as e:
                raise DriverError("Redis refused the login: %s" % e,
                                  hint="Edit the connection and check its user and password")
        db = int(cfg.get("db") or 0)
        if db:
            try:
                self.call("SELECT", str(db))
            except ReplyError as e:
                raise DriverError("Cannot select database %d: %s" % (db, e))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def _cancel(self):
        raise Cancelled(Cancel.why)

    def _fill(self):
        wait_readable(self.sock, self._cancel)
        try:
            chunk = self.sock.recv(262144)
        except ssl.SSLWantReadError:
            return
        except OSError as e:
            raise DriverError("Lost the connection to Redis: %s" % e)
        if not chunk:
            raise DriverError("Redis closed the connection")
        if self.pos > 1 << 20:
            del self.buf[: self.pos]
            self.pos = 0
        self.buf += chunk

    def _line(self):
        while True:
            end = self.buf.find(b"\r\n", self.pos)
            if end >= 0:
                line = bytes(self.buf[self.pos:end])
                self.pos = end + 2
                return line
            self._fill()

    def _exact(self, n):
        while len(self.buf) - self.pos < n + 2:
            self._fill()
        data = bytes(self.buf[self.pos:self.pos + n])
        self.pos += n + 2
        return data

    def _reply(self):
        line = self._line()
        kind, rest = line[:1], line[1:]
        if kind == b"+":
            return ("status", rest.decode("utf-8", "replace"))
        if kind == b"-":
            return ReplyError(rest.decode("utf-8", "replace"))
        if kind == b":":
            return int(rest)
        if kind == b"$":
            size = int(rest)
            return None if size < 0 else self._exact(size)
        if kind == b"*":
            size = int(rest)
            return None if size < 0 else [self._reply() for _ in range(size)]
        raise DriverError("Redis sent a reply this client cannot read: %r" % line[:40])

    def send(self, commands):
        payload = bytearray()
        for args in commands:
            payload += b"*%d\r\n" % len(args)
            for a in args:
                b = a if isinstance(a, bytes) else str(a).encode("utf-8")
                payload += b"$%d\r\n%s\r\n" % (len(b), b)
        try:
            self.sock.sendall(payload)
        except OSError as e:
            raise DriverError("Lost the connection to Redis: %s" % e)

    def call(self, *args):
        self.send([args])
        reply = self._reply()
        if isinstance(reply, ReplyError):
            raise reply
        return reply

    def pipeline(self, commands):
        self.send(commands)
        return [self._reply() for _ in commands]


def scalar(reply):
    if isinstance(reply, tuple):
        return reply[1]
    if reply is None:
        return "(nil)"
    if isinstance(reply, int):
        return "(integer) %d" % reply
    return text(reply)


def flat(reply):
    """A nested reply as one cell."""
    if isinstance(reply, list):
        return json.dumps([flat(r) for r in reply], ensure_ascii=False)
    if isinstance(reply, tuple):
        return reply[1]
    if isinstance(reply, ReplyError):
        return "(error) " + str(reply)
    return text(reply)


def pairs(items, left, right, numeric_right=False):
    rows = [[text(items[i]) if not isinstance(items[i], list) else flat(items[i]),
             flat(items[i + 1]) if i + 1 < len(items) else None] for i in range(0, len(items) - 1, 2)]
    return [column(left), column(right, None, numeric_right)], rows


def info_rows(blob):
    rows, section = [], ""
    for line in text(blob).splitlines():
        line = line.strip()
        if line.startswith("#"):
            section = line[1:].strip()
        elif ":" in line:
            k, _, v = line.partition(":")
            rows.append([section, k, v])
    return [column("section"), column("key"), column("value")], rows


def shape(args, reply):
    """(columns, rows) for a reply worth a table, else None."""
    name = args[0].upper().decode("utf-8", "replace") if args else ""
    flags = {a.upper() for a in args[1:]}
    if name == "INFO" and isinstance(reply, bytes):
        return info_rows(reply)
    if not isinstance(reply, list):
        return None
    if name in ("HGETALL", "CONFIG") or (name == "HRANDFIELD" and b"WITHVALUES" in flags):
        return pairs(reply, "field", "value")
    if name in ("ZRANGE", "ZREVRANGE", "ZRANGEBYSCORE", "ZREVRANGEBYSCORE", "ZRANDMEMBER", "ZPOPMIN",
                "ZPOPMAX", "ZUNION", "ZINTER", "ZDIFF") and (b"WITHSCORES" in flags or name in ("ZPOPMIN", "ZPOPMAX")):
        return pairs(reply, "member", "score", True)
    if name in ("XRANGE", "XREVRANGE"):
        rows = []
        for entry in reply:
            if isinstance(entry, list) and len(entry) == 2:
                fields = entry[1] or []
                rows.append([text(entry[0]), " ".join("%s=%s" % (text(fields[i]), flat(fields[i + 1]))
                                                     for i in range(0, len(fields) - 1, 2))])
        return [column("id"), column("fields")], rows
    if name in ("SCAN", "SSCAN", "HSCAN", "ZSCAN") and len(reply) == 2 and isinstance(reply[1], list):
        items = reply[1]
        if name == "HSCAN":
            cols, rows = pairs(items, "field", "value")
        elif name == "ZSCAN":
            cols, rows = pairs(items, "member", "score", True)
        else:
            cols, rows = [column("key" if name == "SCAN" else "member")], [[flat(i)] for i in items]
        return cols, rows
    if name == "MGET":
        keys = args[1:]
        return [column("key"), column("value")], [[text(keys[i]) if i < len(keys) else None, flat(v)]
                                                    for i, v in enumerate(reply)]
    return [column("#", None, True), column("value")], [[str(i + 1), flat(v)] for i, v in enumerate(reply)]


def run(client, statements, max_rows):
    results = []
    for index, line in enumerate(statements):
        if Cancel.requested():
            return results, Cancelled(Cancel.why)
        start = time.monotonic()
        try:
            args = tokenize(line)
        except DriverError as e:
            results.append(result(index, error=e.message, elapsed_ms=0))
            continue
        if not args:
            continue
        name = args[0].upper().decode("utf-8", "replace")
        if name in REFUSED:
            results.append(result(index, command=name, error="%s keeps the connection busy forever: "
                                  "use redis-cli in a terminal for it" % name, elapsed_ms=0))
            continue
        client.send([args])
        reply = client._reply()
        took = elapsed_since(start)
        if isinstance(reply, ReplyError):
            results.append(result(index, command=name, error=str(reply), elapsed_ms=took))
            continue
        table = shape(args, reply)
        if table is None:
            results.append(result(index, command=name, text=scalar(reply), elapsed_ms=took))
            continue
        cols, rows = table
        results.append(result(index, cols, rows[:max_rows], truncated=(len(rows) > max_rows) or None,
                              count=len(rows), command=name, elapsed_ms=took))
    return results, None


def server(client):
    try:
        info = text(client.call("INFO", "server")) or ""
    except ReplyError:
        return "Redis"
    for line in info.splitlines():
        if line.startswith("redis_version:"):
            return "Redis " + line.split(":", 1)[1].strip()
        if line.startswith("valkey_version:"):
            return "Valkey " + line.split(":", 1)[1].strip()
    return "Redis"


def keys(client, pattern, limit):
    """Up to `limit` keys matching `pattern`, with type and TTL, from SCAN."""
    found, cursor, start = set(), b"0", time.monotonic()
    complete = False
    while True:
        if Cancel.requested():
            raise Cancelled(Cancel.why)
        reply = client.call("SCAN", cursor, "MATCH", pattern or "*", "COUNT", "1000")
        cursor = reply[0]
        found.update(reply[1])
        if cursor == b"0":
            complete = True
            break
        if len(found) >= limit or time.monotonic() - start > 4:
            break
    names = sorted(found)[:limit]
    complete = complete and len(found) <= limit
    replies = client.pipeline([("TYPE", k) for k in names] + [("PTTL", k) for k in names]) if names else []
    out = []
    for i, k in enumerate(names):
        kind = replies[i]
        ttl = replies[len(names) + i]
        out.append({
            "key": text(k),
            "type": kind[1] if isinstance(kind, tuple) else "?",
            "ttl": ttl if isinstance(ttl, int) else -1,
        })
    try:
        size = client.call("DBSIZE")
    except ReplyError:
        size = None
    return {"keys": out, "complete": complete, "dbsize": size, "pattern": pattern or "*"}


def value(client, key):
    """The key's value as a table (or text), with its type, length and TTL."""
    k = key.encode("utf-8")
    kind_reply = client.call("TYPE", k)
    kind = kind_reply[1] if isinstance(kind_reply, tuple) else "none"
    ttl = client.call("PTTL", k)
    meta = {"key": key, "type": kind, "ttl": ttl}
    if kind == "none":
        return meta, result(0, text="(the key does not exist)")
    if kind == "string":
        data = client.call("GET", k)
        meta["length"] = len(data or b"")
        return meta, result(0, text=text(data))
    if kind == "hash":
        meta["length"] = client.call("HLEN", k)
        items, cursor = [], b"0"
        while True:
            cursor, batch = client.call("HSCAN", k, cursor, "COUNT", "500")
            items.extend(batch)
            if cursor == b"0" or len(items) >= MAX_ITEMS * 2:
                break
        cols, rows = pairs(items, "field", "value")
        rows.sort(key=lambda r: r[0] or "")
    elif kind == "list":
        meta["length"] = client.call("LLEN", k)
        items = client.call("LRANGE", k, "0", str(MAX_ITEMS - 1))
        cols, rows = [column("index", None, True), column("value")], [[str(i), flat(v)] for i, v in enumerate(items)]
    elif kind == "set":
        meta["length"] = client.call("SCARD", k)
        items, cursor = [], b"0"
        while True:
            cursor, batch = client.call("SSCAN", k, cursor, "COUNT", "500")
            items.extend(batch)
            if cursor == b"0" or len(items) >= MAX_ITEMS:
                break
        cols, rows = [column("member")], sorted([[flat(v)] for v in items], key=lambda r: r[0] or "")
    elif kind == "zset":
        meta["length"] = client.call("ZCARD", k)
        items = client.call("ZRANGE", k, "0", str(MAX_ITEMS - 1), "WITHSCORES")
        cols, rows = pairs(items, "member", "score", True)
    elif kind == "stream":
        meta["length"] = client.call("XLEN", k)
        cols, rows = shape([b"XRANGE"], client.call("XRANGE", k, "-", "+", "COUNT", str(MAX_ITEMS)))
    elif kind.startswith("ReJSON"):
        return meta, result(0, text=text(client.call("JSON.GET", k)))
    else:
        return meta, result(0, text="A %s: read it with its own commands in the console" % kind)
    truncated = (meta.get("length") or 0) > len(rows)
    return meta, result(0, cols, rows, truncated=truncated or None, count=len(rows))


def handle(req, password):
    client = Client(req.get("conn") or {}, password)
    try:
        op = req.get("op")
        if op == "test":
            client.call("PING")
            return {"ok": True, "server": server(client)}
        if op == "schema":
            return {"ok": True, "schema": {"server": server(client), "tables": [], "schemas": [], "functions": []}}
        if op == "keys":
            found = keys(client, req.get("pattern") or "*", int(req.get("limit") or 500))
            found["server"] = server(client)
            return {"ok": True, "keys": found}
        if op == "value":
            meta, res = value(client, req.get("key") or "")
            return {"ok": True, "value": meta, "results": [res]}
        results, error = run(client, req.get("statements") or [], int(req.get("max_rows") or 500))
        out = {"ok": error is None, "results": results}
        if error is not None:
            out["error"] = error.as_json()
        return out
    except ReplyError as e:
        if str(e).startswith("NOAUTH"):
            raise DriverError("This Redis server needs a password", hint="Edit the connection and enter its password")
        raise DriverError(str(e))
    finally:
        client.close()
