package editor

import "core:fmt"
import "core:strings"

Menu_Item :: struct {
	label:    string,
	shortcut: string,
	cmd:      proc(),
}

Menu :: struct {
	name:  string,
	items: []Menu_Item,
}

MenuState :: struct {
	open:           bool,
	active:         int,  // top-level menu index
	item:           int,  // selected item
}

MENUS := []Menu{
	{
		name = "File",
		items = []Menu_Item{
			{"New",         "Ctrl+N", cmd_new_buffer},
			{"Open File…",  "Ctrl+O", cmd_open_prompt},
			{"Open Recent…","Alt+R", cmd_open_recent},
			{"Refresh File Tree","Ctrl+R", cmd_refresh_tree},
			{"Save",        "Ctrl+S", cmd_save},
			{"Save As…",    "",       cmd_save_as},
			{"Close Buffer","Ctrl+W", cmd_close_buffer},
			{"Pick Buffer…","Ctrl+P", cmd_pick_buffer},
			{"Quit",        "Ctrl+Q", cmd_quit},
		},
	},
	{
		name = "Edit",
		items = []Menu_Item{
			{"Undo",        "Ctrl+Z", cmd_undo},
			{"Redo",        "Ctrl+Y", cmd_redo},
			{"Cut",         "Ctrl+X", cmd_cut},
			{"Copy",        "Ctrl+C", cmd_copy},
			{"Paste",       "Ctrl+V", cmd_paste},
			{"Select All",  "Ctrl+A", cmd_select_all},
			{"Find…",       "Ctrl+F", cmd_find},
			{"Find Next",   "F3",     cmd_find_next},
			{"Find Previous","Shift+F3", cmd_find_prev},
			{"Toggle Case Sensitivity","Alt+C", cmd_toggle_search_case},
			{"Replace…",    "Ctrl+H", cmd_replace},
			{"Go To Line…", "Ctrl+G", cmd_goto_line},
		},
	},
	{
		name = "View",
		items = []Menu_Item{
			{"Toggle Line Wrap",  "Alt+Z",  cmd_toggle_wrap},
			{"Toggle File Tree", "Ctrl+B", cmd_toggle_tree},
			{"Switch Tree/Editor","F6",     cmd_focus_toggle_tree_editor},
			{"Refresh Screen",   "F5",     cmd_refresh_screen},
			{"Next Buffer",      "Ctrl+Tab", cmd_next_buffer},
		},
	},
	{
		name = "Window",
		items = []Menu_Item{
			{"Split Vertical",   "Alt+\\", cmd_split_vertical},
			{"Split Horizontal", "Alt+-",  cmd_split_horizontal},
			{"Close Pane",       "Alt+W / F4",  cmd_close_pane},
			{"Focus Left",       "Alt+H",  proc(){ cmd_focus_dir(.Left) }},
			{"Focus Right",      "Alt+L",  proc(){ cmd_focus_dir(.Right) }},
			{"Focus Up",         "Alt+K",  proc(){ cmd_focus_dir(.Up) }},
			{"Focus Down",       "Alt+J",  proc(){ cmd_focus_dir(.Down) }},
		},
	},
	{
		name = "Help",
		items = []Menu_Item{
			{"Key Bindings",  "F1",  cmd_show_help},
			{"About",         "",    cmd_about},
		},
	},
}

menu_open :: proc(idx: int) {
	g_app.menu.open = true
	g_app.menu.active = idx
	g_app.menu.item = 0
}

menu_close :: proc() {
	g_app.menu.open = false
}

menu_handle_key :: proc(e: Key_Event) {
	m := &g_app.menu
	#partial switch e.key {
	case .Escape, .F10:
		menu_close()
		return
	case .Left:
		m.active -= 1
		if m.active < 0 { m.active = len(MENUS)-1 }
		m.item = 0
		return
	case .Right:
		m.active += 1
		if m.active >= len(MENUS) { m.active = 0 }
		m.item = 0
		return
	case .Up:
		m.item -= 1
		if m.item < 0 { m.item = len(MENUS[m.active].items)-1 }
		return
	case .Down:
		m.item += 1
		if m.item >= len(MENUS[m.active].items) { m.item = 0 }
		return
	case .Enter:
		item := MENUS[m.active].items[m.item]
		menu_close()
		if item.cmd != nil { item.cmd() }
		return
	case .Char:
		// mnemonic on first char
		if e.ch == ' ' && .Ctrl in e.mods { return }
	}
}

menu_x_for :: proc(idx: int) -> int {
	x := 1
	for m, i in MENUS {
		if i == idx { return x }
		x += len(m.name) + 2
	}
	return x
}

menu_index_at :: proc(x: int) -> int {
	cx := 1
	for m, i in MENUS {
		w := len(m.name) + 2
		if x >= cx && x < cx+w { return i }
		cx += w
	}
	return -1
}

menu_dropdown_click :: proc(x, y: int) -> bool {
	idx := g_app.menu.active
	m := MENUS[idx]
	mx := menu_x_for(idx)
	my := 1
	w := 0
	for it in m.items {
		l := len(it.label) + len(it.shortcut) + 4
		if l > w { w = l }
	}
	if w < 16 { w = 16 }
	h := len(m.items) + 2
	if mx + w > g_app.screen.w { mx = g_app.screen.w - w }
	if x < mx || x >= mx+w || y < my || y >= my+h { return false }
	row := y - my - 1
	if row < 0 || row >= len(m.items) { return true }
	g_app.menu.item = row
	item := m.items[row]
	menu_close()
	if item.cmd != nil { item.cmd() }
	return true
}

draw_menu_dropdown :: proc() {
	s := &g_app.screen
	idx := g_app.menu.active
	m := MENUS[idx]
	x := menu_x_for(idx)
	y := 1
	// compute width
	w := 0
	for it in m.items {
		l := len(it.label) + len(it.shortcut) + 4
		if l > w { w = l }
	}
	if w < 16 { w = 16 }
	h := len(m.items) + 2
	if x + w > s.w { x = s.w - w }
	// background box
	for yy in y..<y+h {
		for xx in x..<x+w {
			screen_put(s, xx, yy, Cell{r=' ', fg=.Black, bg=.BrightWhite})
		}
	}
	// border
	for xx in x..<x+w {
		screen_put(s, xx, y, Cell{r='─', fg=.BrightBlack, bg=.BrightWhite})
		screen_put(s, xx, y+h-1, Cell{r='─', fg=.BrightBlack, bg=.BrightWhite})
	}
	for yy in y..<y+h {
		screen_put(s, x, yy, Cell{r='│', fg=.BrightBlack, bg=.BrightWhite})
		screen_put(s, x+w-1, yy, Cell{r='│', fg=.BrightBlack, bg=.BrightWhite})
	}
	screen_put(s, x, y, Cell{r='┌', fg=.BrightBlack, bg=.BrightWhite})
	screen_put(s, x+w-1, y, Cell{r='┐', fg=.BrightBlack, bg=.BrightWhite})
	screen_put(s, x, y+h-1, Cell{r='└', fg=.BrightBlack, bg=.BrightWhite})
	screen_put(s, x+w-1, y+h-1, Cell{r='┘', fg=.BrightBlack, bg=.BrightWhite})
	// items
	for it, i in m.items {
		py := y + 1 + i
		bg := Color.BrightWhite; fg := Color.Black
		if i == g_app.menu.item { bg = .Blue; fg = .BrightWhite }
		for xx in x+1..<x+w-1 { screen_put(s, xx, py, Cell{r=' ', fg=fg, bg=bg}) }
		screen_text(s, x+2, py, it.label, fg, bg)
		if len(it.shortcut) > 0 {
			screen_text(s, x+w-2-len(it.shortcut), py, it.shortcut, fg, bg)
		}
	}
}