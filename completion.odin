package editor

import "core:strings"
import "core:os"
import "core:path/filepath"
import "core:time"

ALLOWED_EXTS := []string{".c", ".cpp", ".cxx", ".cc", ".h", ".hpp", ".hh", ".odin", ".py", ".txt", ".mk", ".md", ".markdown"}
ALLOWED_NAMES := []string{"Makefile", "makefile", "GNUmakefile"}
SCAN_MAX_DIRS :: 20
SCAN_MAX_FILE_BYTES :: 256 * 1024

is_completion_target :: proc(name: string) -> bool {
	for n in ALLOWED_NAMES { if n == name { return true } }
	low := strings.to_lower(name); defer delete(low)
	for ext in ALLOWED_EXTS { if strings.has_suffix(low, ext) { return true } }
	if strings.has_suffix(low, ".mk") { return true }
	return false
}

scan_dir_words :: proc(root: string) -> []string {
	dirs: [dynamic]string
	defer { for d in dirs { delete(d) }; delete(dirs) }
	append(&dirs, strings.clone(root))
	// add immediate subdirs
	if infos, ok := list_directory(root); ok {
		defer delete(infos)
		for fi in infos {
			if !fi.is_dir { continue }
			if fi.name == "." || fi.name == ".." { continue }
			// skip dot dirs and big known dirs
			if len(fi.name) > 0 && fi.name[0] == '.' { continue }
			if fi.name == "node_modules" || fi.name == "build" || fi.name == "target" { continue }
			append(&dirs, strings.clone(fi.fullpath))
			if len(dirs) >= SCAN_MAX_DIRS { break }
		}
	}
	seen := make(map[string]bool); defer delete(seen)
	out: [dynamic]string
	for d in dirs {
		infos, ok := list_directory(d)
		if !ok { continue }
		defer delete(infos)
		for fi in infos {
			if fi.is_dir { continue }
			if !is_completion_target(fi.name) { continue }
			if fi.size > SCAN_MAX_FILE_BYTES { continue }
			data, rok := os.read_entire_file(fi.fullpath)
			if !rok { continue }
			defer delete(data)
			extract_identifiers(data, &out, &seen)
		}
	}
	return out[:]
}

extract_identifiers :: proc(data: []u8, out: ^[dynamic]string, seen: ^map[string]bool) {
	i := 0
	n := len(data)
	for i < n {
		c := data[i]
		if !is_word_start(c) { i += 1; continue }
		j := i
		for j < n && is_word_char(data[j]) { j += 1 }
		w := string(data[i:j])
		if len(w) >= 3 && len(w) <= 64 && !seen[w] {
			seen[w] = true
			append(out, strings.clone(w))
		}
		i = j
	}
}

is_word_start :: proc(c: u8) -> bool {
	return (c>='a' && c<='z') || (c>='A' && c<='Z') || c=='_'
}

CACHE_TTL_SEC :: 30

ensure_disk_word_cache :: proc() {
	if len(g_app.completion_cache_words) > 0 {
		age := time.duration_seconds(time.since(g_app.completion_cache_at))
		if age < CACHE_TTL_SEC { return }
		for w in g_app.completion_cache_words { delete(w) }
		clear(&g_app.completion_cache_words)
	}
	words := scan_dir_words(g_app.cwd)
	for w in words { append(&g_app.completion_cache_words, w) }
	delete(words)
	g_app.completion_cache_at = time.now()
}

KEYWORDS_FOR_LANG :: proc(l: Language) -> []string {
	switch l {
	case .C:        return C_KW
	case .Cpp:      return CPP_KW  // plus C
	case .Odin:     return ODIN_KW
	case .Python:   return PY_KW
	case .Shell:    return SH_KW
	case .Markdown, .JSON, .HTML, .Make, .Text, .None: return nil
	}
	return nil
}

current_word_prefix :: proc(b: ^Buffer) -> (string, int) {
	row := b.lines[b.cursor.row][:]
	end := b.cursor.col
	if end > len(row) { end = len(row) }
	start := end
	for start > 0 && is_word_char(row[start-1]) { start -= 1 }
	return string(row[start:end]), start
}

gather_completions :: proc(prefix: string, b: ^Buffer) -> []string {
	if len(prefix) == 0 { return nil }
	seen := make(map[string]bool)
	defer delete(seen)
	out: [dynamic]string
	// keywords + builtins
	kw_lists := [2][]string{KEYWORDS_FOR_LANG(b.lang), keywords_extra(b.lang)}
	for kws in kw_lists {
		for kw in kws {
			if strings.has_prefix(kw, prefix) && kw != prefix && !seen[kw] {
				seen[kw] = true
				append(&out, strings.clone(kw))
			}
		}
	}
	// scan all open buffers for words
	for buf in g_app.buffers {
		for line in buf.lines {
			i := 0
			n := len(line)
			for i < n {
				c := line[i]
				if !is_word_char(c) { i += 1; continue }
				j := i
				for j < n && is_word_char(line[j]) { j += 1 }
				w := string(line[i:j])
				if len(w) > len(prefix) && strings.has_prefix(w, prefix) && !seen[w] {
					seen[w] = true
					append(&out, strings.clone(w))
				}
				i = j
			}
		}
	}
	// scan cached words from disk (cwd + 1 level)
	ensure_disk_word_cache()
	for w in g_app.completion_cache_words {
		if len(w) > len(prefix) && strings.has_prefix(w, prefix) && !seen[w] {
			seen[w] = true
			append(&out, strings.clone(w))
		}
	}
	if len(out) == 0 { return nil }
	return out[:]
}

keywords_extra :: proc(l: Language) -> []string {
	switch l {
	case .C, .Cpp:  return C_TYPES
	case .Odin:     return ODIN_TYPES
	case .Python:   return PY_BUILTIN
	case .Shell, .Markdown, .JSON, .HTML, .Make, .Text, .None: return nil
	}
	return nil
}

trigger_completion :: proc(b: ^Buffer) {
	prefix, _ := current_word_prefix(b)
	items := gather_completions(prefix, b)
	if items == nil || len(items) == 0 {
		set_status("No completions")
		return
	}
	d := dialog_open(.Completion, "Complete", "", proc(d: ^Dialog){
		if d.sel < 0 || d.sel >= len(d.items) { return }
		w := d.items[d.sel]
		// replace current prefix with w
		b := g_app.active_pane.buffer
		if b == nil { return }
		prefix, start := current_word_prefix(b)
		s := Cursor{b.cursor.row, start}
		e := Cursor{b.cursor.row, start+len(prefix)}
		buffer_delete_range(b, s, e)
		buffer_insert_text(b, s, transmute([]u8)w)
		b.cursor = Cursor{s.row, s.col+len(w)}
		b.want_col = b.cursor.col
	})
	d.items = items
	d.sel = 0
}
