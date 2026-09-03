package gunti

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "base:runtime"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"
import "core:time/datetime"
import tz "core:time/timezone"
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

	// loaded once and kept for the whole run: file times come back as UTC, and a
	// listing that says yesterday for a file you touched this evening is just wrong
	// /etc/localtime directly, because the proc that names the local zone is
	// package-private. nil on failure, which just means dates read as UTC.
	local, _ := tz.region_load_from_file("/etc/localtime", "local")

	cursor, offset := 0, 0
	show_hidden := false
	sort_by := Sort.Name
	msg: string
	// the clipboard has to outlive load(), which frees the arena entry names live in.
	// sized for many paths now that a tick list can be pasted in one go.
	clip: [64 * 1024]byte
	clip_n := 0
	clip_cut := false
	// the query outlives the arena ask() used, so n can repeat it later
	query: [256]byte
	query_n := 0
	all, view, files, selected, cwd := read_dir(show_hidden, sort_by)
	for {
		// re-asked every frame so a resized window just works, no sigwinch handler
		rows, cols := term_size()
		rows = max(rows-2, 1)
		offset = max(min(offset, cursor), cursor-rows+1, 0)
		draw(cwd, files, selected, cursor, offset, rows, cols, msg, sort_by, local)

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
		case ' ':
			if len(files) > 0 {
				selected[cursor] = !selected[cursor]
				// step down so a run of files ticks with repeated taps
				cursor = min(cursor+1, len(files)-1)
			}
		case 's':
			sort_by = Sort((int(sort_by) + 1) % len(Sort))
			cursor, offset = 0, 0
			// the entries are already in memory; only the order changed
			files = refilter(all, view, selected, show_hidden, sort_by)
		case '.':
			show_hidden = !show_hidden
			cursor, offset = 0, 0
			// read_dir already fetched the dotfiles, so this is just a re-filter
			files = refilter(all, view, selected, show_hidden, sort_by)
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
				all, view, files, selected, cwd = read_dir(show_hidden, sort_by)
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
				all, view, files, selected, cwd = read_dir(show_hidden, sort_by)
				cursor, offset = index_of(files, string(leaving[:n])), 0
			}
		case 'd':
			if len(files) > 0 {
				victims := targets(files, selected, cursor)
				// remove() is rmdir for directories, so a non-empty one refuses to die. keep it that way.
				if confirm(fmt.tprintf("delete %s? (y/N) ", describe(victims))) {
					failed := 0
					for v in victims {
						if os.remove(v.name) != nil {
							failed += 1
						}
					}
					total := len(victims)
					all, view, files, selected, cwd = read_dir(show_hidden, sort_by)
					cursor = clamp(cursor, 0, max(len(files)-1, 0))
					if failed > 0 {
						msg = fmt.tprintf("%d of %d could not be deleted", failed, total)
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
						all, view, files, selected, cwd = read_dir(show_hidden, sort_by)
						cursor = clamp(index_of(files, string(renamed[:rn])), 0, max(len(files)-1, 0))
					}
				}
			}
		case 'y', 'x':
			if len(files) > 0 {
				picked := targets(files, selected, cursor)
				clip_n = 0
				clip_cut = key == 'x'
				held := 0
				for f in picked {
					n := join_path(clip[clip_n:], cwd, f.name)
					// one newline per entry, so leave room for it before committing
					if n == 0 || clip_n+n+1 > len(clip) {
						break
					}
					clip_n += n
					clip[clip_n] = '\n'
					clip_n += 1
					held += 1
				}
				if held < len(picked) {
					msg = fmt.tprintf("only %d of %d fit", held, len(picked))
				} else {
					msg = fmt.tprintf("%s %s", "cut" if clip_cut else "yanked", describe(picked))
				}
			}
		case 'p':
			if clip_n > 0 {
				problem: [256]byte
				pn := 0
				last: [256]byte
				ln := 0
				pasted := 0

				paths := string(clip[:clip_n])
				for src in strings.split_lines_iterator(&paths) {
					if src == "" {
						continue
					}
					name, why := paste_one(src, cwd, clip_cut)
					ln = copy(last[:], name)
					if why != "" {
						pn = copy(problem[:], why)
					} else {
						pasted += 1
					}
				}
				// only forget a cut once every piece of it landed
				if pn == 0 && clip_cut {
					clip_n = 0
				}
				all, view, files, selected, cwd = read_dir(show_hidden, sort_by)
				cursor = clamp(index_of(files, string(last[:ln])), 0, max(len(files)-1, 0))
				if pn > 0 {
					msg = fmt.tprintf("%s", string(problem[:pn]))
				} else if pasted > 1 {
					msg = fmt.tprintf("pasted %d items", pasted)
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
				all, view, files, selected, cwd = read_dir(show_hidden, sort_by)
				cursor = clamp(index_of(files, string(made[:mn])), 0, max(len(files)-1, 0))
				if err != nil {
					msg = fmt.tprintf("create failed: %v", err)
				}
			}
		case 'R':
			// keep the highlight on the same entry: a refresh can shift every index
			keep: [256]byte
			kn := 0
			if len(files) > 0 {
				kn = copy(keep[:], files[cursor].name)
			}
			all, view, files, selected, cwd = read_dir(show_hidden, sort_by)
			cursor = clamp(index_of(files, string(keep[:kn])), 0, max(len(files)-1, 0))
		case 'c':
			if path, got := ask("go to: ", ""); got {
				target := expand_home(path, os.get_env("HOME", context.temp_allocator))
				if err := os.set_working_directory(target); err != nil {
					msg = fmt.tprintf("cannot go there: %v", err)
				} else {
					cursor, offset = 0, 0
					all, view, files, selected, cwd = read_dir(show_hidden, sort_by)
				}
			}
		case 'v':
			if len(files) > 0 && files[cursor].type != .Directory {
				preview(files[cursor].name)
			}
		case '?':
			help()
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

// kept next to nothing else on purpose: this is the only place the key list is written down
HELP := [?]string{
	"GUNTI",
	"",
	"  j  down            k  up",
	"  g  top             G  bottom",
	"  h  parent dir      l  enter dir, or open file in $EDITOR",
	"  c  go to a path, ~ included",
	"  R  re-read the folder from disk",
	"",
	"  /  search          n  next match",
	"  s  cycle sort: name / size / time",
	"  .  show or hide dotfiles",
	"",
	"  v  peek inside a file",
	"  space  tick a file; d, y and x then act on every ticked one",
	"  a  create, end the name with / for a directory",
	"  r  rename          d  delete",
	"  y  copy            x  cut            p  paste",
	"",
	"  ?  this help       q  quit",
	"",
	"  arrows work as hjkl, backspace as h, enter as l",
}

// enough for any sane terminal, and it means previewing a 4GB log reads 32KB of it
PREVIEW_BYTES :: 32 * 1024

// a NUL byte means it is not text, and dumping it raw would garble the terminal
is_binary :: proc(data: []byte) -> bool {
	return slice.contains(data, 0)
}

@(test)
test_is_binary :: proc(t: ^testing.T) {
	testing.expect(t, !is_binary(transmute([]byte)string("hello\nworld")), "plain text is not binary")
	testing.expect(t, is_binary([]byte{'a', 0, 'b'}), "an embedded NUL means binary")
	testing.expect(t, !is_binary([]byte{}), "an empty file is not binary")
}

// any key returns, same as help
preview :: proc(name: string) {
	rows, cols := term_size()
	fmt.print("\x1b[2J\x1b[H")
	fmt.printfln("\x1b[1m%s\x1b[0m", fit(name, cols))

	buf: [PREVIEW_BYTES]byte
	n: int
	if f, err := os.open(name); err != nil {
		fmt.printf("cannot read: %v", err)
	} else {
		defer os.close(f)
		n, _ = os.read(f, buf[:])
		data := buf[:n]
		switch {
		case n == 0:
			fmt.print("(empty)")
		case is_binary(data):
			fmt.print("(binary)")
		case:
			// rows-2 leaves the header and the footer their own lines
			printed := 0
			text := string(data)
			for line in strings.split_lines_iterator(&text) {
				if printed >= rows-2 {
					break
				}
				fmt.println(fit(line, cols))
				printed += 1
			}
		}
	}

	bar(" press any key ")
	read_key()
}

// any key returns, so there is nothing to learn to get back out
help :: proc() {
	rows, cols := term_size()
	fmt.print("\x1b[2J\x1b[H")
	for line, i in HELP {
		if i >= rows-1 {
			break
		}
		fmt.println(fit(line, cols))
	}
	// no trailing newline on the last row, same reason as draw()
	fmt.printf("\x1b[7m%s\x1b[0m", fit(" press any key ", cols))
	read_key()
}

// case-insensitive substring match, wrapping past the end so the last hit leads back to the first
// shortcut: lowercases into the temp arena, which only load() frees, so a long search spree holds memory
find :: proc(files: []Entry, query: string, start: int) -> (int, bool) {
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
	files := []Entry{{info = {name = "alpha.txt"}}, {info = {name = "README"}}, {info = {name = "notes.md"}}}

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

// ~ alone or a leading ~/ means home; everything else is passed through untouched.
// home is a parameter so this can be checked without depending on the machine it runs on.
expand_home :: proc(path, home: string) -> string {
	if path == "~" {
		return home
	}
	if strings.has_prefix(path, "~/") {
		return fmt.tprintf("%s%s", home, path[1:])
	}
	return path
}

@(test)
test_expand_home :: proc(t: ^testing.T) {
	testing.expect(t, expand_home("~", "/home/x") == "/home/x", "~ alone is home")
	testing.expect(t, expand_home("~/Work", "/home/x") == "/home/x/Work", "~/ prefixes home")
	testing.expect(t, expand_home("/etc", "/home/x") == "/etc", "absolute paths pass through")
	testing.expect(t, expand_home("sub", "/home/x") == "sub", "relative paths pass through")
	testing.expect(t, expand_home("~xyz", "/home/x") == "~xyz", "only ~ alone or ~/ expands")
	testing.expect(t, expand_home("", "/home/x") == "", "empty stays empty")
}

// the ticked entries, or just the highlighted one when nothing is ticked
targets :: proc(files: []Entry, selected: []bool, cursor: int) -> []Entry {
	out := make([dynamic]Entry, 0, len(files), context.temp_allocator)
	for f, i in files {
		if selected[i] {
			append(&out, f)
		}
	}
	if len(out) == 0 && len(files) > 0 {
		append(&out, files[cursor])
	}
	return out[:]
}

// a name reads better than "1 items" when only one thing is going to happen
describe :: proc(files: []Entry) -> string {
	if len(files) == 1 {
		return files[0].name
	}
	return fmt.tprintf("%d items", len(files))
}

// one clipboard entry into cwd. the returned text is "" when it worked.
paste_one :: proc(src, cwd: string, cut: bool) -> (name: string, why: string) {
	name = os.base(src)
	dbuf: [4096]byte
	dn := join_path(dbuf[:], cwd, name)
	if dn == 0 {
		return name, "path too long to paste"
	}
	if string(dbuf[:dn]) == src {
		// copy_file opens dst with O_TRUNC while src is still open, and empties it
		return name, "source and destination are the same"
	}
	if os.is_directory(src) && under(cwd, src) {
		// the copy would walk into the copy it is making, until the path runs out
		return name, "cannot paste a directory into itself"
	}
	// rename and copy_file both clobber the target silently, so do the asking ourselves
	if os.exists(name) && !confirm(fmt.tprintf("overwrite %s? (y/N) ", name)) {
		return name, "skipped"
	}

	err: os.Error
	switch {
	case cut:
		// moves files and directories alike, but only within one filesystem
		err = os.rename(src, name)
	case os.is_directory(src):
		err = os.copy_directory_all(name, src)
	case:
		// dst first, src second: backwards from cp(1) and from os.rename above
		err = os.copy_file(name, src)
	}
	if err != nil {
		return name, fmt.tprintf("paste failed: %v", err)
	}
	return name, ""
}

@(test)
test_targets :: proc(t: ^testing.T) {
	files := []Entry{{info = {name = "a"}}, {info = {name = "b"}}, {info = {name = "c"}}}

	got := targets(files, []bool{false, false, false}, 1)
	testing.expect(t, len(got) == 1 && got[0].name == "b", "no ticks means act on the highlighted entry")

	got = targets(files, []bool{true, false, true}, 1)
	testing.expect(t, len(got) == 2, "ticks win over the cursor")
	testing.expect(t, got[0].name == "a" && got[1].name == "c", "ticked entries keep listing order")

	testing.expect(t, len(targets(files[:0], []bool{}, 0)) == 0, "an empty listing has no targets")
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

Entry :: struct {
	using info: os.File_Info,
	link:       string, // "" unless this is a symlink
}

// the only proc here that touches the disk. it reads everything, hidden files
// included, so that changing the view afterwards never needs the disk again.
read_dir :: proc(show_hidden: bool, sort_by: Sort) -> (all, view, files: []Entry, selected: []bool, cwd: string) {
	free_all(context.temp_allocator)
	cwd, _ = os.get_working_directory(context.temp_allocator)

	all = scan(".", context.temp_allocator)
	for &e in all {
		if e.type != .Symlink {
			continue
		}
		// resolved here rather than in draw: this costs a disk read per link
		target, err := os.read_link(e.name, context.temp_allocator)
		switch {
		case err != nil:
			e.link = " -> ?"
		case os.exists(e.name):
			// exists() follows the link, so a false here means it points at nothing
			e.link = fmt.tprintf(" -> %s", target)
		case:
			e.link = fmt.tprintf(" -> %s (broken)", target)
		}
	}

	// sized once for the whole listing and reused, so re-sorting allocates nothing
	view = make([]Entry, len(all), context.temp_allocator)
	selected = make([]bool, len(all), context.temp_allocator)
	files = refilter(all, view, selected, show_hidden, sort_by)
	return
}

// core:os reads a directory by opening a file descriptor for every single entry
// and closing it again: three syscalls each. getdents hands us the names and the
// types in one call, and fstatat fills in the rest with one syscall per entry.
// on 50k files that is the difference between 330ms and 60ms.
scan :: proc(path: string, allocator: runtime.Allocator) -> []Entry {
	out := make([dynamic]Entry, 0, 64, allocator)

	pbuf: [4096]byte
	copy(pbuf[:], path)
	fd, oerr := linux.open(cstring(&pbuf[0]), {.DIRECTORY})
	if oerr != .NONE {
		return out[:]
	}
	defer linux.close(fd)

	// one buffer for the whole walk, refilled per getdents call
	buf: [64 * 1024]byte
	name_buf: [4096]byte
	for {
		n, errno := linux.getdents(fd, buf[:])
		if errno != .NONE || n == 0 {
			break
		}
		off := 0
		for d in linux.dirent_iterate_buf(buf[:n], &off) {
			name := linux.dirent_name(d)
			if name == "." || name == ".." {
				continue
			}

			e: Entry
			// the name points into buf, which the next getdents overwrites
			e.name = strings.clone(name, allocator)
			e.type = entry_type(d.type)

			// fstatat needs a NUL terminator, and dirent names do not carry one
			copy(name_buf[:], name)
			name_buf[len(name)] = 0
			st: linux.Stat
			// NOFOLLOW so a symlink reports itself, not whatever it points at
			if linux.fstatat(fd, cstring(&name_buf[0]), &st, {.SYMLINK_NOFOLLOW}) == .NONE {
				e.size = i64(st.size)
				// the low nine bits mean the same thing in both bit sets, in the same order
				e.mode = transmute(os.Permissions)(u32(transmute(u32)st.mode) & 0o777)
				e.modification_time = time.Time{i64(st.mtime.time_sec) * 1_000_000_000 + i64(st.mtime.time_nsec)}
				if e.type == .Undetermined {
					// filesystems are allowed to answer UNKNOWN, so fall back to the mode
					e.type = mode_type(u32(transmute(u32)st.mode))
				}
			}
			append(&out, e)
		}
	}
	return out[:]
}

// scan replaces a core:os call, so prove it agrees with the thing it replaced
@(test)
test_scan_matches_core :: proc(t: ^testing.T) {
	tmp, terr := os.temp_directory(context.temp_allocator)
	if !testing.expect_value(t, terr, nil) {
		return
	}
	dir, derr := os.make_directory_temp(tmp, "gunti_scan", context.temp_allocator)
	if !testing.expect_value(t, derr, nil) {
		return
	}
	defer os.remove_all(dir)

	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/regular.txt", dir), "hello world"), nil)
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/empty.txt", dir), ""), nil)
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/.dotfile", dir), "x"), nil)
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/späced ünicode.txt", dir), "u"), nil)
	testing.expect_value(t, os.make_directory(fmt.tprintf("%s/subdir", dir)), nil)
	testing.expect_value(t, os.symlink("regular.txt", fmt.tprintf("%s/alink", dir)), nil)
	testing.expect_value(t, os.symlink("nowhere", fmt.tprintf("%s/broken", dir)), nil)

	mine := scan(dir, context.temp_allocator)
	theirs, rerr := os.read_all_directory_by_path(dir, context.temp_allocator)
	if !testing.expect_value(t, rerr, nil) {
		return
	}
	testing.expectf(t, len(mine) == len(theirs), "entry count: got %d, core says %d", len(mine), len(theirs))

	for want in theirs {
		found := false
		for got in mine {
			if got.name != want.name {
				continue
			}
			found = true
			testing.expectf(t, got.type == want.type, "%s type: got %v, core says %v", want.name, got.type, want.type)
			testing.expectf(t, got.size == want.size, "%s size: got %d, core says %d", want.name, got.size, want.size)
			testing.expectf(t, got.mode == want.mode, "%s mode: got %v, core says %v", want.name, got.mode, want.mode)
			testing.expectf(t, got.modification_time._nsec == want.modification_time._nsec,
				"%s mtime: got %d, core says %d", want.name, got.modification_time._nsec, want.modification_time._nsec)
			break
		}
		testing.expectf(t, found, "scan missed %s", want.name)
	}
}

entry_type :: proc(t: linux.Dirent_Type) -> os.File_Type {
	switch t {
	case .DIR:     return .Directory
	case .REG:     return .Regular
	case .LNK:     return .Symlink
	case .FIFO:    return .Named_Pipe
	case .SOCK:    return .Socket
	case .BLK:     return .Block_Device
	case .CHR:     return .Character_Device
	case .UNKNOWN, .WHT:
		return .Undetermined
	}
	return .Undetermined
}

mode_type :: proc(mode: u32) -> os.File_Type {
	switch mode & 0o170000 {
	case 0o040000: return .Directory
	case 0o100000: return .Regular
	case 0o120000: return .Symlink
	case 0o010000: return .Named_Pipe
	case 0o140000: return .Socket
	case 0o060000: return .Block_Device
	case 0o020000: return .Character_Device
	}
	return .Undetermined
}

// rebuilds the visible listing from what read_dir already fetched. no disk, no
// allocation, so re-sorting a huge directory costs a copy and a sort, not a re-read.
refilter :: proc(all, view: []Entry, selected: []bool, show_hidden: bool, sort_by: Sort) -> []Entry {
	n := 0
	for e in all {
		if show_hidden || (len(e.name) > 0 && e.name[0] != '.') {
			view[n] = e
			n += 1
		}
	}
	files := view[:n]

	// readdir order is whatever the fs feels like; sort or it looks broken
	sort_files(files, sort_by)

	// ticks belong to the listing they were made in
	for i in 0 ..< len(selected) {
		selected[i] = false
	}
	return files
}

Sort :: enum {
	Name,
	Size,
	Time,
}

// readdir order is whatever the fs feels like; sort or it looks broken.
// slice.sort_by takes a plain proc with no captured state, so each mode gets its own.
sort_files :: proc(files: []Entry, mode: Sort) {
	switch mode {
	case .Name:
		slice.sort_by(files, proc(a, b: Entry) -> bool {
			if ad, bd := a.type == .Directory, b.type == .Directory; ad != bd {
				return ad
			}
			return a.name < b.name
		})
	case .Size:
		slice.sort_by(files, proc(a, b: Entry) -> bool {
			if ad, bd := a.type == .Directory, b.type == .Directory; ad != bd {
				return ad
			}
			// biggest first, since that is the reason to sort by size at all
			return a.size > b.size
		})
	case .Time:
		slice.sort_by(files, proc(a, b: Entry) -> bool {
			if ad, bd := a.type == .Directory, b.type == .Directory; ad != bd {
				return ad
			}
			// newest first, for "what did I just touch"
			return a.modification_time._nsec > b.modification_time._nsec
		})
	}
}

@(test)
test_sort_files :: proc(t: ^testing.T) {
	files := []Entry{
		{info = {name = "b.txt", size = 10, type = .Regular}},
		{info = {name = "dir", type = .Directory}},
		{info = {name = "a.txt", size = 30, type = .Regular}},
	}

	sort_files(files, .Name)
	testing.expect(t, files[0].name == "dir", "directories sort first by name")
	testing.expect(t, files[1].name == "a.txt", "then names ascend")

	sort_files(files, .Size)
	testing.expect(t, files[0].name == "dir", "directories still sort first by size")
	testing.expect(t, files[1].name == "a.txt", "biggest file first")
	testing.expect(t, files[2].name == "b.txt", "smallest file last")
}

index_of :: proc(files: []Entry, name: string) -> int {
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

// file times come back as UTC. render them in the viewer's zone instead, since a
// listing that says yesterday for a file touched this evening is simply wrong.
// falls back to UTC when the zone will not load, which beats refusing to draw.
local_date :: proc(t: time.Time, local: ^datetime.TZ_Region, buf: []byte) -> string {
	dt, ok := time.time_to_datetime(t)
	if !ok {
		return "?"
	}
	if local != nil {
		// per timestamp, so a file from the other side of a daylight-saving switch still reads right
		if shifted, moved := tz.datetime_to_tz(dt, local); moved {
			dt = shifted
		}
	}
	return fmt.bprintf(buf, "%02d-%02d-%04d", dt.day, dt.month, dt.year)
}

// name on the left, the sorted-by value on the right, padded between so the
// cursor highlight covers the whole row instead of stopping at the name
row_text :: proc(buf: []byte, mark, name, tail, right: string, cols: int) -> string {
	// 2 covers the mark and at least one space before the right column. the name
	// yields to the tail first, then the tail itself is trimmed to what is left,
	// or a long link target pushes the row past the terminal width.
	room := max(cols-len(right)-2, 1)
	fitted := fit(name, max(room-len(tail), 1))
	trimmed := fit(tail, max(room-len(fitted), 0))
	n := copy(buf, mark)
	n += copy(buf[n:], fitted)
	n += copy(buf[n:], trimmed)
	for n < min(cols-len(right), len(buf)) {
		buf[n] = ' '
		n += 1
	}
	n += copy(buf[n:], right)
	return string(buf[:n])
}

@(test)
test_row_text :: proc(t: ^testing.T) {
	buf: [512]byte

	got := row_text(buf[:], " ", "a.txt", "", "10B", 20)
	testing.expect(t, len(got) == 20, "row fills the width so the highlight covers it")
	testing.expect(t, strings.has_prefix(got, " a.txt"), "name sits on the left")
	testing.expect(t, strings.has_suffix(got, "10B"), "the sorted-by value sits on the right")

	got = row_text(buf[:], "*", "dir", "/", "dir", 20)
	testing.expect(t, strings.has_prefix(got, "*dir/"), "the tick and the slash both survive")

	got = row_text(buf[:], " ", "mylink", " -> /some/target", "link", 40)
	testing.expect(t, len(got) == 40, "a link row still fills the width exactly")
	testing.expect(t, strings.contains(got, "mylink -> /some/target"), "the link target is shown in full")

	// a target longer than the row must not push the line past the terminal width
	wide := row_text(buf[:], " ", "n", " -> /a/very/long/target/path/that/keeps/going", "link", 20)
	testing.expect(t, len(wide) <= 20, "a long link target never overflows the row")

	long := row_text(buf[:], " ", "a-very-long-file-name-that-will-not-fit.txt", "", "1.5KiB", 20)
	testing.expect(t, len(long) <= 20, "a long name is truncated, never wrapped")
	testing.expect(t, strings.has_suffix(long, "1.5KiB"), "the right column survives truncation")

	narrow := row_text(buf[:], " ", "name", "", "10B", 4)
	testing.expect(t, len(narrow) > 0, "a very narrow terminal still produces a row")
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
draw :: proc(cwd: string, files: []Entry, selected: []bool, cursor, offset, rows, cols: int, msg: string, sort_by: Sort, local: ^datetime.TZ_Region) {
	fmt.print("\x1b[2J\x1b[H")
	fmt.printfln("\x1b[1m%s\x1b[0m", fit(cwd, cols))

	if len(files) == 0 {
		fmt.print("(empty or unreadable)")
		// an empty listing is exactly when you need to be told why, so say it here too
		if msg != "" {
			fmt.printf("\n\x1b[7m %s \x1b[0m", fit(msg, cols-2))
		}
		return
	}

	row: [512]byte
	for i in offset ..< min(offset+rows, len(files)) {
		f := files[i]
		mark := "*" if selected[i] else " "
		// a directory gets its slash, a link shows where it points
		tail := f.link
		if f.type == .Directory {
			tail = "/"
		}

		// the right column shows whatever the listing is sorted by, so the order is readable
		rbuf: [32]byte
		right: string
		switch {
		case sort_by == .Time:
			right = local_date(f.modification_time, local, rbuf[:])
		case f.type == .Symlink:
			// the byte length of a link is its target string, which nobody wants to read
			right = "link"
		case f.type == .Directory:
			right = "dir"
		case:
			// bprintf into a stack buffer: draw runs every keypress and must not allocate
			right = fmt.bprintf(rbuf[:], "%M", f.size)
		}

		line := row_text(row[:], mark, f.name, tail, right, cols)
		if i == cursor {
			fmt.printfln("\x1b[7m%s\x1b[0m", line)
		} else {
			fmt.printfln("%s", line)
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
		status = fmt.bprintf(sbuf[:], " %s  dir  %d/%d  %v ", string(pp[:]), cursor+1, len(files), sort_by)
	} else {
		status = fmt.bprintf(sbuf[:], " %s  %M  %d/%d  %v ", string(pp[:]), f.size, cursor+1, len(files), sort_by)
	}
	fmt.printf("\x1b[7m%s\x1b[0m", fit(status, cols))
}
