package editor

import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:slice"
import "core:fmt"

Tree_Node :: struct {
	name:    string,
	path:    string,
	is_dir:  bool,
	expanded: bool,
	depth:    int,
	children: [dynamic]^Tree_Node,
	loaded:   bool,
}

FileTree :: struct {
	root:     ^Tree_Node,
	flat:     [dynamic]^Tree_Node,
	selected: int,
	scroll:   int,
}

file_tree_init :: proc(t: ^FileTree, root_path: string) {
	r := new(Tree_Node)
	r.name = filepath.base(root_path)
	r.path = strings.clone(root_path)
	r.is_dir = true
	r.expanded = true
	tree_load_children(r)
	t.root = r
	tree_rebuild_flat(t)
}

tree_load_children :: proc(n: ^Tree_Node) {
	if !n.is_dir || n.loaded { return }
	infos, ok := list_directory(n.path)
	if !ok { n.loaded = true; return }
	defer delete(infos)
	for fi in infos {
		// skip hidden? show them
		if fi.name == "." || fi.name == ".." { continue }
		c := new(Tree_Node)
		c.name = strings.clone(fi.name)
		c.path = strings.clone(fi.fullpath)
		c.is_dir = fi.is_dir
		c.depth = n.depth + 1
		append(&n.children, c)
	}
	// sort: dirs first, then alphabetical
	slice.sort_by(n.children[:], proc(a, b: ^Tree_Node) -> bool {
		if a.is_dir != b.is_dir { return a.is_dir }
		return a.name < b.name
	})
	n.loaded = true
}

tree_rebuild_flat :: proc(t: ^FileTree) {
	clear(&t.flat)
	if t.root == nil { return }
	tree_walk(t, t.root)
}

tree_walk :: proc(t: ^FileTree, n: ^Tree_Node) {
	append(&t.flat, n)
	if n.is_dir && n.expanded {
		for c in n.children { tree_walk(t, c) }
	}
}

tree_toggle :: proc(t: ^FileTree, n: ^Tree_Node) {
	if !n.is_dir { return }
	if !n.loaded { tree_load_children(n) }
	n.expanded = !n.expanded
	tree_rebuild_flat(t)
}

tree_activate_selected :: proc() {
	t := &g_app.file_tree
	if t.selected < 0 || t.selected >= len(t.flat) { return }
	n := t.flat[t.selected]
	if n.is_dir {
		tree_toggle(t, n)
	} else {
		// open file in active pane
		buf := find_buffer_by_path(n.path)
		if buf == nil {
			buf = buffer_load_file(n.path)
			append(&g_app.buffers, buf)
		}
		open_in_active_pane(buf)
	}
}

find_buffer_by_path :: proc(path: string) -> ^Buffer {
	for b in g_app.buffers {
		if b.path == path { return b }
	}
	return nil
}

tree_mouse_click :: proc(x, y: int) {
	t := &g_app.file_tree
	g_app.focus = .Tree
	// Tree pane occupies y=1 (header) and y=2..h-2 (items).
	// A click on row 1 (the FILES header) just moves focus, no selection.
	if y < 2 { return }
	row := t.scroll + (y - 2)
	if row < 0 || row >= len(t.flat) { return }
	prev_sel := t.selected
	t.selected = row
	if prev_sel == row {
		tree_activate_selected()
		n := tree_selected()
		if n != nil && !n.is_dir { g_app.focus = .Editor }
	}
}

tree_move :: proc(delta: int) {
	t := &g_app.file_tree
	t.selected += delta
	if t.selected < 0 { t.selected = 0 }
	if t.selected >= len(t.flat) { t.selected = len(t.flat)-1 }
}

tree_selected :: proc() -> ^Tree_Node {
	t := &g_app.file_tree
	if t.selected < 0 || t.selected >= len(t.flat) { return nil }
	return t.flat[t.selected]
}

tree_refresh :: proc() {
	// Reload children of every expanded dir whose parent path still exists
	if g_app.file_tree.root != nil {
		tree_refresh_node(g_app.file_tree.root)
		tree_rebuild_flat(&g_app.file_tree)
	}
}

tree_refresh_node :: proc(n: ^Tree_Node) {
	if !n.is_dir { return }
	if !n.loaded { return }
	// remember which children were expanded
	expanded_names := make(map[string]bool)
	defer delete(expanded_names)
	for c in n.children {
		if c.is_dir && c.expanded { expanded_names[c.name] = true }
		delete(c.name); if c.path != "" { delete(c.path) }
		// recursively free
		tree_free_subtree(c)
	}
	clear(&n.children)
	n.loaded = false
	tree_load_children(n)
	for c in n.children {
		if c.is_dir && expanded_names[c.name] {
			c.expanded = true
			tree_load_children(c)
			tree_refresh_node(c)
		}
	}
}

tree_free_subtree :: proc(n: ^Tree_Node) {
	for c in n.children { tree_free_subtree(c) }
	delete(n.children)
	free(n)
}

// Find directory in which a new file should be created based on selection.
tree_dir_for_new :: proc() -> string {
	n := tree_selected()
	if n == nil { return g_app.cwd }
	if n.is_dir { return n.path }
	return dir_name(n.path)
}

tree_handle_key :: proc(e: Key_Event) {
	t := &g_app.file_tree
	#partial switch e.key {
	case .Escape, .F6:
		g_app.focus = .Editor
		return
	case .Up:    tree_move(-1); return
	case .Down:  tree_move(+1); return
	case .PageUp:   tree_move(-10); return
	case .PageDown: tree_move(+10); return
	case .Home:  t.selected = 0; return
	case .End:   t.selected = len(t.flat)-1; return
	case .Right:
		n := tree_selected()
		if n != nil && n.is_dir && !n.expanded { tree_toggle(t, n) }
		return
	case .Left:
		n := tree_selected()
		if n != nil && n.is_dir && n.expanded { tree_toggle(t, n); return }
		// move to parent
		if n != nil {
			parent_depth := n.depth - 1
			for i := t.selected-1; i >= 0; i -= 1 {
				if t.flat[i].depth == parent_depth { t.selected = i; break }
			}
		}
		return
	case .Enter:
		tree_activate_selected()
		// after opening a file, focus moves to editor; for dirs stay
		n := tree_selected()
		if n != nil && !n.is_dir { g_app.focus = .Editor }
		return
	case .F2:
		tree_rename_selected()
		return
	case .Delete:
		tree_delete_selected()
		return
	case .Insert:
		tree_new_file()
		return
	case .Char:
		if .Ctrl in e.mods {
			switch e.ch {
			case 'n': tree_new_file(); return
			case 'd': tree_new_dir(); return
			case 'r': tree_refresh(); set_status("Tree refreshed"); return
			}
		}
	}
}

tree_rename_selected :: proc() {
	n := tree_selected()
	if n == nil { return }
	d := dialog_open(.Prompt, "Rename", fmt.aprintf("New name for %s:", n.name), proc(d: ^Dialog){
		nn := tree_selected()
		if nn == nil { return }
		new_name := strings.clone(string(d.input[:]))
		defer delete(new_name)
		if new_name == "" || new_name == nn.name { return }
		newp := filepath.join({dir_name(nn.path), new_name})
		ok := os_rename(nn.path, newp)
		if !ok { set_status("Rename failed"); return }
		// update any open buffer paths
		for b in g_app.buffers {
			if b.path == nn.path {
				delete(b.path); b.path = strings.clone(newp)
				delete(b.name); b.name = strings.clone(new_name)
				b.lang = detect_language(newp)
			}
		}
		tree_refresh()
		set_status("Renamed to %s", new_name)
	})
	for c in n.name { append(&d.input, u8(c)) }
	d.cursor = len(d.input)
}

tree_delete_selected :: proc() {
	n := tree_selected()
	if n == nil { return }
	if n == g_app.file_tree.root { return }
	prompt := fmt.aprintf("Delete '%s'? Type 'yes' to confirm:", n.name)
	d := dialog_open(.Confirm, "Delete File", prompt, proc(d: ^Dialog){
		nn := tree_selected()
		if nn == nil { return }
		if string(d.input[:]) != "yes" { set_status("Delete cancelled"); return }
		ok := os_remove_path(nn.path)
		if !ok { set_status("Delete failed"); return }
		// close any open buffer with that path
		for b, i in g_app.buffers {
			if b.path == nn.path {
				panes: [dynamic]^Pane
				collect_panes(g_app.root, &panes)
				replacement: ^Buffer
				if len(g_app.buffers) > 1 {
					replacement = g_app.buffers[0] if g_app.buffers[0] != b else g_app.buffers[1]
				} else {
					replacement = buffer_new_scratch("*scratch*")
					append(&g_app.buffers, replacement)
				}
				for p in panes { if p.buffer == b { p.buffer = replacement } }
				delete(panes)
				ordered_remove(&g_app.buffers, i)
				for line in b.lines { delete(line) }
				delete(b.lines); delete(b.name); if b.path != "" { delete(b.path) }
				free(b)
				break
			}
		}
		tree_refresh()
		set_status("Deleted")
	})
	_ = d
}

tree_new_file :: proc() {
	dir := tree_dir_for_new()
	d := dialog_open(.Prompt, "New File", fmt.aprintf("Create file in %s :", dir), proc(d: ^Dialog){
		name := strings.clone(string(d.input[:]))
		defer delete(name)
		if name == "" { return }
		dir := tree_dir_for_new()
		full := filepath.join({dir, name})
		if path_exists(full) { set_status("Already exists: %s", full); return }
		// create empty file
		if !os.write_entire_file(full, []u8{}) { set_status("Create failed"); return }
		// expand the parent dir in tree
		tree_refresh()
		// open the new file
		do_open_path(full)
		set_status("Created %s", full)
	})
	_ = d
}

tree_new_dir :: proc() {
	dir := tree_dir_for_new()
	d := dialog_open(.Prompt, "New Folder", fmt.aprintf("Create folder in %s :", dir), proc(d: ^Dialog){
		name := strings.clone(string(d.input[:]))
		defer delete(name)
		if name == "" { return }
		dir := tree_dir_for_new()
		full := filepath.join({dir, name})
		if !os_mkdir(full) { set_status("mkdir failed"); return }
		tree_refresh()
		set_status("Created folder %s", full)
	})
	_ = d
}
