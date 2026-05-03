package editor

import "core:os"
import "core:strings"
import "core:path/filepath"

RECENT_MAX :: 20

recent_dir :: proc() -> string {
	return filepath.join({home_dir(), ".config", "john"})
}

recent_file_path :: proc() -> string {
	return filepath.join({recent_dir(), "recent"})
}

recent_load :: proc() {
	clear(&g_app.recent)
	if g_app.recent_path != "" { delete(g_app.recent_path) }
	g_app.recent_path = recent_file_path()
	data, ok := os.read_entire_file(g_app.recent_path)
	if !ok { return }
	defer delete(data)
	s := string(data)
	for line in strings.split_lines_iterator(&s) {
		l := strings.trim_space(line)
		if l == "" { continue }
		append(&g_app.recent, strings.clone(l))
	}
}

recent_save :: proc() {
	if g_app.recent_path == "" { return }
	dir := recent_dir()
	ensure_dir(dir)
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for r in g_app.recent {
		strings.write_string(&sb, r)
		strings.write_byte(&sb, '\n')
	}
	os.write_entire_file(g_app.recent_path, transmute([]u8)strings.to_string(sb))
}

recent_add :: proc(path: string) {
	if path == "" { return }
	abs, ok := absolute_path(path)
	if !ok { abs = strings.clone(path) }
	defer delete(abs)
	// dedupe (move to front)
	for r, i in g_app.recent {
		if r == abs {
			delete(g_app.recent[i])
			ordered_remove(&g_app.recent, i)
			break
		}
	}
	inject_at(&g_app.recent, 0, strings.clone(abs))
	for len(g_app.recent) > RECENT_MAX {
		last := len(g_app.recent)-1
		delete(g_app.recent[last])
		pop(&g_app.recent)
	}
	recent_save()
}

cmd_focus_toggle_tree_editor :: proc() {
	if !g_app.show_tree { g_app.show_tree = true; g_app.focus = .Tree; return }
	g_app.focus = .Editor if g_app.focus == .Tree else .Tree
}
