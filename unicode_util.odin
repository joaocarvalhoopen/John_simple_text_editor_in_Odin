package editor

// Lightweight UTF-8 helpers used throughout the editor for codepoint-aware
// cursor movement, display width measurement, and screen <-> buffer column
// conversions. Buffers store raw UTF-8 bytes; (row, col) where `col` is a
// BYTE offset is the canonical position. These helpers translate between
// byte offsets and visual (display) columns.

// Decode the UTF-8 codepoint at line[i]. Returns the rune and how many
// bytes it occupies. On invalid input, returns (rune(line[i]), 1) so
// editing never gets stuck.
decode_utf8_at :: proc(line: []u8, i: int) -> (rune, int) {
	if i < 0 || i >= len(line) { return 0, 0 }
	b0 := line[i]
	if b0 < 0x80 { return rune(b0), 1 }
	n := 0
	if b0 & 0xE0 == 0xC0 { n = 2 }
	else if b0 & 0xF0 == 0xE0 { n = 3 }
	else if b0 & 0xF8 == 0xF0 { n = 4 }
	else { return rune(b0), 1 }
	if i + n > len(line) { return rune(b0), 1 }
	for k in 1..<n {
		if line[i+k] & 0xC0 != 0x80 { return rune(b0), 1 }
	}
	r: rune
	switch n {
	case 2: r = (rune(line[i]&0x1F)<<6) | rune(line[i+1]&0x3F)
	case 3: r = (rune(line[i]&0x0F)<<12) | (rune(line[i+1]&0x3F)<<6) | rune(line[i+2]&0x3F)
	case 4: r = (rune(line[i]&0x07)<<18) | (rune(line[i+1]&0x3F)<<12) | (rune(line[i+2]&0x3F)<<6) | rune(line[i+3]&0x3F)
	}
	return r, n
}

// Byte index of the next rune start after byte offset `i` (clamped to len).
next_rune_start :: proc(line: []u8, i: int) -> int {
	if i >= len(line) { return len(line) }
	_, n := decode_utf8_at(line, i)
	if n <= 0 { return i + 1 }
	return i + n
}

// Byte index where the rune that ends just before `i` begins.
prev_rune_start :: proc(line: []u8, i: int) -> int {
	if i <= 0 { return 0 }
	j := i - 1
	for j > 0 && line[j] & 0xC0 == 0x80 { j -= 1 }
	return j
}

// Display width of a single rune. We treat all printable codepoints as
// width 1 (typical narrow latin/greek/cyrillic/symbols). This keeps the
// renderer simple; CJK wide runes will still display, just slightly
// narrower than ideal in some terminals.
rune_display_width :: proc(r: rune) -> int {
	if r == 0 { return 0 }
	if r == '\t' { return 1 }   // fallback when caller has no column info
	if r < 0x20 { return 0 }
	return 1
}

// Column-aware advance: how many display columns this rune consumes when
// it sits at display column `dcol`. Tabs expand to the next multiple of
// the editor's tab width, so source code lines up correctly regardless of
// whether the file uses spaces or hard tabs.
rune_advance_at :: proc(r: rune, dcol: int) -> int {
	if r == '\t' {
		tw := g_app.tab_width
		if tw < 1 { tw = 4 }
		return tw - (dcol % tw)
	}
	return rune_display_width(r)
}

// Display width of the whole line (in screen columns).
line_display_width :: proc(line: []u8) -> int {
	w := 0
	i := 0
	for i < len(line) {
		r, n := decode_utf8_at(line, i)
		if n <= 0 { i += 1; continue }
		w += rune_advance_at(r, w)
		i += n
	}
	return w
}

// Display column of the cursor at byte offset `byte_col` within `line`.
display_col_of_byte :: proc(line: []u8, byte_col: int) -> int {
	w := 0
	i := 0
	limit := byte_col
	if limit > len(line) { limit = len(line) }
	for i < limit {
		r, n := decode_utf8_at(line, i)
		if n <= 0 { i += 1; continue }
		w += rune_advance_at(r, w)
		i += n
	}
	return w
}

// Byte offset within `line` whose visual column is closest to `target_dcol`
// without exceeding it. Useful for vertical cursor movement where we want
// to land near the same column on the new line.
byte_col_for_display :: proc(line: []u8, target_dcol: int) -> int {
	if target_dcol <= 0 { return 0 }
	w := 0
	i := 0
	for i < len(line) {
		r, n := decode_utf8_at(line, i)
		if n <= 0 { i += 1; continue }
		rw := rune_advance_at(r, w)
		if w + rw > target_dcol { return i }
		w += rw
		i += n
	}
	return len(line)
}

// Number of visual rows occupied by `line` when wrapped at display width
// `text_w`. Empty lines occupy one row.
line_visual_rows :: proc(line: []u8, text_w: int) -> int {
	if text_w < 1 { return 1 }
	dw := line_display_width(line)
	if dw == 0 { return 1 }
	return (dw + text_w - 1) / text_w
}

// Within `line`, return the visual segment index (0-based) and the
// in-segment display column (0-based) corresponding to byte offset.
visual_seg_of_byte :: proc(line: []u8, byte_col, text_w: int) -> (seg: int, col_in_seg: int) {
	if text_w < 1 { return 0, 0 }
	dc := display_col_of_byte(line, byte_col)
	return dc / text_w, dc % text_w
}

// Treat any non-ASCII byte (UTF-8 continuation or lead) as part of a word
// so identifier-style movement works for accented letters (café, naïve).
is_word_byte :: proc(c: u8) -> bool {
	if c >= 0x80 { return true }
	return (c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='_'
}
