"""Trino through its client REST protocol (POST /v1/statement, then nextUri).

Statements run one by one; the session state Trino hands back (USE, SET
SESSION, prepared statements, transactions) carries over between them and is
returned, so the block can send the catalog and schema with its next run.
A password needs HTTPS: Trino refuses basic authentication over plain HTTP."""

import base64
import json
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

from tdb_common import Cancel, Cancelled, DriverError, cell, column, elapsed_since, result

NUMERIC_PREFIXES = ("tinyint", "smallint", "integer", "bigint", "real", "double", "decimal")
REQUEST_TIMEOUT = 60
RETRY_STATUSES = (429, 502, 503, 504)


class Client:
    def __init__(self, cfg, password, session):
        self.https = bool(cfg.get("tls"))
        host = (cfg.get("host") or "localhost").strip()
        port = int(cfg.get("port") or (443 if self.https else 8080))
        self.base = "%s://%s:%d" % ("https" if self.https else "http", host, port)
        self.user = (cfg.get("user") or "").strip() or "tern"
        self.catalog = (session or {}).get("catalog") or (cfg.get("catalog") or "").strip() or None
        self.schema = (session or {}).get("schema") or (cfg.get("schema") or "").strip() or None
        self.properties = {}
        self.prepared = {}
        self.transaction = None
        self.password = password or ""
        if self.password and not self.https:
            raise DriverError("Trino takes passwords only over HTTPS",
                              hint="Turn on HTTPS for this connection, or remove its password")
        if self.https:
            self.context = ssl.create_default_context()
            if cfg.get("insecure"):
                self.context.check_hostname = False
                self.context.verify_mode = ssl.CERT_NONE
        else:
            self.context = None
        self.changed = False

    def headers(self):
        h = {
            "X-Trino-User": self.user,
            "X-Trino-Source": "tern-databases",
            "User-Agent": "tern-databases",
        }
        if self.catalog:
            h["X-Trino-Catalog"] = self.catalog
        if self.schema:
            h["X-Trino-Schema"] = self.schema
        if self.properties:
            h["X-Trino-Session"] = ",".join(
                "%s=%s" % (k, urllib.parse.quote(v, safe="")) for k, v in self.properties.items())
        if self.prepared:
            h["X-Trino-Prepared-Statement"] = ",".join(
                "%s=%s" % (urllib.parse.quote(k, safe=""), urllib.parse.quote(v, safe=""))
                for k, v in self.prepared.items())
        if self.transaction:
            h["X-Trino-Transaction-Id"] = self.transaction
        if self.password:
            token = base64.b64encode(("%s:%s" % (self.user, self.password)).encode()).decode()
            h["Authorization"] = "Basic " + token
        return h

    def request(self, method, url, body=None):
        """One HTTP exchange; Trino's busy statuses are retried."""
        delay = 0.1
        while True:
            req = urllib.request.Request(url, data=body, headers=self.headers(), method=method)
            if body is not None:
                req.add_header("Content-Type", "text/plain; charset=utf-8")
            try:
                with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT, context=self.context) as resp:
                    self.session_headers(resp.headers)
                    raw = resp.read()
                    return json.loads(raw.decode("utf-8")) if raw else {}
            except urllib.error.HTTPError as e:
                if e.code in RETRY_STATUSES and not Cancel.requested():
                    time.sleep(delay)
                    delay = min(delay * 2, 2.0)
                    continue
                text = e.read().decode("utf-8", "replace").strip()
                if e.code == 401:
                    raise DriverError("Trino refused the user or password (HTTP 401)",
                                      hint="Edit the connection and check its user and password")
                raise DriverError("Trino answered HTTP %d: %s" % (e.code, text.splitlines()[0] if text else e.reason))
            except urllib.error.URLError as e:
                reason = e.reason
                if isinstance(reason, ssl.SSLCertVerificationError):
                    raise DriverError("The server's certificate is not trusted: %s" % (reason.verify_message or reason),
                                      hint="Turn off certificate checks for this connection only if you trust the network")
                raise DriverError("Cannot reach %s: %s" % (self.base, getattr(reason, "strerror", None) or reason))
            except (socket.timeout, TimeoutError):
                raise DriverError("Trino did not answer within %d s" % REQUEST_TIMEOUT)
            except ValueError:
                raise DriverError("Trino sent an answer that is not JSON")

    def session_headers(self, headers):
        catalog = headers.get("X-Trino-Set-Catalog")
        if catalog:
            self.catalog, self.changed = catalog, True
        schema = headers.get("X-Trino-Set-Schema")
        if schema:
            self.schema, self.changed = schema, True
        for value in headers.get_all("X-Trino-Set-Session") or []:
            k, _, v = value.partition("=")
            self.properties[k.strip()] = urllib.parse.unquote(v.strip())
        for value in headers.get_all("X-Trino-Clear-Session") or []:
            self.properties.pop(value.strip(), None)
        for value in headers.get_all("X-Trino-Added-Prepare") or []:
            k, _, v = value.partition("=")
            self.prepared[urllib.parse.unquote(k.strip())] = urllib.parse.unquote(v.strip())
        for value in headers.get_all("X-Trino-Deallocated-Prepare") or []:
            self.prepared.pop(urllib.parse.unquote(value.strip()), None)
        started = headers.get("X-Trino-Started-Transaction-Id")
        if started:
            self.transaction = started
        if headers.get("X-Trino-Clear-Transaction-Id"):
            self.transaction = None

    def cancel(self, next_uri):
        if not next_uri:
            return
        try:
            self.request("DELETE", next_uri)
        except DriverError:
            pass

    def statement(self, index, sql, max_rows):
        start = time.monotonic()
        resp = self.request("POST", self.base + "/v1/statement", sql.encode("utf-8"))
        cols, rows, truncated = None, [], False
        while True:
            if cols is None and resp.get("columns"):
                cols = [column(c.get("name", ""), c.get("type"),
                               (c.get("type") or "").startswith(NUMERIC_PREFIXES)) for c in resp["columns"]]
            for row in resp.get("data") or []:
                if len(rows) < max_rows:
                    rows.append([cell(v) for v in row])
                else:
                    truncated = True
            error = resp.get("error")
            if error:
                where = error.get("errorLocation") or {}
                raise DriverError(error.get("message") or "Trino reported an error",
                                  code=error.get("errorName"), line=where.get("lineNumber"),
                                  column=where.get("columnNumber"))
            next_uri = resp.get("nextUri")
            if not next_uri:
                break
            if truncated:
                self.cancel(next_uri)
                break
            if Cancel.requested():
                self.cancel(next_uri)
                raise Cancelled(Cancel.why)
            resp = self.request("GET", next_uri)
        update = resp.get("updateType")
        count = resp.get("updateCount")
        command = update if update else ("SELECT" if cols is not None else None)
        if update and isinstance(count, int):
            command = "%s %d" % (update, count)
        return result(index, cols, rows if cols is not None else None, truncated=truncated or None,
                      command=command, count=count if isinstance(count, int) else (len(rows) if cols else None),
                      elapsed_ms=elapsed_since(start))

    def run(self, statements, max_rows):
        results = []
        for index, sql in enumerate(statements):
            if Cancel.requested():
                return results, Cancelled(Cancel.why)
            try:
                results.append(self.statement(index, sql, max_rows))
            except DriverError as e:
                e.info["statement"] = index
                return results, e
        return results, None

    def rows(self, sql, max_rows=50000):
        out = self.statement(0, sql, max_rows)
        return out.get("rows") or [], bool(out.get("truncated"))

    def server(self):
        try:
            info = self.request("GET", self.base + "/v1/info")
        except DriverError:
            return "Trino"
        version = (info.get("nodeVersion") or {}).get("version")
        return "Trino " + version if version else "Trino"


def quote(name):
    return '"' + name.replace('"', '""') + '"'


def literal(text):
    return "'" + text.replace("'", "''") + "'"


def schema(client):
    catalogs = [r[0] for r in client.rows("SHOW CATALOGS")[0]]
    out = {"server": client.server(), "catalogs": catalogs, "schemas": [], "tables": [], "functions": [],
           "catalog": client.catalog, "default_schema": client.schema}
    if not client.catalog:
        return out
    cat = quote(client.catalog)
    where = "table_schema <> 'information_schema'"
    if client.schema:
        where += " AND table_schema = " + literal(client.schema)
    out["schemas"] = [r[0] for r in client.rows("SHOW SCHEMAS FROM " + cat)[0] if r[0] != "information_schema"]
    kinds, _ = client.rows("SELECT table_schema, table_name, table_type FROM %s.information_schema.tables WHERE %s"
                           % (cat, where))
    by_key, tables = {}, []
    for schema_name, name, kind in kinds:
        table = {"schema": schema_name, "name": name,
                 "kind": "view" if (kind or "").upper() == "VIEW" else "table", "columns": []}
        by_key[(schema_name, name)] = table
        tables.append(table)
    cols, truncated = client.rows(
        "SELECT table_schema, table_name, column_name, data_type, is_nullable FROM %s.information_schema.columns "
        "WHERE %s ORDER BY table_schema, table_name, ordinal_position" % (cat, where))
    for schema_name, name, col, type_name, nullable in cols:
        table = by_key.get((schema_name, name))
        if table is None:
            table = {"schema": schema_name, "name": name, "kind": "table", "columns": []}
            by_key[(schema_name, name)] = table
            tables.append(table)
        entry = {"name": col, "type": type_name}
        if nullable == "NO":
            entry["notnull"] = True
        table["columns"].append(entry)
    tables.sort(key=lambda t: (t["schema"], t["name"]))
    out["tables"] = tables
    out["truncated"] = truncated
    return out


def handle(req, password):
    client = Client(req.get("conn") or {}, password, req.get("session"))
    op = req.get("op")
    if op == "test":
        client.rows("SELECT 1")
        return {"ok": True, "server": client.server()}
    if op == "schema":
        return {"ok": True, "schema": schema(client)}
    results, error = client.run(req.get("statements") or [], int(req.get("max_rows") or 500))
    out = {"ok": error is None, "results": results}
    if error is not None:
        out["error"] = error.as_json()
    if client.changed:
        out["session"] = {"catalog": client.catalog, "schema": client.schema}
    if client.transaction:
        out["notices"] = ["The open transaction ends with the run: each run is its own Trino session"]
    return out
