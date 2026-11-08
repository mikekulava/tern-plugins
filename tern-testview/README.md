# Test Explorer

**A test runner panel for [Tern](https://docs.stencil.so/tern/).** It finds the unit tests in
a workspace, lists them by file, runs them, and shows each failure's trace next to the
source line.

<p align="center">
  <img src="docs/demo.gif" alt="Test Explorer runs a Python suite: six pass, one fails, one is skipped; selecting the failure shows the AssertionError, the stack and the failing line" width="100%">
</p>

## Install

```sh
tern plugin install github.com/sneaky-bulgarian/tern-plugins/tern-testview
```

## What it runs

- **pytest** and **unittest**: any directory with `pyproject.toml`,
  `pytest.ini`, `setup.cfg`, `setup.py` or `tox.ini` (or the workspace itself
  when nothing else is found). Uses the project's `.venv`/`venv` interpreter
  when there is one, else `python3`. It picks pytest when the project mentions
  it and has it installed, otherwise unittest.
- **vitest** (2 and later) and **jest** (26.5 and later): any `package.json`
  that depends on them, run through `node_modules/.bin`.

The workspace is the git checkout containing the directory you open it from,
searched 4 levels deep (skipping `node_modules`, hidden directories, virtualenvs
and build output).

## Use

- Palette: **Open test explorer** (⇧⌘U) opens it beside the focused pane, for
  that pane's directory.
- Files pane: **Open with Test Explorer** on a test file opens it with that
  file selected.

| Key | Does |
| --- | --- |
| ↑ ↓ / j k | Move |
| ← → / h l, Space | Fold and unfold files and suites |
| Enter / r | Run the selected test, file or suite |
| ⇧R | Run everything |
| F | Rerun failed tests (and files that failed to load) |
| O, double-click | Open the test at its line |
| C | Copy the failure |
| P | Hide passed tests |
| X | Stop the run |
| D | Look for suites again |

Clicking a file unfolds it. Clicking a test shows its result on the right: the
error and stack (your frames first, library frames dimmed, the failing line
highlighted in the source), the assertion message or diff, the runner's full
report, and the captured output. Double-click a frame to open it.

Results are kept per workspace in the plugin's data directory, so they come
back the next time the explorer opens.

## How it works

`host.luau` defines the block; `frameworks.luau` finds suites and builds the
runner command lines; `model.luau` holds the tree and applies results;
`view.luau` draws it. Runners report through the helpers in `helpers/`
(`testview_py.py`, `vitest-reporter.mjs`, `jest-reporter.cjs`). Each writes one
JSON event per line to the file `$TESTVIEW_OUT` names, which the block reads
while the run goes on.

## Develop

```sh
tern plugin link .          # reloads on every save
tern plugin types .         # tern.d.luau for luau-lsp
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau *.luau
```
