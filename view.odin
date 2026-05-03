package editor

import "core:fmt"
import "core:strings"

render_frame :: proc() {
	screen_clear(&g_app.screen)
	w := g_app.width
	h := g_app.height
	if w < 20 || h < 5 { return }

	// Top: menu bar (row 0)
	draw_menu_bar(&g_app.screen)
	// Bottom: status bar (row h-1)
	draw_status_bar(&g_app.screen)

	// Editor area: rows 1..h-2
	left := 0
	if g_app.show_tree {
		tw := g_app.tree_width
		if tw > w/2 { tw = w/2 }
		draw_file_tree(&g_app.screen, 0, 1, tw, h-2)
		// vertical separator
		for yy in 1..<h-1 {
			screen_put(&g_app.screen, tw, yy, Cell{r='│', fg=.BrightBlack, bg=.Default})
		}
		left = tw + 1
	}
	editor_w := w - left
	editor_h := h - 2
	layout(g_app.root, left, 1, editor_w, editor_h)
	draw_panes(g_app.root)
	draw_split_borders(g_app.root, &g_app.screen)

	// Help overlay
	if g_app.help_open {
		draw_help_overlay()
	}
	// Menu dropdown
	if g_app.menu.open {
		draw_menu_dropdown()
	}
	// Dialog
	if g_app.dialog != nil {
		draw_dialog(g_app.dialog)
	}

	// Cursor
	cur_x, cur_y, vis := compute_cursor_pos()
	screen_present(&g_app.prev_screen, &g_app.screen, cur_x, cur_y, vis)
}

// Returns the "visual row" the buffer cursor sits on inside its pane,
// accounting for soft wrap when p.wrap is true. Always 0-based, relative
// to the start of the buffer (not the viewport).
visual_row_of_cursor :: proc(p: ^Pane, b: ^Buffer) -> (vrow: int, vcol: int) {
	view_w := p.w - 6
	if view_w < 1 { view_w = 1 }
	if !p.wrap {
		dc := display_col_of_byte(b.lines[b.cursor.row][:], b.cursor.col)
		return b.cursor.row, dc
	}
	vr := 0
	for r in 0..<b.cursor.row {
		vr += line_visual_rows(b.lines[r][:], view_w)
	}
	seg, col_in_seg := visual_seg_of_byte(b.lines[b.cursor.row][:], b.cursor.col, view_w)
	vr += seg
	return vr, col_in_seg
}

// Total visual rows in the buffer in this pane.
total_visual_rows :: proc(p: ^Pane, b: ^Buffer) -> int {
	view_w := p.w - 6
	if view_w < 1 { view_w = 1 }
	if !p.wrap { return len(b.lines) }
	total := 0
	for line in b.lines {
		total += line_visual_rows(line[:], view_w)
	}
	return total
}

compute_cursor_pos :: proc() -> (int, int, bool) {
	if g_app.dialog != nil {
		return dialog_cursor()
	}
	if g_app.menu.open {
		return 0, 0, false
	}
	if g_app.help_open { return 0, 0, false }
	if g_app.focus == .Tree && g_app.show_tree { return 0, 0, false }
	return buffer_cursor_screen_pos()
}

buffer_cursor_screen_pos :: proc() -> (int, int, bool) {
	p := g_app.active_pane
	if p == nil || p.buffer == nil { return 0, 0, false }
	b := p.buffer
	scroll_into_view(p, b)
	vr, vc := visual_row_of_cursor(p, b)
	x := p.x + 6 + (vc - p.scroll_x)
	y := p.y + 1 + (vr - p.scroll_y)
	if x < p.x || x >= p.x+p.w || y <= p.y || y >= p.y+p.h { return 0, 0, false }
	return x, y, true
}

scroll_into_view :: proc(p: ^Pane, b: ^Buffer) {
	view_h := p.h - 1   // minus title
	view_w := p.w - 6
	if view_h < 1 { view_h = 1 }
	if view_w < 1 { view_w = 1 }
	// Only force the cursor into view when it actually moved; otherwise
	// the user is scrolling with the wheel and the viewport must be free
	// to leave the cursor off-screen.
	moved := p.last_cursor_buffer != b ||
		p.last_cursor.row != b.cursor.row ||
		p.last_cursor.col != b.cursor.col
	p.last_cursor        = b.cursor
	p.last_cursor_buffer = b
	if !moved { return }
	vr, vc := visual_row_of_cursor(p, b)
	if vr < p.scroll_y { p.scroll_y = vr }
	if vr >= p.scroll_y + view_h { p.scroll_y = vr - view_h + 1 }
	if p.wrap {
		p.scroll_x = 0
	} else {
		if vc < p.scroll_x { p.scroll_x = vc }
		if vc >= p.scroll_x + view_w { p.scroll_x = vc - view_w + 1 }
	}
}

draw_panes :: proc(n: ^Node) {
	if n == nil { return }
	#partial switch v in n {
	case ^Pane: draw_pane(v)
	case ^Split:
		draw_panes(v.a)
		draw_panes(v.b)
	}
}

draw_pane :: proc(p: ^Pane) {
	s := &g_app.screen
	// Title row
	bg_t: Color = .BrightBlack
	fg_t: Color = .White
	if p == g_app.active_pane {
		bg_t = .Blue
		fg_t = .BrightWhite
	}
	for xx in p.x..<p.x+p.w {
		screen_put(s, xx, p.y, Cell{r=' ', fg=fg_t, bg=bg_t})
	}
	if p.buffer != nil {
		title := pane_title(p)
		defer delete(title)
		screen_text(s, p.x+1, p.y, title, fg_t, bg_t, {.Bold} if p == g_app.active_pane else {})
	}

	if p.buffer == nil {
		screen_text(s, p.x+2, p.y+1, "(no buffer)", .BrightBlack, .Default)
		return
	}
	draw_buffer(p, p.buffer)
}

pane_title :: proc(p: ^Pane) -> string {
	b := p.buffer
	if b == nil { return strings.clone("(empty)") }
	d := ""
	if b.dirty { d = " ●" }
	idx := buffer_index(b)
	return fmt.aprintf(" [%d] %s%s ", idx, b.name, d)
}

buffer_index :: proc(b: ^Buffer) -> int {
	for x, i in g_app.buffers { if x == b { return i+1 } }
	return 0
}

draw_buffer :: proc(p: ^Pane, b: ^Buffer) {
	s := &g_app.screen
	// Make sure the cursor is in view BEFORE we sample p.scroll_y, otherwise
	// a long jump (F3 / Shift+F3 / goto-line) would render the previous page
	// for one frame.  Only the active pane forces auto-scroll — inactive
	// panes keep the user's wheel scroll position.
	if p == g_app.active_pane {
		scroll_into_view(p, b)
	}
	view_top_y := p.y + 1
	view_h := p.h - 1
	view_x := p.x
	view_w := p.w
	text_w := view_w - 6

	if p.wrap && text_w > 0 {
		draw_buffer_wrapped(p, b, s, view_x, view_top_y, view_h, text_w)
		return
	}

	last_visible_row := p.scroll_y + view_h - 1
	if last_visible_row >= len(b.lines) { last_visible_row = len(b.lines)-1 }
	tokens := highlight_buffer(b, last_visible_row)
	defer {
		for t in tokens { delete(t) }
		delete(tokens)
	}

	sel_s, sel_e, has_sel := selection_range(b)

	for yy in 0..<view_h {
		row := p.scroll_y + yy
		py := view_top_y + yy
		// line number gutter
		if row < len(b.lines) {
			ln := fmt.aprintf("%5d ", row+1)
			defer delete(ln)
			fg_ln: Color = .White
			bg_ln: Color = .Default
			st_ln: Style = {}
			if row == b.cursor.row && p == g_app.active_pane {
				fg_ln = .BrightWhite
				bg_ln = .Blue
				st_ln = {.Bold}
			}
			screen_text(s, view_x, py, ln, fg_ln, bg_ln, st_ln)
		} else {
			screen_text(s, view_x, py, "     ", .BrightBlack, .Default)
		}

		text_x := view_x + 6

		if row >= len(b.lines) {
			screen_text(s, text_x, py, "~", .BrightBlack, .Default)
			continue
		}
		line := b.lines[row][:]
		toks := tokens[row]

		// Walk codepoints, painting from display column p.scroll_x.
		dcol := 0
		bi := 0
		for bi < len(line) && dcol < p.scroll_x + text_w {
			r, n := decode_utf8_at(line, bi)
			if n <= 0 { bi += 1; continue }
			rw := rune_advance_at(r, dcol)
			// Draw character: a tab paints `rw` spaces; everything else
			// paints itself in a single cell.
			tk := Token_Kind.Text
			if bi < len(toks) { tk = toks[bi] }
			fg := token_color(tk)
			bg_base := Color.Default
			st_base: Style = token_style(tk)
			sel_here := has_sel && in_selection(row, bi, sel_s, sel_e)
			if sel_here {
				// High-contrast selection: yellow background, black bold
				// foreground. Distinct from every syntax color so it
				// always stands out without any "rose"/magenta tint.
				bg_base = .Yellow
				fg = .Black
				st_base = {.Bold}
			}
			for k in 0..<rw {
				ccol := dcol + k
				if ccol < p.scroll_x { continue }
				cx := ccol - p.scroll_x
				if cx < 0 || cx >= text_w { continue }
				ch: rune = r
				if r == '\t' { ch = ' ' }
				screen_put(s, text_x+cx, py, Cell{r=ch, fg=fg, bg=bg_base, st=st_base})
			}
			dcol += rw
			bi += n
		}

		// Pad rest of line with selection background if applicable, else
		// blanks.
		for cx in 0..<text_w {
			col_dc := p.scroll_x + cx
			if col_dc < dcol { continue }
			ch: rune = ' '
			bg := Color.Default
			// Selection across the newline (at or beyond end-of-line).
			if has_sel && in_selection(row, len(line), sel_s, sel_e) {
				if col_dc == dcol { bg = .Yellow }
			}
			screen_put(s, text_x+cx, py, Cell{r=ch, fg=.Default, bg=bg})
		}
	}
}

// Render the buffer with soft line wrapping. Each visual row corresponds to
// a window of `text_w` columns into a logical line. Line numbers are shown
// only on the first visual row of each logical line.
draw_buffer_wrapped :: proc(p: ^Pane, b: ^Buffer, s: ^Screen, view_x, view_top_y, view_h, text_w: int) {
	// Find the logical row that contains visual row p.scroll_y, and how
	// many wrapped visual rows precede it within that logical row.
	target := p.scroll_y
	skip_rows := 0
	first_row := len(b.lines)
	{
		acc := 0
		for r, idx in b.lines {
			seg := line_visual_rows(r[:], text_w)
			if acc + seg > target {
				first_row = idx
				skip_rows = target - acc
				break
			}
			acc += seg
		}
	}

	last_logical := first_row + view_h
	if last_logical >= len(b.lines) { last_logical = len(b.lines)-1 }
	tokens := highlight_buffer(b, last_logical)
	defer {
		for t in tokens { delete(t) }
		delete(tokens)
	}

	sel_s, sel_e, has_sel := selection_range(b)

	yy := 0
	row := first_row
	seg_in_row := skip_rows
	for yy < view_h {
		py := view_top_y + yy
		if row >= len(b.lines) {
			screen_text(s, view_x, py, "     ", .BrightBlack, .Default)
			screen_text(s, view_x+6, py, "~", .BrightBlack, .Default)
			yy += 1
			continue
		}
		line := b.lines[row][:]
		seg_count := line_visual_rows(line, text_w)
		dcol_start := seg_in_row * text_w
		dcol_end   := dcol_start + text_w

		// gutter
		if seg_in_row == 0 {
			ln := fmt.aprintf("%5d ", row+1)
			defer delete(ln)
			fg_ln: Color = .White
			bg_ln: Color = .Default
			st_ln: Style = {}
			if row == b.cursor.row && p == g_app.active_pane {
				fg_ln = .BrightWhite
				bg_ln = .Blue
				st_ln = {.Bold}
			}
			screen_text(s, view_x, py, ln, fg_ln, bg_ln, st_ln)
		} else {
			screen_text(s, view_x, view_top_y+yy, "    ↳ ", .BrightBlack, .Default)
		}

		text_x := view_x + 6
		toks := tokens[row]

		// Walk runes, paint those whose display position falls in
		// [dcol_start, dcol_end).
		dcol := 0
		bi := 0
		for bi < len(line) && dcol < dcol_end {
			r, n := decode_utf8_at(line, bi)
			if n <= 0 { bi += 1; continue }
			rw := rune_advance_at(r, dcol)
			tk := Token_Kind.Text
			if bi < len(toks) { tk = toks[bi] }
			fg := token_color(tk)
			bg_base := Color.Default
			st_base: Style = token_style(tk)
			if has_sel && in_selection(row, bi, sel_s, sel_e) {
				bg_base = .Yellow
				fg = .Black
				st_base = {.Bold}
			}
			for k in 0..<rw {
				ccol := dcol + k
				if ccol < dcol_start || ccol >= dcol_end { continue }
				cx := ccol - dcol_start
				if cx < 0 || cx >= text_w { continue }
				ch: rune = r
				if r == '\t' { ch = ' ' }
				screen_put(s, text_x+cx, py, Cell{r=ch, fg=fg, bg=bg_base, st=st_base})
			}
			dcol += rw
			bi += n
		}
		// blank the rest of this segment
		for cx in 0..<text_w {
			col_dc := dcol_start + cx
			if col_dc < dcol { continue }
			screen_put(s, text_x+cx, py, Cell{r=' ', fg=.Default, bg=.Default})
		}

		yy += 1
		seg_in_row += 1
		if seg_in_row >= seg_count {
			row += 1
			seg_in_row = 0
		}
	}
}

in_selection :: proc(row, col: int, s, e: Cursor) -> bool {
	if row < s.row || row > e.row { return false }
	if row == s.row && col < s.col { return false }
	if row == e.row && col >= e.col { return false }
	return true
}

draw_file_tree :: proc(s: ^Screen, x, y, w, h: int) {
	t := &g_app.file_tree
	focused := g_app.focus == .Tree
	// Header
	hdr_bg := Color.BrightBlack
	hdr_fg := Color.White
	if focused { hdr_bg = .Blue; hdr_fg = .BrightWhite }
	for xx in x..<x+w { screen_put(s, xx, y, Cell{r=' ', fg=hdr_fg, bg=hdr_bg}) }
	header := " FILES " if !focused else " FILES ◄ "
	screen_text(s, x+1, y, header, hdr_fg, hdr_bg, {.Bold})

	// adjust scroll
	if t.selected < t.scroll { t.scroll = t.selected }
	if t.selected >= t.scroll + (h-1) { t.scroll = t.selected - (h-1) + 1 }
	if t.scroll < 0 { t.scroll = 0 }

	for i in 0..<h-1 {
		idx := t.scroll + i
		if idx >= len(t.flat) { break }
		n := t.flat[idx]
		py := y + 1 + i
		bg := Color.Default
		if idx == t.selected {
			bg = .Blue if focused else .BrightBlack
		}
		// fill row
		for xx in x..<x+w { screen_put(s, xx, py, Cell{r=' ', fg=.Default, bg=bg}) }
		marker: rune = ' '
		if n.is_dir { marker = '▾' if n.expanded else '▸' }
		fg := Color.Default
		if n.is_dir { fg = .BrightYellow }
		if idx == t.selected && focused { fg = .BrightWhite }
		// indent
		text := fmt.aprintf("%*s%c %s", n.depth*2, "", marker, n.name)
		defer delete(text)
		screen_text(s, x+1, py, text, fg, bg, {.Bold} if n.is_dir else {})
	}
}

draw_menu_bar :: proc(s: ^Screen) {
	w := s.w
	for xx in 0..<w { screen_put(s, xx, 0, Cell{r=' ', fg=.Black, bg=.Cyan}) }
	x := 1
	for m, i in MENUS {
		label := fmt.aprintf(" %s ", m.name)
		defer delete(label)
		st := Style{}
		bg := Color.Cyan; fg := Color.Black
		if g_app.menu.open && g_app.menu.active == i {
			bg = .BrightWhite; fg = .Black; st = {.Bold}
		}
		for j in 0..<len(label) { screen_put(s, x+j, 0, Cell{r=rune(label[j]), fg=fg, bg=bg, st=st}) }
		x += len(label)
	}
	hint := " F1=Help  F10=Menu  Ctrl+Q=Quit "
	if x + len(hint) < w {
		screen_text(s, w-len(hint)-1, 0, hint, .Black, .Cyan)
	}
}

draw_status_bar :: proc(s: ^Screen) {
	w := s.w
	y := s.h-1
	for xx in 0..<w { screen_put(s, xx, y, Cell{r=' ', fg=.Black, bg=.White}) }
	left := ""
	if g_app.active_pane != nil && g_app.active_pane.buffer != nil {
		b := g_app.active_pane.buffer
		dc := display_col_of_byte(b.lines[b.cursor.row][:], b.cursor.col)
		left = fmt.aprintf(" %s%s  Ln %d, Col %d  %s ",
			b.name, " *" if b.dirty else "",
			b.cursor.row+1, dc+1, lang_name(b.lang))
	} else {
		left = fmt.aprintf(" no buffer ")
	}
	screen_text(s, 0, y, left, .Black, .White, {.Bold})
	delete(left)
	msg := current_status()
	if len(msg) > 0 {
		mx := w/2 - len(msg)/2
		if mx < 0 { mx = 0 }
		screen_text(s, mx, y, msg, .Black, .White)
	}
	right := fmt.aprintf(" %dx%d ", g_app.width, g_app.height)
	defer delete(right)
	screen_text(s, w-len(right), y, right, .Black, .White)
}

lang_name :: proc(l: Language) -> string {
	switch l {
	case .C: return "C"
	case .Cpp: return "C++"
	case .Odin: return "Odin"
	case .Python: return "Python"
	case .Markdown: return "Markdown"
	case .Shell: return "Shell"
	case .JSON: return "JSON"
	case .HTML: return "HTML"
	case .Make: return "Makefile"
	case .Text, .None: return "Text"
	}
	return "Text"
}
