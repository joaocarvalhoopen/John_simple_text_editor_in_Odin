// John - Simple Editor in Odin
//
// Description : A simple text editor for Linux.
// License     : MIT Open Source License

package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Focus_Area :: enum { Editor, Tree }

App :: struct {
	cwd:               string,
	buffers:           [dynamic]^Buffer,
	root:              ^Node,
	active_pane:       ^Pane,
	file_tree:         FileTree,
	show_tree:         bool,
	tree_width:        int,
	focus:             Focus_Area,
	width, height:     int,
	clipboard:         [dynamic]u8,
	clip_is_lines:     bool,
	menu:              MenuState,
	dialog:            ^Dialog,
	status_msg:        string,
	status_msg_until:  time.Time,
	quit:              bool,
	help_open:         bool,
	help_scroll:       int,
	prev_screen:       Screen,
	screen:            Screen,
	tab_width:         int,
	recent:            [dynamic]string,
	recent_path:       string,
	completion_cache_at: time.Time,
	completion_cache_words: [dynamic]string,
	// Drag state for resizing splits / tree pane.
	drag_kind:    Drag_Kind,
	drag_split:   ^Split,
	// Persistent search state, shared across all buffers and panes.
	search_needle:        string,   // last needle used, "" if none
	search_case_sensitive: bool,    // false = case-insensitive (default)
}

Drag_Kind :: enum { None, Tree, Split }

g_app: App

main :: proc() {
	args := os.args
	start_path := "."
	// CLI flags: --list-commands prints every binding-target command name.
	for i in 1..<len(args) {
		a := args[i]
		switch a {
		case "--list-commands":
			keymap_init()
			keymap_list_commands()
			os.exit(0)
		case "--help", "-h":
			fmt.println("Usage: john [--list-commands] [path]")
			fmt.println("  Keybindings live in ~/.config/john/keys.conf")
			os.exit(0)
		}
		if len(a) > 0 && a[0] != '-' { start_path = a }
	}

	abs, ok := absolute_path(start_path)
	if !ok {
		fmt.eprintln("Cannot resolve path:", start_path)
		os.exit(1)
	}

	is_dir := path_is_dir(abs)
	if is_dir {
		g_app.cwd = abs
	} else {
		g_app.cwd = dir_name(abs)
	}

	g_app.tab_width = 4
	g_app.show_tree = true
	g_app.tree_width = 28
	g_app.focus = .Editor
	recent_load()
	keymap_init()
	keymap_load()

	if !terminal_init() {
		fmt.eprintln("Failed to initialize terminal (need a TTY).")
		os.exit(1)
	}
	defer terminal_shutdown()

	terminal_query_size(&g_app.width, &g_app.height)
	screen_init(&g_app.screen, g_app.width, g_app.height)
	screen_init(&g_app.prev_screen, g_app.width, g_app.height)

	file_tree_init(&g_app.file_tree, g_app.cwd)

	// Open initial buffer
	if !is_dir {
		buf := buffer_load_file(abs)
		append(&g_app.buffers, buf)
		open_in_active_pane(buf)
	} else {
		buf := buffer_new_scratch("*scratch*")
		append(&g_app.buffers, buf)
		open_in_active_pane(buf)
	}

	set_status("Welcome to JOHN — press F1 (or Ctrl+?) for help, F10 for menu, Ctrl+Q to quit")

	for !g_app.quit {
		render_frame()
		ev := input_read_event()
		handle_event(ev)
	}
}

set_status :: proc(msg: string, args: ..any) {
	delete(g_app.status_msg)
	g_app.status_msg = fmt.aprintf(msg, ..args)
	g_app.status_msg_until = time.time_add(time.now(), 5 * time.Second)
}

current_status :: proc() -> string {
	if time.time_to_unix(time.now()) > time.time_to_unix(g_app.status_msg_until) {
		return ""
	}
	return g_app.status_msg
}

open_in_active_pane :: proc(buf: ^Buffer) {
	if g_app.root == nil {
		p := new(Pane)
		p.buffer = buf
		n := new(Node)
		n^ = p
		g_app.root = n
		g_app.active_pane = p
		return
	}
	if g_app.active_pane != nil {
		g_app.active_pane.buffer = buf
		return
	}
	p := find_first_pane(g_app.root)
	if p != nil {
		p.buffer = buf
		g_app.active_pane = p
	}
}

handle_event :: proc(ev: Event) {
	switch e in ev {
	case Key_Event:
		// dialog has priority
		if g_app.dialog != nil {
			dialog_handle_key(e)
			return
		}
		if g_app.help_open {
			help_handle_key(e)
			return
		}
		if g_app.menu.open {
			menu_handle_key(e)
			return
		}
		// global keys
		if global_key(e) { return }
		// tree focus path
		if g_app.focus == .Tree && g_app.show_tree {
			tree_handle_key(e)
			return
		}
		// pass to active pane / buffer
		if g_app.active_pane != nil && g_app.active_pane.buffer != nil {
			editor_key(g_app.active_pane.buffer, e)
		}
	case Resize_Event:
		g_app.width = e.width
		g_app.height = e.height
		screen_resize(&g_app.screen, e.width, e.height)
		screen_resize(&g_app.prev_screen, e.width, e.height)
		// Force full repaint and wipe any leftover characters from
		// the old terminal geometry.
		for i in 0..<len(g_app.prev_screen.cells) {
			g_app.prev_screen.cells[i] = Cell{r=0, fg=Color(255), bg=Color(255)}
		}
		write_str("\x1b[2J\x1b[H")
	case Mouse_Event:
		handle_mouse(e)
	case Paste_Event:
		defer delete(e.text)
		if len(e.text) == 0 { return }
		// Dialogs only consume printable bytes (skip control bytes
		// other than tab; newlines truncate to first line for single-
		// line input fields).
		if g_app.dialog != nil {
			dialog_handle_paste(e.text)
			return
		}
		if g_app.help_open || g_app.menu.open { return }
		if g_app.focus == .Tree && g_app.show_tree { return }
		if g_app.active_pane != nil && g_app.active_pane.buffer != nil {
			insert_text_user(g_app.active_pane.buffer, e.text)
		}
	}
}

handle_mouse :: proc(e: Mouse_Event) {
	// Wheel scroll
	if e.button == 4 || e.button == 5 {
		if e.button == 4 { mouse_wheel(-3) } else { mouse_wheel(+3) }
		return
	}

	// End any active drag on button release.
	if !e.pressed && !e.drag {
		g_app.drag_kind = .None
		g_app.drag_split = nil
		return
	}

	// Continue an in-progress drag (drag events).
	if g_app.drag_kind != .None {
		switch g_app.drag_kind {
		case .None: // unreachable
		case .Tree:
			tw := e.x
			min_w := 10
			max_w := g_app.width - 20
			if tw < min_w { tw = min_w }
			if tw > max_w { tw = max_w }
			g_app.tree_width = tw
		case .Split:
			s := g_app.drag_split
			if s == nil { return }
			rx, ry, rw, rh := split_rect(s)
			if s.dir == .Vertical {
				rel := f32(e.x - rx) / f32(rw)
				if rel < 0.05 { rel = 0.05 }
				if rel > 0.95 { rel = 0.95 }
				s.ratio = rel
			} else {
				rel := f32(e.y - ry) / f32(rh)
				if rel < 0.05 { rel = 0.05 }
				if rel > 0.95 { rel = 0.95 }
				s.ratio = rel
			}
		}
		return
	}

	// Only act on left-button press from here on.
	if e.button != 0 || !e.pressed { return }

	// Help overlay: any click closes it
	if g_app.help_open { g_app.help_open = false; return }

	// Dialog: ignore for now (keep modal)
	if g_app.dialog != nil { return }

	// Menu open: clicks on dropdown items / menu bar
	if g_app.menu.open {
		if e.y == 0 {
			idx := menu_index_at(e.x)
			if idx >= 0 { g_app.menu.active = idx; g_app.menu.item = 0 }
			return
		}
		if menu_dropdown_click(e.x, e.y) { return }
		menu_close()
		return
	}

	// Menu bar row
	if e.y == 0 {
		idx := menu_index_at(e.x)
		if idx >= 0 { menu_open(idx) }
		return
	}

	// Tree-divider drag (vertical line right of the tree column)
	if g_app.show_tree {
		tw := g_app.tree_width
		if tw > g_app.width/2 { tw = g_app.width/2 }
		if e.x == tw && e.y >= 1 && e.y < g_app.height-1 {
			g_app.drag_kind = .Tree
			return
		}
	}

	// Pane-divider drag
	if s := find_split_at_divider(g_app.root, e.x, e.y); s != nil {
		g_app.drag_kind = .Split
		g_app.drag_split = s
		return
	}

	// File tree click
	if g_app.show_tree {
		tw := g_app.tree_width
		if tw > g_app.width/2 { tw = g_app.width/2 }
		if e.x < tw {
			tree_mouse_click(e.x, e.y)
			return
		}
	}

	// Pane area
	p := pane_at(g_app.root, e.x, e.y)
	if p == nil { return }
	g_app.active_pane = p
	g_app.focus = .Editor
	if p.buffer == nil { return }
	if e.y == p.y { return }   // title bar
	// translate to buffer cursor (account for soft wrap)
	row, col := pane_xy_to_buffer_cursor(p, e.x, e.y)
	if e.drag {
		ensure_anchor(p.buffer)
	} else {
		clear_selection(p.buffer)
	}
	p.buffer.cursor = Cursor{row, col}
	p.buffer.want_col = display_col_of_byte(p.buffer.lines[row][:], col)
}

pane_xy_to_buffer_cursor :: proc(p: ^Pane, mx, my: int) -> (int, int) {
	b := p.buffer
	view_y_off := my - p.y - 1
	if view_y_off < 0 { view_y_off = 0 }
	col_off := mx - p.x - 6
	if col_off < 0 { col_off = 0 }

	if !p.wrap {
		row := p.scroll_y + view_y_off
		if row >= len(b.lines) { row = len(b.lines)-1 }
		if row < 0 { row = 0 }
		target_dc := p.scroll_x + col_off
		col := byte_col_for_display(b.lines[row][:], target_dc)
		return row, col
	}

	// Wrapped: walk visual rows from the top of the buffer.
	text_w := p.w - 6
	if text_w < 1 { text_w = 1 }
	target_vrow := p.scroll_y + view_y_off
	acc := 0
	for line, r in b.lines {
		seg := line_visual_rows(line[:], text_w)
		if acc + seg > target_vrow {
			seg_idx := target_vrow - acc
			target_dc := seg_idx * text_w + col_off
			col := byte_col_for_display(line[:], target_dc)
			return r, col
		}
		acc += seg
	}
	r := len(b.lines) - 1
	if r < 0 { r = 0 }
	return r, len(b.lines[r])
}

mouse_wheel :: proc(delta: int) {
	if g_app.help_open {
		g_app.help_scroll += delta
		if g_app.help_scroll < 0 { g_app.help_scroll = 0 }
		return
	}
	if g_app.focus == .Tree && g_app.show_tree {
		tree_move(delta)
		return
	}
	p := g_app.active_pane
	if p == nil || p.buffer == nil { return }
	p.scroll_y += delta
	if p.scroll_y < 0 { p.scroll_y = 0 }
	max_scroll := total_visual_rows(p, p.buffer) - 1
	if p.scroll_y > max_scroll { p.scroll_y = max_scroll }
}

pane_at :: proc(n: ^Node, x, y: int) -> ^Pane {
	if n == nil { return nil }
	#partial switch v in n {
	case ^Pane:
		if x >= v.x && x < v.x+v.w && y >= v.y && y < v.y+v.h { return v }
	case ^Split:
		if p := pane_at(v.a, x, y); p != nil { return p }
		return pane_at(v.b, x, y)
	}
	return nil
}

global_key :: proc(e: Key_Event) -> bool {
	// All command keys are configured via ~/.config/john/keys.conf.
	return keymap_dispatch(e)
}