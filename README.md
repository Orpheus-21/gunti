# gunti

A terminal file manager in Odin. No ncurses, no dependencies — just `core:os`,
`core:sys/posix` for raw mode, and ANSI escapes.

Built in stages, in public. It now browses: move the highlight, walk into
directories, walk back out. It does not copy, move, delete, rename, or preview
anything. Stage 3 of 4.

## build

    odin build . -out:gunti

## usage

    ./gunti

Browses whatever directory you launch it from. To use it anywhere, put it on
your PATH:

    ln -s "$PWD/gunti" ~/.local/bin/gunti

## keys

| key | does |
|---|---|
| `j` / `↓` | down |
| `k` / `↑` | up |
| `l` / `→` / `Enter` | into the highlighted directory |
| `h` / `←` / `Backspace` | up to the parent |
| `q` / `Ctrl-C` | quit |

Changing directory only affects gunti. Your shell stays where it was — this is
not a `cd` replacement and can't be one, since no process can change its
parent's directory.

## requirements

Odin `dev-2026-08` or newer. Linux — raw mode goes through posix termios, so
Windows is out and staying out.

## known rough edges

- No scrolling. A directory taller than your terminal runs off the top.
- Directories you can't read show as empty rather than saying so.
- Going up always lands the highlight on the first entry, not on the directory
  you just came out of.
- Pressing Escape alone blocks until you press two more keys.

## stages

1. **done** — list a directory, sorted, exit.
2. **done** — raw mode, moving highlight, quit without wrecking the terminal.
3. **done** — walk into directories and back out, path bar.
4. size and permissions, delete with a confirm, rename.

No config file, no themes, no keybinding system, no preview pane, no mouse.
If any of that ever shows up here, something has gone wrong.
