package editor

import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:sys/posix"

absolute_path :: proc(p: string) -> (string, bool) {
	abs, err := filepath.abs(p)
	if err == false { return "", false }
	return abs, true
}

path_is_dir :: proc(path: string) -> bool {
	fi, err := os.stat(path)
	if err != nil { return false }
	return fi.is_dir
}

path_exists :: proc(path: string) -> bool {
	_, err := os.stat(path)
	return err == nil
}

dir_name :: proc(p: string) -> string {
	d := filepath.dir(p)
	if d == "" { return "." }
	return d
}

// Robust directory listing.  Uses posix opendir/readdir directly so that a
// single broken symlink, unreadable entry, or stat failure cannot wipe out the
// whole listing (which is what `os.read_dir` does — see issue: any lstat
// failure aborts the entire enumeration and silently yields zero files).
// Every dirent returned by the kernel is included; entries we can't lstat are
// still listed, with `is_dir` inferred from `d_type` and size = 0.
list_directory :: proc(path: string) -> ([]os.File_Info, bool) {
	cpath := strings.clone_to_cstring(path); defer delete(cpath)
	dirp := posix.opendir(cpath)
	if dirp == nil { return nil, false }
	defer posix.closedir(dirp)

	out: [dynamic]os.File_Info
	for {
		entry := posix.readdir(dirp)
		if entry == nil { break }
		name := string(cstring(&entry.d_name[0]))
		if name == "." || name == ".." { continue }

		full := filepath.join({path, name})
		fi: os.File_Info
		fi.name = filepath.base(full)
		fi.fullpath = full

		// Try to stat for accurate size / dir flag, but don't drop the entry
		// if it fails (broken symlinks, EACCES, etc.).
		if st, serr := os.stat(full); serr == nil {
			fi.size = st.size
			fi.mode = st.mode
			fi.is_dir = st.is_dir
			fi.creation_time = st.creation_time
			fi.modification_time = st.modification_time
			fi.access_time = st.access_time
		} else {
			fi.is_dir = entry.d_type == .DIR
		}
		append(&out, fi)
	}
	return out[:], true
}

os_rename :: proc(old, new: string) -> bool {
	o := strings.clone_to_cstring(old); defer delete(o)
	n := strings.clone_to_cstring(new); defer delete(n)
	return posix.rename(o, n) == 0
}

os_mkdir :: proc(path: string) -> bool {
	p := strings.clone_to_cstring(path); defer delete(p)
	return posix.mkdir(p, posix.S_IRWXU | posix.S_IRWXG | posix.S_IRWXO) == .OK
}

os_remove_path :: proc(path: string) -> bool {
	p := strings.clone_to_cstring(path); defer delete(p)
	if posix.unlink(p) == .OK { return true }
	if posix.rmdir(p) == .OK { return true }
	return false
}

ensure_dir :: proc(path: string) -> bool {
	if path_exists(path) { return path_is_dir(path) }
	parent := dir_name(path)
	if parent != path && parent != "" && parent != "." && parent != "/" {
		ensure_dir(parent)
	}
	return os_mkdir(path)
}

home_dir :: proc() -> string {
	if h, ok := os.lookup_env("HOME"); ok { return h }
	return "/tmp"
}
