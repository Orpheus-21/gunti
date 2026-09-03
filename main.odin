package gunti

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:testing"

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
	// the clipboard has to outlive load(), which frees the arena entry names live in
	clip: [4096]byte
	clip_n := 0
	clip_cut := false
	// the query outlives the arena ask() used, so n can repeat it later
	query: [256]byte
	query_n := 0
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
				// shortcut: a dir we lack permission to enter also lands here and gets handed to the editor
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
					// ask() answers live in the arena load() frees, so keep a copy for the highlight
					renamed: [256]byte
					rn := copy(renamed[:], name)
					if err := os.rename(old, name); err != nil {
						msg = fmt.tprintf("rename failed: %v", err)
					} else {
						files, cwd = load(show_hidden)
						cursor = clamp(index_of(files, string(renamed[:rn])), 0, max(len(files)-1, 0))
					}
				}
			}
		case 'y', 'x':
			if len(files) > 0 {
				name := files[cursor].name
				clip_n = join_path(clip[:], cwd, name)
				clip_cut = key == 'x'
				if clip_n == 0 {
					msg = "path too long to hold"
				} else {
					msg = fmt.tprintf("%s %s", "cut" if clip_cut else "yanked", name)
				}
			}
		case 'p':
			if clip_n > 0 {
				src := string(clip[:clip_n])
				// paste lands in the directory we're standing in, under the same name
				name := os.base(src)
				dbuf: [4096]byte
				dn := join_path(dbuf[:], cwd, name)
				if dn == 0 {
					msg = "path too long to paste"
					break
				}
				if string(dbuf[:dn]) == src {
					// copy_file opens dst with O_TRUNC while src is still open, and empties it
					msg = "source and destination are the same"
					break
				}
				if os.is_directory(src) && under(cwd, src) {
					// the copy would walk into the copy it is making, until the path runs out
					msg = "cannot paste a directory into itself"
					break
				}
				// rename and copy_file both clobber the target silently, so do the asking ourselves
				if os.exists(name) && !confirm(fmt.tprintf("overwrite %s? (y/N) ", name)) {
					break
				}
				err: os.Error
				switch {
				case clip_cut:
					// moves files and directories alike, but only within one filesystem
					err = os.rename(src, name)
				case os.is_directory(src):
					err = os.copy_directory_all(name, src)
				case:
					// dst first, src second: backwards from cp(1) and from os.rename above
					err = os.copy_file(name, src)
				}
				if err == nil && clip_cut {
					clip_n = 0 // the source moved, so the clipboard points at nothing
				}
				files, cwd = load(show_hidden)
				cursor = clamp(index_of(files, name), 0, max(len(files)-1, 0))
				if err != nil {
					msg = fmt.tprintf("paste failed: %v", err)
				}
			}
		case 'a':
			// a trailing / means directory, so one key covers both without a second prompt
			if raw, got := ask("create (end with / for a directory): ", ""); got {
				is_dir := raw[len(raw)-1] == '/'
				name := raw[:len(raw)-1] if is_dir else raw
				// ask() answers live in the arena load() frees, so keep a copy for the highlight
				made: [256]byte
				mn := copy(made[:], name)

				err: os.Error
				if is_dir {
					// shortcut: one level only, make_directory_all if nested paths ever get typed
					err = os.make_directory(name)
				} else {
					err = create_file(name)
				}
				files, cwd = load(show_hidden)
				cursor = clamp(index_of(files, string(made[:mn])), 0, max(len(files)-1, 0))
				if err != nil {
					msg = fmt.tprintf("create failed: %v", err)
				}
			}
		case '/', 'n':
			// n is the same jump with the previous query, so they share everything below
			if key == '/' {
				q, got := ask("/", "")
				if !got {
					break
				}
				query_n = copy(query[:], q)
			}
			if query_n == 0 {
				break
			}
			// always move to the next match, so a hit under the cursor doesn't look like nothing happened
			if i, found := find(files, string(query[:query_n]), cursor+1); found {
				cursor = i
			} else {
				msg = fmt.tprintf("not found: %s", string(query[:query_n]))
			}
		}
	}
}

// case-insensitive substring match, wrapping past the end so the last hit leads back to the first
// shortcut: lowercases into the temp arena, which only load() frees, so a long search spree holds memory
find :: proc(files: []os.File_Info, query: string, start: int) -> (int, bool) {
	if len(files) == 0 || query == "" {
		return 0, false
	}
	q, _ := strings.to_lower(query, context.temp_allocator)
	for k in 0 ..< len(files) {
		i := (start + k) % len(files)
		name, _ := strings.to_lower(files[i].name, context.temp_allocator)
		if strings.contains(name, q) {
			return i, true
		}
	}
	return 0, false
}

@(test)
test_find :: proc(t: ^testing.T) {
	files := []os.File_Info{{name = "alpha.txt"}, {name = "README"}, {name = "notes.md"}}

	i, ok := find(files, "readme", 0)
	testing.expect(t, ok && i == 1, "must match regardless of case")
	i, ok = find(files, "ALPHA", 2)
	testing.expect(t, ok && i == 0, "must wrap past the end")
	i, ok = find(files, "notes.md", 2)
	testing.expect(t, ok && i == 2, "must find a match at the starting index")
	_, ok = find(files, "zzz", 0)
	testing.expect(t, !ok, "a miss must report not found")
	_, ok = find(files[:0], "a", 0)
	testing.expect(t, !ok, "an empty listing must not divide by zero")
}

// .Excl makes the kernel refuse a name that already exists. os.create would
// truncate it instead, quietly emptying whatever was there.
create_file :: proc(name: string) -> os.Error {
	f := os.open(name, {.Read, .Write, .Create, .Excl}, os.Permissions_Default_File) or_return
	return os.close(f)
}

@(test)
test_create_file_never_clobbers :: proc(t: ^testing.T) {
	tmp, terr := os.temp_directory(context.temp_allocator)
	if !testing.expect_value(t, terr, nil) {
		return
	}
	dir, derr := os.make_directory_temp(tmp, "gunti", context.temp_allocator)
	if !testing.expect_value(t, derr, nil) {
		return
	}
	defer os.remove_all(dir)

	path := fmt.tprintf("%s/a.txt", dir)
	testing.expect_value(t, create_file(path), nil)
	// an error here means the file was never opened, so nothing could have been truncated
	testing.expect(t, create_file(path) != nil, "creating over an existing file must fail")
}

// a plain buffer, not the temp allocator, so the result survives the next load()
join_path :: proc(buf: []byte, dir, name: string) -> int {
	sep := "/" if dir != "/" else ""
	if len(dir)+len(sep)+len(name) > len(buf) {
		return 0
	}
	n := copy(buf[:], dir)
	n += copy(buf[n:], sep)
	n += copy(buf[n:], name)
	return n
}

// true if path is root itself or sits somewhere beneath it
// shortcut: textual compare, so a symlink pointing back inside root still slips through
under :: proc(path, root: string) -> bool {
	if len(path) < len(root) || path[:len(root)] != root {
		return false
	}
	rest := path[len(root):]
	return rest == "" || rest[0] == '/' || root == "/"
}

@(test)
test_paste_guards :: proc(t: ^testing.T) {
	buf: [64]byte
	n := join_path(buf[:], "/home/x", "a.txt")
	testing.expect(t, string(buf[:n]) == "/home/x/a.txt")
	n = join_path(buf[:], "/", "a.txt")
	testing.expect(t, string(buf[:n]) == "/a.txt", "root must not produce //a.txt")
	testing.expect(t, join_path(buf[:4], "/home/x", "a.txt") == 0, "overlong path must refuse")

	testing.expect(t, under("/a/b", "/a/b"), "a dir is under itself")
	testing.expect(t, under("/a/b/c", "/a/b"), "a child is under its parent")
	testing.expect(t, under("/a/b", "/"), "everything is under root")
	testing.expect(t, !under("/a/bc", "/a/b"), "a name sharing a prefix is not a child")
	testing.expect(t, !under("/a", "/a/b"), "a parent is not under its child")
}

// shortcut: whole listing re-read on every navigation, cache it when a directory is slow enough to notice
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
	// shortcut: a lone esc blocks here until two more keys arrive, nobody presses esc yet
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

// shortcut: no left/right editing in here, and arrows insert hjkl. it's a filename, not an essay.
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
		return 24, 80 // shortcut: not a tty, assume the ancient default
	}
	return int(ws.row), int(ws.col)
}

// shortcut: counts runes, not display columns, so CJK and emoji still overflow
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

// shortcut: full redraw per keypress, diff the rows if it ever feels slow
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
