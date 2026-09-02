package gunti

import "core:fmt"
import "core:os"
import "core:slice"

main :: proc() {
	files, err := os.read_all_directory_by_path(".", context.temp_allocator)
	if err != nil {
		fmt.eprintfln("gunti: %v", err)
		os.exit(1)
	}

	// readdir order is whatever the fs feels like; sort or it looks broken
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool { return a.name < b.name })

	for f in files {
		if f.type == .Directory {
			fmt.printfln("%s/", f.name)
		} else {
			fmt.println(f.name)
		}
	}
}
