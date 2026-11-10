# Git Identity

**Choose which git user a repository commits as, in [Tern](https://docs.stencil.so/tern/).**
Pick one of the identities on this machine or add a new one, and the repository's commits
use it, whether they come from Tern's git block, an omp agent or the terminal.

## Install

```sh
tern plugin install github.com/sneaky-bulgarian/tern-plugins/tern-git-identity
```

## Open it

- Status line: click **git user** (shown when the focused pane is inside a git repository and
  Settings › Status line is on), or press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>Y</kbd>. It opens for
  the focused pane's repository.
- Files pane: the person button in its header opens it for the selected folder's repository,
  else the repository of the folder the pane shows.
- Palette: **Git identity for this repository**.

Outside a git repository it says so instead of opening.

## The pane

The header shows the repository, its branch, the identity commits use now and where that is
set: this repository's `.git/config`, the global `~/.gitconfig` or the system config.

The list holds the global and system `user.name` and `user.email`, those in files that
`includeIf` pulls into `~/.gitconfig`, the repository's own, and the identities you add. Added
identities are kept by the plugin and offered in every repository. The one in use has a check.

| Key | Does |
| --- | --- |
| ↑ ↓, click | Select |
| ⏎, double-click | Use the selected identity for this repository |
| A | Add an identity: name, then email (⇥ between them); ⏎ saves and uses it, Esc cancels |
| D | Remove an identity you added |
| R | Read the git settings again |

**Reset to default** removes the repository's own identity, so the global one applies again.

## How it works

Using an identity runs `git config --local user.name` and `git config --local user.email` in
the repository; **Reset to default** runs `git config --local --unset-all` on both. Nothing
outside the repository's `.git/config` changes. Tern's git block commits through git, so it
picks the setting up like any other git command.

`window.luau` finds the repository with `git rev-parse --show-toplevel` and opens the
`identity` block from `host.luau` beside the focused pane, or switches to the one already open
for that repository.

## Develop

```sh
tern plugin link .          # reloads on every save
tern plugin types .         # tern.d.luau for luau-lsp
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau *.luau
```
