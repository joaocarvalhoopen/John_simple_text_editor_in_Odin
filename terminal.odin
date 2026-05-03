package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:sys/linux"
import "core:c"
import "core:encoding/base64"

Winsize :: struct {
	ws_row:    u16,
	ws_col:    u16,
	ws_xpixel: u16,
	ws_ypixel: u16,
}

orig_termios: posix.termios
in_raw_mode: bool

STDIN  :: 0
STDOUT :: 1

write_str :: proc(s: string) {
	if len(s) == 0 { return }
	bytes := transmute([]u8)s
	_, _ = os.write(os.stdout, bytes)
}

write_bytes :: proc(b: []u8) {
	if len(b) == 0 { return }
	_, _ = os.write(os.stdout, b)
}

terminal_init :: proc() -> bool {
	if posix.tcgetattr(posix.FD(STDIN), &orig_termios) != .OK {
		return false
	}
	raw := orig_termios
	raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}
	raw.c_cc[posix.Control_Char.VMIN] = 0
	raw.c_cc[posix.Control_Char.VTIME] = 1
	if posix.tcsetattr(posix.FD(STDIN), .TCSAFLUSH, &raw) != .OK {
		return false
	}
	in_raw_mode = true
	// Enter alt screen, hide cursor while drawing
	write_str("\x1b[?1049h")
	write_str("\x1b[?25l")
	write_str("\x1b[?7l") // disable line wrap
	// Ask the terminal to blink the cursor: DECSCUSR 1 = blinking block;
	// also enable cursor blink attribute (?12h) for terminals that honor it.
	write_str("\x1b[?12h\x1b[1 q")
	// Enable xterm mouse: button events + drag + SGR encoding
	write_str("\x1b[?1000h\x1b[?1002h\x1b[?1006h")
	// Enable bracketed paste so the terminal wraps clipboard pastes
	// in ESC[200~ ... ESC[201~. Lets us treat them as text insertion
	// rather than a stream of synthetic keys.
	write_str("\x1b[?2004h")
	return true
}

terminal_shutdown :: proc() {
	if !in_raw_mode { return }
	// Disable bracketed paste
	write_str("\x1b[?2004l")
	// Disable mouse
	write_str("\x1b[?1006l\x1b[?1002l\x1b[?1000l")
	write_str("\x1b[?7h")
	// Restore cursor shape/blink to terminal default.
	write_str("\x1b[0 q")
	write_str("\x1b[?25h")
	write_str("\x1b[?1049l")
	posix.tcsetattr(posix.FD(STDIN), .TCSAFLUSH, &orig_termios)
	in_raw_mode = false
}

terminal_query_size :: proc(w, h: ^int) {
	ws: Winsize
	ret := linux.ioctl(linux.Fd(STDOUT), linux.TIOCGWINSZ, uintptr(&ws))
	if i64(ret) >= 0 && ws.ws_col > 0 && ws.ws_row > 0 {
		w^ = int(ws.ws_col)
		h^ = int(ws.ws_row)
	} else {
		w^ = 80
		h^ = 24
	}
}

// ---- INPUT ---------------------------------------------------------------

Key :: enum {
	None,
	Char,
	Enter,
	Tab,
	Backspace,
	Escape,
	Up,
	Down,
	Left,
	Right,
	Home,
	End,
	PageUp,
	PageDown,
	Delete,
	Insert,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}

Mod :: enum { Shift, Alt, Ctrl }
Mods :: bit_set[Mod]

Key_Event :: struct {
	key:  Key,
	ch:   rune,
	mods: Mods,
}

Resize_Event :: struct { width, height: int }

Mouse_Event :: struct { x, y: int, button: int, pressed: bool, drag: bool }

// Bracketed-paste payload from the terminal. `text` is heap-allocated and
// must be freed by the consumer.
Paste_Event :: struct { text: []u8 }

Event :: union { Key_Event, Resize_Event, Mouse_Event, Paste_Event }

resize_pending: bool

input_read_byte :: proc() -> (b: u8, ok: bool) {
	buf: [1]u8
	for {
		// Check resize first
		if resize_pending {
			ok = false
			return
		}
		n, err := os.read(os.stdin, buf[:])
		if err != nil { return 0, false }
		if n > 0 {
			return buf[0], true
		}
		// timeout: re-check size (poll based)
		new_w, new_h: int
		terminal_query_size(&new_w, &new_h)
		if new_w != g_app.width || new_h != g_app.height {
			g_app.width = new_w
			g_app.height = new_h
			screen_resize(&g_app.screen, new_w, new_h)
			screen_resize(&g_app.prev_screen, new_w, new_h)
			resize_pending = true
			return 0, false
		}
	}
}

input_try_byte :: proc() -> (b: u8, ok: bool) {
	buf: [1]u8
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n == 0 { return 0, false }
	return buf[0], true
}

input_read_event :: proc() -> Event {
	if resize_pending {
		resize_pending = false
		return Resize_Event{g_app.width, g_app.height}
	}
	b, ok := input_read_byte()
	if !ok {
		if resize_pending {
			resize_pending = false
			return Resize_Event{g_app.width, g_app.height}
		}
		return Key_Event{key=.None}
	}
	return parse_key(b)
}

parse_key :: proc(first: u8) -> Event {
	b := first
	if b == 0x1b {
		// Could be ESC alone or ESC sequence
		b2, has := input_try_byte()
		if !has {
			return Key_Event{key=.Escape}
		}
		if b2 == '[' || b2 == 'O' {
			return parse_csi(b2)
		}
		// Alt + key
		ev := parse_key(b2).(Key_Event) or_else Key_Event{}
		ev.mods += {.Alt}
		return ev
	}
	if b == 0x7f || b == 0x08 {
		return Key_Event{key=.Backspace}
	}
	if b == '\r' || b == '\n' {
		return Key_Event{key=.Enter, ch='\n'}
	}
	if b == '\t' {
		return Key_Event{key=.Tab, ch='\t'}
	}
	if b < 0x20 {
		// Ctrl + letter
		if b == 0 {
			return Key_Event{key=.Char, ch=' ', mods={.Ctrl}}  // Ctrl+Space
		}
		return Key_Event{key=.Char, ch=rune('a' + b - 1), mods={.Ctrl}}
	}
	// UTF-8 decoding
	if b < 0x80 {
		return Key_Event{key=.Char, ch=rune(b)}
	}
	// multi-byte
	nbytes := 0
	if b & 0xE0 == 0xC0 { nbytes = 2 }
	else if b & 0xF0 == 0xE0 { nbytes = 3 }
	else if b & 0xF8 == 0xF0 { nbytes = 4 }
	else { return Key_Event{key=.Char, ch=rune(b)} }
	bytes: [4]u8
	bytes[0] = b
	for i in 1..<nbytes {
		bb, has := input_try_byte()
		if !has { return Key_Event{key=.Char, ch=rune(b)} }
		bytes[i] = bb
	}
	r: rune
	switch nbytes {
	case 2: r = (rune(bytes[0]&0x1F)<<6) | rune(bytes[1]&0x3F)
	case 3: r = (rune(bytes[0]&0x0F)<<12) | (rune(bytes[1]&0x3F)<<6) | rune(bytes[2]&0x3F)
	case 4: r = (rune(bytes[0]&0x07)<<18) | (rune(bytes[1]&0x3F)<<12) | (rune(bytes[2]&0x3F)<<6) | rune(bytes[3]&0x3F)
	}
	return Key_Event{key=.Char, ch=r}
}

parse_csi :: proc(introducer: u8) -> Event {
	// Read parameter bytes 0x30-0x3f, intermediate 0x20-0x2f, final 0x40-0x7e
	params: [32]u8
	plen := 0
	final: u8
	for {
		c, ok := input_try_byte()
		if !ok { return Key_Event{key=.Escape} }
		if c >= 0x40 && c <= 0x7e {
			final = c
			break
		}
		if plen < len(params) {
			params[plen] = c
			plen += 1
		}
	}
	pstr := string(params[:plen])
	if introducer == 'O' {
		switch final {
		case 'P': return Key_Event{key=.F1}
		case 'Q': return Key_Event{key=.F2}
		case 'R': return Key_Event{key=.F3}
		case 'S': return Key_Event{key=.F4}
		case 'H': return Key_Event{key=.Home}
		case 'F': return Key_Event{key=.End}
		}
	}
	// SGR mouse: ESC [ < b ; col ; row M  (press)  /  m (release)
	if plen > 0 && params[0] == '<' && (final == 'M' || final == 'm') {
		s := string(params[1:plen])
		bn, col, row: int
		// split by ';'
		i := 0
		bn, i = parse_int_until(s, i, ';')
		col_, i2 := parse_int_until(s, i, ';')
		col = col_
		row, _ = parse_int_until(s, i2, 0)
		btn_raw := bn
		drag := (btn_raw & 32) != 0
		btn := btn_raw & 3
		// 64+ = scroll wheel: 64 up, 65 down
		if btn_raw & 64 != 0 {
			b := 4 if btn == 0 else 5
			return Mouse_Event{x=col-1, y=row-1, button=b, pressed=true, drag=false}
		}
		// release: btn==3 in legacy; in SGR, final=='m' means release
		pressed := final == 'M'
		return Mouse_Event{x=col-1, y=row-1, button=btn, pressed=pressed, drag=drag}
	}
	// CSI
	mods: Mods
	// xterm: CSI 1;mods FINAL  for arrows, etc.
	// extract first numeric; if there's ";", second is modifier
	first_n := 0
	mod_n := 1
	{
		p1, p2, has2 := split_semi(pstr)
		if len(p1) > 0 { first_n = atoi(p1) }
		if has2 && len(p2) > 0 { mod_n = atoi(p2) }
	}
	if mod_n > 1 {
		m := mod_n - 1
		if m & 1 != 0 { mods += {.Shift} }
		if m & 2 != 0 { mods += {.Alt} }
		if m & 4 != 0 { mods += {.Ctrl} }
	}
	switch final {
	case 'A': return Key_Event{key=.Up, mods=mods}
	case 'B': return Key_Event{key=.Down, mods=mods}
	case 'C': return Key_Event{key=.Right, mods=mods}
	case 'D': return Key_Event{key=.Left, mods=mods}
	case 'H': return Key_Event{key=.Home, mods=mods}
	case 'F': return Key_Event{key=.End, mods=mods}
	case 'P': return Key_Event{key=.F1, mods=mods}
	case 'Q': return Key_Event{key=.F2, mods=mods}
	case 'R': return Key_Event{key=.F3, mods=mods}
	case 'S': return Key_Event{key=.F4, mods=mods}
	case 'Z': return Key_Event{key=.Tab, mods=mods+{.Shift}}
	case '~':
		switch first_n {
		case 1, 7: return Key_Event{key=.Home, mods=mods}
		case 2:    return Key_Event{key=.Insert, mods=mods}
		case 3:    return Key_Event{key=.Delete, mods=mods}
		case 4, 8: return Key_Event{key=.End, mods=mods}
		case 5:    return Key_Event{key=.PageUp, mods=mods}
		case 6:    return Key_Event{key=.PageDown, mods=mods}
		case 11:   return Key_Event{key=.F1, mods=mods}
		case 12:   return Key_Event{key=.F2, mods=mods}
		case 13:   return Key_Event{key=.F3, mods=mods}
		case 14:   return Key_Event{key=.F4, mods=mods}
		case 15:   return Key_Event{key=.F5, mods=mods}
		case 17:   return Key_Event{key=.F6, mods=mods}
		case 18:   return Key_Event{key=.F7, mods=mods}
		case 19:   return Key_Event{key=.F8, mods=mods}
		case 20:   return Key_Event{key=.F9, mods=mods}
		case 21:   return Key_Event{key=.F10, mods=mods}
		case 23:   return Key_Event{key=.F11, mods=mods}
		case 24:   return Key_Event{key=.F12, mods=mods}
		case 200:  return read_bracketed_paste()
		case 201:  return Key_Event{key=.None}  // stray paste end
		}
	}
	return Key_Event{key=.None}
}

split_semi :: proc(s: string) -> (a, b: string, has_b: bool) {
	for i in 0..<len(s) {
		if s[i] == ';' {
			return s[:i], s[i+1:], true
		}
	}
	return s, "", false
}

atoi :: proc(s: string) -> int {
	n := 0
	for c in s {
		if c < '0' || c > '9' { break }
		n = n*10 + int(c - '0')
	}
	return n
}

parse_int_until :: proc(s: string, start: int, sep: u8) -> (int, int) {
	n := 0
	i := start
	for i < len(s) {
		c := s[i]
		if sep != 0 && c == sep { i += 1; return n, i }
		if c < '0' || c > '9' { return n, i+1 }
		n = n*10 + int(c - '0')
		i += 1
	}
	return n, i
}

// Reads bytes until the bracketed-paste end marker ESC [ 201 ~ is seen.
// The terminator is stripped from the returned buffer. The returned slice
// is heap-allocated and must be freed by the caller.
read_bracketed_paste :: proc() -> Event {
	end := []u8{0x1b, '[', '2', '0', '1', '~'}
	buf: [dynamic]u8
	match := 0
	// Allow a longer timeout per byte during paste so we don't truncate
	// large pastes that arrive with brief gaps.
	for {
		b, ok := input_try_byte()
		if !ok {
			// One more chance, then give up.
			b, ok = input_try_byte()
			if !ok { break }
		}
		append(&buf, b)
		if b == end[match] {
			match += 1
			if match == len(end) {
				resize(&buf, len(buf) - len(end))
				break
			}
		} else {
			match = (1 if b == 0x1b else 0)
		}
	}
	return Paste_Event{text = buf[:]}
}

// OSC 52 — write `data` to the terminal's selection buffer ("c" = clipboard).
// Most modern terminals (xterm, kitty, wezterm, alacritty, iTerm2, foot,
// recent gnome-terminal) honour this, which lets copy-to-clipboard work
// transparently across SSH. For tmux, set `set -g set-clipboard on`.
osc52_copy :: proc(data: []u8) {
	if len(data) == 0 { return }
	enc, err := base64.encode(data)
	if err != nil { return }
	defer delete(enc)
	// Some terminals reject very long OSC 52 payloads (typical limit ~74KB
	// of base64). Skip silently in that case rather than spamming garbage.
	if len(enc) > 100_000 { return }
	write_str("\x1b]52;c;")
	write_str(enc)
	write_str("\x07")
}
