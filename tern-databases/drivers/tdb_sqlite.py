"""SQLite through Python's sqlite3 module.

The file must exist (a typo in the path should not make an empty database).
Statements run in autocommit mode, one by one; a transaction a run leaves
open is rolled back when the run ends."""

import os
import sqlite3
import time
import urllib.parse

from tdb_common import Cancel, Cancelled, DriverError, cell, column, elapsed_since, first_word, result


def open_db(cfg):
    path = os.path.expanduser((cfg.get("path") or "").strip())
    if not path:
        raise DriverError("This connection has no database file", hint="Edit the connection and choose the file")
    if not os.path.isfile(path):
        raise DriverError("No database file at " + path, hint="Edit the connection and check the path")
    uri = "file:" + urllib.parse.quote(path) + "?mode=rw"
    try:
        db = sqlite3.connect(uri, uri=True, isolation_level=None, timeout=5, check_same_thread=False)
    except sqlite3.Error as e:
        raise DriverError("Cannot open %s: %s" % (path, e))
    db.set_progress_handler(lambda: 1 if Cancel.requested() else 0, 20000)
    return db


def sqlite_error(e):
    text = str(e)
    if text == "interrupted" and Cancel.flag:
        return Cancelled(Cancel.why)
    return DriverError(text, code=getattr(e, "sqlite_errorname", None))


def run(db, statements, max_rows):
    results = []
    for index, sql in enumerate(statements):
        if Cancel.requested():
            return results, Cancelled(Cancel.why)
        start = time.monotonic()
        try:
            cur = db.execute(sql)
            if cur.description is not None:
                names = [d[0] for d in cur.description]
                fetched = cur.fetchmany(max_rows + 1)
                truncated = len(fetched) > max_rows
                fetched = fetched[:max_rows]
                numeric = [True] * len(names)
                seen = [False] * len(names)
                for row in fetched:
                    for i, v in enumerate(row):
                        if v is not None:
                            seen[i] = True
                            if isinstance(v, bool) or not isinstance(v, (int, float)):
                                numeric[i] = False
                cols = [column(n, None, numeric[i] and seen[i]) for i, n in enumerate(names)]
                rows = [[cell(v) for v in row] for row in fetched]
                results.append(result(index, cols, rows, truncated=truncated or None, count=len(rows),
                                      command="SELECT", elapsed_ms=elapsed_since(start)))
            else:
                word = first_word(sql) or "OK"
                count = cur.rowcount if cur.rowcount is not None and cur.rowcount >= 0 else None
                command = word if count is None or word not in ("INSERT", "UPDATE", "DELETE", "REPLACE") \
                    else "%s %d" % (word, count)
                results.append(result(index, command=command, count=count, elapsed_ms=elapsed_since(start)))
        except sqlite3.Error as e:
            err = sqlite_error(e)
            err.info["statement"] = index
            return results, err
    return results, None


def schema(db):
    version = db.execute("SELECT sqlite_version()").fetchone()[0]
    tables = []
    rows = db.execute(
        "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ).fetchall()
    for name, kind in rows:
        cols = []
        quoted = '"' + name.replace('"', '""') + '"'
        try:
            info = db.execute("PRAGMA table_xinfo(%s)" % quoted).fetchall()
        except sqlite3.Error:
            info = db.execute("PRAGMA table_info(%s)" % quoted).fetchall()
        for entry in info:
            if len(entry) > 6 and entry[6] == 1:
                continue  # a virtual table's hidden column
            col = {"name": entry[1], "type": entry[2] or ""}
            if entry[5]:
                col["pk"] = True
            if entry[3]:
                col["notnull"] = True
            cols.append(col)
        tables.append({"name": name, "kind": kind, "columns": cols})
    return {"server": "SQLite " + version, "tables": tables, "schemas": [], "functions": []}


def handle(req, _password):
    db = open_db(req.get("conn") or {})
    try:
        op = req.get("op")
        if op == "test":
            return {"ok": True, "server": "SQLite " + db.execute("SELECT sqlite_version()").fetchone()[0]}
        if op == "schema":
            try:
                return {"ok": True, "schema": schema(db)}
            except sqlite3.Error as e:
                raise sqlite_error(e)
        results, error = run(db, req.get("statements") or [], int(req.get("max_rows") or 500))
        notices = []
        if db.in_transaction:
            db.rollback()
            notices.append("The open transaction was rolled back when the run ended: end it with COMMIT in the same run")
        out = {"ok": error is None, "results": results, "server": "SQLite " + sqlite3.sqlite_version}
        if error is not None:
            out["error"] = error.as_json()
        if notices:
            out["notices"] = notices
        return out
    finally:
        db.close()
