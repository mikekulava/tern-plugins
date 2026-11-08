"""Test Explorer helper for Python projects: collects and runs pytest or unittest
tests and writes one JSON event per line to the file named by --out.

    python testview_py.py collect --out FILE [--framework auto|pytest|unittest]
    python testview_py.py run --out FILE --framework pytest|unittest [ID ...]

Runs in the project's directory and with the project's interpreter, like
`python -m pytest` (the directory is on sys.path). Python 3.7+.
"""

import json
import linecache
import os
import sys
import time
import traceback

CONTEXT = 4  # source lines kept on each side of an app frame's line
MAX_OUTPUT = 64 * 1024
MAX_TEXT = 64 * 1024

ROOT = os.getcwd()
LIB_MARKERS = (os.sep + "site-packages" + os.sep, os.sep + "dist-packages" + os.sep, os.sep + ".venv" + os.sep,
               os.sep + "venv" + os.sep, os.sep + "lib" + os.sep + "python")


class Out:
    """Appends events to the --out file, flushed per line so a reader polling it sees them at once."""

    def __init__(self, path):
        self.fh = open(path, "a", encoding="utf-8")

    def emit(self, ev, **fields):
        fields["ev"] = ev
        self.fh.write(json.dumps(fields, default=str) + "\n")
        self.fh.flush()


def clip(text, limit):
    if text and len(text) > limit:
        return text[:limit] + "\n… [%d characters cut]" % (len(text) - limit)
    return text


def is_app(path):
    real = os.path.realpath(path)
    if not real.startswith(os.path.realpath(ROOT) + os.sep):
        return False
    return not any(m in real for m in LIB_MARKERS)


def excerpt(path, line):
    start = max(1, line - CONTEXT)
    lines = []
    for n in range(start, line + CONTEXT + 1):
        text = linecache.getline(path, n)
        if not text and n > line:
            break
        lines.append(text.rstrip("\n"))
    return {"start": start, "lines": lines}


def frames_of(tb, first_file=None):
    """The traceback's frames innermost first; frames before the first one in `first_file`
    (the test runner's own) are dropped."""
    summary = traceback.extract_tb(tb)
    if first_file:
        first_real = os.path.realpath(first_file)
        for i, fs in enumerate(summary):
            if os.path.realpath(fs.filename) == first_real:
                summary = summary[i:]
                break
    frames = []
    for fs in summary:
        app = is_app(fs.filename)
        frame = {"file": fs.filename, "line": fs.lineno, "fn": fs.name, "app": app}
        if app and fs.lineno:
            frame["code"] = excerpt(fs.filename, fs.lineno)
        frames.append(frame)
    frames.reverse()
    return frames


def error_of(etype, value, tb, first_file=None, text=None):
    message = str(value)
    return {
        "type": getattr(etype, "__name__", str(etype)),
        "message": clip(message, MAX_TEXT),
        "frames": frames_of(tb, first_file),
        "text": clip(text, MAX_TEXT) if text else None,
    }


# ---------------------------------------------------------------- pytest


def nodeid_name(nodeid):
    parts = nodeid.split("::")
    return " › ".join(parts[1:]) if len(parts) > 1 else nodeid


def item_file(item):
    path = getattr(item, "path", None)
    return str(path if path is not None else item.fspath)


class PytestPlugin:
    def __init__(self, out, collect_only):
        self.out = out
        self.collect_only = collect_only
        self.items = {}
        self.pending = {}

    def pytest_collectreport(self, report):
        if report.failed:
            path = os.path.join(ROOT, report.nodeid.split("::")[0]) if report.nodeid else ROOT
            text = report.longreprtext
            self.out.emit("file_error", file=path, message=last_line(text), text=clip(text, MAX_TEXT))

    def pytest_collection_finish(self, session):
        tests = []
        for item in session.items:
            self.items[item.nodeid] = item
            line = item.location[1]
            tests.append({
                "id": item.nodeid,
                "file": item_file(item),
                "name": nodeid_name(item.nodeid),
                "line": (line + 1) if isinstance(line, int) else None,
            })
        self.out.emit("collect", framework="pytest", rootdir=str(session.config.rootpath)
                      if hasattr(session.config, "rootpath") else str(session.config.rootdir), tests=tests)

    def pytest_runtest_logstart(self, nodeid, location):
        self.out.emit("start", id=nodeid)

    def pytest_runtest_makereport(self, item, call):
        if call.excinfo is not None and not call.excinfo.errisinstance(skip_exceptions()):
            ei = call.excinfo
            item._testview_error = (ei.type, ei.value, ei.tb)

    def pytest_runtest_logreport(self, report):
        acc = self.pending.setdefault(report.nodeid, {"duration": 0.0, "status": "passed", "report": None})
        acc["duration"] += getattr(report, "duration", 0.0) or 0.0
        if report.failed:
            if acc["status"] != "failed" and acc["status"] != "error":
                acc["status"] = "failed" if report.when == "call" else "error"
                acc["report"] = report
        elif report.skipped and acc["status"] == "passed":
            acc["status"] = "skipped"
            acc["report"] = report
        if report.when != "teardown":
            return
        del self.pending[report.nodeid]
        item = self.items.get(report.nodeid)
        result = {
            "id": report.nodeid,
            "file": item_file(item) if item else os.path.join(ROOT, report.location[0]),
            "name": nodeid_name(report.nodeid),
            "line": (report.location[1] + 1) if isinstance(report.location[1], int) else None,
            "status": acc["status"],
            "duration": round(acc["duration"] * 1000, 3),
            "output": clip(captured(report), MAX_OUTPUT),
        }
        failing = acc["report"]
        if acc["status"] in ("failed", "error") and failing is not None:
            err = getattr(item, "_testview_error", None) if item else None
            text = failing.longreprtext
            if err:
                result["error"] = error_of(err[0], err[1], err[2], result["file"], text)
            else:
                result["error"] = {"type": "Error", "message": last_line(text), "frames": [], "text": clip(text, MAX_TEXT)}
            if acc["status"] == "error":
                result["error"]["phase"] = failing.when
        elif acc["status"] == "skipped" and failing is not None:
            longrepr = failing.longrepr
            reason = longrepr[2] if isinstance(longrepr, tuple) and len(longrepr) == 3 else str(longrepr or "")
            if reason.startswith("Skipped: "):
                reason = reason[len("Skipped: "):]
            result["reason"] = reason
        self.out.emit("result", **result)


_SKIP = None


def skip_exceptions():
    global _SKIP
    if _SKIP is None:
        import pytest
        kinds = [pytest.skip.Exception]
        xfail = getattr(pytest.xfail, "Exception", None)
        if xfail:
            kinds.append(xfail)
        _SKIP = tuple(kinds)
    return _SKIP


def captured(report):
    parts = []
    for title, text in report.sections:
        if title.startswith("Captured") and text:
            parts.append(text if len(report.sections) == 1 else "── %s ──\n%s" % (title, text))
    return "".join(parts) or None


def last_line(text):
    lines = [l for l in (text or "").splitlines() if l.strip()]
    for line in reversed(lines):
        if line.startswith("E "):
            return line[1:].strip()
    return lines[-1].strip() if lines else ""


def pytest_main(out, collect_only, ids):
    import pytest
    args = ["-q", "--color=no", "-p", "no:randomly"]
    if collect_only:
        args.append("--collect-only")
    args.extend(ids)
    plugin = PytestPlugin(out, collect_only)
    return pytest.main(args, plugins=[plugin])


def has_pytest():
    try:
        import pytest  # noqa: F401
        return True
    except Exception:
        return False


def wants_pytest():
    """Whether the project names pytest anywhere (config files, dependencies, conftest)."""
    if os.path.exists(os.path.join(ROOT, "pytest.ini")) or os.path.exists(os.path.join(ROOT, "conftest.py")):
        return True
    for name, marker in (("pyproject.toml", "pytest"), ("setup.cfg", "tool:pytest"), ("tox.ini", "pytest"),
                         ("requirements-dev.txt", "pytest"), ("requirements.txt", "pytest")):
        path = os.path.join(ROOT, name)
        try:
            with open(path, encoding="utf-8") as fh:
                if marker in fh.read():
                    return True
        except OSError:
            pass
    return False


# ---------------------------------------------------------------- unittest


def iter_tests(suite):
    import unittest
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            for t in iter_tests(test):
                yield t
        else:
            yield test


def unittest_meta(test):
    import inspect
    method = getattr(test, "_testMethodName", None)
    fn = getattr(test, method, None) if method else None
    path, line = None, None
    try:
        path = inspect.getsourcefile(type(test))
        if fn is not None:
            line = inspect.getsourcelines(fn)[1]
    except (TypeError, OSError):
        pass
    cls = type(test).__name__
    name = "%s › %s" % (cls, method) if method else test.id()
    return path, line, name


def failed_load(test):
    return type(test).__name__ == "_FailedTest" or test.id().startswith("unittest.loader.")


def unittest_load(ids):
    import unittest
    loader = unittest.TestLoader()
    if ids:
        return loader.loadTestsFromNames(ids)
    start = ROOT
    for name in ("tests", "test"):
        if os.path.isdir(os.path.join(ROOT, name)) and not os.path.exists(os.path.join(ROOT, name, "__init__.py")):
            start = os.path.join(ROOT, name)
            break
    return loader.discover(start, pattern="test*.py", top_level_dir=ROOT if start == ROOT else start)


def unittest_collect(out):
    suite = unittest_load([])
    tests = []
    for test in iter_tests(suite):
        if failed_load(test):
            emit_load_error(out, test)
            continue
        path, line, name = unittest_meta(test)
        tests.append({"id": test.id(), "file": path, "name": name, "line": line})
    out.emit("collect", framework="unittest", rootdir=ROOT, tests=tests)


def emit_load_error(out, test):
    exc = getattr(test, "_exception", None)
    module = test.id().split(".")[-1]
    path = os.path.join(ROOT, *module.split(".")) + ".py"
    text = str(exc) if exc else test.id()
    out.emit("file_error", file=path, message=last_line(text), text=clip(text, MAX_TEXT))


def unittest_run(out, ids):
    import unittest

    class Result(unittest.TestResult):
        def __init__(self):
            super().__init__()
            self.buffer = True
            self.current = None

        def startTest(self, test):
            self.current = {"t0": time.perf_counter(), "status": "passed", "error": None, "reason": None}
            out.emit("start", id=test.id())
            super().startTest(test)

        def _set(self, test, status, err=None, reason=None):
            if self.current is None:
                return
            self.current["status"] = status
            if err is not None:
                path = unittest_meta(test)[0]
                text = "".join(traceback.format_exception(*err))
                self.current["error"] = error_of(err[0], err[1], err[2], path, text)
            self.current["reason"] = reason

        def addFailure(self, test, err):
            super().addFailure(test, err)
            self._set(test, "failed", err)

        def addError(self, test, err):
            super().addError(test, err)
            self._set(test, "error", err)

        def addSkip(self, test, reason):
            super().addSkip(test, reason)
            self._set(test, "skipped", reason=reason)

        def addExpectedFailure(self, test, err):
            super().addExpectedFailure(test, err)
            self._set(test, "passed")

        def addUnexpectedSuccess(self, test):
            super().addUnexpectedSuccess(test)
            self._set(test, "failed")
            self.current["error"] = {"type": "UnexpectedSuccess", "message": "expected to fail, but passed", "frames": []}

        def addSubTest(self, test, subtest, err):
            super().addSubTest(test, subtest, err)
            if err is not None:
                failed = issubclass(err[0], test.failureException)
                self._set(test, "failed" if failed else "error", err)

        def stopTest(self, test):
            output = None
            stdout = getattr(self, "_stdout_buffer", None)
            stderr = getattr(self, "_stderr_buffer", None)
            if stdout is not None or stderr is not None:
                output = (stdout.getvalue() if stdout else "") + (stderr.getvalue() if stderr else "")
            # The buffered output is reported in the event; don't also echo it to stdout.
            self._mirrorOutput = False
            super().stopTest(test)
            cur, self.current = self.current, None
            if cur is None or failed_load(test):
                return
            path, line, name = unittest_meta(test)
            fields = {
                "id": test.id(), "file": path, "name": name, "line": line, "status": cur["status"],
                "duration": round((time.perf_counter() - cur["t0"]) * 1000, 3),
                "output": clip(output, MAX_OUTPUT) or None,
            }
            if cur["error"]:
                fields["error"] = cur["error"]
            if cur["reason"]:
                fields["reason"] = cur["reason"]
            out.emit("result", **fields)

    suite = unittest_load(ids)
    runnable = unittest.TestSuite()
    for test in iter_tests(suite):
        if failed_load(test):
            emit_load_error(out, test)
        else:
            runnable.addTest(test)
    result = Result()
    runnable.run(result)
    return 0 if result.wasSuccessful() else 1


# ---------------------------------------------------------------- main


def main(argv):
    if len(argv) < 2 or argv[0] not in ("collect", "run"):
        sys.stderr.write(__doc__)
        return 2
    mode = argv[0]
    rest = argv[1:]
    out_path, framework, ids = None, "auto", []
    i = 0
    while i < len(rest):
        if rest[i] == "--out":
            out_path = rest[i + 1]
            i += 2
        elif rest[i] == "--framework":
            framework = rest[i + 1]
            i += 2
        else:
            ids.append(rest[i])
            i += 1
    if not out_path:
        sys.stderr.write("--out is required\n")
        return 2
    # Behave like `python -m pytest`: the project's directory first on sys.path, not ours.
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path[:] = [p for p in sys.path if os.path.abspath(p or ".") != here]
    sys.path.insert(0, ROOT)
    out = Out(out_path)
    if framework == "auto":
        framework = "pytest" if has_pytest() and (wants_pytest() or not unittest_finds_tests()) else "unittest"
        if framework == "pytest" and not has_pytest():
            framework = "unittest"
    if framework == "pytest" and not has_pytest():
        out.emit("fatal", message="pytest is not installed for %s" % sys.executable)
        return 3
    try:
        if framework == "pytest":
            code = pytest_main(out, mode == "collect", ids)
        elif mode == "collect":
            unittest_collect(out)
            code = 0
        else:
            code = unittest_run(out, ids)
    except Exception:
        out.emit("fatal", message=traceback.format_exc())
        code = 3
    out.emit("done", code=int(code) if code is not None else 0)
    return code


def unittest_finds_tests():
    try:
        return any(not failed_load(t) for t in iter_tests(unittest_load([])))
    except Exception:
        return False


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
