"""Test Explorer: lets the explorer follow test runs started in Tern panes.

Tern panes opened while the plugin is loaded get this directory on PYTHONPATH and
TESTVIEW_WATCH naming a spool directory. Python then imports this module at startup,
which only installs an import hook: when a process imports pytest's config or
unittest's runner, testview_watch.py adds a reporter that writes the run's events to a
file in the spool, where the Test Explorer picks it up. Processes that run no tests
load nothing else.

Afterwards it runs the sitecustomize this one shadows, if the environment has one.
"""

import os
import sys


def _install():
    if not os.environ.get("TESTVIEW_WATCH") or os.environ.get("TESTVIEW_OUT"):
        return
    here = os.path.dirname(os.path.abspath(__file__))

    def patch(name):
        def run(module):
            if here not in sys.path:
                sys.path.append(here)
            import testview_watch

            getattr(testview_watch, "patch_" + name)(module)

        return run

    hooks = {"_pytest.config": patch("pytest"), "unittest.runner": patch("unittest")}

    class AfterImport:
        """Runs a hook right after one of `hooks`' modules finishes executing."""

        def find_spec(self, name, path=None, target=None):
            hook = hooks.get(name)
            if hook is None:
                return None
            for finder in sys.meta_path:
                if finder is self or not hasattr(finder, "find_spec"):
                    continue
                spec = finder.find_spec(name, path, target)
                if spec is not None:
                    break
            else:
                return None
            loader = spec.loader
            if loader is None or not hasattr(loader, "exec_module"):
                return spec
            del hooks[name]
            original = loader.exec_module

            def exec_module(module):
                original(module)
                try:
                    hook(module)
                except Exception:
                    pass

            loader.exec_module = exec_module
            return spec

    sys.meta_path.insert(0, AfterImport())


def _chain():
    """Runs the next sitecustomize on sys.path, which this module hides."""
    import importlib.machinery
    import importlib.util

    here = os.path.dirname(os.path.abspath(__file__))
    rest = [p for p in sys.path if os.path.abspath(p or ".") != here]
    spec = importlib.machinery.PathFinder.find_spec("sitecustomize", rest)
    if spec is None or spec.loader is None:
        return
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)


try:
    _install()
except Exception:
    pass

try:
    _chain()
except Exception:
    pass
