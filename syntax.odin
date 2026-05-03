package editor

Token_Kind :: enum u8 {
	Text, Keyword, Type, Builtin, Number, String, Char, Comment, Preproc, Operator, Function, FunctionDef,
}

token_color :: proc(t: Token_Kind) -> Color {
	switch t {
	case .Text:        return .Default
	case .Keyword:     return .BrightBlue
	case .Type:        return .BrightCyan
	case .Builtin:     return .BrightCyan
	case .Number:      return .BrightYellow
	case .String:      return .Green
	case .Char:        return .Green
	case .Comment:     return .BrightGreen
	case .Preproc:     return .Yellow
	case .Operator:    return .BrightWhite
	case .Function:    return .Orange
	case .FunctionDef: return .Gray
	}
	return .Default
}

token_style :: proc(t: Token_Kind) -> Style {
	#partial switch t {
	case .Function:    return {.Bold}
	case .FunctionDef: return {.Bold}
	case .Comment:     return {.Italic}
	case .Keyword:     return {.Bold}
	}
	return {}
}

// Multi-line state carried row to row.
Lex_State :: enum u8 {
	Normal,
	BlockComment,
	StringDQ,
	StringSQ,
	StringRaw,
	StringTriple,
}

// Per-line array of token spans. Each cell maps a column to a token kind.
// We tokenize on demand: produce []Token_Kind length = len(line).
Token_Line :: struct {
	kinds:    []Token_Kind,
	end_state: Lex_State,
}

// Cache: per buffer we keep states and per-line kinds (lazy).
// For simplicity: re-tokenize the whole buffer from row 0 to last visible.
// For typical files this is fast enough.

highlight_buffer :: proc(b: ^Buffer, up_to_row: int) -> [][]Token_Kind {
	n := up_to_row + 1
	if n > len(b.lines) { n = len(b.lines) }
	out := make([][]Token_Kind, n)
	state := Lex_State.Normal
	for r in 0..<n {
		line := b.lines[r][:]
		k, st := tokenize_line(b.lang, line, state)
		out[r] = k
		state = st
	}
	return out
}

tokenize_line :: proc(lang: Language, line: []u8, in_state: Lex_State) -> ([]Token_Kind, Lex_State) {
	kinds := make([]Token_Kind, len(line))
	st := in_state
	switch lang {
	case .C, .Cpp:        st = lex_c_like(line, kinds, st, lang == .Cpp)
	case .Odin:           st = lex_odin(line, kinds, st)
	case .Python:         st = lex_python(line, kinds, st)
	case .Shell:          st = lex_shell(line, kinds, st)
	case .JSON:           st = lex_json(line, kinds, st)
	case .Markdown:       st = lex_markdown(line, kinds, st)
	case .Make:           st = lex_make(line, kinds, st)
	case .HTML:           // simple
		for i in 0..<len(line) { kinds[i] = .Text }
	case .Text, .None:
		// nothing
	}
	return kinds, st
}

paint_range :: proc(kinds: []Token_Kind, start, end: int, t: Token_Kind) {
	for i in start..<end { if i < len(kinds) { kinds[i] = t } }
}

is_alpha_ :: proc(c: u8) -> bool {
	return (c>='a'&&c<='z')||(c>='A'&&c<='Z')||c=='_'
}
is_alnum_ :: proc(c: u8) -> bool {
	return is_alpha_(c) || (c>='0'&&c<='9')
}
is_digit :: proc(c: u8) -> bool { return c>='0'&&c<='9' }

// ----- C / C++ -----

C_KW := []string{
	"if","else","while","for","do","switch","case","default","break","continue","return",
	"goto","sizeof","typedef","struct","union","enum","extern","static","const","volatile",
	"register","inline","restrict","auto","_Bool","_Complex","_Imaginary","_Atomic",
	"_Noreturn","_Alignas","_Alignof","_Generic","_Static_assert","_Thread_local",
}
CPP_KW := []string{
	"class","public","private","protected","virtual","override","final","new","delete",
	"this","template","typename","namespace","using","try","catch","throw","operator",
	"explicit","friend","mutable","constexpr","noexcept","nullptr","true","false",
	"and","or","not","xor","decltype","static_cast","dynamic_cast","reinterpret_cast",
	"const_cast","co_await","co_yield","co_return","concept","requires","consteval",
	"constinit","import","module","export",
}
C_TYPES := []string{
	"void","char","short","int","long","float","double","signed","unsigned",
	"size_t","ssize_t","ptrdiff_t","intptr_t","uintptr_t","FILE","NULL",
	"int8_t","int16_t","int32_t","int64_t","uint8_t","uint16_t","uint32_t","uint64_t",
	"bool",
}

word_in :: proc(line: []u8, start, end: int, set: []string) -> bool {
	w := string(line[start:end])
	for s in set { if s == w { return true } }
	return false
}

lex_c_like :: proc(line: []u8, kinds: []Token_Kind, in_state: Lex_State, cpp: bool) -> Lex_State {
	st := in_state
	i := 0
	n := len(line)
	if st == .BlockComment {
		j := i
		for j < n {
			if j+1 < n && line[j]=='*' && line[j+1]=='/' {
				paint_range(kinds, i, j+2, .Comment)
				i = j+2
				st = .Normal
				break
			}
			j += 1
		}
		if st == .BlockComment { paint_range(kinds, i, n, .Comment); return st }
	}
	for i < n {
		c := line[i]
		// preprocessor (only if first non-space char is #)
		if c == '#' {
			only_space := true
			for k in 0..<i { if line[k] != ' ' && line[k] != '\t' { only_space = false; break } }
			if only_space {
				paint_range(kinds, i, n, .Preproc)
				return st
			}
		}
		if c == '/' && i+1 < n && line[i+1] == '/' {
			paint_range(kinds, i, n, .Comment); return st
		}
		if c == '/' && i+1 < n && line[i+1] == '*' {
			j := i+2
			closed := false
			for j < n {
				if j+1 < n && line[j]=='*' && line[j+1]=='/' {
					paint_range(kinds, i, j+2, .Comment)
					i = j+2
					closed = true
					break
				}
				j += 1
			}
			if closed { continue }
			paint_range(kinds, i, n, .Comment)
			return .BlockComment
		}
		if c == '"' {
			j := i+1
			for j < n {
				if line[j] == '\\' && j+1 < n { j += 2; continue }
				if line[j] == '"' { j += 1; break }
				j += 1
			}
			paint_range(kinds, i, j, .String)
			i = j
			continue
		}
		if c == '\'' {
			j := i+1
			for j < n {
				if line[j] == '\\' && j+1 < n { j += 2; continue }
				if line[j] == '\'' { j += 1; break }
				j += 1
			}
			paint_range(kinds, i, j, .Char)
			i = j
			continue
		}
		if is_digit(c) || (c == '.' && i+1 < n && is_digit(line[i+1])) {
			j := i
			for j < n && (is_alnum_(line[j]) || line[j]=='.') { j += 1 }
			paint_range(kinds, i, j, .Number)
			i = j
			continue
		}
		if is_alpha_(c) {
			j := i
			for j < n && is_alnum_(line[j]) { j += 1 }
			if word_in(line, i, j, C_KW) || (cpp && word_in(line, i, j, CPP_KW)) {
				paint_range(kinds, i, j, .Keyword)
			} else if word_in(line, i, j, C_TYPES) {
				paint_range(kinds, i, j, .Type)
			} else {
				// detect function call vs definition: identifier followed by (
				k := j
				for k < n && (line[k]==' '||line[k]=='\t') { k += 1 }
				if k < n && line[k]=='(' {
					if c_like_is_funcdef(line, i) {
						paint_range(kinds, i, j, .FunctionDef)
					} else {
						paint_range(kinds, i, j, .Function)
					}
				} else {
					paint_range(kinds, i, j, .Text)
				}
			}
			i = j
			continue
		}
		if is_op_byte(c) {
			kinds[i] = .Operator
		} else {
			kinds[i] = .Text
		}
		i += 1
	}
	return st
}

is_op_byte :: proc(c: u8) -> bool {
	switch c {
	case '+','-','*','/','%','=','<','>','!','&','|','^','~','?',':',';',',','(',')','{','}','[',']','.':
		return true
	}
	return false
}

// ----- Odin -----

ODIN_KW := []string{
	"package","import","foreign","when","if","else","for","switch","case","do","break","continue",
	"return","defer","fallthrough","proc","using","in","not_in","or_else","or_return","or_break",
	"or_continue","map","struct","union","enum","bit_set","bit_field","cast","transmute",
	"auto_cast","distinct","dynamic","typeid","context","matrix","where","nil","true","false",
	"size_of","align_of","offset_of","type_of","len","cap","make","new","delete","copy","append",
	"clear","resize","reserve","raw_data","swizzle","abs","min","max","clamp","real","imag",
	"jmag","kmag","conj","expand_values","quaternion","complex","unroll",
}
ODIN_TYPES := []string{
	"int","uint","i8","i16","i32","i64","i128","u8","u16","u32","u64","u128","uintptr","rune",
	"f16","f32","f64","string","cstring","bool","b8","b16","b32","b64","byte","rawptr",
	"any","i16le","i32le","i64le","u16le","u32le","u64le","i16be","i32be","i64be","u16be",
	"u32be","u64be","f16le","f32le","f64le","f16be","f32be","f64be","complex32","complex64",
	"complex128","quaternion64","quaternion128","quaternion256",
}

lex_odin :: proc(line: []u8, kinds: []Token_Kind, in_state: Lex_State) -> Lex_State {
	st := in_state
	i := 0
	n := len(line)
	if st == .BlockComment {
		j := i
		depth := 1
		for j < n {
			if j+1<n && line[j]=='/' && line[j+1]=='*' { depth += 1; j+=2; continue }
			if j+1<n && line[j]=='*' && line[j+1]=='/' {
				depth -= 1; j+=2
				if depth == 0 { paint_range(kinds, i, j, .Comment); i = j; st = .Normal; break }
				continue
			}
			j += 1
		}
		if st == .BlockComment { paint_range(kinds, i, n, .Comment); return st }
	}
	for i < n {
		c := line[i]
		if c=='/' && i+1<n && line[i+1]=='/' { paint_range(kinds, i, n, .Comment); return st }
		if c=='/' && i+1<n && line[i+1]=='*' {
			j := i+2; depth := 1
			for j < n {
				if j+1<n && line[j]=='/' && line[j+1]=='*' { depth+=1; j+=2; continue }
				if j+1<n && line[j]=='*' && line[j+1]=='/' { depth-=1; j+=2; if depth==0 { break }; continue }
				j += 1
			}
			if depth == 0 {
				paint_range(kinds, i, j, .Comment); i = j; continue
			}
			paint_range(kinds, i, n, .Comment); return .BlockComment
		}
		if c == '"' {
			j := i+1
			for j < n {
				if line[j] == '\\' && j+1 < n { j+=2; continue }
				if line[j] == '"' { j+=1; break }
				j += 1
			}
			paint_range(kinds, i, j, .String); i = j; continue
		}
		if c == '`' {
			j := i+1
			for j < n {
				if line[j] == '`' { j+=1; break }
				j += 1
			}
			paint_range(kinds, i, j, .String); i = j; continue
		}
		if c == '\'' {
			j := i+1
			for j < n {
				if line[j] == '\\' && j+1 < n { j+=2; continue }
				if line[j] == '\'' { j+=1; break }
				j += 1
			}
			paint_range(kinds, i, j, .Char); i = j; continue
		}
		if is_digit(c) {
			j := i
			for j < n && (is_alnum_(line[j]) || line[j]=='.') { j += 1 }
			paint_range(kinds, i, j, .Number); i = j; continue
		}
		if is_alpha_(c) {
			j := i
			for j < n && is_alnum_(line[j]) { j += 1 }
			if word_in(line, i, j, ODIN_KW) {
				paint_range(kinds, i, j, .Keyword)
			} else if word_in(line, i, j, ODIN_TYPES) {
				paint_range(kinds, i, j, .Type)
			} else {
				// Odin function definition: `name :: proc` (or `:: #force_inline proc`)
				k := j
				for k < n && (line[k]==' '||line[k]=='\t') { k += 1 }
				if k+1 < n && line[k]==':' && line[k+1]==':' {
					m := k + 2
					for m < n && (line[m]==' '||line[m]=='\t') { m += 1 }
					// optional directives like #force_inline
					if m < n && line[m] == '#' {
						for m < n && (is_alnum_(line[m]) || line[m]=='#') { m += 1 }
						for m < n && (line[m]==' '||line[m]=='\t') { m += 1 }
					}
					if m+4 <= n && string(line[m:m+4]) == "proc" && (m+4 == n || !is_alnum_(line[m+4])) {
						paint_range(kinds, i, j, .FunctionDef)
						i = j
						continue
					}
				}
				if k < n && line[k]=='(' {
					paint_range(kinds, i, j, .Function)
				} else {
					paint_range(kinds, i, j, .Text)
				}
			}
			i = j
			continue
		}
		if c == '@' {
			j := i+1
			for j < n && is_alnum_(line[j]) { j += 1 }
			paint_range(kinds, i, j, .Preproc); i = j; continue
		}
		if is_op_byte(c) { kinds[i] = .Operator } else { kinds[i] = .Text }
		i += 1
	}
	return st
}

// ----- Python -----

PY_KW := []string{
	"False","None","True","and","as","assert","async","await","break","class","continue","def",
	"del","elif","else","except","finally","for","from","global","if","import","in","is",
	"lambda","nonlocal","not","or","pass","raise","return","try","while","with","yield","match","case",
}
PY_BUILTIN := []string{
	"print","len","range","int","str","float","list","dict","set","tuple","bool","bytes","bytearray",
	"open","input","abs","min","max","sum","map","filter","zip","sorted","reversed","enumerate",
	"isinstance","issubclass","type","id","hash","repr","format","getattr","setattr","hasattr",
	"delattr","callable","iter","next","object","super","self","cls",
}

lex_python :: proc(line: []u8, kinds: []Token_Kind, in_state: Lex_State) -> Lex_State {
	st := in_state
	i := 0
	n := len(line)
	expect_def := false  // next identifier is a function/class name being defined
	if st == .StringTriple {
		j := i
		for j < n {
			if j+2<n && line[j]=='"' && line[j+1]=='"' && line[j+2]=='"' {
				paint_range(kinds, i, j+3, .String); i = j+3; st = .Normal; break
			}
			j += 1
		}
		if st == .StringTriple { paint_range(kinds, i, n, .String); return st }
	}
	for i < n {
		c := line[i]
		if c == '#' { paint_range(kinds, i, n, .Comment); return st }
		if i+2<n && c=='"' && line[i+1]=='"' && line[i+2]=='"' {
			j := i+3
			closed := false
			for j < n {
				if j+2<n && line[j]=='"' && line[j+1]=='"' && line[j+2]=='"' {
					paint_range(kinds, i, j+3, .String); i = j+3; closed = true; break
				}
				j += 1
			}
			if closed { continue }
			paint_range(kinds, i, n, .String); return .StringTriple
		}
		if c == '"' || c == '\'' {
			q := c
			j := i+1
			for j < n {
				if line[j]=='\\' && j+1<n { j+=2; continue }
				if line[j]==q { j+=1; break }
				j += 1
			}
			paint_range(kinds, i, j, .String); i = j; continue
		}
		if is_digit(c) {
			j := i
			for j < n && (is_alnum_(line[j]) || line[j]=='.') { j += 1 }
			paint_range(kinds, i, j, .Number); i = j; continue
		}
		if is_alpha_(c) {
			j := i
			for j < n && is_alnum_(line[j]) { j += 1 }
			if word_in(line, i, j, PY_KW) {
				paint_range(kinds, i, j, .Keyword)
				w := string(line[i:j])
				expect_def = (w == "def" || w == "class")
			} else if word_in(line, i, j, PY_BUILTIN) {
				paint_range(kinds, i, j, .Builtin)
				expect_def = false
			} else {
				k := j
				for k < n && (line[k]==' '||line[k]=='\t') { k += 1 }
				if expect_def {
					paint_range(kinds, i, j, .FunctionDef)
					expect_def = false
				} else if k < n && line[k]=='(' {
					paint_range(kinds, i, j, .Function)
				} else {
					paint_range(kinds, i, j, .Text)
				}
			}
			i = j
			continue
		}
		if c == '@' {
			j := i+1
			for j < n && is_alnum_(line[j]) { j += 1 }
			paint_range(kinds, i, j, .Preproc); i = j; continue
		}
		if is_op_byte(c) { kinds[i] = .Operator } else { kinds[i] = .Text }
		i += 1
	}
	return st
}

// ----- Shell -----

SH_KW := []string{
	"if","then","else","elif","fi","for","in","do","done","while","until","case","esac",
	"function","return","break","continue","local","export","readonly","unset","shift","exit",
	"set","alias","unalias","trap","echo","printf","read","cd","pwd","source",
}

lex_shell :: proc(line: []u8, kinds: []Token_Kind, in_state: Lex_State) -> Lex_State {
	st := in_state
	i := 0
	n := len(line)
	expect_def := false
	for i < n {
		c := line[i]
		if c == '#' { paint_range(kinds, i, n, .Comment); return st }
		if c == '"' || c == '\'' {
			q := c
			j := i+1
			for j < n {
				if line[j]=='\\' && j+1<n && q=='"' { j+=2; continue }
				if line[j]==q { j+=1; break }
				j += 1
			}
			paint_range(kinds, i, j, .String); i = j; continue
		}
		if c == '$' {
			j := i+1
			if j < n && line[j]=='{' {
				for j < n && line[j] != '}' { j += 1 }
				if j < n { j += 1 }
			} else {
				for j < n && is_alnum_(line[j]) { j += 1 }
			}
			paint_range(kinds, i, j, .Preproc); i = j; continue
		}
		if is_alpha_(c) {
			j := i
			for j < n && is_alnum_(line[j]) { j += 1 }
			if word_in(line, i, j, SH_KW) {
				paint_range(kinds, i, j, .Keyword)
				expect_def = (string(line[i:j]) == "function")
			} else {
				// `name()` directly (no space between identifier and `()`) is
				// a shell function definition: foo() { ... }
				is_def := expect_def
				if !is_def && j+1 < n && line[j]=='(' && line[j+1]==')' {
					is_def = true
				}
				if is_def {
					paint_range(kinds, i, j, .FunctionDef)
				} else {
					paint_range(kinds, i, j, .Text)
				}
				expect_def = false
			}
			i = j; continue
		}
		if is_digit(c) {
			j := i
			for j < n && is_alnum_(line[j]) { j += 1 }
			paint_range(kinds, i, j, .Number); i = j; continue
		}
		if is_op_byte(c) || c=='\\' { kinds[i] = .Operator } else { kinds[i] = .Text }
		i += 1
	}
	return st
}

// ----- JSON -----

lex_json :: proc(line: []u8, kinds: []Token_Kind, in_state: Lex_State) -> Lex_State {
	st := in_state
	i := 0
	n := len(line)
	for i < n {
		c := line[i]
		if c == '"' {
			j := i+1
			for j < n {
				if line[j]=='\\' && j+1<n { j+=2; continue }
				if line[j]=='"' { j+=1; break }
				j += 1
			}
			paint_range(kinds, i, j, .String); i = j; continue
		}
		if is_digit(c) || c=='-' {
			j := i
			for j < n && (is_alnum_(line[j])||line[j]=='.'||line[j]=='-'||line[j]=='+') { j += 1 }
			paint_range(kinds, i, j, .Number); i = j; continue
		}
		if is_alpha_(c) {
			j := i
			for j < n && is_alnum_(line[j]) { j += 1 }
			w := string(line[i:j])
			if w=="true" || w=="false" || w=="null" { paint_range(kinds, i, j, .Keyword) }
			else { paint_range(kinds, i, j, .Text) }
			i = j; continue
		}
		if is_op_byte(c) { kinds[i] = .Operator } else { kinds[i] = .Text }
		i += 1
	}
	return st
}

// ----- Makefile -----

MAKE_KW := []string{
	"include","sinclude","-include","ifeq","ifneq","ifdef","ifndef","else","endif",
	"define","endef","export","unexport","override","private","vpath","undefine",
}
MAKE_FN := []string{
	"subst","patsubst","strip","findstring","filter","filter-out","sort","word",
	"wordlist","words","firstword","lastword","dir","notdir","suffix","basename",
	"addsuffix","addprefix","join","wildcard","realpath","abspath","if","or","and",
	"foreach","call","value","eval","origin","flavor","shell","error","warning","info",
}

lex_make :: proc(line: []u8, kinds: []Token_Kind, in_state: Lex_State) -> Lex_State {
	n := len(line)
	if n == 0 { return in_state }
	// recipe lines start with TAB
	if line[0] == '\t' {
		// shell-style highlight, but treat $(...) and ${...} as variables
		paint_range(kinds, 0, n, .Text)
		i := 0
		for i < n {
			c := line[i]
			if c == '#' { paint_range(kinds, i, n, .Comment); return in_state }
			if c == '$' && i+1 < n {
				j := i+1
				if line[j] == '(' || line[j] == '{' {
					closer: u8 = ')' if line[j]=='(' else '}'
					k := j+1
					for k < n && line[k] != closer { k += 1 }
					if k < n { k += 1 }
					paint_range(kinds, i, k, .Preproc); i = k; continue
				}
				paint_range(kinds, i, j+1, .Preproc); i = j+1; continue
			}
			if c == '"' || c == '\'' {
				q := c; j := i+1
				for j < n {
					if line[j]=='\\' && j+1<n { j+=2; continue }
					if line[j]==q { j+=1; break }
					j += 1
				}
				paint_range(kinds, i, j, .String); i = j; continue
			}
			i += 1
		}
		return in_state
	}
	i := 0
	// comment
	for i < n && (line[i]==' ') { i += 1 }
	if i < n && line[i] == '#' { paint_range(kinds, i, n, .Comment); return in_state }
	i = 0
	// variable assignment / target detection
	// find ':' (not '::=', '?=', '+=', ':=' etc.) — first colon is target separator
	// or '=' for assignment
	colon := -1
	eq := -1
	for j in 0..<n {
		c := line[j]
		if (c == '=' || (c == ':' && j+1<n && line[j+1]=='=') ||
		    (c == '?' && j+1<n && line[j+1]=='=') ||
		    (c == '+' && j+1<n && line[j+1]=='=')) && eq < 0 {
			eq = j; break
		}
		if c == ':' && colon < 0 { colon = j }
	}
	for i < n {
		c := line[i]
		if c == '#' { paint_range(kinds, i, n, .Comment); return in_state }
		if c == '$' && i+1 < n {
			j := i+1
			if line[j] == '(' || line[j] == '{' {
				closer: u8 = ')' if line[j]=='(' else '}'
				k := j+1
				// also check function call
				name_start := k
				for k < n && (is_alnum_(line[k]) || line[k]=='-') { k += 1 }
				if k < n && line[k]==' ' && word_in(line, name_start, k, MAKE_FN) {
					paint_range(kinds, i, k, .Function)
					// rest until matching closer
					depth := 1
					for k < n && depth > 0 {
						if line[k] == '(' || line[k] == '{' { depth += 1 }
						else if line[k] == ')' || line[k] == '}' { depth -= 1; if depth==0 { k+=1; break } }
						k += 1
					}
					i = k; continue
				}
				// variable
				k = j+1
				for k < n && line[k] != closer { k += 1 }
				if k < n { k += 1 }
				paint_range(kinds, i, k, .Preproc); i = k; continue
			}
			paint_range(kinds, i, j+1, .Preproc); i = j+1; continue
		}
		if is_alpha_(c) {
			j := i
			for j < n && (is_alnum_(line[j]) || line[j]=='-') { j += 1 }
			// keyword?
			if word_in(line, i, j, MAKE_KW) {
				paint_range(kinds, i, j, .Keyword)
			} else if eq >= 0 && i < eq {
				paint_range(kinds, i, j, .Type)  // variable name LHS
			} else if colon >= 0 && i < colon {
				paint_range(kinds, i, j, .FunctionDef) // target name (definition)
			} else {
				paint_range(kinds, i, j, .Text)
			}
			i = j; continue
		}
		if c == ':' || c == '=' { kinds[i] = .Operator; i += 1; continue }
		if is_op_byte(c) { kinds[i] = .Operator } else { kinds[i] = .Text }
		i += 1
	}
	return in_state
}

lex_markdown :: proc(line: []u8, kinds: []Token_Kind, in_state: Lex_State) -> Lex_State {
	st := in_state
	for i in 0..<len(line) { kinds[i] = .Text }
	n := len(line)

	// Fenced code block (``` or ~~~). Track via StringTriple state.
	is_fence := false
	if n >= 3 {
		if (line[0]=='`' && line[1]=='`' && line[2]=='`') ||
		   (line[0]=='~' && line[1]=='~' && line[2]=='~') {
			is_fence = true
		}
	}
	if is_fence {
		paint_range(kinds, 0, n, .Preproc)
		if st == .StringTriple { return .Normal }
		return .StringTriple
	}
	if st == .StringTriple {
		paint_range(kinds, 0, n, .String)
		return st
	}

	// Skip leading whitespace
	i := 0
	for i < n && (line[i]==' ' || line[i]=='\t') { i += 1 }

	// Headings: # .. ###### at line start (after optional spaces)
	if i < n && line[i] == '#' {
		j := i
		hashes := 0
		for j < n && line[j] == '#' && hashes < 6 { j += 1; hashes += 1 }
		if j < n && line[j] == ' ' {
			paint_range(kinds, 0, n, .Keyword)
			return .Normal
		}
	}

	// Blockquote: starts with '>'
	if i < n && line[i] == '>' {
		paint_range(kinds, i, n, .Comment)
		// keep going to also paint inline emphasis below
	}

	// Horizontal rule: --- *** ___ alone
	if n - i >= 3 {
		c := line[i]
		if c == '-' || c == '*' || c == '_' {
			ok := true
			cnt := 0
			for k := i; k < n; k += 1 {
				if line[k] == c { cnt += 1 }
				else if line[k] == ' ' || line[k] == '\t' { /* ok */ }
				else { ok = false; break }
			}
			if ok && cnt >= 3 {
				paint_range(kinds, 0, n, .Preproc)
				return .Normal
			}
		}
	}

	// List markers: -, *, +, or 1. 2. ...
	if i < n {
		c := line[i]
		if (c == '-' || c == '*' || c == '+') && i+1 < n && line[i+1] == ' ' {
			kinds[i] = .Keyword
		} else if c >= '0' && c <= '9' {
			j := i
			for j < n && line[j] >= '0' && line[j] <= '9' { j += 1 }
			if j < n && line[j] == '.' && j+1 < n && line[j+1] == ' ' {
				paint_range(kinds, i, j+1, .Keyword)
			}
		}
	}

	// Inline scan: `code`, **bold**, *italic*, _italic_, [text](url), images, links
	k := 0
	for k < n {
		c := line[k]
		switch c {
		case '`':
			// inline code till next backtick
			start := k
			k += 1
			for k < n && line[k] != '`' { k += 1 }
			if k < n { k += 1 }
			paint_range(kinds, start, k, .String)
		case '*', '_':
			start := k
			marker := c
			run := 1
			k += 1
			if k < n && line[k] == marker { run = 2; k += 1 }
			// find closing run
			closed := false
			for k < n {
				if line[k] == marker {
					rr := 0
					kk := k
					for kk < n && line[kk] == marker && rr < run { kk += 1; rr += 1 }
					if rr == run { k = kk; closed = true; break }
				}
				k += 1
			}
			if closed {
				tk := Token_Kind.Type if run == 2 else Token_Kind.Builtin
				paint_range(kinds, start, k, tk)
			}
		case '[':
			start := k
			k += 1
			for k < n && line[k] != ']' { k += 1 }
			if k < n { k += 1 }
			paint_range(kinds, start, k, .Function)
			if k < n && line[k] == '(' {
				url_start := k
				for k < n && line[k] != ')' { k += 1 }
				if k < n { k += 1 }
				paint_range(kinds, url_start, k, .String)
			}
		case '!':
			if k+1 < n && line[k+1] == '[' {
				kinds[k] = .Function
			}
			k += 1
		case:
			k += 1
		}
	}
	return .Normal
}

// Heuristic: in C/C++/Java-like languages, decide whether the identifier
// at byte `name_start` (which is followed by `(`) is a function DEFINITION
// or a function CALL.
//
// A definition has only return-type tokens between column 0 and the name:
// identifier characters, '*', '&', spaces and tabs. Anything else (operator,
// '(', ',', digit, string quote …) means we are inside an expression — it's
// a call. We also require at least one non-space char before the name so
// that a bare `foo(` at column 0 (most likely a call/macro use) stays a
// call.
c_like_is_funcdef :: proc(line: []u8, name_start: int) -> bool {
saw_token := false
for k := name_start - 1; k >= 0; k -= 1 {
c := line[k]
if c == ' ' || c == '\t' { continue }
if is_alnum_(c) || c == '*' || c == '&' {
saw_token = true
continue
}
return false
}
return saw_token
}
