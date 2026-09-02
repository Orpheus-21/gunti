package gunti

import "core:fmt"
import "core:os"
import "core:slice"
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

	cursor := 0
	files, cwd := load()
	for {
		draw(cwd, files, cursor)

		key, ok := read_key()
		if !ok {
			break
		}

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
				cursor = 0
				files, cwd = load()
			}
		case 'h', 127:
			if os.set_working_directory("..") == nil {
				cursor = 0
				files, cwd = load()
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

// ponytail: full redraw per keypress, diff the rows if a listing ever outgrows the screen
draw :: proc(cwd: string, files: []os.File_Info, cursor: int) {
	fmt.print("\x1b[2J\x1b[H")
	fmt.printfln("\x1b[1m%s\x1b[0m", cwd)

	if len(files) == 0 {
		fmt.println("(empty or unreadable)")
		return
	}

	for f, i in files {
		slash := "/" if f.type == .Directory else ""
		if i == cursor {
			fmt.printfln("\x1b[7m%s%s\x1b[0m", f.name, slash)
		} else {
			fmt.printfln("%s%s", f.name, slash)
		}
	}
}
