# gunti

A terminal file manager in Odin. No ncurses, no dependencies — just `core:os`,
`core:sys/posix` for raw mode, and ANSI escapes.

It browses: move the highlight, walk into
directories, walk back out, scroll through listings bigger than the screen. It
does not copy, move, delete, rename, or preview anything.

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

The bottom bar shows the highlighted entry's size and where you are in the
listing. Long directories scroll; resizing the window is picked up on the next
keypress.

Changing directory only affects gunti. Your shell stays where it was — this is
not a `cd` replacement and can't be one, since no process can change its
parent's directory.

## requirements

Odin `dev-2026-08` or newer. Linux — raw mode goes through posix termios.
