# Search Everywhere

**PyCharm's Search Everywhere, in [Tern](https://docs.stencil.so/tern/).** Tap **Shift twice** and
jump to any file, class, function or variable in the folder you're in.

<p align="center">
  <img src="docs/demo.gif" alt="Double Shift opens a search bar; typing QuerySet, urls and Model.save finds them in the Django source, and Enter opens base.py at Model.save" width="100%">
</p>

<p align="center"><sub>Django's 7,000 files and 52,000 declarations, indexed in about three seconds.</sub></p>

The bar starts as just the scope tabs and the query, and grows to fit the results once there
are some (up to 12 rows, at most three quarters of the tab). Matching works like JetBrains:
`fbn` finds `findByName`, `Model.save` finds a method of a class, `db/models` matches paths
and `views.py:10` opens at line 10.

## Install

```sh
tern plugin install github.com/sneaky-bulgarian/tern-plugins/tern-searcheverywhere
```

## What it searches

- The folder is the focused pane's working directory, or the folder of the file it shows.
- Files come from `git ls-files` (tracked and untracked, without ignored ones) inside a git
  checkout, else from `find`, else (Windows) a walk in Luau, skipping hidden directories,
  `node_modules`, virtualenvs and build output.
- Declarations are read from Python, JavaScript/TypeScript, Go, Rust, Lua/Luau, Ruby,
  Java, C#, Dart, Kotlin, Scala, Swift, C/C++, PHP and shell files. Only top-level
  declarations and members of classes, structs, traits and the like count, not locals.

## Use

- **Shift, Shift** (or the palette's **Search everywhere**) opens the overlay. Doing it again
  while it shows closes it. Tern's double-tap shortcuts don't tell left Shift from right,
  so either Shift works; rebind it in Settings › Keyboard.
- Files pane: the search button in its header searches that folder.
- Status line: click **Search** (shown when Settings › Status line is on).

| Key | Does |
| --- | --- |
| typing | Filter: `fbn` finds `findByName`, `Model.save` a method in a class, `db/models` a path |
| `name:42` | Open the pick at line 42 |
| ↑ ↓, ⌃P ⌃N, Page Up/Down | Move; ↓ on an empty query lists your last picks in that folder |
| ⏎, double-click | Open the pick (in a file block, at its line) and close the overlay |
| ⇥ / ⇧⇥ | All → Files → Symbols |
| ⌥⌫ / ⌃W, ⌘⌫ / ⌃U | Delete a word, clear |
| Esc, click outside | Close |

Matches rank exact names first, then prefixes, then matches starting at a word or camel
hump, then looser ones; one typed character matches name starts only. The best 100 show.

## How it works

`window.luau` registers the command (default chord `shift>shift`), the Files pane
button and a status line segment, and opens the `search` block with `how = "glimpse"`. Tern draws a glimpse over the
whole tab and has no selector for one block's glimpse, so while the bar shows the window
half installs a sheet (`tern.css`) that sizes every glimpse and hides its header and
footer, and drops it when the bar closes. The block reports how many list lines it shows
in its title (`Search Everywhere · results 8`), and the window half resizes the sheet on
each `title` event. `host.luau` is the block: the query, ranking and view. `index.luau`
lists and reads files in 25 ms slices so the bar stays live while it indexes, keeps an
index per folder while the host runs, and rebuilds it in the background when the bar opens
after 20 s, or after ten times what the last build took. `symbols.luau` finds declarations
line by line per language (brace depth or indentation decides what is top level);
`fuzzy.luau` scores names.

### Big folders

A plugin's Luau heap in Tern holds 256 MiB, garbage included, and nothing can force a
collection, so the index is built to stay small whatever the folder (a home folder, `/`,
the Linux kernel):

- A file costs its name plus 4 bytes, a declaration its name plus 13 bytes (file, line,
  owner and kind live in byte buffers); folder paths and owner names are stored once.
- All folders' indexes together stay under about 72 MiB. Past that, folders no open bar
  shows are dropped, least recently used first; then the index stops growing and the bar
  says **partly indexed, folder too big**. Files nearest the folder are listed and read
  first, so a cut keeps them: a listing too big for one read is redone shallower.
- Files over 1 MiB, binary files and lines over 2,000 characters (minified code) aren't
  read for declarations, and one file adds at most 2,000 of them.
- If memory runs out anyway, the index keeps what it has and the bar stays usable;
  later builds use a smaller budget.

On the Linux kernel (97k files) the whole file list and about 530k declarations fit, in
about 25 s, with the heap peaking near 120 MiB.

Picks on this machine are opened by the window half so the file takes focus; on a remote
host the block opens them.

## Develop

```sh
tern plugin link .          # reloads on every save
tern plugin types .         # tern.d.luau for luau-lsp
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau *.luau
```
