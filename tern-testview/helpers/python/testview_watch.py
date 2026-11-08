"""Test Explorer: reports a pytest or unittest run started in a Tern pane (by you or by an
agent) to the spool directory in TESTVIEW_WATCH, one JSON event per line, in the format
testview_py.py writes for the explorer's own runs. sitecustomize.py patches the runners
when they are imported; nothing here changes what the run prints or how it exits.

Each run writes `<spool>/<ms since epoch>-<pid>.jsonl`, starting with a `watch` event
naming the working directory, the pane (TERN_PANE) and the framework.
"""

import os
import sys
import time

_here = os.path.dirname(os.path.abspath(__file__))
_helpers = os.path.dirname(_here)
if _helpers not in sys.path:
    sys.path.append(_helpers)
import testview_py  # noqa: E402

_runs = 0


class Spool:
    """The run's event file, created when the first event arrives."""

    def __init__(self, framework):
        self.framework = framework
        self.out = None

    def emit(self, ev, **fields):
        if self.out is None:
            global _runs
            _runs += 1
            spool = os.environ["TESTVIEW_WATCH"]
            os.makedirs(spool, exist_ok=True)
            name = "%d-%d-%d.jsonl" % (int(time.time() * 1000), os.getpid(), _runs)
            self.out = testview_py.Out(os.path.join(spool, name))
            self.out.emit(
                "watch",
                framework=self.framework,
                cwd=os.getcwd(),
                pane=os.environ.get("TERN_PANE"),
                argv=sys.argv,
                python=sys.executable,
                pid=os.getpid(),
            )
        self.out.emit(ev, **fields)


# ---------------------------------------------------------------- pytest


class PytestWatch:
    """Registered with every pytest session; reports it unless it only collects."""

    def __init__(self):
        self.spool = None

    def pytest_configure(self, config):
        if config.getoption("collectonly", False) or hasattr(config, "workerinput"):
            return
        self.spool = Spool("pytest")
        config.pluginmanager.register(testview_py.PytestPlugin(self.spool, False), "testview-watch-events")

    def pytest_sessionfinish(self, session, exitstatus):
        if self.spool is not None and self.spool.out is not None:
            self.spool.emit("done", code=int(exitstatus))


def patch_pytest(config_module):
    original = config_module.main
    if getattr(original, "_testview", False):
        return

    def main(args=None, plugins=None):
        return original(args, list(plugins or []) + [PytestWatch()])

    main._testview = True
    config_module.main = main


# ---------------------------------------------------------------- unittest


def patch_unittest(runner_module):
    base = runner_module.TextTestRunner.resultclass
    if getattr(base, "_testview", False):
        return

    class WatchResult(base):
        """unittest's text result, also reporting each test to the spool."""

        _testview = True

        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self._spool = Spool("unittest")
            self._current = None

        def startTest(self, test):
            self._current = {"t0": time.perf_counter(), "status": "passed", "error": None, "reason": None}
            if not testview_py.failed_load(test):
                self._spool.emit("start", id=test.id())
            super().startTest(test)

        def _set(self, test, status, err=None, reason=None):
            cur = self._current
            if cur is None:
                return
            cur["status"] = status
            if err is not None:
                path = testview_py.unittest_meta(test)[0]
                text = "".join(testview_py.traceback.format_exception(*err))
                cur["error"] = testview_py.error_of(err[0], err[1], err[2], path, text)
            cur["reason"] = reason

        def addFailure(self, test, err):
            super().addFailure(test, err)
            self._set(test, "failed", err)

        def addError(self, test, err):
            super().addError(test, err)
            if testview_py.failed_load(test):
                testview_py.emit_load_error(self._spool, test)
                self._current = None
            else:
                self._set(test, "error", err)

        def addSkip(self, test, reason):
            super().addSkip(test, reason)
            self._set(test, "skipped", reason=reason)

        def addUnexpectedSuccess(self, test):
            super().addUnexpectedSuccess(test)
            self._set(test, "failed")
            if self._current is not None:
                self._current["error"] = {"type": "UnexpectedSuccess", "message": "expected to fail, but passed", "frames": []}

        def addSubTest(self, test, subtest, err):
            super().addSubTest(test, subtest, err)
            if err is not None:
                self._set(test, "failed" if issubclass(err[0], test.failureException) else "error", err)

        def stopTest(self, test):
            super().stopTest(test)
            cur, self._current = self._current, None
            if cur is None or testview_py.failed_load(test):
                return
            path, line, name = testview_py.unittest_meta(test)
            fields = {
                "id": test.id(), "file": path, "name": name, "line": line, "status": cur["status"],
                "duration": round((time.perf_counter() - cur["t0"]) * 1000, 3),
            }
            if cur["error"]:
                fields["error"] = cur["error"]
            if cur["reason"]:
                fields["reason"] = cur["reason"]
            self._spool.emit("result", **fields)

        def stopTestRun(self):
            super().stopTestRun()
            if self._spool.out is not None:
                self._spool.emit("done", code=0 if self.wasSuccessful() else 1)

    runner_module.TextTestRunner.resultclass = WatchResult
