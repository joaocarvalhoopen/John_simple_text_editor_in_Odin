package editor

import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:unicode/utf8"

Color :: enum u8 {
	Default = 0,
	Black, Red, Green, Yellow, Blue, Magenta, Cyan, White,
	BrightBlack, BrightRed, BrightGreen, BrightYellow,
	BrightBlue, BrightMagenta, BrightCyan, BrightWhite,
	Orange,  // 256-color #208 — used for function calls; not in the basic 16
	Gray,    // 256-color #250 — bright gray for function defs/decls
}

Style :: bit_set[Style_Bit]
Style_Bit :: enum { Bold, Italic, Underline, Reverse }

Cell :: struct {
	r:    rune,
	fg:   Color,
	bg:   Color,
	st:   Style,
}

Screen :: struct {
	w, h:  int,
	cells: []Cell,
}

screen_init :: proc(s: ^Screen, w, h: int) {
	s.w = w
	s.h = h
	s.cells = make([]Cell, w*h)
	screen_clear(s)
}

screen_resize :: proc(s: ^Screen, w, h: int) {
	if s.w == w && s.h == h { return }
	delete(s.cells)
	s.w = w
	s.h = h
	s.cells = make([]Cell, w*h)
	screen_clear(s)
}

screen_clear :: proc(s: ^Screen) {
	for i in 0..<len(s.cells) {
		s.cells[i] = Cell{r=' ', fg=.Default, bg=.Default}
	}
}

screen_put :: proc(s: ^Screen, x, y: int, c: Cell) {
	if x < 0 || y < 0 || x >= s.w || y >= s.h { return }
	s.cells[y*s.w + x] = c
}

screen_get :: proc(s: ^Screen, x, y: int) -> Cell {
	if x < 0 || y < 0 || x >= s.w || y >= s.h { return Cell{r=' '} }
	return s.cells[y*s.w + x]
}

screen_fill :: proc(s: ^Screen, x, y, w, h: int, c: Cell) {
	for yy in y..<y+h {
		for xx in x..<x+w {
			screen_put(s, xx, yy, c)
		}
	}
}

screen_text :: proc(s: ^Screen, x, y: int, str: string, fg, bg: Color, st: Style = {}) -> int {
	cx := x
	for r in str {
		if cx >= s.w { break }
		screen_put(s, cx, y, Cell{r=r, fg=fg, bg=bg, st=st})
		cx += rune_width(r)
	}
	return cx - x
}

rune_width :: proc(r: rune) -> int {
	if r == 0 { return 0 }
	if r < 0x20 { return 0 }
	// approximate: treat all as 1; CJK not handled fully
	return 1
}

// ---- present (diff & flush) ----------------------------------------------

color_fg_code :: proc(c: Color) -> string {
	switch c {
	case .Default:       return "39"
	case .Black:         return "30"
	case .Red:           return "31"
	case .Green:         return "32"
	case .Yellow:        return "33"
	case .Blue:          return "34"
	case .Magenta:       return "35"
	case .Cyan:          return "36"
	case .White:         return "37"
	case .BrightBlack:   return "90"
	case .BrightRed:     return "91"
	case .BrightGreen:   return "92"
	case .BrightYellow:  return "93"
	case .BrightBlue:    return "94"
	case .BrightMagenta: return "95"
	case .BrightCyan:    return "96"
	case .BrightWhite:   return "97"
	case .Orange:        return "38;5;208"
	case .Gray:          return "38;5;250"
	}
	return "39"
}

color_bg_code :: proc(c: Color) -> string {
	switch c {
	case .Default:       return "49"
	case .Black:         return "40"
	case .Red:           return "41"
	case .Green:         return "42"
	case .Yellow:        return "43"
	case .Blue:          return "44"
	case .Magenta:       return "45"
	case .Cyan:          return "46"
	case .White:         return "47"
	case .BrightBlack:   return "100"
	case .BrightRed:     return "101"
	case .BrightGreen:   return "102"
	case .BrightYellow:  return "103"
	case .BrightBlue:    return "104"
	case .BrightMagenta: return "105"
	case .BrightCyan:    return "106"
	case .BrightWhite:   return "107"
	case .Orange:        return "48;5;208"
	case .Gray:          return "48;5;250"
	}
	return "49"
}

screen_present :: proc(prev, cur: ^Screen, cursor_x, cursor_y: int, cursor_visible: bool) {
	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, "\x1b[?25l")
	last_fg := Color(255)
	last_bg := Color(255)
	last_st := Style{}
	cursor_set := false
	cur_x := -1
	cur_y := -1
	for y in 0..<cur.h {
		for x in 0..<cur.w {
			c := cur.cells[y*cur.w+x]
			if y < prev.h && x < prev.w {
				p := prev.cells[y*prev.w+x]
				if p == c && cursor_set { continue }
			}
			if cur_x != x || cur_y != y {
				fmt.sbprintf(&sb, "\x1b[%d;%dH", y+1, x+1)
				cur_x = x
				cur_y = y
				cursor_set = true
			}
			if c.fg != last_fg || c.bg != last_bg || c.st != last_st {
				strings.write_string(&sb, "\x1b[0m")
				if .Bold in c.st      { strings.write_string(&sb, "\x1b[1m") }
				if .Italic in c.st    { strings.write_string(&sb, "\x1b[3m") }
				if .Underline in c.st { strings.write_string(&sb, "\x1b[4m") }
				if .Reverse in c.st   { strings.write_string(&sb, "\x1b[7m") }
				fmt.sbprintf(&sb, "\x1b[%sm", color_fg_code(c.fg))
				fmt.sbprintf(&sb, "\x1b[%sm", color_bg_code(c.bg))
				last_fg = c.fg
				last_bg = c.bg
				last_st = c.st
			}
			r := c.r
			if r < 0x20 || r == 0x7f { r = ' ' }
			enc, n := utf8.encode_rune(r)
			strings.write_bytes(&sb, enc[:n])
			cur_x = x + rune_width(r)
		}
	}
	strings.write_string(&sb, "\x1b[0m")
	if cursor_visible {
		fmt.sbprintf(&sb, "\x1b[%d;%dH", cursor_y+1, cursor_x+1)
		strings.write_string(&sb, "\x1b[?25h")
	}
	write_str(strings.to_string(sb))
	// copy current to prev
	for i in 0..<len(cur.cells) {
		prev.cells[i] = cur.cells[i]
	}
}
