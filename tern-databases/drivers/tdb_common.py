"""Pieces every driver shares: errors, cancellation, cells and results."""

import json
import os
import select
import signal
import time

# Longest cell text sent back; the rest is cut with an ellipsis.
MAX_CELL = 4000


class DriverError(Exception):
    """A failure to report to the block: `message` is one line, `info` adds
    detail, hint, code and where in the statement it happened."""

    def __init__(self, message, **info):
        super().__init__(message)
        self.message = message
        self.info = {k: v for k, v in info.items() if v not in (None, "")}

    def as_json(self):
        out = {"message": self.message}
        out.update(self.info)
        return out


class Cancelled(DriverError):
    def __init__(self, why="The query was cancelled"):
        super().__init__(why, code="cancelled")


class Cancel:
    """SIGTERM/SIGINT and the deadline set `flag`; `fd` wakes a select()."""

    flag = False
    why = "The query was cancelled"
    fd = None
    deadline = None

    @classmethod
    def install(cls, timeout_ms):
        r, w = os.pipe()
        os.set_blocking(r, False)
        os.set_blocking(w, False)
        signal.set_wakeup_fd(w)
        cls.fd = r

        def handler(_signum, _frame):
            cls.flag = True

        signal.signal(signal.SIGTERM, handler)
        signal.signal(signal.SIGINT, handler)
        if timeout_ms:
            cls.deadline = time.monotonic() + timeout_ms / 1000.0

    @classmethod
    def requested(cls):
        """True once the block asked to stop or the deadline passed."""
        if not cls.flag and cls.deadline is not None and time.monotonic() >= cls.deadline:
            cls.flag = True
            cls.why = "The query ran past the time limit and was cancelled"
        return cls.flag

    @classmethod
    def drain(cls):
        try:
            while os.read(cls.fd, 64):
                pass
        except (BlockingIOError, OSError, TypeError):
            pass


def wait_readable(sock, on_cancel):
    """Blocks until `sock` has data. While a cancel is requested, `on_cancel()`
    runs every half second of the wait (it may raise) and the wait goes on."""
    while True:
        pending = getattr(sock, "pending", None)
        if pending is not None and pending() > 0:
            return
        fds = [sock] + ([Cancel.fd] if Cancel.fd is not None else [])
        ready, _, _ = select.select(fds, [], [], 0.5)
        if Cancel.fd in ready:
            Cancel.drain()
        if Cancel.requested():
            on_cancel()
        if sock in ready:
            return


def cell(value):
    """A result value as text, or None for NULL."""
    if value is None:
        return None
    if isinstance(value, bool):
        text = "true" if value else "false"
    elif isinstance(value, (bytes, bytearray, memoryview)):
        text = "\\x" + bytes(value).hex()
    elif isinstance(value, float):
        text = repr(value)
    elif isinstance(value, (list, dict)):
        text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    else:
        text = str(value)
    if len(text) > MAX_CELL:
        text = text[:MAX_CELL] + "…"
    return text


def column(name, type_name=None, numeric=False):
    out = {"name": name}
    if type_name:
        out["type"] = type_name
    if numeric:
        out["num"] = True
    return out


def result(index, columns=None, rows=None, **extra):
    out = {"statement": index}
    if columns is not None:
        out["columns"] = columns
        out["rows"] = rows if rows is not None else []
    out.update({k: v for k, v in extra.items() if v is not None})
    return out


def elapsed_since(start):
    return round((time.monotonic() - start) * 1000.0, 1)


def first_word(sql):
    """The statement's first keyword, upper-cased (`SELECT`, `INSERT`)."""
    i, n = 0, len(sql)
    while i < n:
        if sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j + 1
        elif sql.startswith("/*", i):
            j = sql.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif sql[i].isspace() or sql[i] == "(":
            i += 1
        else:
            break
    j = i
    while j < n and (sql[j].isalnum() or sql[j] == "_"):
        j += 1
    return sql[i:j].upper()
