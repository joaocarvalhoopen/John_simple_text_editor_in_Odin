package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"

Dialog_Kind :: enum {
	Prompt,        // single line input
	Find,
	Replace,
	GoTo,
	Confirm,
	Pick,          // pick from list
	Completion,    // completion popup
}

Dialog :: struct {
	kind:   Dialog_Kind,
	title:  string,
	prompt: string,
	input:  [dynamic]u8,
	cursor: int,
	// for replace
	input2: [dynamic]u8,
	cursor2: int,
	field2: bool,
	// list
	items:  []string,
	sel:    int,
	scroll: int,
	on_ok:  proc(d: ^Dialog),
	on_cancel: proc(d: ^Dialog),
}

dialog_open :: proc(kind: Dialog_Kind, title, prompt: string, on_ok: proc(d: ^Dialog)) -> ^Dialog {
	d := new(Dialog)
	d.kind = kind
	d.title = strings.clone(title)
	d.prompt = strings.clone(prompt)
	d.on_ok = on_ok
	g_app.dialog = d
	return d
}

dialog_close :: proc() {
	d := g_app.dialog
	if d == nil { return }
	delete(d.title)
	delete(d.prompt)
	delete(d.input)
	delete(d.input2)
	if d.items != nil { delete(d.items) }
	free(d)
	g_app.dialog = nil
}

dialog_handle_key :: proc(e: Key_Event) {
	d := g_app.dialog
	if d == nil { return }
	// Alt+C toggles case sensitivity from inside Find/Replace dialogs and
	// refreshes the prompt label so the new state is visible.
	if (d.kind == .Find || d.kind == .Replace) && .Alt in e.mods && e.key == .Char {
		if e.ch == 'c' || e.ch == 'C' {
			cmd_toggle_search_case()
			delete(d.prompt)
			d.prompt = fmt.aprintf("Search for (case %s):",
				"SENSITIVE" if g_app.search_case_sensitive else "insensitive")
			return
		}
	}
	if d.kind == .Pick || d.kind == .Completion {
		#partial switch e.key {
		case .Escape: if d.on_cancel != nil { d.on_cancel(d) }; dialog_close(); return
		case .Enter:
			if d.on_ok != nil { d.on_ok(d) }
			dialog_close(); return
		case .Up:
			d.sel -= 1; if d.sel < 0 { d.sel = len(d.items)-1 }; return
		case .Down:
			d.sel += 1; if d.sel >= len(d.items) { d.sel = 0 }; return
		case .PageUp:    d.sel -= 10; if d.sel<0 { d.sel = 0 }; return
		case .PageDown:  d.sel += 10; if d.sel>=len(d.items) { d.sel = len(d.items)-1 }; return
		}
		// for Completion, allow continued typing to filter? (not implemented)
		if d.kind == .Completion {
			// any other key cancels
			if d.on_cancel != nil { d.on_cancel(d) }
			dialog_close()
			handle_event(e)  // re-dispatch
			return
		}
	}
	#partial switch e.key {
	case .Escape:
		if d.on_cancel != nil { d.on_cancel(d) }
		dialog_close()
		return
	case .Enter:
		if d.kind == .Replace && !d.field2 {
			d.field2 = true
			return
		}
		cb := d.on_ok
		if cb != nil { cb(d) }
		// Callback may have replaced or closed the dialog.
		if g_app.dialog == d { dialog_close() }
		return
	case .Tab:
		if d.kind == .Replace { d.field2 = !d.field2; return }
		if d.kind == .Prompt { dialog_path_complete(d) }
		return
	case .Backspace:
		buf := d.field2 ? &d.input2 : &d.input
		cur := d.field2 ? &d.cursor2 : &d.cursor
		if cur^ > 0 {
			start := prev_rune_start(buf[:], cur^)
			for _ in 0..<(cur^ - start) {
				ordered_remove(buf, start)
			}
			cur^ = start
		}
		return
	case .Delete:
		buf := d.field2 ? &d.input2 : &d.input
		cur := d.field2 ? &d.cursor2 : &d.cursor
		if cur^ < len(buf) {
			end := next_rune_start(buf[:], cur^)
			for _ in 0..<(end - cur^) {
				ordered_remove(buf, cur^)
			}
		}
		return
	case .Left:
		cur := d.field2 ? &d.cursor2 : &d.cursor
		buf := d.field2 ? &d.input2 : &d.input
		if cur^>0 { cur^ = prev_rune_start(buf[:], cur^) }
		return
	case .Right:
		cur := d.field2 ? &d.cursor2 : &d.cursor
		buf := d.field2 ? &d.input2 : &d.input
		if cur^<len(buf) { cur^ = next_rune_start(buf[:], cur^) }
		return
	case .Home:
		cur := d.field2 ? &d.cursor2 : &d.cursor
		cur^ = 0; return
	case .End:
		cur := d.field2 ? &d.cursor2 : &d.cursor
		buf := d.field2 ? &d.input2 : &d.input
		cur^ = len(buf); return
	case .Char:
		if .Ctrl in e.mods { return }
		if e.ch < 0x20 { return }
		buf := d.field2 ? &d.input2 : &d.input
		cur := d.field2 ? &d.cursor2 : &d.cursor
		// utf-8 encode
		bytes: [4]u8
		n := encode_rune_utf8(e.ch, bytes[:])
		for k in 0..<n {
			inject_at(buf, cur^, bytes[k])
			cur^ += 1
		}
		return
	}
}

// Tab-completion for the single-line path Prompt dialogs (Open / Save As /
// New File etc). Splits the current input into <dir>/<prefix>, lists `dir`,
// and extends the input by the longest common prefix of all entries that
// start with `prefix`. If exactly one match remains and it's a directory we
// also append a trailing '/'. Operates on whatever is currently in d.input
// up to d.cursor; characters after the cursor are preserved.
dialog_path_complete :: proc(d: ^Dialog) {
	full := string(d.input[:d.cursor])
	tail := string(d.input[d.cursor:])

	// Expand a leading '~' for convenience.
	if strings.has_prefix(full, "~/") || full == "~" {
		full = strings.concatenate({home_dir(), full[1:]})
	} else {
		full = strings.clone(full)
	}
	defer delete(full)

	dir, prefix: string
	if i := strings.last_index_byte(full, '/'); i >= 0 {
		dir = full[:i+1]
		prefix = full[i+1:]
	} else {
		dir = "./"
		prefix = full
	}

	scan_dir := dir
	if scan_dir == "" { scan_dir = "." } else if strings.has_suffix(scan_dir, "/") && len(scan_dir) > 1 {
		scan_dir = scan_dir[:len(scan_dir)-1]
	}
	infos, ok := list_directory(scan_dir)
	if !ok || len(infos) == 0 {
		defer if infos != nil { delete(infos) }
		return
	}
	defer {
		for fi in infos { os.file_info_delete(fi) }
		delete(infos)
	}

	matches: [dynamic]string
	dir_flags: [dynamic]bool
	defer delete(matches)
	defer delete(dir_flags)
	for fi in infos {
		name := filepath.base(fi.fullpath)
		if !strings.has_prefix(name, prefix) { continue }
		append(&matches, name)
		append(&dir_flags, fi.is_dir)
	}
	if len(matches) == 0 { return }

	// Longest common prefix of all matches.
	lcp := matches[0]
	for i in 1..<len(matches) {
		m := matches[i]
		n := min(len(lcp), len(m))
		k := 0
		for k < n && lcp[k] == m[k] { k += 1 }
		lcp = lcp[:k]
	}
	if len(lcp) <= len(prefix) {
		// No further common prefix to extend by; nothing to do (or beep).
		return
	}

	completed := lcp
	// If exactly one match and it's a directory, append '/'.
	suffix_slash := len(matches) == 1 && dir_flags[0] && !strings.has_suffix(completed, "/")

	// Rebuild the input: keep dir + completed + (optional '/') + tail.
	clear(&d.input)
	for c in dir { append(&d.input, u8(c)) }
	for c in completed { append(&d.input, u8(c)) }
	if suffix_slash { append(&d.input, '/') }
	new_cursor := len(d.input)
	for c in tail { append(&d.input, u8(c)) }
	d.cursor = new_cursor
}

encode_rune_utf8 :: proc(r: rune, b: []u8) -> int {
	r := r
	if r < 0x80 { b[0] = u8(r); return 1 }
	if r < 0x800 {
		b[0] = u8(0xC0 | (r>>6))
		b[1] = u8(0x80 | (r & 0x3F))
		return 2
	}
	if r < 0x10000 {
		b[0] = u8(0xE0 | (r>>12))
		b[1] = u8(0x80 | ((r>>6)&0x3F))
		b[2] = u8(0x80 | (r & 0x3F))
		return 3
	}
	b[0] = u8(0xF0 | (r>>18))
	b[1] = u8(0x80 | ((r>>12)&0x3F))
	b[2] = u8(0x80 | ((r>>6)&0x3F))
	b[3] = u8(0x80 | (r & 0x3F))
	return 4
}

draw_dialog :: proc(d: ^Dialog) {
	s := &g_app.screen
	W := s.w
	H := s.h
	if d.kind == .Pick || d.kind == .Completion {
		w := 60
		if w > W-4 { w = W-4 }
		h := 18
		if h > H-4 { h = H-4 }
		x := (W-w)/2
		y := (H-h)/2
		if d.kind == .Completion {
			// position on the line BELOW the actual buffer cursor
			cx, cy, _ := buffer_cursor_screen_pos()
			h = len(d.items)+2
			if h > 12 { h = 12 }
			w = 32
			x = cx
			y = cy + 1
			// Prefer placing below; if no space, place above.
			if y + h > H { y = cy - h }
			if y < 1 { y = 1 }
			// Keep within horizontal bounds (right side of screen).
			if x + w > W { x = W - w }
			if x < 0 { x = 0 }
		}
		draw_box(x, y, w, h, d.title)
		// items
		visible := h-2
		if d.sel < d.scroll { d.scroll = d.sel }
		if d.sel >= d.scroll+visible { d.scroll = d.sel-visible+1 }
		for i in 0..<visible {
			idx := d.scroll + i
			if idx >= len(d.items) { break }
			py := y+1+i
			bg := Color.BrightWhite; fg := Color.Black
			if idx == d.sel { bg = .Blue; fg = .BrightWhite }
			for xx in x+1..<x+w-1 { screen_put(s, xx, py, Cell{r=' ', fg=fg, bg=bg}) }
			it := d.items[idx]
			if len(it) > w-3 { it = it[:w-3] }
			screen_text(s, x+2, py, it, fg, bg)
		}
		return
	}
	w := W - 8
	if w > 80 { w = 80 }
	h := 5
	if d.kind == .Replace { h = 7 }
	x := (W-w)/2
	y := (H-h)/2
	draw_box(x, y, w, h, d.title)
	screen_text(s, x+2, y+1, d.prompt, .Black, .BrightWhite)
	// input field row at y+2
	for xx in x+2..<x+w-2 { screen_put(s, xx, y+2, Cell{r=' ', fg=.BrightWhite, bg=.Black}) }
	screen_text(s, x+2, y+2, string(d.input[:]), .BrightWhite, .Black)
	if d.kind == .Replace {
		screen_text(s, x+2, y+3, "Replace with:", .Black, .BrightWhite)
		for xx in x+2..<x+w-2 { screen_put(s, xx, y+4, Cell{r=' ', fg=.BrightWhite, bg=.Black}) }
		screen_text(s, x+2, y+4, string(d.input2[:]), .BrightWhite, .Black)
	}
}

dialog_cursor :: proc() -> (int, int, bool) {
	d := g_app.dialog
	W := g_app.screen.w; H := g_app.screen.h
	if d.kind == .Pick || d.kind == .Completion { return 0, 0, false }
	w := W - 8
	if w > 80 { w = 80 }
	h := 5
	if d.kind == .Replace { h = 7 }
	x := (W-w)/2
	y := (H-h)/2
	cy := y + 2
	cx_off := display_col_of_byte(d.input[:], d.cursor)
	if d.kind == .Replace && d.field2 {
		cy = y + 4
		cx_off = display_col_of_byte(d.input2[:], d.cursor2)
	}
	return x+2+cx_off, cy, true
}

draw_box :: proc(x, y, w, h: int, title: string) {
	s := &g_app.screen
	// fill
	for yy in y..<y+h {
		for xx in x..<x+w {
			screen_put(s, xx, yy, Cell{r=' ', fg=.Black, bg=.BrightWhite})
		}
	}
	for xx in x..<x+w {
		screen_put(s, xx, y, Cell{r='─', fg=.Black, bg=.BrightWhite})
		screen_put(s, xx, y+h-1, Cell{r='─', fg=.Black, bg=.BrightWhite})
	}
	for yy in y..<y+h {
		screen_put(s, x, yy, Cell{r='│', fg=.Black, bg=.BrightWhite})
		screen_put(s, x+w-1, yy, Cell{r='│', fg=.Black, bg=.BrightWhite})
	}
	screen_put(s, x, y, Cell{r='┌', fg=.Black, bg=.BrightWhite})
	screen_put(s, x+w-1, y, Cell{r='┐', fg=.Black, bg=.BrightWhite})
	screen_put(s, x, y+h-1, Cell{r='└', fg=.Black, bg=.BrightWhite})
	screen_put(s, x+w-1, y+h-1, Cell{r='┘', fg=.Black, bg=.BrightWhite})
	if len(title) > 0 {
		t := fmt.aprintf(" %s ", title)
		defer delete(t)
		screen_text(s, x+2, y, t, .Blue, .BrightWhite, {.Bold})
	}
}
