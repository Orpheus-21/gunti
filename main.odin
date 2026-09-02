package gunti

import "core:fmt"
import "core:os"
import "core:slice"
import "core:sys/posix"

main :: proc() {
	files, err := os.read_all_directory_by_path(".", context.temp_allocator)
	if err != nil {
		fmt.eprintfln("gunti: %v", err)
		os.exit(1)
	}

	// readdir order is whatever the fs feels like; sort or it looks broken
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool { return a.name < b.name })

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
	buf: [3]byte
	for {
		draw(files, cursor)

		if n, rerr := os.read(os.stdin, buf[:1]); rerr != nil || n == 0 {
			break
		}

		key := buf[0]
		// arrows arrive as esc [ A/B; fold them onto k/j so movement lives in one place
		// ponytail: a lone esc blocks here until two more keys arrive, nobody presses esc yet
		if key == 0x1b {
			if n, _ := os.read(os.stdin, buf[1:3]); n == 2 && buf[1] == '[' {
				switch buf[2] {
				case 'A': key = 'k'
				case 'B': key = 'j'
				}
			}
		}

		switch key {
		case 'q', 3:
			return
		case 'j':
			cursor = min(cursor+1, len(files)-1)
		case 'k':
			cursor = max(cursor-1, 0)
		}
	}
}

// ponytail: full redraw per keypress, diff the rows if a listing ever outgrows the screen
draw :: proc(files: []os.File_Info, cursor: int) {
	fmt.print("\x1b[2J\x1b[H")
	for f, i in files {
		slash := "/" if f.type == .Directory else ""
		if i == cursor {
			fmt.printfln("\x1b[7m%s%s\x1b[0m", f.name, slash)
		} else {
			fmt.printfln("%s%s", f.name, slash)
		}
	}
}
