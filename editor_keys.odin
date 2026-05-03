package editor

import "core:strings"

editor_key :: proc(b: ^Buffer, e: Key_Event) {
	// All command bindings (Ctrl+*, Alt+*, F-keys, Ctrl+Space) are dispatched
	// upstream by keymap_dispatch in main.global_key.  This proc only handles
	// the always-on raw editing keys: typing, motion, indentation, selection
	// extension via Shift+arrows.
	shift := .Shift in e.mods
	ctrl := .Ctrl in e.mods
	alt := .Alt in e.mods

	#partial switch e.key {
	case .Up:        move_cursor(b, -1, 0, shift); return
	case .Down:      move_cursor(b, +1, 0, shift); return
	case .Left:
		if ctrl { move_word(b, -1, shift) } else { move_cursor(b, 0, -1, shift) }
		return
	case .Right:
		if ctrl { move_word(b, +1, shift) } else { move_cursor(b, 0, +1, shift) }
		return
	case .Home:      move_home(b, shift); return
	case .End:       move_end(b, shift); return
	case .PageUp:
		if g_app.active_pane != nil {
			ph := g_app.active_pane.h - 1
			if ph < 1 { ph = 1 }
			move_cursor(b, -ph, 0, shift)
		}
		return
	case .PageDown:
		if g_app.active_pane != nil {
			ph := g_app.active_pane.h - 1
			if ph < 1 { ph = 1 }
			move_cursor(b, +ph, 0, shift)
		}
		return
	case .Backspace: backspace(b); return
	case .Delete:    delete_forward(b); return
	case .Enter:     newline_with_indent(b); return
	case .Tab:
		if shift { return }
		insert_tab(b); return
	case .Char:
		if !ctrl && !alt && e.ch >= 0x20 {
			bytes: [4]u8
			n := encode_rune_utf8(e.ch, bytes[:])
			insert_text_user(b, bytes[:n])
		}
		return
	case .Escape: clear_selection(b); return
	}
}
