package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"

Language :: enum {
	None, C, Cpp, Odin, Python, Markdown, Shell, JSON, HTML, Make, Text,
}

Cursor :: struct { row, col: int }

Edit_Kind :: enum { Insert, Delete }

Edit :: struct {
	kind:      Edit_Kind,
	row, col:  int,
	text:      []u8,
	cursor_before: Cursor,
	cursor_after:  Cursor,
}

Buffer :: struct {
	name:        string,
	path:        string,
	lines:       [dynamic][dynamic]u8,
	cursor:      Cursor,
	want_col:    int,
	sel_anchor:  Maybe(Cursor),
	dirty:       bool,
	lang:        Language,
	undo:        [dynamic]Edit,
	redo:        [dynamic]Edit,
	read_only:   bool,
}

buffer_new_scratch :: proc(name: string) -> ^Buffer {
	b := new(Buffer)
	b.name = strings.clone(name)
	b.path = ""
	b.lang = .Text
	append(&b.lines, make([dynamic]u8))
	return b
}

buffer_load_file :: proc(path: string) -> ^Buffer {
	b := new(Buffer)
	b.path = strings.clone(path)
	b.name = strings.clone(filepath.base(path))
	b.lang = detect_language(path)
	data, ok := os.read_entire_file(path)
	if !ok {
		append(&b.lines, make([dynamic]u8))
		return b
	}
	defer delete(data)
	start := 0
	for i in 0..<len(data) {
		if data[i] == '\n' {
			line := make([dynamic]u8)
			end := i
			if end > start && data[end-1] == '\r' { end -= 1 }
			append(&line, ..data[start:end])
			append(&b.lines, line)
			start = i+1
		}
	}
	// last
	if start < len(data) {
		line := make([dynamic]u8)
		append(&line, ..data[start:])
		append(&b.lines, line)
	}
	if len(b.lines) == 0 {
		append(&b.lines, make([dynamic]u8))
	}
	return b
}

buffer_save :: proc(b: ^Buffer) -> bool {
	if b.path == "" { return false }
	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)
	for line, i in b.lines {
		strings.write_bytes(&sb, line[:])
		if i < len(b.lines)-1 {
			strings.write_byte(&sb, '\n')
		}
	}
	ok := os.write_entire_file(b.path, transmute([]u8)strings.to_string(sb))
	if ok { b.dirty = false }
	return ok
}

detect_language :: proc(path: string) -> Language {
	base := filepath.base(path)
	if base == "Makefile" || base == "makefile" || base == "GNUmakefile" {
		return .Make
	}
	ext := filepath.ext(path)
	switch ext {
	case ".c", ".h":
		return .C
	case ".cc", ".cpp", ".cxx", ".hpp", ".hh", ".hxx":
		return .Cpp
	case ".odin":
		return .Odin
	case ".py":
		return .Python
	case ".md", ".markdown":
		return .Markdown
	case ".sh", ".bash":
		return .Shell
	case ".json":
		return .JSON
	case ".html", ".htm":
		return .HTML
	case ".mk":
		return .Make
	}
	return .Text
}

buffer_clamp_cursor :: proc(b: ^Buffer) {
	if b.cursor.row < 0 { b.cursor.row = 0 }
	if b.cursor.row >= len(b.lines) { b.cursor.row = len(b.lines)-1 }
	row_len := len(b.lines[b.cursor.row])
	if b.cursor.col < 0 { b.cursor.col = 0 }
	if b.cursor.col > row_len { b.cursor.col = row_len }
}

cursor_lt :: proc(a, b: Cursor) -> bool {
	if a.row != b.row { return a.row < b.row }
	return a.col < b.col
}

cursor_eq :: proc(a, b: Cursor) -> bool {
	return a.row == b.row && a.col == b.col
}

selection_range :: proc(b: ^Buffer) -> (s, e: Cursor, ok: bool) {
	a, has := b.sel_anchor.?
	if !has { return Cursor{}, Cursor{}, false }
	if cursor_lt(a, b.cursor) {
		return a, b.cursor, true
	}
	return b.cursor, a, true
}

clear_selection :: proc(b: ^Buffer) {
	b.sel_anchor = nil
}

ensure_anchor :: proc(b: ^Buffer) {
	if _, ok := b.sel_anchor.?; !ok {
		b.sel_anchor = b.cursor
	}
}

// ---- low-level edits with undo ------------------------------------------

push_undo :: proc(b: ^Buffer, e: Edit) {
	append(&b.undo, e)
	for x in b.redo { delete(x.text) }
	clear(&b.redo)
}

buffer_insert_text :: proc(b: ^Buffer, pos: Cursor, text: []u8, record: bool = true) -> Cursor {
	cur_before := b.cursor
	row := pos.row
	col := pos.col
	if row < 0 { row = 0 }
	if row >= len(b.lines) { row = len(b.lines)-1 }
	if col < 0 { col = 0 }
	if col > len(b.lines[row]) { col = len(b.lines[row]) }
	// split text by '\n'
	start := 0
	first := true
	cur := Cursor{row, col}
	for i := 0; i <= len(text); i += 1 {
		if i == len(text) || text[i] == '\n' {
			seg := text[start:i]
			if first {
				// insert into line at col
				old := &b.lines[cur.row]
				inject_at(old, cur.col, ..seg)
				cur.col += len(seg)
				first = false
			} else {
				// new line: split: take rest of current line after cur.col
				cur_line := &b.lines[cur.row]
				rest := make([dynamic]u8)
				if cur.col < len(cur_line) {
					append(&rest, ..cur_line[cur.col:])
					resize(cur_line, cur.col)
				}
				new_line := make([dynamic]u8)
				append(&new_line, ..seg)
				append(&new_line, ..rest[:])
				delete(rest)
				cur.row += 1
				inject_at(&b.lines, cur.row, new_line)
				cur.col = len(seg)
			}
			start = i+1
		}
	}
	b.dirty = true
	if record {
		buf := make([]u8, len(text))
		copy(buf, text)
		push_undo(b, Edit{
			kind = .Insert,
			row = pos.row, col = pos.col,
			text = buf,
			cursor_before = cur_before,
			cursor_after = cur,
		})
	}
	return cur
}

buffer_delete_range :: proc(b: ^Buffer, a, c: Cursor, record: bool = true) {
	cur_before := b.cursor
	s := a; e := c
	if cursor_lt(c, a) { s = c; e = a }
	// collect deleted text
	collected: [dynamic]u8
	if s.row == e.row {
		line := &b.lines[s.row]
		append(&collected, ..line[s.col:e.col])
		remove_range(line, s.col, e.col)
	} else {
		first := &b.lines[s.row]
		append(&collected, ..first[s.col:])
		append(&collected, '\n')
		for r in s.row+1..<e.row {
			append(&collected, ..b.lines[r][:])
			append(&collected, '\n')
		}
		last := &b.lines[e.row]
		append(&collected, ..last[:e.col])
		// merge: keep first[0:s.col] + last[e.col:]
		resize(first, s.col)
		append(first, ..last[e.col:])
		// remove rows s.row+1 .. e.row inclusive
		for _ in s.row+1..=e.row {
			delete(b.lines[s.row+1])
			ordered_remove(&b.lines, s.row+1)
		}
	}
	b.dirty = true
	b.cursor = s
	if record {
		buf := make([]u8, len(collected))
		copy(buf, collected[:])
		push_undo(b, Edit{
			kind = .Delete,
			row = s.row, col = s.col,
			text = buf,
			cursor_before = cur_before,
			cursor_after = s,
		})
	}
	delete(collected)
}

undo :: proc(b: ^Buffer) -> bool {
	if len(b.undo) == 0 { return false }
	e := pop(&b.undo)
	if e.kind == .Insert {
		// reverse: delete text inserted starting at e.row,e.col
		// compute end cursor
		end := compute_end_after_insert(e.row, e.col, e.text)
		buffer_delete_range(b, Cursor{e.row,e.col}, end, false)
	} else {
		buffer_insert_text(b, Cursor{e.row,e.col}, e.text, false)
	}
	b.cursor = e.cursor_before
	append(&b.redo, e)
	clear_selection(b)
	return true
}

redo :: proc(b: ^Buffer) -> bool {
	if len(b.redo) == 0 { return false }
	e := pop(&b.redo)
	if e.kind == .Insert {
		buffer_insert_text(b, Cursor{e.row,e.col}, e.text, false)
	} else {
		end := compute_end_after_insert(e.row, e.col, e.text)
		buffer_delete_range(b, Cursor{e.row,e.col}, end, false)
	}
	b.cursor = e.cursor_after
	append(&b.undo, e)
	clear_selection(b)
	return true
}

compute_end_after_insert :: proc(row, col: int, text: []u8) -> Cursor {
	r := row; c := col
	for i in 0..<len(text) {
		if text[i] == '\n' {
			r += 1; c = 0
		} else {
			c += 1
		}
	}
	return Cursor{r, c}
}

// ---- high-level user operations ----

selection_text :: proc(b: ^Buffer) -> []u8 {
	s, e, ok := selection_range(b)
	if !ok { return nil }
	out: [dynamic]u8
	if s.row == e.row {
		append(&out, ..b.lines[s.row][s.col:e.col])
	} else {
		append(&out, ..b.lines[s.row][s.col:])
		append(&out, '\n')
		for r in s.row+1..<e.row {
			append(&out, ..b.lines[r][:])
			append(&out, '\n')
		}
		append(&out, ..b.lines[e.row][:e.col])
	}
	return out[:]
}

delete_selection_if_any :: proc(b: ^Buffer) -> bool {
	s, e, ok := selection_range(b)
	if !ok { return false }
	buffer_delete_range(b, s, e)
	clear_selection(b)
	return true
}

insert_text_user :: proc(b: ^Buffer, text: []u8) {
	delete_selection_if_any(b)
	end := buffer_insert_text(b, b.cursor, text)
	b.cursor = end
	b.want_col = display_col_of_byte(b.lines[b.cursor.row][:], b.cursor.col)
	clear_selection(b)
}

backspace :: proc(b: ^Buffer) {
	if delete_selection_if_any(b) { return }
	if b.cursor.row == 0 && b.cursor.col == 0 { return }
	prev := b.cursor
	if b.cursor.col > 0 {
		prev.col = prev_rune_start(b.lines[b.cursor.row][:], b.cursor.col)
	} else {
		prev.row -= 1
		prev.col = len(b.lines[prev.row])
	}
	buffer_delete_range(b, prev, b.cursor)
	b.cursor = prev
	b.want_col = display_col_of_byte(b.lines[b.cursor.row][:], b.cursor.col)
}

delete_forward :: proc(b: ^Buffer) {
	if delete_selection_if_any(b) { return }
	row_len := len(b.lines[b.cursor.row])
	nxt := b.cursor
	if b.cursor.col < row_len {
		nxt.col = next_rune_start(b.lines[b.cursor.row][:], b.cursor.col)
	} else if b.cursor.row < len(b.lines)-1 {
		nxt.row += 1
		nxt.col = 0
	} else {
		return
	}
	buffer_delete_range(b, b.cursor, nxt)
	b.want_col = display_col_of_byte(b.lines[b.cursor.row][:], b.cursor.col)
}

newline_with_indent :: proc(b: ^Buffer) {
	delete_selection_if_any(b)
	// compute leading whitespace of current row
	row := b.lines[b.cursor.row]
	indent: [dynamic]u8
	for i in 0..<len(row) {
		c := row[i]
		if c == ' ' || c == '\t' { append(&indent, c) } else { break }
	}
	text: [dynamic]u8
	append(&text, '\n')
	append(&text, ..indent[:])
	end := buffer_insert_text(b, b.cursor, text[:])
	delete(indent)
	delete(text)
	b.cursor = end
	b.want_col = b.cursor.col
}

insert_tab :: proc(b: ^Buffer) {
	delete_selection_if_any(b)
	if b.lang == .Make {
		// Makefiles require literal tabs at the start of recipes.
		end := buffer_insert_text(b, b.cursor, []u8{'\t'})
		b.cursor = end
		b.want_col = b.cursor.col
		return
	}
	tw := g_app.tab_width
	pad: [dynamic]u8
	for _ in 0..<tw { append(&pad, ' ') }
	end := buffer_insert_text(b, b.cursor, pad[:])
	delete(pad)
	b.cursor = end
	b.want_col = b.cursor.col
}

move_cursor :: proc(b: ^Buffer, drow, dcol: int, extend: bool) {
	if extend { ensure_anchor(b) } else { clear_selection(b) }
	if dcol != 0 {
		// Step horizontally by codepoints, crossing line boundaries.
		steps := dcol if dcol > 0 else -dcol
		dir   := 1 if dcol > 0 else -1
		for _ in 0..<steps {
			line := b.lines[b.cursor.row][:]
			if dir > 0 {
				if b.cursor.col < len(line) {
					b.cursor.col = next_rune_start(line, b.cursor.col)
				} else if b.cursor.row < len(b.lines)-1 {
					b.cursor.row += 1
					b.cursor.col = 0
				}
			} else {
				if b.cursor.col > 0 {
					b.cursor.col = prev_rune_start(line, b.cursor.col)
				} else if b.cursor.row > 0 {
					b.cursor.row -= 1
					b.cursor.col = len(b.lines[b.cursor.row])
				}
			}
		}
	}
	if drow != 0 {
		b.cursor.row += drow
		if b.cursor.row < 0 { b.cursor.row = 0 }
		if b.cursor.row >= len(b.lines) { b.cursor.row = len(b.lines)-1 }
		// Map the desired display column onto the new line.
		b.cursor.col = byte_col_for_display(b.lines[b.cursor.row][:], b.want_col)
	} else {
		b.want_col = display_col_of_byte(b.lines[b.cursor.row][:], b.cursor.col)
	}
}

move_home :: proc(b: ^Buffer, extend: bool) {
	if extend { ensure_anchor(b) } else { clear_selection(b) }
	row := b.lines[b.cursor.row]
	first_nb := 0
	for ; first_nb < len(row); first_nb += 1 {
		if row[first_nb] != ' ' && row[first_nb] != '\t' { break }
	}
	if b.cursor.col != first_nb {
		b.cursor.col = first_nb
	} else {
		b.cursor.col = 0
	}
	b.want_col = display_col_of_byte(b.lines[b.cursor.row][:], b.cursor.col)
}

move_end :: proc(b: ^Buffer, extend: bool) {
	if extend { ensure_anchor(b) } else { clear_selection(b) }
	b.cursor.col = len(b.lines[b.cursor.row])
	b.want_col = display_col_of_byte(b.lines[b.cursor.row][:], b.cursor.col)
}

is_word_char :: proc(c: u8) -> bool {
	return is_word_byte(c)
}

move_word :: proc(b: ^Buffer, dir: int, extend: bool) {
	if extend { ensure_anchor(b) } else { clear_selection(b) }
	if dir > 0 {
		row := b.lines[b.cursor.row][:]
		i := b.cursor.col
		for i < len(row) && is_word_byte(row[i]) { i = next_rune_start(row, i) }
		for i < len(row) && !is_word_byte(row[i]) { i = next_rune_start(row, i) }
		if i == b.cursor.col {
			if b.cursor.row < len(b.lines)-1 {
				b.cursor.row += 1
				b.cursor.col = 0
			}
		} else {
			b.cursor.col = i
		}
	} else {
		row := b.lines[b.cursor.row][:]
		i := b.cursor.col
		for i > 0 {
			j := prev_rune_start(row, i)
			if is_word_byte(row[j]) { break }
			i = j
		}
		for i > 0 {
			j := prev_rune_start(row, i)
			if !is_word_byte(row[j]) { break }
			i = j
		}
		if i == b.cursor.col {
			if b.cursor.row > 0 {
				b.cursor.row -= 1
				b.cursor.col = len(b.lines[b.cursor.row])
			}
		} else {
			b.cursor.col = i
		}
	}
	b.want_col = display_col_of_byte(b.lines[b.cursor.row][:], b.cursor.col)
}

select_all :: proc(b: ^Buffer) {
	b.sel_anchor = Cursor{0, 0}
	b.cursor.row = len(b.lines)-1
	b.cursor.col = len(b.lines[b.cursor.row])
	b.want_col = display_col_of_byte(b.lines[b.cursor.row][:], b.cursor.col)
}
