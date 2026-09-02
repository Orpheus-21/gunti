# gunti

A terminal file manager in Odin. No ncurses, no dependencies — just `core:os`
and ANSI escapes.

Built in stages, in public. Right now it is at stage 1: it lists a directory
and exits. It does not navigate, it does not take input, it is not yet a file
manager. Watch this space or don't.

## build

    odin build . -out:gunti

## usage

    ./gunti

Prints the sorted contents of the current directory, one per line, directories
suffixed with `/`. That's it. That's the whole program.

## requirements

Odin `dev-2026-08` or newer. Linux — later stages use posix termios for raw
mode, so Windows is out and staying out.

## stages

1. **done** — list a directory, sorted, exit.
2. raw mode, cursor, `j`/`k` to move a highlight, `q` to quit.
3. `Enter`/`l` into a directory, `h` back out, path bar.
4. maybe: size/permission line, delete with a confirm, rename.

No config file, no themes, no keybinding system, no preview pane, no mouse.
If any of that ever shows up here, something has gone wrong.
