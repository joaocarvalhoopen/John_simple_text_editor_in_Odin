package editor

import "core:fmt"
import "core:strings"

// Recursive split tree
Pane :: struct {
	buffer:    ^Buffer,
	// runtime layout
	x, y, w, h: int,
	// per-pane viewport so two panes showing the same buffer scroll independently
	scroll_x, scroll_y: int,
	// soft line wrap inside this pane (toggled with Alt+Z)
	wrap: bool,
	// last cursor seen by the renderer; used to detect when the user moved
	// the cursor (versus when the user merely scrolled the viewport with
	// the mouse wheel) so we only auto-scroll-into-view on real cursor
	// movement.
	last_cursor:        Cursor,
	last_cursor_buffer: ^Buffer,
}

Split_Dir :: enum { Horizontal, Vertical }
// Horizontal split = stacked top/bottom (divider is horizontal line)
// Vertical split   = side by side left/right (divider is vertical line)

Split :: struct {
	dir: Split_Dir,
	a:   ^Node,
	b:   ^Node,
	ratio: f32,
}

Node :: union { ^Pane, ^Split }

find_first_pane :: proc(n: ^Node) -> ^Pane {
	if n == nil { return nil }
	#partial switch v in n {
	case ^Pane: return v
	case ^Split:
		p := find_first_pane(v.a)
		if p != nil { return p }
		return find_first_pane(v.b)
	}
	return nil
}

collect_panes :: proc(n: ^Node, out: ^[dynamic]^Pane) {
	if n == nil { return }
	#partial switch v in n {
	case ^Pane: append(out, v)
	case ^Split:
		collect_panes(v.a, out)
		collect_panes(v.b, out)
	}
}

layout :: proc(n: ^Node, x, y, w, h: int) {
	if n == nil { return }
	#partial switch v in n {
	case ^Pane:
		v.x = x; v.y = y; v.w = w; v.h = h
	case ^Split:
		if v.dir == .Vertical {
			la := int(f32(w) * v.ratio)
			if la < 4 { la = 4 }
			if la > w-5 { la = w-5 }
			layout(v.a, x, y, la, h)
			layout(v.b, x+la+1, y, w-la-1, h)
		} else {
			la := int(f32(h) * v.ratio)
			if la < 2 { la = 2 }
			if la > h-3 { la = h-3 }
			layout(v.a, x, y, w, la)
			layout(v.b, x, y+la+1, w, h-la-1)
		}
	}
}

draw_split_borders :: proc(n: ^Node, s: ^Screen) {
	if n == nil { return }
	#partial switch v in n {
	case ^Pane: // none
	case ^Split:
		if v.dir == .Vertical {
			pa := find_first_pane(v.a)
			if pa != nil {
				div_x := pa.x + pa.w
				for yy in pa.y..<pa.y+pa.h+1 {
					screen_put(s, div_x, yy, Cell{r='│', fg=.BrightBlack, bg=.Default})
				}
			}
		} else {
			pa := find_first_pane(v.a)
			if pa != nil {
				div_y := pa.y + pa.h
				for xx in pa.x..<pa.x+pa.w {
					screen_put(s, xx, div_y, Cell{r='─', fg=.BrightBlack, bg=.Default})
				}
			}
		}
		draw_split_borders(v.a, s)
		draw_split_borders(v.b, s)
	}
}

// Splitting commands

split_pane :: proc(p: ^Pane, dir: Split_Dir) {
	// Find parent pointer
	parent := find_node_parent(g_app.root, p)
	new_pane := new(Pane)
	new_pane.buffer = p.buffer
	new_split := new(Split)
	new_split.dir = dir
	new_split.ratio = 0.5
	pa := new(Node); pa^ = p
	pb := new(Node); pb^ = new_pane
	new_split.a = pa
	new_split.b = pb
	new_node := new(Node); new_node^ = new_split
	if parent == nil {
		g_app.root = new_node
	} else {
		// replace pointer
		s := parent.(^Split)
		if pane_in(s.a, p) {
			s.a = new_node
		} else {
			s.b = new_node
		}
	}
	g_app.active_pane = new_pane
}

pane_in :: proc(n: ^Node, p: ^Pane) -> bool {
	if n == nil { return false }
	#partial switch v in n {
	case ^Pane: return v == p
	case ^Split: return pane_in(v.a, p) || pane_in(v.b, p)
	}
	return false
}

find_node_parent :: proc(n: ^Node, p: ^Pane) -> ^Node {
	if n == nil { return nil }
	#partial switch v in n {
	case ^Pane: return nil
	case ^Split:
		if a, ok := v.a.(^Pane); ok && a == p { return n }
		if b, ok := v.b.(^Pane); ok && b == p { return n }
		r := find_node_parent(v.a, p); if r != nil { return r }
		return find_node_parent(v.b, p)
	}
	return nil
}

close_pane :: proc(p: ^Pane) {
	parent := find_node_parent(g_app.root, p)
	if parent == nil {
		// last pane: do nothing
		return
	}
	s := parent.(^Split)
	other: ^Node
	if a, ok := s.a.(^Pane); ok && a == p { other = s.b } else { other = s.a }
	// replace parent with other
	grand := find_split_parent(g_app.root, parent)
	if grand == nil {
		g_app.root = other
	} else {
		gs := grand.(^Split)
		if gs.a == parent { gs.a = other } else { gs.b = other }
	}
	free(p)
	g_app.active_pane = find_first_pane(g_app.root)
}

find_split_parent :: proc(n: ^Node, target: ^Node) -> ^Node {
	if n == nil { return nil }
	#partial switch v in n {
	case ^Split:
		if v.a == target || v.b == target { return n }
		r := find_split_parent(v.a, target); if r != nil { return r }
		return find_split_parent(v.b, target)
	}
	return nil
}

// Find a Split whose divider line passes through (x,y) — used for click-drag
// resizing.  Vertical splits have a divider at column = a.x+a.w running
// down a's height; horizontal splits at row = a.y+a.h running across.
find_split_at_divider :: proc(n: ^Node, x, y: int) -> ^Split {
	if n == nil { return nil }
	#partial switch v in n {
	case ^Split:
		pa := find_first_pane(v.a)
		if pa != nil {
			if v.dir == .Vertical {
				div_x := pa.x + pa.w
				if x == div_x && y >= pa.y && y < pa.y+pa.h+1 { return v }
			} else {
				div_y := pa.y + pa.h
				if y == div_y && x >= pa.x && x < pa.x+pa.w { return v }
			}
		}
		if r := find_split_at_divider(v.a, x, y); r != nil { return r }
		return find_split_at_divider(v.b, x, y)
	}
	return nil
}

// Returns the screen-space rectangle the given split occupies (the union of
// its two children).  Used to translate an absolute mouse coordinate into
// a new split ratio while dragging the divider.
split_rect :: proc(s: ^Split) -> (x, y, w, h: int) {
	pa_min := find_first_pane(s.a)
	if pa_min == nil { return 0, 0, 1, 1 }
	pa_max := find_last_pane(s.b)
	if pa_max == nil { pa_max = pa_min }
	x = pa_min.x
	y = pa_min.y
	w = (pa_max.x + pa_max.w) - x
	h = (pa_max.y + pa_max.h) - y
	return
}

find_last_pane :: proc(n: ^Node) -> ^Pane {
	if n == nil { return nil }
	#partial switch v in n {
	case ^Pane: return v
	case ^Split:
		p := find_last_pane(v.b)
		if p != nil { return p }
		return find_last_pane(v.a)
	}
	return nil
}

// Direction-based focus
Dir :: enum { Left, Right, Up, Down }

cmd_focus_dir :: proc(d: Dir) {
	if g_app.active_pane == nil { return }
	cur := g_app.active_pane
	cx := cur.x + cur.w/2
	cy := cur.y + cur.h/2
	panes: [dynamic]^Pane
	collect_panes(g_app.root, &panes)
	defer delete(panes)
	best: ^Pane
	best_dist := 1<<30
	for p in panes {
		if p == cur { continue }
		px := p.x + p.w/2
		py := p.y + p.h/2
		switch d {
		case .Left:  if px >= cx { continue }
		case .Right: if px <= cx { continue }
		case .Up:    if py >= cy { continue }
		case .Down:  if py <= cy { continue }
		}
		dx := px-cx; if dx<0 { dx = -dx }
		dy := py-cy; if dy<0 { dy = -dy }
		dist := dx+dy
		if dist < best_dist { best_dist = dist; best = p }
	}
	if best != nil { g_app.active_pane = best }
}
