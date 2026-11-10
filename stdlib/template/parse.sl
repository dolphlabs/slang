// Parsing: text and {{ actions }} into a tree.
//
//   {{ .a.b }}  {{ . }}  {{ $x }}  {{ $x.name }}       values
//   {{ .name | upper }}  {{ default "none" .nick }}     pipelines and calls
//   {{ if .x }} … {{ else if .y }} … {{ else }} … {{ end }}
//   {{ range .items }} … {{ else }} … {{ end }}         . is the element
//   {{ range $i, $x := .items }} … {{ end }}
//   {{ with .user }} … {{ else }} … {{ end }}
//   {{ define "name" }} … {{ end }}   {{ template "name" .x }}
//   {{/* a comment */}}   {{- and -}} trim the whitespace beside them

import "strings";

let N_TEXT = 0;
let N_OUT = 1;
let N_IF = 2;
let N_RANGE = 3;
let N_WITH = 4;
let N_CALL = 5;
let N_SET = 6;     // {{ $x := pipeline }} or {{ $x = pipeline }}: no output

let A_DOT = 0;      // . or .a.b
let A_VAR = 1;      // $x or $x.a
let A_STR = 2;
let A_NUM = 3;
let A_BOOL = 4;
let A_FUNC = 5;     // an identifier: a function name
let A_NULL = 6;
let A_SUB = 7;      // ( pipeline ) or ( pipeline ).a.b

// The template functions, by id: a call names its function once, at
// parse time, and running it dispatches on the id.
let F_EQ = 0;
let F_NE = 1;
let F_LT = 2;
let F_LE = 3;
let F_GT = 4;
let F_GE = 5;
let F_AND = 6;
let F_OR = 7;
let F_NOT = 8;
let F_LEN = 9;
let F_UPPER = 10;
let F_LOWER = 11;
let F_TRIM = 12;
let F_DEFAULT = 13;
let F_JOIN = 14;
let F_INDEX = 15;
let F_ADD = 16;
let F_SUB = 17;
let F_JSON = 18;
let F_URLQUERY = 19;
let F_RAW = 20;
let F_PRINT = 21;
let F_PRINTF = 22;

fn func_names() -> str {
    return "eq ne lt le gt ge and or not len upper lower trim default join index add sub json urlquery raw print printf";
}

fn func_id(name: str) -> int {
    return switch name {
        case "eq" { 0 }
        case "ne" { 1 }
        case "lt" { 2 }
        case "le" { 3 }
        case "gt" { 4 }
        case "ge" { 5 }
        case "and" { 6 }
        case "or" { 7 }
        case "not" { 8 }
        case "len" { 9 }
        case "upper" { 10 }
        case "lower" { 11 }
        case "trim" { 12 }
        case "default" { 13 }
        case "join" { 14 }
        case "index" { 15 }
        case "add" { 16 }
        case "sub" { 17 }
        case "json" { 18 }
        case "urlquery" { 19 }
        case "raw" { 20 }
        case "print" { 21 }
        case "printf" { 22 }
        default { -1 }
    };
}

gc struct Arg {
    kind: int,
    path: [str],
    name: str,
    text: str,
    b: bool,
    // path's names as bytes, made once for in-place key comparison
    keys: [bytes],
    // A_VAR: the variable's slot in the frame; A_FUNC: the function's
    // id (F_*); both resolved at parse time
    slot: int,
    // A_SUB: the parenthesised pipeline (one element)
    sub: [Pipe],
}

gc struct Cmd {
    args: [Arg],
}

gc struct Pipe {
    cmds: [Cmd],
}

gc struct Node {
    kind: int,
    line: int,
    text: str,
    pipe: Pipe,
    body: [Node],
    alt: [Node],
    // N_RANGE: the frame slots of $i and $x, or -1 for none;
    // N_SET: slot_val is the variable's slot
    slot_key: int,
    slot_val: int,
    // N_CALL: the template's name
    name: str,
    // the escaping context of an N_OUT, set by the escaper
    ctx: int,
}

fn new_node(kind: int, line: int) -> Node {
    return Node { kind: kind, line: line, text: "", pipe: Pipe { cmds: [] }, body: [], alt: [],
                  slot_key: -1, slot_val: -1, name: "", ctx: 0 };
}

// ---- lexing ------------------------------------------------------------------------

// A piece of the source: literal text, or one action's inside.
gc struct Piece {
    is_action: bool,
    text: str,
    line: int,
}

fn split_pieces(name: str, src: str) -> result[[Piece], str] {
    let b = to_bytes(src);
    let out: [Piece] = [];
    let i = 0;
    let line = 1;
    let text_start = 0;
    let trim_next = false;
    while i < len(b) {
        if i + 1 < len(b) && b[i] == 123 && b[i + 1] == 123 {
            // literal text up to here, trimmed on the right by {{-
            let close = find_close(b, i + 2);
            if close < 0 {
                let at = line;
                for k in text_start..i {
                    if b[k] == 10 { at += 1; }
                }
                return err("template " + name + ":" + to_str(at) + ": unclosed {{");
            }
            let inner_start = i + 2;
            let inner_end = close;
            let trim_left = inner_start < inner_end && b[inner_start] == 45 &&
                            inner_start + 1 < inner_end && is_space(b[inner_start + 1]);
            let trim_right = inner_end - 1 >= inner_start && b[inner_end - 1] == 45 &&
                             inner_end - 2 >= inner_start && is_space(b[inner_end - 2]);
            let t_end = i;
            if trim_left {
                while t_end > text_start && is_space(b[t_end - 1]) {
                    t_end -= 1;
                }
                inner_start += 1;
            }
            let t_start = text_start;
            if trim_next {
                while t_start < t_end && is_space(b[t_start]) {
                    t_start += 1;
                }
            }
            if t_end > t_start {
                push(out, Piece { is_action: false, text: strings.from_bytes(b, t_start, t_end), line: line });
            }
            for k in text_start..i {
                if b[k] == 10 { line += 1; }
            }
            if trim_right {
                inner_end -= 1;
            }
            let inner = strings.trim(strings.from_bytes(b, inner_start, inner_end));
            if !(strings.has_prefix(inner, "/*") && strings.has_suffix(inner, "*/")) {
                push(out, Piece { is_action: true, text: inner, line: line });
            }
            for k in i..close {
                if b[k] == 10 { line += 1; }
            }
            i = close + 2;
            text_start = i;
            trim_next = trim_right;
            continue;
        }
        i += 1;
    }
    let t_start = text_start;
    if trim_next {
        while t_start < len(b) && is_space(b[t_start]) {
            t_start += 1;
        }
    }
    if t_start < len(b) {
        push(out, Piece { is_action: false, text: strings.from_bytes(b, t_start, len(b)), line: line });
    }
    return ok(out);
}

fn is_space(c: int) -> bool {
    return c == 32 || c == 9 || c == 10 || c == 13;
}

// The index of the }} closing an action from i, skipping quoted strings.
fn find_close(b: bytes, from: int) -> int {
    let i = from;
    while i + 1 < len(b) {
        let c = b[i];
        if c == 34 || c == 96 {
            let q = c;
            i += 1;
            while i < len(b) && b[i] != q {
                if b[i] == 92 && q == 34 { i += 1; }
                i += 1;
            }
            i += 1;
            continue;
        }
        if c == 125 && b[i + 1] == 125 {
            return i;
        }
        i += 1;
    }
    return -1;
}

// Words of an action: identifiers, .paths, $vars, "strings", numbers,
// and the punctuation | := , ( ). A field path written straight after a
// closing parenthesis comes out as one word, ").a.b", so the parser can
// tell (x).a from (x) .a.
fn words(s: str) -> result[[str], str] {
    let b = to_bytes(s);
    let out: [str] = [];
    let i = 0;
    while i < len(b) {
        let c = b[i];
        if is_space(c) {
            i += 1;
            continue;
        }
        if c == 34 || c == 96 {
            let q = c;
            let start = i;
            i += 1;
            while i < len(b) && b[i] != q {
                if b[i] == 92 && q == 34 { i += 1; }
                i += 1;
            }
            if i >= len(b) {
                return err("unterminated string");
            }
            i += 1;
            push(out, strings.from_bytes(b, start, i));
            continue;
        }
        if c == 41 && i + 2 < len(b) && b[i + 1] == 46 && !is_space(b[i + 2]) {
            let start = i;
            i += 1;
            while i < len(b) && !is_space(b[i]) && b[i] != 124 && b[i] != 44 && b[i] != 40 && b[i] != 41 {
                i += 1;
            }
            push(out, strings.from_bytes(b, start, i));
            continue;
        }
        if c == 124 || c == 44 || c == 40 || c == 41 {
            push(out, strings.from_bytes(b, i, i + 1));
            i += 1;
            continue;
        }
        if c == 58 && i + 1 < len(b) && b[i + 1] == 61 {
            push(out, ":=");
            i += 2;
            continue;
        }
        let start = i;
        while i < len(b) && !is_space(b[i]) && b[i] != 124 && b[i] != 44 && b[i] != 40 &&
              b[i] != 41 && !(b[i] == 58 && i + 1 < len(b) && b[i + 1] == 61) {
            i += 1;
        }
        push(out, strings.from_bytes(b, start, i));
    }
    return ok(out);
}

// ---- parsing -----------------------------------------------------------------------

// Variables are resolved while parsing: each $name becomes a slot in its
// template's frame (a list of values made once per call), so running a
// template never looks a variable up by name. The scope is the list of
// names in slot order; a block's variables are dropped at its {{ end }},
// and frames[name] is the most slots a template needs at once.
gc struct Parser {
    name: str,
    pieces: [Piece],
    pos: int,
    defines: map[str][Node],
    frames: map[str]int,
    scope: [str],
    most: int,
}

// Parse src into its top-level nodes; {{ define }} blocks go to defines,
// and each template's frame size to frames.
fn parse_source(name: str, src: str, defines: map[str][Node], frames: map[str]int) -> result[[Node], str] {
    let pr = split_pieces(name, src);
    guard let pieces = pr else let e = err_of(pr) { return err(e); }
    let p = Parser { name: name, pieces: pieces, pos: 0, defines: defines, frames: frames,
                     scope: ["$"], most: 1 };
    let lr = parse_list(p, false);
    guard let res = lr else let e = err_of(lr) { return err(e); }
    if res.stop != "" {
        return err(here(p, res.line) + "unexpected {{ " + res.stop + " }}");
    }
    frames[name] = p.most;
    return ok(res.nodes);
}

fn declare(p: Parser, v: str) -> int {
    push(p.scope, v);
    if len(p.scope) > p.most {
        p.most = len(p.scope);
    }
    return len(p.scope) - 1;
}

fn drop_to(p: Parser, mark: int) {
    while len(p.scope) > mark {
        pop(p.scope);
    }
}

// The innermost variable of that name.
fn lookup(p: Parser, v: str) -> int {
    let k = len(p.scope) - 1;
    while k >= 0 {
        if p.scope[k] == v {
            return k;
        }
        k -= 1;
    }
    return -1;
}

fn resolve_pipe(p: Parser, pipe: Pipe) -> result[bool, str] {
    for c in pipe.cmds {
        for a in c.args {
            if a.kind == A_VAR {
                a.slot = lookup(p, a.name);
                if a.slot < 0 {
                    return err("undefined variable " + a.name);
                }
            } else if a.kind == A_SUB {
                let r = resolve_pipe(p, a.sub[0]);
                guard let _r = r else let e = err_of(r) { return err(e); }
            }
        }
    }
    return ok(true);
}

fn is_var_name(w: str) -> bool {
    let b = to_bytes(w);
    if len(b) < 2 || b[0] != 36 {
        return false;
    }
    for k in 1..len(b) {
        let c = b[k];
        if !((c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95) {
            return false;
        }
    }
    return true;
}

// A pipeline from words, with its variables resolved.
fn pipe_of(p: Parser, ws: [str], line: int) -> result[Pipe, str] {
    let ppr = parse_pipe(ws);
    guard let pipe = ppr else let e = err_of(ppr) { return err(here(p, line) + e); }
    let rr = resolve_pipe(p, pipe);
    guard let _r = rr else let e = err_of(rr) { return err(here(p, line) + e); }
    return ok(pipe);
}

fn rest_of(ws: [str], from: int) -> [str] {
    let out: [str] = [];
    for k in from..len(ws) {
        push(out, ws[k]);
    }
    return out;
}

gc struct ListResult {
    nodes: [Node],
    // what ended the list: "", "end", "else", or "else if <rest>"
    stop: str,
    line: int,
}

fn here(p: Parser, line: int) -> str {
    return "template " + p.name + ":" + to_str(line) + ": ";
}

fn parse_list(p: Parser, inside: bool) -> result[ListResult, str] {
    let mark = len(p.scope);
    let r = parse_list_in(p, inside);
    drop_to(p, mark);
    return r;
}

fn parse_list_in(p: Parser, inside: bool) -> result[ListResult, str] {
    let nodes: [Node] = [];
    while p.pos < len(p.pieces) {
        let pc = p.pieces[p.pos];
        p.pos += 1;
        if !pc.is_action {
            let t = new_node(N_TEXT, pc.line);
            t.text = pc.text;
            push(nodes, t);
            continue;
        }
        let a = pc.text;
        if a == "end" || a == "else" || strings.has_prefix(a, "else ") {
            if !inside {
                return err(here(p, pc.line) + "{{ " + a + " }} without an open block");
            }
            return ok(ListResult { nodes: nodes, stop: a, line: pc.line });
        }
        let kw = first_word(a);
        let rest = strings.trim(strings.slice(a, len(kw), len(a)));
        if kw == "if" || kw == "with" {
            let nr = parse_branch(p, kw, rest, pc.line);
            guard let n = nr else let e = err_of(nr) { return err(e); }
            push(nodes, n);
        } else if kw == "range" {
            let nr = parse_range(p, rest, pc.line);
            guard let n = nr else let e = err_of(nr) { return err(e); }
            push(nodes, n);
        } else if kw == "define" {
            let dn = unquote_arg(rest);
            if dn == "" {
                return err(here(p, pc.line) + "define needs a quoted name");
            }
            // a define is a template of its own: a fresh scope and frame
            let saved_scope = p.scope;
            let saved_most = p.most;
            p.scope = ["$"];
            p.most = 1;
            let br = parse_list(p, true);
            let most = p.most;
            p.scope = saved_scope;
            p.most = saved_most;
            guard let body = br else let e = err_of(br) { return err(e); }
            if body.stop != "end" {
                return err(here(p, pc.line) + "define \"" + dn + "\" is not closed by {{ end }}");
            }
            p.defines[dn] = body.nodes;
            p.frames[dn] = most;
        } else if kw == "template" {
            let wr = words(rest);
            guard let ws = wr else let e = err_of(wr) { return err(here(p, pc.line) + e); }
            if len(ws) == 0 {
                return err(here(p, pc.line) + "template needs a quoted name");
            }
            let n = new_node(N_CALL, pc.line);
            n.name = unquote_arg(ws[0]);
            if n.name == "" {
                return err(here(p, pc.line) + "template needs a quoted name");
            }
            let pipe_words: [str] = [];
            for k in 1..len(ws) {
                push(pipe_words, ws[k]);
            }
            if len(pipe_words) == 0 {
                push(pipe_words, ".");
            }
            let ppr = pipe_of(p, pipe_words, pc.line);
            guard let pipe = ppr else let e = err_of(ppr) { return err(e); }
            n.pipe = pipe;
            push(nodes, n);
        } else {
            let wr = words(a);
            guard let ws = wr else let e = err_of(wr) { return err(here(p, pc.line) + e); }
            if len(ws) >= 2 && (ws[1] == ":=" || ws[1] == "=") && strings.has_prefix(ws[0], "$") {
                // {{ $x := pipeline }} declares; {{ $x = pipeline }} assigns
                if !is_var_name(ws[0]) || ws[0] == "$" {
                    return err(here(p, pc.line) + "bad variable name " + ws[0]);
                }
                if len(ws) == 2 {
                    return err(here(p, pc.line) + ws[0] + " " + ws[1] + " needs a value");
                }
                let ppr = pipe_of(p, rest_of(ws, 2), pc.line);
                guard let pipe = ppr else let e = err_of(ppr) { return err(e); }
                let n = new_node(N_SET, pc.line);
                n.pipe = pipe;
                if ws[1] == ":=" {
                    n.slot_val = declare(p, ws[0]);
                } else {
                    n.slot_val = lookup(p, ws[0]);
                    if n.slot_val < 0 {
                        return err(here(p, pc.line) + "undefined variable " + ws[0]);
                    }
                }
                push(nodes, n);
                continue;
            }
            let ppr = pipe_of(p, ws, pc.line);
            guard let pipe = ppr else let e = err_of(ppr) { return err(e); }
            let n = new_node(N_OUT, pc.line);
            n.pipe = pipe;
            push(nodes, n);
        }
    }
    return ok(ListResult { nodes: nodes, stop: "", line: 0 });
}

fn first_word(a: str) -> str {
    let b = to_bytes(a);
    let i = 0;
    while i < len(b) && !is_space(b[i]) {
        i += 1;
    }
    return strings.from_bytes(b, 0, i);
}

fn unquote_arg(s: str) -> str {
    let t = strings.trim(s);
    if len(t) >= 2 && (strings.has_prefix(t, "\"") && strings.has_suffix(t, "\"") ||
                       strings.has_prefix(t, "`") && strings.has_suffix(t, "`")) {
        return strings.slice(t, 1, len(t) - 1);
    }
    return "";
}

// if/with: a pipeline, a body, then else / else if / end.
fn parse_branch(p: Parser, kw: str, cond: str, line: int) -> result[Node, str] {
    let kind = N_IF;
    if kw == "with" {
        kind = N_WITH;
    }
    let n = new_node(kind, line);
    let wr = words(cond);
    guard let ws = wr else let e = err_of(wr) { return err(here(p, line) + e); }
    if len(ws) == 0 {
        return err(here(p, line) + kw + " needs a condition");
    }
    // {{ if $x := pipeline }}: $x is in scope in every branch
    let mark = len(p.scope);
    let r = parse_branch_in(p, kw, n, ws, line);
    drop_to(p, mark);
    return r;
}

fn parse_branch_in(p: Parser, kw: str, n: Node, ws: [str], line: int) -> result[Node, str] {
    let pw = ws;
    let decl = "";
    if len(ws) >= 3 && ws[1] == ":=" && is_var_name(ws[0]) {
        decl = ws[0];
        pw = rest_of(ws, 2);
    }
    let ppr = pipe_of(p, pw, line);
    guard let pipe = ppr else let e = err_of(ppr) { return err(e); }
    n.pipe = pipe;
    if decl != "" {
        n.slot_val = declare(p, decl);
    }
    let br = parse_list(p, true);
    guard let body = br else let e = err_of(br) { return err(e); }
    n.body = body.nodes;
    if body.stop == "end" {
        return ok(n);
    }
    if body.stop == "" {
        return err(here(p, line) + "{{ " + kw + " }} is not closed by {{ end }}");
    }
    if body.stop == "else" {
        let ar = parse_list(p, true);
        guard let alt = ar else let e = err_of(ar) { return err(e); }
        if alt.stop != "end" {
            return err(here(p, alt.line) + "expected {{ end }} after {{ else }}");
        }
        n.alt = alt.nodes;
        return ok(n);
    }
    // else if / else with: a nested branch that shares this {{ end }}
    let rest = strings.trim(strings.slice(body.stop, 4, len(body.stop)));
    let kw2 = first_word(rest);
    if kw2 != "if" && kw2 != "with" {
        return err(here(p, body.line) + "unexpected {{ " + body.stop + " }}");
    }
    let inner = parse_branch(p, kw2, strings.trim(strings.slice(rest, len(kw2), len(rest))), body.line);
    guard let nested = inner else let e = err_of(inner) { return err(e); }
    n.alt = [nested];
    return ok(n);
}

fn parse_range(p: Parser, spec: str, line: int) -> result[Node, str] {
    let n = new_node(N_RANGE, line);
    let wr = words(spec);
    guard let ws = wr else let e = err_of(wr) { return err(here(p, line) + e); }
    let pipe_from = 0;
    let vk = "";
    let vv = "";
    // $x := …   or   $i, $x := …
    if len(ws) >= 3 && ws[1] == ":=" && is_var_name(ws[0]) {
        vv = ws[0];
        pipe_from = 2;
    } else if len(ws) >= 5 && ws[1] == "," && ws[3] == ":=" && is_var_name(ws[0]) && is_var_name(ws[2]) {
        vk = ws[0];
        vv = ws[2];
        pipe_from = 4;
    }
    let pw = rest_of(ws, pipe_from);
    if len(pw) == 0 {
        return err(here(p, line) + "range needs something to range over");
    }
    // the pipeline is evaluated outside the loop's variables
    let ppr = pipe_of(p, pw, line);
    guard let pipe = ppr else let e = err_of(ppr) { return err(e); }
    n.pipe = pipe;
    let mark = len(p.scope);
    if vk != "" {
        n.slot_key = declare(p, vk);
    }
    if vv != "" {
        n.slot_val = declare(p, vv);
    }
    let br = parse_list(p, true);
    drop_to(p, mark);
    guard let body = br else let e = err_of(br) { return err(e); }
    n.body = body.nodes;
    if body.stop == "else" {
        let ar = parse_list(p, true);
        guard let alt = ar else let e = err_of(ar) { return err(e); }
        if alt.stop != "end" {
            return err(here(p, alt.line) + "expected {{ end }} after {{ else }}");
        }
        n.alt = alt.nodes;
        return ok(n);
    }
    if body.stop != "end" {
        return err(here(p, line) + "{{ range }} is not closed by {{ end }}");
    }
    return ok(n);
}

// a | b c | d  -> commands; each command is words, and an argument can be
// a parenthesised pipeline of its own.
fn parse_pipe(ws: [str]) -> result[Pipe, str] {
    let st = PipeAt { i: 0 };
    let r = parse_pipe_at(ws, st, 0);
    guard let pipe = r else let e = err_of(r) { return err(e); }
    if st.i < len(ws) {
        return err("unexpected '" + ws[st.i] + "'");
    }
    return ok(pipe);
}

gc struct PipeAt {
    i: int,
}

// Parses up to the end of the words or an unmatched ")" (left unconsumed).
fn parse_pipe_at(ws: [str], st: PipeAt, depth: int) -> result[Pipe, str] {
    if depth > 32 {
        return err("parentheses nested too deeply");
    }
    let cmds: [Cmd] = [];
    let cur: [Arg] = [];
    while st.i < len(ws) {
        let w = ws[st.i];
        if w == ")" || strings.has_prefix(w, ").") {
            break;
        }
        if w == "|" {
            if len(cur) == 0 {
                return err("empty command in a pipeline");
            }
            push(cmds, Cmd { args: cur });
            cur = [];
            st.i += 1;
            continue;
        }
        if w == "(" {
            st.i += 1;
            let sr = parse_pipe_at(ws, st, depth + 1);
            guard let sub = sr else let e = err_of(sr) { return err(e); }
            if st.i >= len(ws) {
                return err("unclosed parenthesis");
            }
            let close = ws[st.i];
            st.i += 1;
            let a = Arg { kind: A_SUB, path: [], name: "", text: "", b: false, slot: -1, keys: [], sub: [sub] };
            if close != ")" {
                let pr = field_path(strings.slice(close, 2, len(close)), close);
                guard let parts = pr else let e = err_of(pr) { return err(e); }
                a.path = parts;
                a.keys = keys_of(parts);
            }
            push(cur, a);
            continue;
        }
        if w == "," || w == ":=" {
            return err("unexpected '" + w + "'");
        }
        let ar = parse_arg(w);
        guard let a = ar else let e = err_of(ar) { return err(e); }
        a.keys = keys_of(a.path);
        push(cur, a);
        st.i += 1;
    }
    if len(cur) == 0 {
        if depth > 0 {
            return err("empty parentheses");
        }
        return err("empty pipeline");
    }
    push(cmds, Cmd { args: cur });
    return ok(Pipe { cmds: cmds });
}

fn keys_of(path: [str]) -> [bytes] {
    let out: [bytes] = [];
    for p in path {
        push(out, to_bytes(p));
    }
    return out;
}

fn field_path(s: str, shown: str) -> result[[str], str] {
    let parts = strings.split(s, ".");
    for x in parts {
        if x == "" {
            return err("bad field path " + shown);
        }
        let xb = to_bytes(x);
        for k in 0..len(xb) {
            let c = xb[k];
            if !((c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95) {
                return err("bad field path " + shown);
            }
        }
    }
    return ok(parts);
}

fn parse_arg(w: str) -> result[Arg, str] {
    let a = Arg { kind: A_DOT, path: [], name: "", text: "", b: false, slot: -1, keys: [], sub: [] };
    if w == "." {
        return ok(a);
    }
    if strings.has_prefix(w, ".") {
        let pr = field_path(strings.slice(w, 1, len(w)), w);
        guard let parts = pr else let e = err_of(pr) { return err(e); }
        a.path = parts;
        return ok(a);
    }
    if strings.has_prefix(w, "$") {
        a.kind = A_VAR;
        let dot = strings.find(w, ".");
        if dot < 0 {
            a.name = w;
        } else {
            a.name = strings.slice(w, 0, dot);
            let pr = field_path(strings.slice(w, dot + 1, len(w)), w);
            guard let parts = pr else let e = err_of(pr) { return err(e); }
            a.path = parts;
        }
        return ok(a);
    }
    if strings.has_prefix(w, "\"") {
        a.kind = A_STR;
        let r = unescape_go_string(strings.slice(w, 1, len(w) - 1));
        guard let s = r else let e = err_of(r) { return err(e); }
        a.text = s;
        return ok(a);
    }
    if strings.has_prefix(w, "`") {
        a.kind = A_STR;
        a.text = strings.slice(w, 1, len(w) - 1);
        return ok(a);
    }
    if w == "true" || w == "false" {
        a.kind = A_BOOL;
        a.b = w == "true";
        return ok(a);
    }
    if w == "nil" {
        a.kind = A_NULL;
        return ok(a);
    }
    let b = to_bytes(w);
    if (b[0] >= 48 && b[0] <= 57) || (b[0] == 45 && len(b) > 1) {
        let fr = to_float(w);
        guard let _f = fr else { return err("bad number " + w); }
        a.kind = A_NUM;
        a.text = w;
        return ok(a);
    }
    for k in 0..len(b) {
        let c = b[k];
        if !((c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95) {
            return err("unexpected '" + w + "'");
        }
    }
    a.kind = A_FUNC;
    a.name = w;
    a.slot = func_id(w);
    if a.slot < 0 {
        return err("no function \"" + w + "\" (have: " + func_names() + ")");
    }
    return ok(a);
}

fn unescape_go_string(s: str) -> result[str, str] {
    if !strings.contains(s, "\\") {
        return ok(s);
    }
    let b = to_bytes(s);
    let out = strings.bytes_zero(len(b));
    let o = 0;
    let i = 0;
    while i < len(b) {
        let c = b[i];
        if c == 92 && i + 1 < len(b) {
            let e = b[i + 1];
            if e == 110 { c = 10; }
            else if e == 116 { c = 9; }
            else if e == 114 { c = 13; }
            else if e == 34 || e == 92 { c = e; }
            else { return err("unknown escape \\" + strings.from_bytes(b, i + 1, i + 2)); }
            i += 2;
        } else {
            i += 1;
        }
        out[o] = c;
        o += 1;
    }
    return ok(strings.from_bytes(out, 0, o));
}
