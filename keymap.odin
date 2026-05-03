#+feature dynamic-literals
package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:path/filepath"

// ---------------------------------------------------------------------------
// Configurable keybindings.
//
// Bindings live in a plain text file at ~/.config/john/keys.conf, beside the
// "recent" file. The file is read on every startup. If it is missing it is
// recreated with the standard JOHN keymap, so the user can edit a known good
// baseline.  Parse errors are reported with the absolute file path, the line
// and column of the offending token, and what JOHN could not recognise; the
// editor then refuses to start so you can fix the configuration.
//
// Format
//   # comments and blank lines are ignored
//   <key-combo> = <command-name>
//
// Modifiers (in any order, joined with "+"):  ctrl  alt  shift
// Keys:
//   Single printable character        e.g.  a, A, /, \, -, ?
//   F1 .. F12
//   Tab Enter Escape Backspace Delete Insert
//   Home End PageUp PageDown Up Down Left Right Space
//
// Examples
//   ctrl+s = save
//   shift+F3 = find_prev
//   alt+\\ = split_vertical
//
// To enumerate every command name JOHN understands, run with --list-commands.
// ---------------------------------------------------------------------------

Action :: proc()

Key_Spec :: struct {
	key:  Key,
	ch:   rune,
	mods: Mods,
}

g_commands: map[string]Action
g_bindings: map[Key_Spec]string

keymap_path :: proc() -> string {
	return filepath.join({recent_dir(), "keys.conf"})
}

keymap_init :: proc() {
	g_commands = make(map[string]Action)
	g_bindings = make(map[Key_Spec]string)
	register_commands()
}

register :: proc(name: string, p: Action) {
	g_commands[strings.clone(name)] = p
}

// ---- Wrappers around per-buffer commands so they can be bound ----------

cmd_complete :: proc() {
	if g_app.active_pane != nil && g_app.active_pane.buffer != nil {
		trigger_completion(g_app.active_pane.buffer)
	}
}
cmd_duplicate_line :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	b := g_app.active_pane.buffer
	row := b.lines[b.cursor.row][:]
	text: [dynamic]u8
	append(&text, '\n')
	append(&text, ..row)
	old_col := b.cursor.col
	buffer_insert_text(b, Cursor{b.cursor.row, len(row)}, text[:])
	delete(text)
	b.cursor = Cursor{b.cursor.row+1, old_col}
	set_status("Duplicated line")
}
cmd_delete_line :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	b := g_app.active_pane.buffer
	row := b.cursor.row
	s := Cursor{row, 0}
	e2: Cursor
	if row < len(b.lines)-1 { e2 = Cursor{row+1, 0} }
	else                    { e2 = Cursor{row, len(b.lines[row])} }
	buffer_delete_range(b, s, e2)
}
cmd_select_line :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	b := g_app.active_pane.buffer
	row := b.cursor.row
	b.sel_anchor = Cursor{row, 0}
	b.cursor = Cursor{row, len(b.lines[row])}
	b.want_col = b.cursor.col
}
cmd_delete_word_forward :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	b := g_app.active_pane.buffer
	move_word(b, +1, true)
	delete_selection_if_any(b)
}
cmd_move_eol :: proc() {
	if g_app.active_pane == nil || g_app.active_pane.buffer == nil { return }
	move_end(g_app.active_pane.buffer, false)
}
cmd_open_menu      :: proc() { menu_open(0) }
cmd_focus_left     :: proc() { cmd_focus_dir(.Left)  }
cmd_focus_right    :: proc() { cmd_focus_dir(.Right) }
cmd_focus_up       :: proc() { cmd_focus_dir(.Up)    }
cmd_focus_down     :: proc() { cmd_focus_dir(.Down)  }
cmd_jump_buffer_1  :: proc() { cmd_jump_buffer(1) }
cmd_jump_buffer_2  :: proc() { cmd_jump_buffer(2) }
cmd_jump_buffer_3  :: proc() { cmd_jump_buffer(3) }
cmd_jump_buffer_4  :: proc() { cmd_jump_buffer(4) }
cmd_jump_buffer_5  :: proc() { cmd_jump_buffer(5) }
cmd_jump_buffer_6  :: proc() { cmd_jump_buffer(6) }
cmd_jump_buffer_7  :: proc() { cmd_jump_buffer(7) }
cmd_jump_buffer_8  :: proc() { cmd_jump_buffer(8) }
cmd_jump_buffer_9  :: proc() { cmd_jump_buffer(9) }

register_commands :: proc() {
	register("quit",                cmd_quit)
	register("open_file",           cmd_open_prompt)
	register("new_buffer",          cmd_new_buffer)
	register("save",                cmd_save)
	register("save_as",             cmd_save_as)
	register("close_buffer",        cmd_close_buffer)
	register("find",                cmd_find)
	register("find_next",           cmd_find_next)
	register("find_prev",           cmd_find_prev)
	register("replace",             cmd_replace)
	register("toggle_search_case",  cmd_toggle_search_case)
	register("goto_line",           cmd_goto_line)
	register("pick_buffer",         cmd_pick_buffer)
	register("open_recent",         cmd_open_recent)
	register("help",                cmd_show_help)
	register("about",               cmd_about)
	register("menu",                cmd_open_menu)
	register("toggle_tree",         cmd_toggle_tree)
	register("focus_toggle_tree_editor", cmd_focus_toggle_tree_editor)
	register("split_vertical",      cmd_split_vertical)
	register("split_horizontal",    cmd_split_horizontal)
	register("close_pane",          cmd_close_pane)
	register("toggle_wrap",         cmd_toggle_wrap)
	register("focus_left",          cmd_focus_left)
	register("focus_right",         cmd_focus_right)
	register("focus_up",            cmd_focus_up)
	register("focus_down",          cmd_focus_down)
	register("next_buffer",         cmd_next_buffer)
	register("refresh_screen",      cmd_refresh_screen)
	register("refresh_tree",        cmd_refresh_tree)
	register("undo",                cmd_undo)
	register("redo",                cmd_redo)
	register("copy",                cmd_copy)
	register("cut",                 cmd_cut)
	register("paste",               cmd_paste)
	register("select_all",          cmd_select_all)
	register("duplicate_line",      cmd_duplicate_line)
	register("delete_line",         cmd_delete_line)
	register("select_line",         cmd_select_line)
	register("complete",            cmd_complete)
	register("delete_word_forward", cmd_delete_word_forward)
	register("move_eol",            cmd_move_eol)
	register("jump_buffer_1",       cmd_jump_buffer_1)
	register("jump_buffer_2",       cmd_jump_buffer_2)
	register("jump_buffer_3",       cmd_jump_buffer_3)
	register("jump_buffer_4",       cmd_jump_buffer_4)
	register("jump_buffer_5",       cmd_jump_buffer_5)
	register("jump_buffer_6",       cmd_jump_buffer_6)
	register("jump_buffer_7",       cmd_jump_buffer_7)
	register("jump_buffer_8",       cmd_jump_buffer_8)
	register("jump_buffer_9",       cmd_jump_buffer_9)
}

DEFAULT_KEYMAP :: `# JOHN — John simple editor in Odin — keybindings
#
# Format:  <key-combo> = <command-name>
# Modifiers (any order, joined with '+'):  ctrl  alt  shift
# Keys:    F1..F12, Tab, Enter, Escape, Backspace, Delete, Insert,
#          Home, End, PageUp, PageDown, Up, Down, Left, Right, Space,
#          or any single printable character.
#
# Lines beginning with '#' and empty lines are ignored.
# Re-bind freely; restart JOHN to reload.  To list every command name,
# run:  john --list-commands

# --- Files / buffers ---
ctrl+o = open_file
ctrl+n = new_buffer
ctrl+s = save
ctrl+w = close_buffer
ctrl+p = pick_buffer
ctrl+r = refresh_tree
alt+r = open_recent
ctrl+tab = next_buffer
ctrl+q = quit

# --- Editing ---
ctrl+z = undo
ctrl+y = redo
ctrl+c = copy
ctrl+x = cut
ctrl+v = paste
ctrl+a = select_all
ctrl+d = duplicate_line
ctrl+k = delete_line
ctrl+l = select_line
ctrl+e = move_eol
alt+d = delete_word_forward

# --- Search & replace ---
ctrl+f = find
F3 = find_next
shift+F3 = find_prev
alt+c = toggle_search_case
ctrl+h = replace
ctrl+g = goto_line

# --- Code completion ---
ctrl+space = complete

# --- Window / layout ---
F1 = help
ctrl+? = help
F10 = menu
F6 = focus_toggle_tree_editor
ctrl+b = toggle_tree
alt+\ = split_vertical
alt+- = split_horizontal
F4 = close_pane
alt+w = close_pane
F5 = refresh_screen
alt+z = toggle_wrap
alt+h = focus_left
alt+l = focus_right
alt+k = focus_up
alt+j = focus_down

# --- Quick buffer jump ---
alt+1 = jump_buffer_1
alt+2 = jump_buffer_2
alt+3 = jump_buffer_3
alt+4 = jump_buffer_4
alt+5 = jump_buffer_5
alt+6 = jump_buffer_6
alt+7 = jump_buffer_7
alt+8 = jump_buffer_8
alt+9 = jump_buffer_9
`

ensure_keymap_file :: proc() -> string {
	dir := recent_dir()
	ensure_dir(dir)
	path := keymap_path()
	if !os.exists(path) {
		os.write_entire_file(path, transmute([]u8)string(DEFAULT_KEYMAP))
	}
	return path
}

// Write `msg` to stderr with the file path/line/column context, then exit.
keymap_fail :: proc(path: string, line, col: int, msg: string) -> ! {
	fmt.eprintf("john: %s:%d:%d: %s\n", path, line, col, msg)
	os.exit(2)
}

// Load and parse the keymap. Aborts on syntax error.
keymap_load :: proc() {
	path := ensure_keymap_file()
	data, ok := os.read_entire_file(path)
	if !ok {
		fmt.eprintf("john: cannot read keymap file %s\n", path)
		os.exit(2)
	}
	defer delete(data)

	clear(&g_bindings)
	src := string(data)
	line_no := 0
	for raw_line in strings.split_lines_iterator(&src) {
		line_no += 1
		// strip trailing CR if present
		line := raw_line
		// Find first non-space col (1-based) for diagnostics.
		first_col := 1
		for i in 0..<len(line) {
			if line[i] != ' ' && line[i] != '\t' {
				first_col = i + 1
				break
			}
		}
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' { continue }

		// Locate '='.
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			keymap_fail(path, line_no, first_col,
				fmt.tprintf("missing '=' in binding (expected '<key> = <command>')"))
		}
		left  := strings.trim_space(line[:eq])
		right := strings.trim_space(line[eq+1:])
		if len(left) == 0 {
			keymap_fail(path, line_no, first_col, "empty key on left side of '='")
		}
		if len(right) == 0 {
			keymap_fail(path, line_no, eq+2, "empty command name on right side of '='")
		}

		spec, kerr := parse_key_spec(left)
		if kerr != "" {
			// Compute column of the offending token within the original line.
			kcol := strings.index(line, left) + 1
			if kcol < 1 { kcol = first_col }
			keymap_fail(path, line_no, kcol, kerr)
		}

		if _, ok2 := g_commands[right]; !ok2 {
			ccol := strings.index(line[eq+1:], right)
			full_col := eq + 2 + (ccol if ccol >= 0 else 0)
			keymap_fail(path, line_no, full_col,
				fmt.tprintf("unknown command '%s' (run with --list-commands)", right))
		}

		g_bindings[spec] = strings.clone(right)
	}
}

// ---- Key parsing ---------------------------------------------------------

parse_key_spec :: proc(s: string) -> (Key_Spec, string) {
	mods: Mods = {}
	body := s
	for {
		plus := strings.index_byte(body, '+')
		if plus < 0 { break }
		tok := strings.to_lower(strings.trim_space(body[:plus]))
		defer delete(tok)
		// If this token isn't a modifier, stop — the '+' belongs to the key
		// itself (e.g. "ctrl+=" would fail, but "alt+plus" works; we do not
		// allow bare '+' as a key to avoid ambiguity).
		switch tok {
		case "ctrl", "control": mods |= {.Ctrl}
		case "alt", "meta":     mods |= {.Alt}
		case "shift":           mods |= {.Shift}
		case:
			return Key_Spec{}, fmt.tprintf("unknown modifier '%s'", tok)
		}
		body = strings.trim_space(body[plus+1:])
	}

	if len(body) == 0 {
		return Key_Spec{}, "key name is empty"
	}

	// Named keys (case-insensitive).
	low := strings.to_lower(body)
	defer delete(low)

	named := map[string]Key{
		"f1"=.F1, "f2"=.F2, "f3"=.F3, "f4"=.F4, "f5"=.F5, "f6"=.F6,
		"f7"=.F7, "f8"=.F8, "f9"=.F9, "f10"=.F10, "f11"=.F11, "f12"=.F12,
		"tab"=.Tab, "enter"=.Enter, "return"=.Enter,
		"escape"=.Escape, "esc"=.Escape,
		"backspace"=.Backspace, "bsp"=.Backspace,
		"delete"=.Delete, "del"=.Delete,
		"insert"=.Insert, "ins"=.Insert,
		"home"=.Home, "end"=.End,
		"pageup"=.PageUp, "pgup"=.PageUp,
		"pagedown"=.PageDown, "pgdn"=.PageDown,
		"up"=.Up, "down"=.Down, "left"=.Left, "right"=.Right,
	}
	defer delete(named)

	if k, ok := named[low]; ok {
		return Key_Spec{key=k, mods=mods}, ""
	}
	if low == "space" {
		return Key_Spec{key=.Char, ch=' ', mods=mods}, ""
	}

	// Single character (printable). Lowercase ASCII letters so the binding
	// is case-insensitive unless 'shift' is present.
	r, n := decode_utf8_at(transmute([]u8)body, 0)
	if n == 0 || n != len(body) {
		return Key_Spec{}, fmt.tprintf("unknown key '%s'", body)
	}
	if r >= 'A' && r <= 'Z' {
		r = r + ('a' - 'A')
		mods |= {.Shift}
	}
	return Key_Spec{key=.Char, ch=r, mods=mods}, ""
}

// Normalize a runtime Key_Event so it lines up with parsed Key_Specs.
//   * Ctrl+letter is delivered with mods={.Ctrl} and ch in 'a'..'z' already.
//   * Alt+letter may arrive with ch='Q' (Shift+Alt+q) or ch='q'; we
//     lowercase ASCII letters and add .Shift if the letter was uppercase.
normalize_event :: proc(e: Key_Event) -> Key_Spec {
	spec := Key_Spec{key=e.key, ch=e.ch, mods=e.mods}
	if e.key == .Char && e.ch >= 'A' && e.ch <= 'Z' {
		spec.ch = e.ch + ('a' - 'A')
		spec.mods |= {.Shift}
	}
	return spec
}

keymap_dispatch :: proc(e: Key_Event) -> bool {
	spec := normalize_event(e)
	if name, ok := g_bindings[spec]; ok {
		if action, ok2 := g_commands[name]; ok2 {
			action()
			return true
		}
	}
	return false
}

// CLI helper: print every registered command name, one per line.
keymap_list_commands :: proc() {
	names := make([dynamic]string)
	defer delete(names)
	for k in g_commands { append(&names, k) }
	// simple insertion sort for stable, alphabetic output
	for i in 1..<len(names) {
		j := i
		for j > 0 && names[j-1] > names[j] {
			names[j-1], names[j] = names[j], names[j-1]
			j -= 1
		}
	}
	for n in names { fmt.println(n) }
}
