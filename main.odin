package gunti

import "core:fmt"
import "core:os"
import "core:slice"
import "core:sys/linux"
import "core:sys/posix"

main :: proc() {
	cooked: posix.termios
	posix.tcgetattr(posix.STDIN_FILENO, &cooked)
	defer posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &cooked)
	defer fmt.print("\x1b[2J\x1b[H\x1b[?25h")

	raw := cooked
	// isig off so ctrl-c arrives as byte 3 instead of killing us mid-raw-mode
	raw.c_lflag -= {.ECHO, .ICANON, .ISIG}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw)
	fmt.print("\x1b[?25l")

	cursor, offset := 0, 0
	show_hidden := false
	msg: string
	files, cwd := load(show_hidden)
	for {
		// re-asked every frame so a resized window just works, no sigwinch handler
		rows, cols := term_size()
		rows = max(rows-2, 1)
		offset = max(min(offset, cursor), cursor-rows+1, 0)
		draw(cwd, files, cursor, offset, rows, cols, msg)

		key, ok := read_key()
		if !ok {
			break
		}
		msg = "" // messages live exactly one frame, and must die before load() frees them

		switch key {
		case 'q', 3:
			return
		case 'j':
			cursor = min(cursor+1, len(files)-1)
		case 'k':
			cursor = max(cursor-1, 0)
		case 'g':
			cursor = 0
		case 'G':
			cursor = max(len(files)-1, 0)
		case '.':
			show_hidden = !show_hidden
			cursor, offset = 0, 0
			files, cwd = load(show_hidden)
		case 'l', '\r', '\n':
			if len(files) > 0 {
				// try to walk in first: chdir fails on a regular file, and symlinked dirs work free
				eerr: os.Error
				// ponytail: a dir we lack permission to enter also lands here and gets handed to the editor
				if os.set_working_directory(files[cursor].name) == nil {
					cursor, offset = 0, 0
				} else {
					eerr = open_in_editor(files[cursor].name, &cooked, &raw)
				}
				files, cwd = load(show_hidden)
				cursor = clamp(cursor, 0, max(len(files)-1, 0))
				if eerr != nil {
					msg = fmt.tprintf("could not run $EDITOR: %v", eerr)
				}
			}
		case 'h', 127:
			// remember what we're leaving so the highlight lands on it, not on the top
			leaving: [256]byte
			n := copy(leaving[:], os.base(cwd))
			if os.set_working_directory("..") == nil {
				files, cwd = load(show_hidden)
				cursor, offset = index_of(files, string(leaving[:n])), 0
			}
		case 'd':
			if len(files) > 0 {
				name := files[cursor].name
				// remove() is rmdir for directories, so a non-empty one refuses to die. keep it that way.
				if confirm(fmt.tprintf("delete %s? (y/N) ", name)) {
					if err := os.remove(name); err != nil {
						msg = fmt.tprintf("delete failed: %v", err)
					} else {
						files, cwd = load(show_hidden)
						cursor = clamp(cursor, 0, max(len(files)-1, 0))
					}
				}
			}
		case 'r':
			if len(files) > 0 {
				old := files[cursor].name
				if name, got := ask("rename to: ", old); got && name != old {
					// rename(2) replaces the target without a word, so do the asking ourselves
					if os.exists(name) && !confirm(fmt.tprintf("overwrite %s? (y/N) ", name)) {
						break
					}
					if err := os.rename(old, name); err != nil {
						msg = fmt.tprintf("rename failed: %v", err)
					} else {
						files, cwd = load(show_hidden)
						cursor = clamp(index_of(files, name), 0, max(len(files)-1, 0))
					}
				}
			}
		}
	}
}

// ponytail: whole listing re-read on every navigation, cache it when a directory is slow enough to notice
load :: proc(show_hidden: bool) -> (files: []os.File_Info, cwd: string) {
	free_all(context.temp_allocator)
	cwd, _ = os.get_working_directory(context.temp_allocator)
	files, _ = os.read_all_directory_by_path(".", context.temp_allocator)

	if !show_hidden {
		keep := make([dynamic]os.File_Info, 0, len(files), context.temp_allocator)
		for f in files {
			if len(f.name) > 0 && f.name[0] != '.' {
				append(&keep, f)
			}
		}
		files = keep[:]
	}

	// readdir order is whatever the fs feels like; sort or it looks broken
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {
		ad, bd := a.type == .Directory, b.type == .Directory
		if ad != bd {
			return ad
		}
		return a.name < b.name
	})
	return
}

index_of :: proc(files: []os.File_Info, name: string) -> int {
	for f, i in files {
		if f.name == name {
			return i
		}
	}
	return 0
}

// the editor wants a normal terminal and the whole screen, so give both back and take them again after
open_in_editor :: proc(name: string, cooked, raw: ^posix.termios) -> (err: os.Error) {
	editor := os.get_env("EDITOR", context.temp_allocator)
	if editor == "" {
		editor = "vi"
	}

	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, cooked)
	fmt.print("\x1b[2J\x1b[H\x1b[?25h")

	// nil on these handles means "close it", not "inherit it"
	p, perr := os.process_start({
		command = {editor, name},
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	})
	if perr == nil {
		_, _ = os.process_wait(p)
	}

	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, raw)
	fmt.print("\x1b[?25l")
	return perr
}

read_key :: proc() -> (key: byte, ok: bool) {
	buf: [3]byte
	if n, err := os.read(os.stdin, buf[:1]); err != nil || n == 0 {
		return 0, false
	}

	key = buf[0]
	// arrows arrive as esc [ A/B/C/D; fold them onto hjkl so movement lives in one place
	// ponytail: a lone esc blocks here until two more keys arrive, nobody presses esc yet
	if key == 0x1b {
		if n, _ := os.read(os.stdin, buf[1:3]); n == 2 && buf[1] == '[' {
			switch buf[2] {
			case 'A': key = 'k'
			case 'B': key = 'j'
			case 'C': key = 'l'
			case 'D': key = 'h'
			}
		}
	}
	return key, true
}

// overwrites the bottom row in place, so prompts don't need the whole screen redrawn
bar :: proc(text: string) {
	rows, _ := term_size()
	fmt.printf("\x1b[%d;1H\x1b[2K\x1b[7m%s\x1b[0m", rows, text)
}

// anything but y is no, because y is the only key that deletes your file
confirm :: proc(text: string) -> bool {
	bar(text)
	key, ok := read_key()
	return ok && key == 'y'
}

// ponytail: no left/right editing in here, and arrows insert hjkl. it's a filename, not an essay.
ask :: proc(label, initial: string) -> (answer: string, ok: bool) {
	buf := make([dynamic]byte, 0, 64, context.temp_allocator)
	append(&buf, initial)

	for {
		bar(fmt.tprintf("%s%s", label, string(buf[:])))

		key, got := read_key()
		if !got || key == 3 {
			return "", false
		}

		switch {
		case key == '\r' || key == '\n':
			return string(buf[:]), len(buf) > 0
		case key == 127:
			if len(buf) > 0 {
				pop(&buf)
			}
		case key >= 32 && key < 127:
			append(&buf, key)
		}
	}
}

Winsize :: struct {
	row, col, xpixel, ypixel: u16,
}

// core ships TIOCGWINSZ but no winsize struct, so it lives here
term_size :: proc() -> (rows: int, cols: int) {
	ws: Winsize
	if linux.ioctl(linux.Fd(posix.STDOUT_FILENO), linux.TIOCGWINSZ, uintptr(&ws)) != 0 || ws.row == 0 {
		return 24, 80 // ponytail: not a tty, assume the ancient default
	}
	return int(ws.row), int(ws.col)
}

// ponytail: counts runes, not display columns, so CJK and emoji still overflow
fit :: proc(s: string, width: int) -> string {
	if width <= 0 {
		return ""
	}
	n := 0
	for _, i in s {
		if n == width {
			return s[:i]
		}
		n += 1
	}
	return s
}

perms :: proc(p: os.Permissions) -> (out: [9]byte) {
	flags := [9]os.Permission_Flag{
		.Read_User, .Write_User, .Execute_User,
		.Read_Group, .Write_Group, .Execute_Group,
		.Read_Other, .Write_Other, .Execute_Other,
	}
	rwx := "rwxrwxrwx"
	for f, i in flags {
		out[i] = rwx[i] if f in p else '-'
	}
	return
}

// ponytail: full redraw per keypress, diff the rows if it ever feels slow
draw :: proc(cwd: string, files: []os.File_Info, cursor, offset, rows, cols: int, msg: string) {
	fmt.print("\x1b[2J\x1b[H")
	fmt.printfln("\x1b[1m%s\x1b[0m", fit(cwd, cols))

	if len(files) == 0 {
		fmt.print("(empty or unreadable)")
		return
	}

	for i in offset ..< min(offset+rows, len(files)) {
		f := files[i]
		slash := "/" if f.type == .Directory else ""
		name := fit(f.name, cols-1) // -1 leaves room for the slash
		if i == cursor {
			fmt.printfln("\x1b[7m%s%s\x1b[0m", name, slash)
		} else {
			fmt.printfln("%s%s", name, slash)
		}
	}

	// no trailing newline, printing one on the last row scrolls the whole screen up
	if msg != "" {
		fmt.printf("\x1b[7m %s \x1b[0m", fit(msg, cols-2))
		return
	}

	f := files[cursor]
	pp := perms(f.mode)
	sbuf: [128]byte // bprintf writes into this, so the per-frame status costs no allocation
	status: string
	if f.type == .Directory {
		status = fmt.bprintf(sbuf[:], " %s  dir  %d/%d ", string(pp[:]), cursor+1, len(files))
	} else {
		status = fmt.bprintf(sbuf[:], " %s  %M  %d/%d ", string(pp[:]), f.size, cursor+1, len(files))
	}
	fmt.printf("\x1b[7m%s\x1b[0m", fit(status, cols))
}
