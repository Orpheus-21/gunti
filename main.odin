package gunti

import "core:fmt"
import "core:os"
import "core:slice"
import "core:sys/linux"
import "core:sys/posix"

main :: proc() {
	orig: posix.termios
	posix.tcgetattr(posix.STDIN_FILENO, &orig)
	defer posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &orig)
	defer fmt.print("\x1b[2J\x1b[H\x1b[?25h")

	raw := orig
	// isig off so ctrl-c arrives as byte 3 instead of killing us mid-raw-mode
	raw.c_lflag -= {.ECHO, .ICANON, .ISIG}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw)
	fmt.print("\x1b[?25l")

	cursor, offset := 0, 0
	msg: string
	files, cwd := load()
	for {
		// re-asked every frame so a resized window just works, no sigwinch handler
		rows := max(term_rows()-2, 1)
		offset = max(min(offset, cursor), cursor-rows+1, 0)
		draw(cwd, files, cursor, offset, rows, msg)

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
		// chdir just fails on a regular file, so no type check needed and symlinked dirs work free
		case 'l', '\r', '\n':
			if len(files) > 0 && os.set_working_directory(files[cursor].name) == nil {
				cursor, offset = 0, 0
				files, cwd = load()
			}
		case 'h', 127:
			if os.set_working_directory("..") == nil {
				cursor, offset = 0, 0
				files, cwd = load()
			}
		case 'd':
			if len(files) > 0 {
				name := files[cursor].name
				// remove() is rmdir for directories, so a non-empty one refuses to die. keep it that way.
				if confirm(fmt.tprintf("delete %s? (y/N) ", name)) {
					if err := os.remove(name); err != nil {
						msg = fmt.tprintf("delete failed: %v", err)
					} else {
						files, cwd = load()
						cursor = clamp(cursor, 0, max(len(files)-1, 0))
					}
				}
			}
		case 'r':
			if len(files) > 0 {
				old := files[cursor].name
				if name, ok := ask("rename to: ", old); ok && name != old {
					if err := os.rename(old, name); err != nil {
						msg = fmt.tprintf("rename failed: %v", err)
					} else {
						files, cwd = load()
						cursor = clamp(cursor, 0, max(len(files)-1, 0))
					}
				}
			}
		}
	}
}

// ponytail: whole listing re-read on every navigation, cache it when a directory is slow enough to notice
load :: proc() -> (files: []os.File_Info, cwd: string) {
	free_all(context.temp_allocator)
	cwd, _ = os.get_working_directory(context.temp_allocator)
	// readdir order is whatever the fs feels like; sort or it looks broken
	files, _ = os.read_all_directory_by_path(".", context.temp_allocator)
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	return
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
	fmt.printf("\x1b[%d;1H\x1b[2K\x1b[7m%s\x1b[0m", term_rows(), text)
}

// anything but y is no, because the y is the only key that deletes your file
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
term_rows :: proc() -> int {
	ws: Winsize
	if linux.ioctl(linux.Fd(posix.STDOUT_FILENO), linux.TIOCGWINSZ, uintptr(&ws)) != 0 || ws.row == 0 {
		return 24 // ponytail: not a tty, assume the ancient default
	}
	return int(ws.row)
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
draw :: proc(cwd: string, files: []os.File_Info, cursor, offset, rows: int, msg: string) {
	fmt.print("\x1b[2J\x1b[H")
	fmt.printfln("\x1b[1m%s\x1b[0m", cwd)

	if len(files) == 0 {
		fmt.print("(empty or unreadable)")
		return
	}

	// ponytail: names wider than the terminal wrap and throw the row count off, truncate when it annoys
	for i in offset ..< min(offset+rows, len(files)) {
		f := files[i]
		slash := "/" if f.type == .Directory else ""
		if i == cursor {
			fmt.printfln("\x1b[7m%s%s\x1b[0m", f.name, slash)
		} else {
			fmt.printfln("%s%s", f.name, slash)
		}
	}

	// no trailing newline, printing one on the last row scrolls the whole screen up
	if msg != "" {
		fmt.printf("\x1b[7m %s \x1b[0m", msg)
		return
	}

	f := files[cursor]
	pp := perms(f.mode)
	if f.type == .Directory {
		fmt.printf("\x1b[7m %s  dir  %d/%d \x1b[0m", string(pp[:]), cursor+1, len(files))
	} else {
		fmt.printf("\x1b[7m %s  %M  %d/%d \x1b[0m", string(pp[:]), f.size, cursor+1, len(files))
	}
}
