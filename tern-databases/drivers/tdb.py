"""The Databases plugin's driver: one request on stdin, one JSON answer on stdout.

The request carries the connection (without secrets), the password, and what
to do: `test`, `schema`, `run` (statements), and for Redis `keys` and
`value`. Passwords arrive on stdin only, never in arguments or the
environment. SIGTERM cancels the work in progress the way each database
allows, then the answer still comes back with what finished."""

import json
import os
import sys
import time
import traceback

sys.dont_write_bytecode = True

from tdb_common import Cancel, DriverError, elapsed_since  # noqa: E402

DRIVERS = {
    "postgres": "tdb_pg",
    "sqlite": "tdb_sqlite",
    "trino": "tdb_trino",
    "redis": "tdb_redis",
}


def answer(out):
    sys.stdout.write(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
    sys.stdout.flush()


def main():
    start = time.monotonic()
    try:
        req = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    except ValueError as e:
        answer({"ok": False, "error": {"message": "The driver got a request that is not JSON: %s" % e}})
        return
    pid_file = req.get("pid_file")
    if pid_file:
        try:
            with open(pid_file, "w") as f:
                f.write(str(os.getpid()))
        except OSError:
            pid_file = None
    Cancel.install(req.get("timeout_ms"))
    kind = (req.get("conn") or {}).get("kind")
    try:
        module = DRIVERS.get(kind)
        if module is None:
            raise DriverError("Unknown kind of database: %s" % kind)
        out = __import__(module).handle(req, req.get("password"))
    except DriverError as e:
        out = {"ok": False, "error": e.as_json()}
    except Exception as e:  # a driver bug: report it rather than leave the block guessing
        out = {"ok": False, "error": {"message": "The %s driver failed: %s" % (kind, e),
                                      "detail": traceback.format_exc(limit=6)}}
    out["elapsed_ms"] = elapsed_since(start)
    answer(out)
    if pid_file:
        try:
            os.remove(pid_file)
        except OSError:
            pass


if __name__ == "__main__":
    main()
