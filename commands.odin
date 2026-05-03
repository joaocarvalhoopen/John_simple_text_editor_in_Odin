package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:path/filepath"

cmd_quit :: proc() {
	dirty := false
	for b in g_app.buffers { if b.dirty { dirty = true; break } }
	if dirty {
		d := dialog_open(.Confirm, "Quit", "Unsaved changes! Type 'yes' to quit anyway:", proc(d: ^Dialog){
			if string(d.input[:]) == "yes" {
				g_app.quit = true
			}
		})
		_ = d
		return
	}
	g_app.quit = true
}

cmd_new_buffer :: proc() {
	b := buffer_new_scratch("*scratch*")
	append(&g_app.buffers, b)
	open_in_active_pane(b)
	set_status("New buffer")
}

cmd_open_prompt :: proc() {
	d := dialog_open(.Prompt, "Open File", "File path:", proc(d: ^Dialog){
		path := strings.clone(string(d.input[:]))
		defer delete(path)
		do_open_path(path)
	})
	// pre-fill cwd
	for c in g_app.cwd { append(&d.input, u8(c)) }
	append(&d.input, '/')
	d.cursor = len(d.input)
}

do_open_path :: proc(path: string) {
	if path == "" { return }
	full := path
	if path[0] != '/' {
		full = filepath.join({g_app.cwd, path})
	}
	if path_is_dir(full) {
		set_status("Cannot open directory as buffer: %s", full)
		return
	}
	if !path_exists(full) {
		// create new buffer with that path
		b := buffer_new_scratch(filepath.base(full))
		b.path = strings.clone(full)
		b.lang = detect_language(full)
		append(&g_app.buffers, b)
		open_in_active_pane(b)
		set_status("New file: %s", full)
		return
	}
	if existing := find_buffer_by_path(full); existing != nil {
		open_in_active_pane(existing)
		set_status("Switched to %s", full)
		return
	}
	b := buffer_load_file(full)
	append(&g_app.buffers, b)
	open_in_active_pane(b)
	recent_add(full)
	set_status("Opened %s", full)
}

cmd_save :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	b := g_app.active_pane.buffer
	if b.path == "" { cmd_save_as(); return }
	if buffer_save(b) { set_status("Saved %s", b.path) }
	else { set_status("Save FAILED") }
}

cmd_save_as :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	b := g_app.active_pane.buffer
	d := dialog_open(.Prompt, "Save As", "Save to path:", proc(d: ^Dialog){
		p := strings.clone(string(d.input[:]))
		buf := g_app.active_pane.buffer
		if buf == nil { return }
		old := buf.path
		buf.path = p
		buf.name = strings.clone(filepath.base(p))
		buf.lang = detect_language(p)
		if buffer_save(buf) {
			set_status("Saved %s", p)
		} else {
			buf.path = old
			set_status("Save failed")
		}
	})
	prefill := b.path
	if prefill == "" { prefill = filepath.join({g_app.cwd, b.name}) }
	for c in prefill { append(&d.input, u8(c)) }
	d.cursor = len(d.input)
}

cmd_close_buffer :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	b := g_app.active_pane.buffer
	if b.dirty {
		d := dialog_open(.Confirm, "Close Buffer", "Discard changes? Type 'yes':", proc(d: ^Dialog){
			if string(d.input[:]) == "yes" {
				do_close_active_buffer()
			}
		})
		_ = d
		return
	}
	do_close_active_buffer()
}

do_close_active_buffer :: proc() {
	b := g_app.active_pane.buffer
	if b == nil { return }
	idx := -1
	for x, i in g_app.buffers { if x == b { idx = i; break } }
	if idx >= 0 { ordered_remove(&g_app.buffers, idx) }
	// pick another buffer
	if len(g_app.buffers) == 0 {
		nb := buffer_new_scratch("*scratch*")
		append(&g_app.buffers, nb)
	}
	new_b := g_app.buffers[0]
	// replace this buffer in all panes
	panes: [dynamic]^Pane
	collect_panes(g_app.root, &panes)
	for p in panes {
		if p.buffer == b { p.buffer = new_b }
	}
	delete(panes)
	// free old buffer
	for line in b.lines { delete(line) }
	delete(b.lines)
	delete(b.name)
	if b.path != "" { delete(b.path) }
	for e in b.undo { delete(e.text) }
	for e in b.redo { delete(e.text) }
	delete(b.undo); delete(b.redo)
	free(b)
	set_status("Closed buffer")
}

cmd_pick_buffer :: proc() {
	d := dialog_open(.Pick, "Buffers", "", proc(d: ^Dialog){
		if d.sel >= 0 && d.sel < len(g_app.buffers) {
			open_in_active_pane(g_app.buffers[d.sel])
		}
	})
	items := make([]string, len(g_app.buffers))
	for b, i in g_app.buffers {
		marker := " "
		if b.dirty { marker = "●" }
		items[i] = fmt.aprintf("%s %s   [%s]", marker, b.name, b.path if b.path != "" else "(scratch)")
	}
	d.items = items
	d.sel = 0
}

cmd_undo :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	if undo(g_app.active_pane.buffer) { set_status("Undo") } else { set_status("Nothing to undo") }
}
cmd_redo :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	if redo(g_app.active_pane.buffer) { set_status("Redo") } else { set_status("Nothing to redo") }
}

cmd_copy :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	b := g_app.active_pane.buffer
	t := selection_text(b)
	if t == nil {
		// copy current line
		row := b.lines[b.cursor.row]
		clear(&g_app.clipboard)
		append(&g_app.clipboard, ..row[:])
		append(&g_app.clipboard, '\n')
		g_app.clip_is_lines = true
		set_status("Copied line")
		return
	}
	clear(&g_app.clipboard)
	append(&g_app.clipboard, ..t)
	g_app.clip_is_lines = false
	delete(t)
	set_status("Copied")
}
cmd_cut :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	b := g_app.active_pane.buffer
	t := selection_text(b)
	if t == nil {
		// cut current line
		row := b.lines[b.cursor.row]
		clear(&g_app.clipboard)
		append(&g_app.clipboard, ..row[:])
		append(&g_app.clipboard, '\n')
		g_app.clip_is_lines = true
		// delete the line
		s := Cursor{b.cursor.row, 0}
		e: Cursor
		if b.cursor.row < len(b.lines)-1 {
			e = Cursor{b.cursor.row+1, 0}
		} else if b.cursor.row > 0 {
			s = Cursor{b.cursor.row-1, len(b.lines[b.cursor.row-1])}
			e = Cursor{b.cursor.row, len(row)}
		} else {
			e = Cursor{b.cursor.row, len(row)}
		}
		buffer_delete_range(b, s, e)
		clear_selection(b)
		set_status("Cut line")
		return
	}
	clear(&g_app.clipboard)
	append(&g_app.clipboard, ..t)
	g_app.clip_is_lines = false
	delete(t)
	delete_selection_if_any(b)
	set_status("Cut")
}
cmd_paste :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	if len(g_app.clipboard) == 0 { return }
	b := g_app.active_pane.buffer
	if g_app.clip_is_lines {
		// insert line above cursor
		old := b.cursor
		b.cursor = Cursor{old.row, 0}
		insert_text_user(b, g_app.clipboard[:])
		b.cursor = Cursor{old.row+1, old.col}
		buffer_clamp_cursor(b)
	} else {
		insert_text_user(b, g_app.clipboard[:])
	}
	set_status("Pasted")
}

cmd_select_all :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	select_all(g_app.active_pane.buffer)
}

cmd_find :: proc() {
	prompt := fmt.aprintf("Search for (case %s):",
		"SENSITIVE" if g_app.search_case_sensitive else "insensitive")
	d := dialog_open(.Find, "Find", prompt, proc(d: ^Dialog){
		needle := strings.clone(string(d.input[:]))
		if needle == "" { delete(needle); return }
		if g_app.search_needle != "" { delete(g_app.search_needle) }
		g_app.search_needle = needle
		do_find(needle, true, true)
	})
	// Pre-fill with the previous needle so Enter repeats the last search.
	if g_app.search_needle != "" {
		for c in transmute([]u8)g_app.search_needle {
			append(&d.input, c)
		}
		d.cursor = len(d.input)
	}
	delete(prompt)
}
cmd_replace :: proc() {
	prompt := fmt.aprintf("Search for (case %s):",
		"SENSITIVE" if g_app.search_case_sensitive else "insensitive")
	d := dialog_open(.Replace, "Find & Replace", prompt, proc(d: ^Dialog){
		needle := string(d.input[:])
		repl := string(d.input2[:])
		if needle == "" { return }
		// also remember it for F3 / Shift+F3
		if g_app.search_needle != "" { delete(g_app.search_needle) }
		g_app.search_needle = strings.clone(needle)
		count := do_replace_all(needle, repl)
		set_status("%d replacement(s)", count)
	})
	_ = d
	delete(prompt)
}

// Repeat last search forward (F3 / Ctrl+K-like — bound to F3).
cmd_find_next :: proc() {
	if g_app.search_needle == "" {
		set_status("No previous search — press Ctrl+F to start one")
		return
	}
	do_find(g_app.search_needle, true, false)
}
// Repeat last search backward (Shift+F3).
cmd_find_prev :: proc() {
	if g_app.search_needle == "" {
		set_status("No previous search — press Ctrl+F to start one")
		return
	}
	do_find(g_app.search_needle, false, false)
}
// Toggle case sensitivity for future searches (Alt+C).
cmd_toggle_search_case :: proc() {
	g_app.search_case_sensitive = !g_app.search_case_sensitive
	set_status("Search case sensitivity: %s",
		"SENSITIVE (exact case)" if g_app.search_case_sensitive else "insensitive")
}

// Lowercase a string into a freshly allocated []u8.  Only ASCII A-Z is
// folded — good enough for the case-insensitive search of identifiers,
// which is the common case in code.  Multibyte UTF-8 bytes (>= 0x80) are
// preserved as-is so a needle byte still matches an identical haystack
// byte.
search_fold :: proc(s: string) -> []u8 {
	out := make([]u8, len(s))
	for i in 0..<len(s) {
		c := s[i]
		if c >= 'A' && c <= 'Z' { c += 32 }
		out[i] = c
	}
	return out
}

// Find `needle` in `hay` starting at byte offset `from`, honouring the
// global case-sensitivity flag.  Returns the byte index, or -1.
search_index_in :: proc(hay: string, needle: string, from: int) -> int {
	if from < 0 || from > len(hay) { return -1 }
	if g_app.search_case_sensitive {
		idx := strings.index(hay[from:], needle)
		return -1 if idx < 0 else from + idx
	}
	h := search_fold(hay)
	defer delete(h)
	n := search_fold(needle)
	defer delete(n)
	idx := strings.index(string(h[from:]), string(n))
	return -1 if idx < 0 else from + idx
}

// Find LAST occurrence of needle in hay strictly before byte offset `before`.
search_index_last_in :: proc(hay: string, needle: string, before: int) -> int {
	if len(needle) == 0 || before <= 0 { return -1 }
	limit := before
	if limit > len(hay) { limit = len(hay) }
	if g_app.search_case_sensitive {
		// strings.last_index doesn't take an endpoint, slice it.
		return strings.last_index(hay[:limit], needle)
	}
	h := search_fold(hay)
	defer delete(h)
	n := search_fold(needle)
	defer delete(n)
	return strings.last_index(string(h[:limit]), string(n))
}

do_find :: proc(needle: string, forward: bool, from_dialog: bool) {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	b := g_app.active_pane.buffer
	if len(needle) == 0 { return }
	mode_tag := "case-sensitive" if g_app.search_case_sensitive else "case-insensitive"

	if forward {
		// Where to start the forward search:
		//  - From the dialog (initial Ctrl+F + Enter): start AT the cursor so
		//    typing a needle that's already at the cursor still matches.
		//  - From F3 (repeat next): start at the END of the current match so
		//    the same hit isn't returned again.  When there's a selection we
		//    use its larger end; otherwise we advance one full codepoint past
		//    the cursor so multi-byte characters aren't split.
		start_row := b.cursor.row
		start_col := b.cursor.col
		if !from_dialog {
			if sa, ok := b.sel_anchor.?; ok {
				if sa.row == b.cursor.row {
					if sa.col > start_col { start_col = sa.col }
				} else if sa.row > start_row {
					start_row = sa.row
					start_col = sa.col
				}
			} else {
				// No selection: skip past one codepoint so we don't re-match
				// the same byte position.  Uses the UTF-8 helper from
				// unicode_util.odin so we never land in the middle of a rune.
				line := b.lines[start_row][:]
				if start_col < len(line) {
					start_col = next_rune_start(line, start_col)
				}
			}
		}
		// Main forward sweep [start_row..end].
		for r in start_row..<len(b.lines) {
			col := 0 if r != start_row else start_col
			line := string(b.lines[r][:])
			if col > len(line) { continue }
			idx := search_index_in(line, needle, col)
			if idx >= 0 {
				b.sel_anchor = Cursor{r, idx}
				b.cursor = Cursor{r, idx + len(needle)}
				b.want_col = b.cursor.col
				set_status("Found '%s' at line %d (%s)", needle, r+1, mode_tag)
				return
			}
		}
		// Wrap-around: search the start of the buffer up to where we began.
		for r in 0..=start_row {
			line := string(b.lines[r][:])
			limit := len(line)
			if r == start_row {
				limit = start_col
				if limit > len(line) { limit = len(line) }
				if limit < 0          { limit = 0 }
			}
			idx := search_index_in(line[:limit], needle, 0)
			if idx >= 0 {
				b.sel_anchor = Cursor{r, idx}
				b.cursor = Cursor{r, idx + len(needle)}
				b.want_col = b.cursor.col
				set_status("Wrapped: '%s' at line %d (%s)", needle, r+1, mode_tag)
				return
			}
		}
	} else {
		// Backward search.  The "before" position is the lower edge of the
		// region we're allowed to match in: the START of the current match
		// (so Shift+F3 steps strictly backwards), or one codepoint before
		// the bare cursor when there's no selection.
		start_row := b.cursor.row
		start_col := b.cursor.col
		if sa, ok := b.sel_anchor.?; ok && sa.row == b.cursor.row && sa.col < b.cursor.col {
			start_col = sa.col
		} else if sa, ok := b.sel_anchor.?; ok && sa.row < b.cursor.row {
			// shouldn't normally happen for our search-driven selection, ignore
			_ = sa
		} else {
			line := b.lines[start_row][:]
			if start_col > 0 {
				start_col = prev_rune_start(line, start_col)
			}
		}

		// Sweep current line (limited) then up to the top.
		r := start_row
		for {
			line := string(b.lines[r][:])
			before := len(line)
			if r == start_row {
				before = start_col
				if before > len(line) { before = len(line) }
				if before < 0          { before = 0 }
			}
			idx := search_index_last_in(line, needle, before)
			if idx >= 0 {
				b.sel_anchor = Cursor{r, idx}
				b.cursor = Cursor{r, idx + len(needle)}
				b.want_col = b.cursor.col
				set_status("Found '%s' at line %d (%s, ←)", needle, r+1, mode_tag)
				return
			}
			if r == 0 { break }
			r -= 1
		}
		// Wrap-around: search from the bottom of the buffer down to where
		// we began (exclusive on the starting line — anything strictly
		// AFTER start_col on start_row is fair game on wrap).
		for r2 := len(b.lines) - 1; r2 >= start_row; r2 -= 1 {
			line := string(b.lines[r2][:])
			idx := search_index_last_in(line, needle, len(line))
			if r2 == start_row {
				if idx < start_col { idx = -1 }
			}
			if idx >= 0 {
				b.sel_anchor = Cursor{r2, idx}
				b.cursor = Cursor{r2, idx + len(needle)}
				b.want_col = b.cursor.col
				set_status("Wrapped: '%s' at line %d (%s, ←)", needle, r2+1, mode_tag)
				return
			}
			if r2 == 0 { break }
		}
	}
	set_status("Not found: %s (%s)", needle, mode_tag)
}

do_replace_all :: proc(needle, repl: string) -> int {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return 0 }
	b := g_app.active_pane.buffer
	count := 0
	for r in 0..<len(b.lines) {
		off := 0
		for {
			line := string(b.lines[r][:])
			idx := search_index_in(line, needle, off)
			if idx < 0 { break }
			s := Cursor{r, idx}
			e := Cursor{r, idx+len(needle)}
			buffer_delete_range(b, s, e)
			buffer_insert_text(b, s, transmute([]u8)repl)
			count += 1
			off = idx + len(repl)
		}
	}
	buffer_clamp_cursor(b)
	return count
}

cmd_goto_line :: proc() {
	d := dialog_open(.GoTo, "Go To Line", "Line number:", proc(d: ^Dialog){
		s := string(d.input[:])
		n, ok := strconv.parse_int(s)
		if !ok || n < 1 { return }
		if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
		b := g_app.active_pane.buffer
		if n > len(b.lines) { n = len(b.lines) }
		b.cursor = Cursor{n-1, 0}
		clear_selection(b)
	})
	_ = d
}

cmd_split_vertical :: proc() {
	if g_app.active_pane == nil { return }
	split_pane(g_app.active_pane, .Vertical)
}
cmd_split_horizontal :: proc() {
	if g_app.active_pane == nil { return }
	split_pane(g_app.active_pane, .Horizontal)
}
cmd_close_pane :: proc() {
	if g_app.active_pane == nil { return }
	// If this is the only pane, do nothing visible but say so.
	if find_node_parent(g_app.root, g_app.active_pane) == nil {
		set_status("Cannot close the last pane")
		return
	}
	close_pane(g_app.active_pane)
	// Force a full redraw so the freed area repaints cleanly.
	cmd_refresh_screen()
	set_status("Pane closed")
}

// Re-query the terminal size, reset the back buffer so the next frame
// repaints every cell, and clear the physical screen.  Useful after
// changing the terminal font size, after another program left the
// terminal in a strange state, or any time the display looks wrong.
cmd_refresh_screen :: proc() {
	new_w, new_h: int
	terminal_query_size(&new_w, &new_h)
	if new_w < 1 { new_w = 1 }
	if new_h < 1 { new_h = 1 }
	g_app.width  = new_w
	g_app.height = new_h
	screen_resize(&g_app.screen,      new_w, new_h)
	screen_resize(&g_app.prev_screen, new_w, new_h)
	// Force a full repaint by making prev_screen impossible to match.
	for i in 0..<len(g_app.prev_screen.cells) {
		g_app.prev_screen.cells[i] = Cell{r=0, fg=Color(255), bg=Color(255)}
	}
	// Clear the actual terminal so any stray characters disappear.
	write_str("\x1b[2J\x1b[H")
	set_status("Screen refreshed (%dx%d)", new_w, new_h)
}

// Re-scan every loaded directory of the file tree from disk so that files
// added, removed or renamed by other programs become visible immediately.
cmd_refresh_tree :: proc() {
	tree_refresh()
	set_status("File tree refreshed from disk")
}

cmd_toggle_tree :: proc() {
	if g_app.show_tree {
		if g_app.focus == .Tree {
			g_app.show_tree = false
			g_app.focus = .Editor
		} else {
			g_app.focus = .Tree
		}
	} else {
		g_app.show_tree = true
		g_app.focus = .Tree
	}
}
cmd_next_buffer :: proc() {
	if len(g_app.buffers) == 0 { return }
	if g_app.active_pane == nil { return }
	cur := g_app.active_pane.buffer
	idx := 0
	for b, i in g_app.buffers { if b == cur { idx = i; break } }
	idx = (idx+1) % len(g_app.buffers)
	open_in_active_pane(g_app.buffers[idx])
}

cmd_jump_buffer :: proc(n: int) {
	if n <= 0 || n > len(g_app.buffers) { return }
	open_in_active_pane(g_app.buffers[n-1])
}

cmd_show_help :: proc() { g_app.help_open = true }

cmd_toggle_wrap :: proc() {
	p := g_app.active_pane
	if p == nil { return }
	p.wrap = !p.wrap
	if p.wrap { p.scroll_x = 0 }
	set_status("Line wrap: %s", "ON" if p.wrap else "OFF")
}

cmd_about :: proc() {
	d := dialog_open(.Pick, "About JOHN — John simple editor in Odin", "", proc(d: ^Dialog){})
	items := [dynamic]string{}
	append(&items, strings.clone("JOHN — John simple editor in Odin"))
	append(&items, strings.clone(""))
	append(&items, strings.clone("A modal-free terminal text editor for programmers."))
	append(&items, strings.clone("Written entirely in the Odin programming language."))
	append(&items, strings.clone(""))
	append(&items, strings.clone("Languages:   C / C++ / Odin / Python / Shell / Make / Markdown"))
	append(&items, strings.clone("Highlighter: handwritten per-language lexers"))
	append(&items, strings.clone("Completion:  buffer + directory scan (Ctrl+Space)"))
	append(&items, strings.clone("Bindings:    Windows-style (Ctrl+S/C/V/Z/Y, F1 help)"))
	append(&items, strings.clone(""))
	append(&items, strings.clone("Press Esc or Enter to close."))
	d.items = items[:]
	d.sel = 0
}

cmd_open_recent :: proc() {
	if len(g_app.recent) == 0 { set_status("No recent files"); return }
	d := dialog_open(.Pick, "Open Recent", "", proc(d: ^Dialog){
		if d.sel < 0 || d.sel >= len(d.items) { return }
		path := strings.clone(d.items[d.sel])
		defer delete(path)
		do_open_path(path)
	})
	items := make([]string, len(g_app.recent))
	for r, i in g_app.recent { items[i] = strings.clone(r) }
	d.items = items
	d.sel = 0
}
