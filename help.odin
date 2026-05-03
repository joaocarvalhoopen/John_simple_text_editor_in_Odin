package editor

import "core:fmt"
import "core:strings"

HELP_TEXT := []string{
	"JOHN — John simple editor in Odin                                Press ESC or F1 to close",
	"================================================================================",
	"",
	"GENERAL",
	"  F1                Toggle this help dialog",
	"  Ctrl+?            Toggle this help dialog (alias)",
	"  F10               Open menu bar  (←/→/↑/↓ to navigate, Enter to pick, Esc to close)",
	"  F6                Switch focus between file tree and editor",
	"  F5                Refresh screen — re-detect terminal size & full repaint",
	"                    (use after changing the terminal font / zoom)",
	"  Ctrl+B            Show / hide the file tree",
	"  Alt+Z             Toggle SOFT LINE WRAP on the active pane",
	"  Ctrl+Q            Quit (asks for confirmation if any buffer is dirty)",
	"  Esc               Cancel selection / close dialog / leave tree focus",
	"",
	"FILE",
	"  Ctrl+N            New scratch buffer",
	"  Ctrl+O            Open file (path prompt)",
	"  Alt+R             Open Recent (last 20 files, persisted to ~/.config/john/recent)",
	"  Ctrl+R            Refresh the file tree from disk (works from anywhere)",
	"  Ctrl+S            Save",
	"  Ctrl+W            Close current buffer (asks if dirty)",
	"  Ctrl+P            Pick buffer from list",
	"",
	"EDIT (Windows-style)",
	"  Ctrl+Z / Ctrl+Y   Undo / Redo",
	"  Ctrl+C            Copy selection (or current line if no selection)",
	"  Ctrl+X            Cut selection (or current line if no selection)",
	"  Ctrl+V            Paste (line-mode if last copy was a whole line)",
	"  Ctrl+A            Select all",
	"  Ctrl+D            Duplicate current line",
	"  Ctrl+K            Delete current line",
	"  Ctrl+L            Select current line",
	"  Alt+D             Delete next word",
	"  Tab               Indent (4 spaces; literal TAB inside Makefiles)",
	"",
	"MOTION & SELECTION",
	"  ←/→/↑/↓           Move cursor",
	"  Shift+arrow       Extend selection",
	"  Ctrl+←/→          Word jump",
	"  Ctrl+Shift+←/→    Word jump with selection",
	"  Home / End        Smart line start (toggles indent vs col 0) / line end",
	"  PageUp/PageDown   Page scroll (per-pane: each split scrolls independently)",
	"",
	"SEARCH",
	"  Ctrl+F            Find — opens the search dialog. The prompt shows the",
	"                    current case-sensitivity mode and pre-fills with the",
	"                    last needle so Enter repeats it.",
	"  F3                Find NEXT occurrence (forward, wraps)",
	"  Shift+F3          Find PREVIOUS occurrence (backward, wraps)",
	"  Alt+C             Toggle CASE-SENSITIVE / case-insensitive search",
	"                    (works globally and inside the Find/Replace dialog;",
	"                     the dialog prompt updates live to show the mode)",
	"  Ctrl+H            Replace all (uses the same case-sensitivity setting)",
	"  Ctrl+G            Go to line",
	"",
	"COMPLETION",
	"  Ctrl+Space        Trigger code completion popup. The popup appears on",
	"                    the line BELOW the cursor (or above if at the bottom)",
	"                    and is clamped to the screen edges, so it works in",
	"                    every part of the window, including the right side.",
	"                    Sources:",
	"                      • language keywords/builtins (C, C++, Odin, Python, Shell)",
	"                      • words from ALL open buffers",
	"                      • identifiers from files in the working directory and",
	"                        one level of sub-directories (max 20 dirs total)",
	"                        for: .c .cpp .cxx .cc .h .hpp .hh .odin .py .txt",
	"                        .md .markdown .mk and Makefile / makefile / GNUmakefile",
	"                    Inside the popup: ↑/↓ to choose, Enter to insert, Esc to dismiss.",
	"",
	"VIEW & WINDOWS",
	"  Ctrl+B            Toggle / focus file tree (hidden→tree-focus→hidden cycle)",
	"  F6                Switch focus between file tree and editor",
	"  Ctrl+Tab          Cycle through buffers",
	"  Alt+1 .. Alt+9    Jump directly to buffer 1..9",
	"  Alt+\\             Split current pane vertically (side by side)",
	"  Alt+-             Split current pane horizontally (stacked)",
	"  Alt+W             Close current pane",
	"  F4                Close current pane (alias)",
	"  Alt+Z             Toggle SOFT LINE WRAP in the active pane (per-pane)",
	"  Alt+H/J/K/L       Focus pane Left/Down/Up/Right (vim-style)",
	"  Each pane keeps its OWN scroll position and OWN wrap setting, so two",
	"  panes on the same buffer scroll and wrap independently with arrows /",
	"  PgUp / PgDn / mouse wheel.",
	"",
	"FILE TREE  (left pane, focus it with Ctrl+B or F6 or by clicking a row)",
	"  ↑ ↓               Move selection",
	"  PageUp/PageDown   Move 10 rows",
	"  Home / End        Jump to top / bottom",
	"  → / ←             Expand / collapse directory  (← on a file jumps to parent)",
	"  Enter             Open file or expand/collapse directory",
	"  F2                Rename selected file or folder (prompt prefilled)",
	"  Delete            Delete selected file/folder (must type 'yes' to confirm)",
	"  Insert            New file in current/parent directory",
	"  Ctrl+N            New file in current/parent directory (alias)",
	"  Ctrl+D            New folder in current/parent directory",
	"  Ctrl+R            Refresh tree from disk",
	"  Esc / F6          Return focus to editor",
	"",
	"MOUSE",
	"  Click in editor pane    Focus that pane and place cursor at line/col",
	"  Drag in editor pane     Extend selection",
	"  Drag a pane divider     Resize panes (vertical OR horizontal split)",
	"  Drag the tree divider   Resize the file tree column width",
	"  Wheel up / wheel down   Scroll active pane (or tree, or help, if focused)",
	"  Click on menu bar       Open that menu",
	"  Click on dropdown item  Execute that command",
	"  Click on tree row       Select it; click again to open / toggle",
	"  Click anywhere in help  Close the help overlay",
	"",
	"DIALOGS",
	"  Enter             Confirm; ok-callback runs and dialog closes",
	"  Esc               Cancel and close dialog",
	"  Tab               (Replace dialog) switch between Find and Replace fields",
	"  In list dialogs (Pick, Open Recent, About, Completion):",
	"    ↑/↓             Move selection      PgUp/PgDn   Move by 10",
	"    Enter           Activate            Esc         Dismiss",
	"",
	"SYNTAX HIGHLIGHTING",
	"  Handwritten lexers for: C, C++, Odin, Python, Shell, Makefile, JSON,",
	"  Markdown (headings, lists, blockquotes, **bold**, *italic*, `code`,",
	"  fenced ```code blocks```, [links](url), images, horizontal rules)",
	"  and HTML. Detected automatically from file extension/name.",
	"",
	"CLIPBOARD",
	"  Internal Ctrl+C/X/V clipboard. Tied to the editor process.",
	"",
	"PERSISTENCE",
	"  ~/.config/john/recent     Recently opened files (max 20, MRU first)",
	"  ~/.config/john/keys.conf  Keybindings — plain text, auto-created on",
	"                            first start. Edit freely; restart JOHN to",
	"                            reload. Run `john --list-commands` to see",
	"                            every command name you can bind. Errors are",
	"                            reported as path:line:column.",
}

draw_help_overlay :: proc() {
	s := &g_app.screen
	W := s.w; H := s.h
	w := W - 8
	h := H - 4
	if w > 90 { w = 90 }
	if h < 10 { h = 10 }
	x := (W-w)/2
	y := (H-h)/2
	draw_box(x, y, w, h, "Help — Key Bindings   (↑/↓ PgUp/PgDn Home/End scroll, Esc to close)")
	visible := h-2
	max_scroll := len(HELP_TEXT) - visible
	if max_scroll < 0 { max_scroll = 0 }
	if g_app.help_scroll > max_scroll { g_app.help_scroll = max_scroll }
	if g_app.help_scroll < 0 { g_app.help_scroll = 0 }
	for i in 0..<visible {
		idx := g_app.help_scroll + i
		if idx >= len(HELP_TEXT) { break }
		line := HELP_TEXT[idx]
		if len(line) > w-4 { line = line[:w-4] }
		fg := Color.Black
		if len(line) >= 2 && line[0] >= 'A' && line[0] <= 'Z' && line[1] >= 'A' && line[1] <= 'Z' {
			fg = .Blue
			screen_text(s, x+2, y+1+i, line, fg, .BrightWhite, {.Bold})
		} else {
			screen_text(s, x+2, y+1+i, line, fg, .BrightWhite)
		}
	}
	// scrollbar hint at right edge
	if max_scroll > 0 {
		bar_h := visible
		thumb_y := int(f32(g_app.help_scroll) / f32(max_scroll) * f32(bar_h-1))
		for i in 0..<bar_h {
			ch: rune = '│'
			if i == thumb_y { ch = '█' }
			screen_put(s, x+w-2, y+1+i, Cell{r=ch, fg=.Blue, bg=.BrightWhite})
		}
	}
}

help_handle_key :: proc(e: Key_Event) {
	visible := g_app.height - 4 - 2
	if visible < 1 { visible = 1 }
	#partial switch e.key {
	case .Escape, .F1:
		g_app.help_open = false
		g_app.help_scroll = 0
		return
	case .Up:        g_app.help_scroll -= 1; return
	case .Down:      g_app.help_scroll += 1; return
	case .PageUp:    g_app.help_scroll -= visible; return
	case .PageDown:  g_app.help_scroll += visible; return
	case .Home:      g_app.help_scroll = 0; return
	case .End:       g_app.help_scroll = len(HELP_TEXT); return
	case .Char:
		if e.ch == '?' && .Ctrl in e.mods {
			g_app.help_open = false
			return
		}
		if e.ch == 'q' || e.ch == 'Q' {
			g_app.help_open = false
			return
		}
	}
}
