# gunti

A terminal file manager. Browse and manage files with the keyboard, inside a terminal window.

## Introduction

Most people move files around by opening a window full of icons and dragging things
with a mouse. gunti does the same job, but it draws a plain list of your files in a
terminal and you move through it with the keyboard. No mouse, no icons, no pictures.

You press a key to move down the list, another to open a folder, another to copy or
delete. Because your hands never leave the keyboard, it is faster than clicking once
you know the keys. There are 24 of them and pressing `?` shows the list at any time.

The whole program is one file of about 1500 lines and it depends on nothing except
the C library your system already has. It starts instantly, including in folders
holding tens of thousands of files. It does not preview images, it has no tabs, and
it will never grow a plugin system. When you want it to do something it does not do,
you tell it to run an ordinary shell command instead, and you bind that command to a
key in a config file.

If you have used `ranger`, `lf` or `yazi`, this is the same category of tool, smaller.

## requirements

Linux only. Raw terminal mode uses POSIX termios and directory reading uses
Linux syscalls directly. No macOS, no BSD, no Windows, and no plans for them.

To run: nothing. The released binary is statically linked and needs kernel 3.2
or newer. There is no libc version requirement, so it works on musl systems
such as Alpine. A binary you build yourself inherits whatever floor your own
toolchain targets.

Used if present, neither needed to start:

- `sh`, for shell command bindings.
- A pager for the `v` key. Uses `$PAGER`, falls back to `less`.

To build: Odin `dev-2026-08` or newer.

## install

Download the binary from the latest release, verify it, put it on your `PATH`:

    curl -fLO https://github.com/Orpheus-21/gunti/releases/latest/download/gunti
    curl -fLO https://github.com/Orpheus-21/gunti/releases/latest/download/gunti.sha256
    sha256sum -c gunti.sha256
    install -Dm755 gunti ~/.local/bin/gunti

GitHub does not preserve the executable bit on release downloads, which is why
`install` sets the mode.

Or build it:

    make
    sudo make install

`make install` honours `DESTDIR` and `PREFIX`:

    make install DESTDIR=/tmp/stage PREFIX=/usr

## build

    make            # build
    make test       # run the tests
    make release    # static, stripped, with a checksum
    make clean

16 tests. They cover the directory reader against `core:os`, path and layout maths,
config parsing, search, sorting, colour selection and the permission parser.

## usage

    ./gunti

With no argument, opens the directory you launch it from. Give it a directory
to start there instead:

    gunti ~/Downloads
    gunti /etc

A path that does not exist, is not a directory, or cannot be read is reported
on stderr and exits 1 rather than opening something else.

    gunti --version

## keys

| key | does |
|---|---|
| `j` `k` | down, up |
| `g` `G` | top, bottom |
| `h` | parent directory |
| `l` | enter directory, or open file in `$EDITOR` |
| `c` | go to a path, `~` accepted |
| `R` | re-read the folder from disk |
| `/` | search |
| `n` `N` | next match, previous match |
| `s` | cycle sort: name, size, time |
| `.` | show or hide dotfiles |
| `space` | tick a file |
| `v` | page through a file |
| `!` | run a shell command |
| `a` | create, end the name with `/` for a directory |
| `r` | rename |
| `d` | delete |
| `m` | change permissions, octal like `644` |
| `y` `x` `p` | copy, cut, paste |
| `?` | help |
| `q` | quit |

Arrows work as `hjkl`. Backspace works as `h`. Enter works as `l`. Ctrl-C quits.

`d`, `y`, `x` and `m` act on every ticked file. With nothing ticked they act on the
highlighted one. Ticks clear whenever the listing reloads.

The right hand column shows whatever you sorted by: size in name and size modes,
modification date in time mode. Dates are local, resolved per timestamp, so daylight
saving is correct.

## config

`$XDG_CONFIG_HOME/gunti/config`, or `~/.config/gunti/config`.

No file means defaults. A line it cannot parse is reported with its line number and
the rest of the file still applies.

    # options
    set sort    name|size|time
    set hidden  true|false

    # colour
    set color dir|link|exec|broken  <colour>

    # bindings
    map <key> <shell command>

There is no `set editor`. `$EDITOR` already does that.

Colours are `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`,
`white`, the same eight prefixed with `bright-`, and `none`. Directories,
symlinks, executables and broken symlinks are coloured; everything else is
left alone. The highlighted row is not coloured, because reverse video over a
colour turns the colour into a background.

Defaults match `ls`: blue directories, cyan symlinks, green executables, red
broken links. Setting `NO_COLOR` to any value turns all of it off, and it wins
over the config.

## shell commands

`!` prompts for a command. `map` binds one to a key. Both run it through `sh`.

Files reach the command as positional arguments, not as text:

| | |
|---|---|
| `"$@"` | the ticked files, or the highlighted one if none are ticked |
| `$f` | the highlighted file |
| `$d` | the current directory |

Use `"$@"` for anything acting on a selection. Filenames containing spaces, quotes,
newlines or leading dashes pass through intact, because gunti never substitutes them
into the command text.

A `!` in front of a binding hands over the terminal and waits for a keypress
afterwards. Use it for anything that prints or asks something. Without it the command
runs unseen, which is what you want for a clipboard copy.

    map D  rm -rf -- "$@"
    map T  trash-put -- "$@"
    map Y  wl-copy < "$f"
    map E  tar xf "$f"
    map L  !less "$f"
    map G  !git add -- "$@"

Bindings override built-in keys. `map d trash-put -- "$@"` replaces delete.

The shell provides prompting, so renaming through a binding works:

    map R !read -p "new name: " n && mv -- "$f" "$n"

## leaving your shell in the directory you browsed to

No process can change its parent shell's directory. gunti writes where it ended up,
and your shell does the rest.

Set `GUNTI_CD` to a file path and gunti writes its final directory there on exit.
Unset, nothing happens.

    gunti() {
      local d target
      d=$(mktemp)
      GUNTI_CD="$d" command gunti "$@"
      target=$(cat "$d"); rm -f "$d"
      [ -n "$target" ] && cd "$target"
    }

## speed

Measured on 50,000 files in one directory, average of three runs:

| | |
|---|---|
| read the directory and draw it | 84 ms |
| `ls -la` on the same directory | 238 ms |
| re-sort, no disk access | 15 ms |
| one keypress | 35 us |

gunti reads directories with `getdents` plus one `fstatat` per entry. `core:os` opens
and closes a file descriptor for every entry, which is three syscalls each instead of
one. Changing sort order or toggling dotfiles rebuilds the view from memory and never
touches the disk.

These numbers are against `ls`, not against other file managers. `ranger`, `lf` and
`yazi` have not been benchmarked here.

## what it does not do

- No progress bar or cancellation on large copies. The display blocks until done.
- Deleting a non-empty directory fails. Delete uses `rmdir` semantics on purpose.
  Bind `rm -rf` if you want the other behaviour.
- Cutting across filesystems fails. `rename` cannot move between mount points.
- Built-in keys cannot be remapped to other keys. `map` binds shell commands only.
- No image previews, tabs, panes, bookmarks, bulk rename, mouse, icons or plugins.
  None of these are planned.
- Wide character widths cover CJK, Hangul, fullwidth forms and the common emoji
  blocks, not the full Unicode tables. Rare scripts may be off by a cell.
- Filenames are assumed to be UTF-8.

## design

The core holds what only the core can do: reading and drawing the listing, moving
around, sorting, ticking, searching, and running commands. Everything else is a
config line.

Previewing is a default binding, not built in, so a pager handles binary files and
huge files properly instead of gunti approximating it. Copy, delete, rename and
permissions stayed in the core because they need prefilled prompts and per file
confirmation that a shell command cannot provide. All of them are overridable.

## licence

GNU GPL v3 or later. See [LICENSE](LICENSE).
