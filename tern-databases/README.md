# Databases

**PostgreSQL, SQLite, Trino and Redis in [Tern](https://docs.stencil.so/tern/), with every
password in the system keychain.** Save connections, browse a database's tables or a Redis
server's keys, write queries with completion, and when you'd rather describe a query than write
it, a `?` line asks the agent of your session to write it in the editor for you.

<p align="center">
  <img src="docs/console.png" alt="The Databases pane: connections and tables on the left, a SQL query with a ? request line and a completion list of a table's columns, and the query's results below" width="100%">
</p>

## Install

```sh
tern plugin install github.com/sneaky-bulgarian/tern-plugins/tern-databases
```

The drivers are part of the plugin and use only Python's standard library, so there is nothing
to `pip install` and no `psql`, `trino` or `redis-cli` to have. They need Python 3.8 or later:
macOS has it with Xcode's command line tools, Homebrew's `python3` is used first when present.

## Open it

- Palette: **Databases**, or <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>D</kbd>. It opens beside
  the focused pane, or shows the one already open.
- Files pane: **Open with Databases** on a `.db`, `.sqlite`, `.sqlite3` or `.db3` file adds it
  as a SQLite connection and opens it.

## Connections

**New connection** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>N</kbd>) opens a sheet for the kind, its
address, user and password; **Test** connects without saving. Pasting a URL into Host fills in
the rest: `postgres://ada@db.example.com:5432/app?sslmode=require`,
`rediss://:secret@cache.example.com:6380/0`, `trino://ada@trino.example.com:443/hive/web`.
<kbd>F2</kbd> edits the chosen connection; right-click one to duplicate or delete it.

| Kind | Connects with |
| --- | --- |
| PostgreSQL | host or socket directory, port, database, user, password; SSL `disable`, `prefer`, `require` (encrypted) or `verify-full` (certificate and host name checked); trust, password, md5 and SCRAM-SHA-256 logins |
| SQLite | an existing database file |
| Trino | host, port, catalog, schema, user; a password needs HTTPS, as Trino requires |
| Redis | host, port, password and Redis 6 ACL user, database number, TLS (`rediss://`) |

**Where the passwords are.** In the system keychain through Tern's plugin secrets: on macOS the
login keychain, service `so.stencil.tern`, account `plugin.databases.conn.<id>`. The connections
themselves, without passwords, are in the plugin's `kv.json`, shared by every Databases pane and
window. A password reaches the driver on its standard input, never in its arguments or
environment, and is never written to a file, to the pane's saved state or into a link. Deleting
a connection deletes its password.

## The pane

On the left, the connections and the chosen one's tables and views; for Redis, its keys (from
`SCAN`, with type and time to live). <kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd> filters them (for
Redis, a `MATCH` pattern such as `user:*`). Click a table for its columns, double-click it for
its first rows; its right-click menu also counts rows, inserts a `SELECT` and copies the name.
Click a Redis key for its value.

On the right, the query editor over the results.

- **Completion** opens as you type (<kbd>⌃</kbd><kbd>Space</kbd> asks for it): tables after
  `FROM`, `JOIN`, `INTO` and `UPDATE`, a table's columns after its alias and a dot and in the
  clauses that use them, a schema's tables after the schema and a dot, functions and keywords.
  For Redis, commands with their arguments, then key names and the command's options.
  <kbd>↑</kbd><kbd>↓</kbd> choose, <kbd>⇥</kbd> or <kbd>⏎</kbd> inserts.
- **Running.** <kbd>⌘</kbd><kbd>⏎</kbd> runs the statement at the caret (for Redis, the block of
  lines around it), <kbd>⌥</kbd><kbd>⌘</kbd><kbd>⏎</kbd> the whole editor.
  <kbd>⌘</kbd><kbd>.</kbd> cancels, on the server too: PostgreSQL gets a cancel request, Trino
  a `DELETE` of the query.
- **Results** show up to the limit you pick (100 to 5,000 rows). A script gives a result per
  statement; click a row for all its values. **Copy** exports the rows as CSV, TSV, JSON or a
  Markdown table. An error marks where the server says it is in the editor.
- **Sessions.** Each run is a session of its own, so a transaction begins and ends in one run
  (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>⏎</kbd> on `BEGIN; …; COMMIT;`); one left open is rolled back.
  Trino's `USE` carries over to the next runs, and the head row says where they start.

## Asking the agent

Write what you want on a line starting with `?`, on its own or above a query you want changed,
and press <kbd>⌘</kbd><kbd>I</kbd> (or <kbd>⌘</kbd><kbd>⏎</kbd> on it):

```sql
? the 10 customers who spent most this year, with their email
```

The block sends an agent of its session the request, the query under it, the connection and the
schema (tables, columns and their types; never rows or passwords). It asks the agent it asked
last, else one in its own tab, else an idle one; with none in the session it starts one beside
the block. The agent's query replaces the request in the editor and does not run:
<kbd>⌘</kbd><kbd>Z</kbd> brings the request back. After a failure, **Ask agent to fix**
(<kbd>⇧</kbd><kbd>⌘</kbd><kbd>I</kbd>) sends the error with the statement.

## Keys

| Key | Does |
| --- | --- |
| ⌘⏎ | Run the statement at the caret, or ask the agent when it has a `?` line |
| ⌥⌘⏎ | Run every statement in the editor |
| ⌘. | Cancel the running query |
| ⌘I, ⇧⌘I | Ask the agent for the query a `?` line describes; to fix the error shown |
| ⌃Space | Complete; ↑ ↓ choose, ⇥ or ⏎ insert, Esc close |
| ⌘/ | Comment or uncomment the lines |
| ⇥, ⇧⇥ | Indent, outdent |
| ⌥↑ ⌥↓ | Previous or next connection |
| ⌘R | Load the tables or keys again |
| ⇧⌘F | Filter the tables or keys; ↑ ↓ choose, ⏎ shows rows, Esc leaves |
| ⇧⌘N, F2 | New connection, edit the chosen one |

## How it works

`host.luau` is the `console` block. Each request runs `drivers/tdb.py` once, with the request
and the password on its standard input and one JSON answer on its output. The drivers speak the
databases' own protocols with the Python standard library: PostgreSQL's frontend/backend
protocol (each statement through Parse, Bind and a row-limited Execute, so a big result stops
at the limit), Trino's REST protocol, Redis's RESP, and SQLite through `sqlite3`. A cancel sends
the driver `SIGTERM`, and it stops the statement the way the database allows.

A block can't reach the keychain or the agents, so it asks `window.luau` over `databases:`
links, answered only for Databases panes. To store a password the window reads it from the
pane's own masked field rather than from the link. An agent request goes through `tern.kv`:
the window hands the prompt to the agent with `cx.agents`, waits for its turn to end, and sends
the answer back; the block takes the query out of its last code block. `databases.css` makes
the work area fill the pane.

## Develop

```sh
tern plugin link .          # reloads on every save
tern plugin types .         # tern.d.luau for luau-lsp
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau $(ls *.luau | grep -v tern.d.luau)
echo '{"op":"test","conn":{"kind":"sqlite","path":"app.db"}}' | python3 drivers/tdb.py
```
