"""PostgreSQL over its frontend/backend protocol 3.0, with the standard library only.

Each run is one session: the statements go one by one through the extended
protocol (Parse, Bind, Describe, Execute with a row limit, Sync), so every
statement gets its own result and transactions span the statements of a run.
Authentication: trust, password, md5 and SCRAM-SHA-256; TLS by `sslmode`.
A cancel request (SIGTERM, or the deadline) sends PostgreSQL's CancelRequest
on a second connection, as psql's Ctrl-C does."""

import base64
import hashlib
import hmac
import os
import socket
import ssl
import stringprep
import struct
import time
import unicodedata

from tdb_common import (
    MAX_CELL,
    Cancel,
    Cancelled,
    DriverError,
    column,
    elapsed_since,
    result,
    wait_readable,
)

CONNECT_TIMEOUT = 15
# Seconds a cancelled statement may take to end before the run gives up on it.
CANCEL_GRACE = 5

TYPES = {
    16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4",
    24: "regproc", 25: "text", 26: "oid", 114: "json", 142: "xml", 600: "point", 650: "cidr",
    700: "float4", 701: "float8", 790: "money", 829: "macaddr", 869: "inet", 1000: "bool[]",
    1001: "bytea[]", 1005: "int2[]", 1007: "int4[]", 1009: "text[]", 1014: "bpchar[]",
    1015: "varchar[]", 1016: "int8[]", 1021: "float4[]", 1022: "float8[]", 1042: "bpchar",
    1043: "varchar", 1082: "date", 1083: "time", 1114: "timestamp", 1115: "timestamp[]",
    1182: "date[]", 1184: "timestamptz", 1185: "timestamptz[]", 1186: "interval",
    1231: "numeric[]", 1266: "timetz", 1560: "bit", 1562: "varbit", 1700: "numeric",
    2205: "regclass", 2249: "record", 2278: "void", 2950: "uuid", 2951: "uuid[]",
    3614: "tsvector", 3802: "jsonb", 3807: "jsonb[]", 3904: "int4range", 3926: "int8range",
    4089: "regnamespace", 4096: "regrole",
}
NUMERIC = {20, 21, 23, 26, 700, 701, 790, 1700}


def message(kind, body):
    return kind + struct.pack("!i", len(body) + 4) + body


def saslprep(text):
    """The password as SCRAM hashes it: RFC 4013 SASLprep, or the raw bytes
    where SASLprep refuses the string (PostgreSQL falls back the same way)."""
    raw = text.encode("utf-8")
    if all(ord(ch) < 128 for ch in text):
        return raw
    kept = []
    for ch in text:
        if stringprep.in_table_c12(ch):
            kept.append(" ")
        elif not stringprep.in_table_b1(ch):
            kept.append(ch)
    out = unicodedata.normalize("NFKC", "".join(kept))
    if not out:
        return raw
    prohibited = (
        stringprep.in_table_c12, stringprep.in_table_c21_c22, stringprep.in_table_c3,
        stringprep.in_table_c4, stringprep.in_table_c5, stringprep.in_table_c6,
        stringprep.in_table_c7, stringprep.in_table_c8, stringprep.in_table_c9,
        stringprep.in_table_a1,
    )
    if any(test(ch) for ch in out for test in prohibited):
        return raw
    if any(stringprep.in_table_d1(ch) for ch in out):
        if any(stringprep.in_table_d2(ch) for ch in out):
            return raw
        if not (stringprep.in_table_d1(out[0]) and stringprep.in_table_d1(out[-1])):
            return raw
    return out.encode("utf-8")


class Scram:
    """SCRAM-SHA-256 without channel binding (RFC 5802, RFC 7677)."""

    def __init__(self, password):
        self.password = saslprep(password)
        self.nonce = base64.b64encode(os.urandom(18)).decode()
        self.first_bare = "n=,r=" + self.nonce
        self.auth = b""
        self.server_key = b""

    def first(self):
        return ("n,," + self.first_bare).encode()

    def final(self, server_first):
        text = server_first.decode("utf-8", "replace")
        attrs = dict(part.split("=", 1) for part in text.split(",") if "=" in part)
        nonce = attrs.get("r", "")
        if not nonce.startswith(self.nonce):
            raise DriverError("The server sent an invalid SCRAM nonce")
        salted = hashlib.pbkdf2_hmac("sha256", self.password, base64.b64decode(attrs["s"]), int(attrs["i"]))
        client_key = hmac.new(salted, b"Client Key", "sha256").digest()
        stored = hashlib.sha256(client_key).digest()
        without_proof = "c=biws,r=" + nonce
        self.auth = (self.first_bare + "," + text + "," + without_proof).encode()
        signature = hmac.new(stored, self.auth, "sha256").digest()
        proof = bytes(a ^ b for a, b in zip(client_key, signature))
        self.server_key = hmac.new(salted, b"Server Key", "sha256").digest()
        return (without_proof + ",p=" + base64.b64encode(proof).decode()).encode()

    def verify(self, server_final):
        text = server_final.decode("utf-8", "replace")
        attrs = dict(part.split("=", 1) for part in text.split(",") if "=" in part)
        if "e" in attrs:
            raise DriverError("SCRAM authentication failed: " + attrs["e"])
        expected = hmac.new(self.server_key, self.auth, "sha256").digest()
        if base64.b64decode(attrs.get("v", "")) != expected:
            raise DriverError("The server's SCRAM signature does not match: it may not be the server it claims")


def count_of(command):
    """Rows a command tag reports (`INSERT 0 5` → 5), or None."""
    if not command:
        return None
    last = command.rsplit(" ", 1)[-1]
    return int(last) if last.isdigit() and " " in command else None


class Session:
    def __init__(self, cfg, password):
        self.host = (cfg.get("host") or "localhost").strip()
        self.port = int(cfg.get("port") or 5432)
        self.user = (cfg.get("user") or "").strip() or os.environ.get("USER") or "postgres"
        self.database = (cfg.get("database") or "").strip() or self.user
        self.sslmode = cfg.get("sslmode") or "prefer"
        self.password = password or ""
        self.sock = None
        self.buf = bytearray()
        self.pos = 0
        self.params = {}
        self.backend = None
        self.status = b"I"
        self.notices = []
        self.cancel_sent = 0.0

    # Connection ---------------------------------------------------------

    def open(self):
        self.sock = self._connect()
        self._startup()

    def close(self):
        if self.sock is None:
            return
        try:
            self.sock.sendall(message(b"X", b""))
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
        self.sock = None

    def _plain_socket(self, timeout):
        if self.host.startswith("/"):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect(os.path.join(self.host, ".s.PGSQL.%d" % self.port))
            return s
        return socket.create_connection((self.host, self.port), timeout=timeout)

    def _connect(self):
        try:
            s = self._plain_socket(CONNECT_TIMEOUT)
        except OSError as e:
            where = self.host if self.host.startswith("/") else "%s:%d" % (self.host, self.port)
            raise DriverError("Cannot reach %s: %s" % (where, e.strerror or e),
                              hint="Check the host and port, and that the server accepts TCP connections")
        if self.sslmode != "disable" and not self.host.startswith("/"):
            s = self._negotiate_ssl(s)
        s.settimeout(None)
        return s

    def _negotiate_ssl(self, s):
        try:
            s.sendall(struct.pack("!ii", 8, 80877103))
            answer = s.recv(1)
        except OSError as e:
            raise DriverError("The connection failed while asking for SSL: %s" % e)
        if answer == b"S":
            if self.sslmode in ("verify-full", "verify-ca"):
                ctx = ssl.create_default_context()
                ctx.check_hostname = self.sslmode == "verify-full"
            else:
                ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
            try:
                return ctx.wrap_socket(s, server_hostname=self.host)
            except ssl.SSLCertVerificationError as e:
                raise DriverError("The server's certificate is not trusted: %s" % (e.verify_message or e),
                                  hint="SSL mode require encrypts without checking the certificate")
            except (ssl.SSLError, OSError) as e:
                raise DriverError("The SSL handshake failed: %s" % e)
        if answer == b"N":
            if self.sslmode in ("require", "verify-ca", "verify-full"):
                raise DriverError("The server does not accept SSL connections",
                                  hint="Set SSL to prefer or disable for this connection")
            return s
        raise DriverError("The server did not answer the SSL request; is it PostgreSQL?")

    def _startup(self):
        params = (
            ("user", self.user),
            ("database", self.database),
            ("application_name", "tern-databases"),
            ("client_encoding", "UTF8"),
        )
        body = struct.pack("!i", 196608)
        for k, v in params:
            body += k.encode() + b"\0" + v.encode("utf-8") + b"\0"
        body += b"\0"
        self._send(struct.pack("!i", len(body) + 4) + body)
        scram = None
        while True:
            kind, body = self._message()
            if kind == b"R":
                code = struct.unpack_from("!i", body)[0]
                if code == 0:
                    continue
                if code in (3, 5, 10) and not self.password:
                    raise DriverError("The server asks for a password", code="28P01",
                                      hint="Edit the connection and enter its password")
                if code == 3:
                    self._send(message(b"p", self.password.encode("utf-8") + b"\0"))
                elif code == 5:
                    inner = hashlib.md5(self.password.encode("utf-8") + self.user.encode("utf-8")).hexdigest()
                    outer = hashlib.md5(inner.encode() + body[4:8]).hexdigest()
                    self._send(message(b"p", b"md5" + outer.encode() + b"\0"))
                elif code == 10:
                    mechanisms = body[4:].split(b"\0")
                    if b"SCRAM-SHA-256" not in mechanisms:
                        raise DriverError("The server offers only SASL mechanisms this client lacks: "
                                          + ", ".join(m.decode() for m in mechanisms if m))
                    scram = Scram(self.password)
                    first = scram.first()
                    self._send(message(b"p", b"SCRAM-SHA-256\0" + struct.pack("!i", len(first)) + first))
                elif code == 11 and scram is not None:
                    self._send(message(b"p", scram.final(body[4:])))
                elif code == 12 and scram is not None:
                    scram.verify(body[4:])
                else:
                    names = {2: "Kerberos", 6: "SCM credentials", 7: "GSSAPI", 9: "SSPI"}
                    raise DriverError("The server asks for %s authentication, which this client lacks"
                                      % names.get(code, "method %d" % code))
            elif kind == b"E":
                raise self._error(body)
            elif kind == b"S":
                self._parameter(body)
            elif kind == b"K":
                self.backend = struct.unpack_from("!ii", body)
            elif kind == b"N":
                self.notices.append(self._notice(body))
            elif kind == b"Z":
                self.status = body[:1]
                return

    # Wire ---------------------------------------------------------------

    def _send(self, data):
        try:
            self.sock.sendall(data)
        except OSError as e:
            raise DriverError("Lost the connection to the server: %s" % e)

    def _on_cancel(self):
        """Sends PostgreSQL's CancelRequest once, then waits for the server to
        end the statement; a server silent for CANCEL_GRACE gives up the run."""
        if self.backend is None:
            raise Cancelled(Cancel.why)
        if self.cancel_sent:
            if time.monotonic() - self.cancel_sent > CANCEL_GRACE:
                raise Cancelled(Cancel.why)
            return
        self.cancel_sent = time.monotonic()
        try:
            s = self._plain_socket(5)
            s.sendall(struct.pack("!iiii", 16, 80877102, self.backend[0], self.backend[1]))
            s.close()
        except OSError:
            raise Cancelled(Cancel.why)

    def _fill(self, n):
        while len(self.buf) - self.pos < n:
            wait_readable(self.sock, self._on_cancel)
            try:
                chunk = self.sock.recv(262144)
            except ssl.SSLWantReadError:
                continue
            except OSError as e:
                raise DriverError("Lost the connection to the server: %s" % e)
            if not chunk:
                raise DriverError("The server closed the connection")
            if self.pos > 1 << 20:
                del self.buf[: self.pos]
                self.pos = 0
            self.buf += chunk

    def _message(self):
        self._fill(5)
        kind = bytes(self.buf[self.pos : self.pos + 1])
        length = struct.unpack_from("!i", self.buf, self.pos + 1)[0]
        self._fill(1 + length)
        body = bytes(self.buf[self.pos + 5 : self.pos + 1 + length])
        self.pos += 1 + length
        return kind, body

    @staticmethod
    def _fields(body):
        out = {}
        for part in body.split(b"\0"):
            if part:
                out[chr(part[0])] = part[1:].decode("utf-8", "replace")
        return out

    def _error(self, body):
        f = self._fields(body)
        code = f.get("C")
        text = f.get("M") or "The server reported an error"
        if code == "57014" and Cancel.flag:
            text = Cancel.why
        position = f.get("P", "")
        hint = f.get("H")
        if code == "28P01":
            hint = hint or "Edit the connection and check its user and password"
        return DriverError(text, code=code, detail=f.get("D"), hint=hint,
                           position=int(position) if position.isdigit() else None, where=f.get("W"))

    def _notice(self, body):
        f = self._fields(body)
        return (f.get("S") or f.get("V") or "NOTICE") + ": " + (f.get("M") or "")

    def _parameter(self, body):
        parts = body.split(b"\0")
        if len(parts) >= 2:
            self.params[parts[0].decode()] = parts[1].decode("utf-8", "replace")

    # Statements ---------------------------------------------------------

    def run(self, statements, max_rows):
        """Runs `statements` in order; returns (results, error). The first
        failing statement ends the run, its error naming the statement."""
        results = []
        for index, sql in enumerate(statements):
            if Cancel.requested():
                return results, Cancelled(Cancel.why)
            start = time.monotonic()
            self.notices = []
            try:
                batch = self._extended(index, sql, max_rows)
            except DriverError as e:
                if e.info.get("code") == "42601" and "multiple commands" in e.message:
                    try:
                        batch = self._simple(index, sql, max_rows)
                    except DriverError as again:
                        again.info["statement"] = index
                        return results, again
                else:
                    e.info["statement"] = index
                    return results, e
            took = elapsed_since(start)
            for r in batch:
                r["elapsed_ms"] = took
            results.extend(batch)
        return results, None

    def _extended(self, index, sql, max_rows):
        q = sql.encode("utf-8")
        self._send(
            message(b"P", b"\0" + q + b"\0" + struct.pack("!h", 0))
            + message(b"B", b"\0\0" + struct.pack("!hhh", 0, 0, 0))
            + message(b"D", b"P\0")
            + message(b"E", b"\0" + struct.pack("!i", max_rows + 1))
            + message(b"S", b"")
        )
        return self._collect(index, max_rows)

    def _simple(self, index, sql, max_rows):
        self._send(message(b"Q", sql.encode("utf-8") + b"\0"))
        return self._collect(index, max_rows)

    def _collect(self, index, max_rows):
        """Reads up to ReadyForQuery. Each CommandComplete (or a suspended
        portal, an empty query) closes one result."""
        out = []
        columns, rows, truncated, copying = None, [], False, False
        error = None

        def close(command):
            nonlocal columns, rows, truncated, copying
            count = count_of(command)
            if count is None and columns is not None:
                count = len(rows)
            out.append(result(index, columns, rows if columns is not None else None,
                              truncated=truncated or None, command=command or None, count=count,
                              notices=list(self.notices) or None))
            columns, rows, truncated, copying = None, [], False, False
            self.notices = []

        while True:
            kind, body = self._message()
            if kind == b"D":
                if len(rows) < max_rows:
                    rows.append(self._data_row(body))
                else:
                    truncated = True
            elif kind == b"T":
                columns = self._row_description(body)
            elif kind == b"C":
                close(body.rstrip(b"\0").decode("utf-8", "replace"))
            elif kind == b"s":
                truncated = True
                close(None)
            elif kind == b"I":
                close(None)
            elif kind == b"E":
                error = error or self._error(body)
            elif kind == b"N":
                self.notices.append(self._notice(body))
            elif kind == b"S":
                self._parameter(body)
            elif kind == b"G":
                self._send(message(b"f", b"COPY FROM STDIN is not available in the Databases block\0"))
            elif kind == b"H":
                columns, rows, copying = [column("COPY")], [], True
            elif kind == b"d":
                if copying and len(rows) < max_rows:
                    rows.append([body.decode("utf-8", "replace").rstrip("\n")])
                elif copying:
                    truncated = True
            elif kind == b"Z":
                self.status = body[:1]
                break
        if error is not None:
            raise error
        return out

    @staticmethod
    def _row_description(body):
        n = struct.unpack_from("!h", body)[0]
        pos, cols = 2, []
        for _ in range(n):
            end = body.index(b"\0", pos)
            name = body[pos:end].decode("utf-8", "replace")
            pos = end + 1
            _table, _attnum, type_oid, _size, _mod, _fmt = struct.unpack_from("!ihihih", body, pos)
            pos += 18
            col = column(name, TYPES.get(type_oid), type_oid in NUMERIC)
            if type_oid not in TYPES:
                col["oid"] = type_oid
            cols.append(col)
        return cols

    @staticmethod
    def _data_row(body):
        n = struct.unpack_from("!h", body)[0]
        pos, out = 2, []
        for _ in range(n):
            size = struct.unpack_from("!i", body, pos)[0]
            pos += 4
            if size < 0:
                out.append(None)
                continue
            text = body[pos : pos + size].decode("utf-8", "replace")
            pos += size
            out.append(text if len(text) <= MAX_CELL else text[:MAX_CELL] + "…")
        return out

    def name_types(self, results):
        """Names the columns of user types (enums, domains) by pg_type."""
        oids = sorted({c["oid"] for r in results for c in r.get("columns", []) if "oid" in c})
        if not oids:
            return
        known = {}
        if self.status != b"E" and not Cancel.flag:
            try:
                names, error = self.run(["SELECT oid::int, typname FROM pg_catalog.pg_type WHERE oid IN (%s)"
                                         % ",".join(str(o) for o in oids)], len(oids))
                if error is None and names:
                    known = {int(row[0]): row[1] for row in names[0]["rows"]}
            except DriverError:
                pass
        for r in results:
            for c in r.get("columns", []):
                oid = c.pop("oid", None)
                if oid is not None:
                    c["type"] = known.get(oid, "oid %d" % oid)

    def server(self):
        version = self.params.get("server_version", "")
        return ("PostgreSQL " + version.split(" ")[0]).strip()


SCHEMA_SQL = (
    "SELECT current_database(), current_schema(), current_setting('search_path')",
    """SELECT nspname FROM pg_catalog.pg_namespace
       WHERE nspname NOT IN ('pg_catalog', 'information_schema') AND nspname !~ '^pg_(toast|temp)'
       ORDER BY 1""",
    """SELECT n.nspname, c.relname, c.relkind::text, a.attname,
              pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull,
              EXISTS (SELECT 1 FROM pg_catalog.pg_index i
                      WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY (i.indkey))
       FROM pg_catalog.pg_class c
       JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
       WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
         AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_(toast|temp)'
       ORDER BY 1, 2, a.attnum""",
    """SELECT DISTINCT p.proname FROM pg_catalog.pg_proc p
       JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_'
       ORDER BY 1""",
)
KINDS = {"r": "table", "p": "table", "v": "view", "m": "materialized view", "f": "foreign table"}
SCHEMA_ROWS = 60000


def schema(session):
    results, error = session.run(list(SCHEMA_SQL), SCHEMA_ROWS)
    if error:
        raise error
    database, current, search_path = results[0]["rows"][0]
    tables, by_key = [], {}
    for schema_name, name, kind, col, type_name, notnull, pk in results[2]["rows"]:
        key = (schema_name, name)
        table = by_key.get(key)
        if table is None:
            table = {"schema": schema_name, "name": name, "kind": KINDS.get(kind, "table"), "columns": []}
            by_key[key] = table
            tables.append(table)
        if col is not None:
            entry = {"name": col, "type": type_name}
            if pk == "t":
                entry["pk"] = True
            if notnull == "t":
                entry["notnull"] = True
            table["columns"].append(entry)
    path = [p.strip().strip('"') for p in (search_path or "").split(",") if p.strip()]
    return {
        "server": session.server(),
        "database": database,
        "default_schema": current,
        "search_path": [p for p in path if p != "$user"],
        "schemas": [row[0] for row in results[1]["rows"]],
        "tables": tables,
        "functions": [row[0] for row in results[3]["rows"]],
        "truncated": bool(results[2].get("truncated")),
    }


def handle(req, password):
    session = Session(req.get("conn") or {}, password)
    try:
        session.open()
        op = req.get("op")
        if op == "test":
            return {"ok": True, "server": session.server()}
        if op == "schema":
            return {"ok": True, "schema": schema(session)}
        results, error = session.run(req.get("statements") or [], int(req.get("max_rows") or 500))
        session.name_types(results)
        notices = list(session.notices)
        if session.status in (b"T", b"E"):
            notices.append("The open transaction was rolled back when the run ended: end it with COMMIT in the same run")
        out = {"ok": error is None, "results": results, "server": session.server()}
        if error is not None:
            out["error"] = error.as_json()
        if notices:
            out["notices"] = notices
        return out
    finally:
        session.close()
