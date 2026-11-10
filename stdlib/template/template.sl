// HTML templates that escape by context, and plain-text templates.
//
//     import "template";
//
//     let r = template.parse("page", "<h1>{{ .title }}</h1>" +
//         "<a href=\"{{ .url }}\">{{ .name }}</a>" +
//         "<script>let user = {{ .user }};</script>");
//     guard let t = r else let e = err_of(r) { panic(e); }
//     let html = template.render(t, page);          // result[str, str]
//
// Data is any value json.encode accepts: a struct's fields are .name, a
// list ranges, a map's keys are fields. Each {{ action }} is escaped for
// where it stands -- text, an attribute, a URL, a script, a style -- which
// is decided when the template is parsed (see escape.sl), so a value can
// never change the page's structure: <script> in a name stays text,
// javascript: in a link is blocked, "; alert(1) in a script stays a
// string. parse_text makes a template for email bodies and other text,
// with no escaping.
//
// A missing field is an error, not an empty string: a typo should not
// render as silence. Use default, if or with for data that may be absent.

import "builder";
import "encoding";
import "json";
import "math";
import "strings";

let M_HTML = 0;
let M_TEXT = 1;
let MAX_DEPTH = 64;

// A set of named templates, parsed and ready to render: make one with
// parse or parse_text, grow it with add. Its fields are internal. Safe to
// render from many tasks at once.
pub gc struct Template {
    name: str,
    mode: int,
    trees: map[str][Node],
    // each template's frame size: its most variables in scope at once
    frames: map[str]int,
    // escaped copies, per template name and the context it is used in
    escaped: map[str][Node],
    ends: map[str]Ctx,
    lock: mutex,
}

// An HTML template, escaped by context. src may hold {{ define }} blocks.
pub fn parse(name: str, src: str) -> result[Template, str] {
    return parse_mode(name, src, M_HTML);
}

// A plain-text template (email bodies, CLI output): nothing is escaped.
pub fn parse_text(name: str, src: str) -> result[Template, str] {
    return parse_mode(name, src, M_TEXT);
}

fn parse_mode(name: str, src: str, mode: int) -> result[Template, str] {
    let t = Template { name: name, mode: mode, trees: {}, frames: {}, escaped: {}, ends: {}, lock: make_mutex() };
    let r = add(t, name, src);
    guard let _a = r else let e = err_of(r) { return err(e); }
    return ok(t);
}

// Add another named template, such as a partial or a layout, which any
// template in the set can call with {{ template "name" }} (passing dot, or
// the value written after the name); its {{ define }} blocks are added too.
pub fn add(t: Template, name: str, src: str) -> result[bool, str] {
    mutex_lock(t.lock);
    let defs: map[str][Node] = {};
    let frames: map[str]int = {};
    let pr = parse_source(name, src, defs, frames);
    guard let nodes = pr else let e = err_of(pr) {
        mutex_unlock(t.lock);
        return err(e);
    }
    t.trees[name] = nodes;
    for dn, body in defs {
        t.trees[dn] = body;
    }
    for fname, size in frames {
        t.frames[fname] = size;
    }
    // escaping is redone lazily for the new set
    t.escaped = {};
    t.ends = {};
    mutex_unlock(t.lock);
    return ok(true);
}

// Render the template parse was given, with data as its dot.
pub fn render[T](t: Template, data: T) -> result[str, str] {
    return render_named(t, t.name, data);
}

// Render one of the templates (a define or one added with add).
pub fn render_named[T](t: Template, name: str, data: T) -> result[str, str] {
    let vr = parse_value_text(json.encode(data));
    guard let root = vr else let e = err_of(vr) { return err(e); }
    let er = escaped_tree(t, name);
    guard let nodes = er else let e = err_of(er) { return err(e); }
    let out = builder.new_str();
    let frame = new_frame(t, name, root);
    let xr = exec_list(t, name, nodes, root, frame, out, 0);
    guard let _x = xr else let e = err_of(xr) { return err(e); }
    return ok(out.finish());
}

// HTML-escape text, for building markup by hand.
pub fn escape_html(s: str) -> str {
    return html_escape(s);
}

// ---- escaping analysis ----------------------------------------------------------------

fn escaped_tree(t: Template, name: str) -> result[[Node], str] {
    mutex_lock(t.lock);
    let r = escape_named(t, name, ctx_text());
    mutex_unlock(t.lock);
    guard let key = r else let e = err_of(r) { return err(e); }
    mutex_lock(t.lock);
    let nodes = t.escaped[key];
    mutex_unlock(t.lock);
    return ok(nodes);
}

// Escape template name for start context c (once; cached). The caller
// holds t.lock. Returns the cache key.
fn escape_named(t: Template, name: str, c: Ctx) -> result[str, str] {
    let key = name + "@" + ctx_key(c);
    if has(t.escaped, key) {
        return ok(key);
    }
    if !has(t.trees, name) {
        return err("template: no template named \"" + name + "\"");
    }
    // a recursive call sees a placeholder that keeps its context
    let placeholder: [Node] = [];
    t.escaped[key] = placeholder;
    t.ends[key] = c;
    let ar = escape_list(t, name, t.trees[name], c);
    guard let res = ar else let e = err_of(ar) {
        del(t.escaped, key);
        del(t.ends, key);
        return err(e);
    }
    t.escaped[key] = res.nodes;
    t.ends[key] = res.c;
    return ok(key);
}

struct Escaped {
    nodes: [Node],
    c: Ctx,
}

fn copy_node(n: Node) -> Node {
    return Node { kind: n.kind, line: n.line, text: n.text, pipe: n.pipe, body: n.body, alt: n.alt,
                  slot_key: n.slot_key, slot_val: n.slot_val, name: n.name, ctx: n.ctx };
}

// A call's variables: slot 0 is $, the rest start as null.
fn new_frame(t: Template, name: str, root: Val) -> [Val] {
    mutex_lock(t.lock);
    let size = 1;
    if has(t.frames, name) {
        size = t.frames[name];
    }
    mutex_unlock(t.lock);
    let frame: [Val] = [root];
    for k in 1..size {
        push(frame, v_null());
    }
    return frame;
}

fn escape_list(t: Template, name: str, nodes: [Node], c0: Ctx) -> result[Escaped, str] {
    let c = c0;
    let out: [Node] = [];
    for n in nodes {
        let m = copy_node(n);
        if n.kind == N_TEXT {
            if t.mode == M_HTML {
                c = scan_text(c, n.text);
            }
        } else if n.kind == N_OUT {
            if t.mode == M_TEXT {
                m.ctx = C_PLAIN;
            } else {
                let ar = action_ctx(c);
                guard let ec = ar else let e = err_of(ar) {
                    return err("template " + name + ":" + to_str(n.line) + ": " + e);
                }
                m.ctx = ec;
                c = after_action(c);
            }
        } else if n.kind == N_CALL {
            if t.mode == M_TEXT {
                let kr = escape_named(t, n.name, c);
                guard let key = kr else let e = err_of(kr) {
                    return err("template " + name + ":" + to_str(n.line) + ": " + e);
                }
                m.text = key;
            } else {
                let kr = escape_named(t, n.name, c);
                guard let key = kr else let e = err_of(kr) {
                    return err("template " + name + ":" + to_str(n.line) + ": " + e);
                }
                m.text = key;
                c = t.ends[key];
            }
        } else if n.kind == N_SET {
            // no output: the context is unchanged
        } else {
            // if, with, range: each branch from c must end where the
            // others do (and a range body where it began, since it loops)
            let br = escape_list(t, name, n.body, c);
            guard let body = br else let e = err_of(br) { return err(e); }
            let ar = escape_list(t, name, n.alt, c);
            guard let alt = ar else let e = err_of(ar) { return err(e); }
            if t.mode == M_HTML {
                if n.kind == N_RANGE && !ctx_eq(body.c, c) {
                    return err("template " + name + ":" + to_str(n.line) +
                               ": the range body ends in " + ctx_name(body.c) + " but begins in " + ctx_name(c));
                }
                if !ctx_eq(body.c, alt.c) {
                    return err("template " + name + ":" + to_str(n.line) +
                               ": the branches end in different contexts (" + ctx_name(body.c) +
                               " and " + ctx_name(alt.c) + ")");
                }
                c = body.c;
            }
            m.body = body.nodes;
            m.alt = alt.nodes;
        }
        push(out, m);
    }
    return ok(Escaped { nodes: out, c: c });
}

// ---- execution ------------------------------------------------------------------------

fn fail(name: str, line: int, msg: str) -> str {
    return "template " + name + ":" + to_str(line) + ": " + msg;
}

fn exec_list(t: Template, name: str, nodes: [Node], dot: Val, frame: [Val], out: builder.Str,
             depth: int) -> result[bool, str] {
    for n in nodes {
        if n.kind == N_TEXT {
            out.write(n.text);
            continue;
        }
        if n.kind == N_SET {
            let vr = eval_quick(n.pipe, dot, frame);
            guard let v = vr else let e = err_of(vr) { return err(fail(name, n.line, e)); }
            frame[n.slot_val] = v;
            continue;
        }
        if n.kind == N_OUT {
            let vr = eval_quick(n.pipe, dot, frame);
            guard let v = vr else let e = err_of(vr) { return err(fail(name, n.line, e)); }
            out.write(escape_for(n.ctx, v));
            continue;
        }
        if n.kind == N_IF || n.kind == N_WITH {
            let vr = eval_quick(n.pipe, dot, frame);
            guard let v = vr else let e = err_of(vr) { return err(fail(name, n.line, e)); }
            if n.slot_val >= 0 {
                frame[n.slot_val] = v;
            }
            if truthy(v) {
                let d = dot;
                if n.kind == N_WITH {
                    d = v;
                }
                let r = exec_list(t, name, n.body, d, frame, out, depth);
                guard let _x = r else let e = err_of(r) { return err(e); }
            } else {
                let r = exec_list(t, name, n.alt, dot, frame, out, depth);
                guard let _x = r else let e = err_of(r) { return err(e); }
            }
            continue;
        }
        if n.kind == N_RANGE {
            let vr = eval_quick(n.pipe, dot, frame);
            guard let v = vr else let e = err_of(vr) { return err(fail(name, n.line, e)); }
            let count = 0;
            if v.kind == V_LIST {
                let d = doc_of(v);
                let c = v.at + 1;
                let items = d.tape[v.at * STRIDE + 2];
                for i in 0..items {
                    if n.slot_key >= 0 {
                        frame[n.slot_key] = v_int(i);
                    }
                    let item = val_at(d, c);
                    if n.slot_val >= 0 {
                        frame[n.slot_val] = item;
                    }
                    let r = exec_list(t, name, n.body, item, frame, out, depth);
                    guard let _x = r else let e = err_of(r) { return err(e); }
                    c = next_of(d, c);
                    count += 1;
                }
            } else if v.kind == V_OBJ {
                for k in obj_keys(v) {
                    let f = obj_get(v, k, to_bytes(k)) ?? v_null();
                    if n.slot_key >= 0 {
                        frame[n.slot_key] = v_str(k);
                    }
                    if n.slot_val >= 0 {
                        frame[n.slot_val] = f;
                    }
                    let r = exec_list(t, name, n.body, f, frame, out, depth);
                    guard let _x = r else let e = err_of(r) { return err(e); }
                    count += 1;
                }
            } else if v.kind != V_NULL {
                return err(fail(name, n.line, "range over " + kind_name(v) + ", not a list or an object"));
            }
            if count == 0 {
                let r = exec_list(t, name, n.alt, dot, frame, out, depth);
                guard let _x = r else let e = err_of(r) { return err(e); }
            }
            continue;
        }
        if n.kind == N_CALL {
            if depth >= MAX_DEPTH {
                return err(fail(name, n.line, "templates nested more than 64 deep"));
            }
            let vr = eval_quick(n.pipe, dot, frame);
            guard let v = vr else let e = err_of(vr) { return err(fail(name, n.line, e)); }
            mutex_lock(t.lock);
            let body = t.escaped[n.text];
            mutex_unlock(t.lock);
            let inner = new_frame(t, n.name, v);
            let r = exec_list(t, n.name, body, v, inner, out, depth + 1);
            guard let _x = r else let e = err_of(r) { return err(e); }
        }
    }
    return ok(true);
}

fn kind_name(v: Val) -> str {
    return switch v.kind {
        case 0 { "null" }
        case 1 { "a bool" }
        case 2 { "a number" }
        case 3 { "a string" }
        case 4 { "a list" }
        case 5 { "an object" }
        default { "safe HTML" }
    };
}

// The pipeline's value. A pipeline that is one field or variable path
// ({{ .user.name }}, {{ $r.id }}) -- most actions -- is looked up
// directly, with no result per step; any failure goes the long way, which
// says what went wrong.
fn eval_quick(p: Pipe, dot: Val, frame: [Val]) -> result[Val, str] {
    if len(p.cmds) == 1 && len(p.cmds[0].args) == 1 {
        let a = p.cmds[0].args[0];
        if a.kind == A_DOT || a.kind == A_VAR {
            let base = dot;
            if a.kind == A_VAR {
                base = frame[a.slot];
            }
            let fr = walk_quick(base, a.path, a.keys);
            guard let v = fr else { return eval_pipe(p, dot, frame); }
            return ok(v);
        }
    }
    return eval_pipe(p, dot, frame);
}

fn walk_quick(v: Val, path: [str], keys: [bytes]) -> opt[Val] {
    let cur = v;
    for k in 0..len(path) {
        if cur.kind != V_OBJ {
            return none;
        }
        let fr = obj_get(cur, path[k], keys[k]);
        guard let next = fr else { return none; }
        cur = next;
    }
    return some(cur);
}

fn eval_pipe(p: Pipe, dot: Val, frame: [Val]) -> result[Val, str] {
    let have = false;
    let piped = v_null();
    for c in p.cmds {
        let r = eval_cmd(c, dot, frame, have, piped);
        guard let v = r else let e = err_of(r) { return err(e); }
        piped = v;
        have = true;
    }
    return ok(piped);
}

fn eval_cmd(c: Cmd, dot: Val, frame: [Val], have: bool, piped: Val) -> result[Val, str] {
    let head = c.args[0];
    if head.kind != A_FUNC {
        if len(c.args) > 1 {
            return err("a value cannot take arguments: did you mean a function?");
        }
        if have {
            return err("only a function can follow a |");
        }
        return eval_arg(head, dot, frame);
    }
    if head.slot == F_AND || head.slot == F_OR {
        return and_or(c, dot, frame, have, piped);
    }
    let args: [Val] = [];
    for k in 1..len(c.args) {
        let r = eval_arg(c.args[k], dot, frame);
        guard let v = r else let e = err_of(r) { return err(e); }
        push(args, v);
    }
    if have {
        push(args, piped);
    }
    return call(head.slot, head.name, args);
}

// and, or: evaluated left to right, stopping at the first argument that
// decides the result (and returning it), as Go's templates do -- so
// {{ if and .user .user.admin }} does not fail on a missing user.
fn and_or(c: Cmd, dot: Val, frame: [Val], have: bool, piped: Val) -> result[Val, str] {
    let is_and = c.args[0].slot == F_AND;
    let n = len(c.args) - 1;
    if have {
        n += 1;
    }
    if n < 1 {
        return err(c.args[0].name + " takes at least 1 argument");
    }
    let last = v_null();
    for k in 1..len(c.args) {
        let r = eval_arg(c.args[k], dot, frame);
        guard let v = r else let e = err_of(r) { return err(e); }
        if truthy(v) != is_and {
            return ok(v);
        }
        last = v;
    }
    if have {
        return ok(piped);
    }
    return ok(last);
}

fn eval_arg(a: Arg, dot: Val, frame: [Val]) -> result[Val, str] {
    if a.kind == A_DOT {
        return walk(dot, a.path, a.keys, ".");
    }
    if a.kind == A_VAR {
        return walk(frame[a.slot], a.path, a.keys, a.name + ".");
    }
    if a.kind == A_STR {
        return ok(v_str(a.text));
    }
    if a.kind == A_NUM {
        return ok(v_num(a.text));
    }
    if a.kind == A_BOOL {
        return ok(v_bool(a.b));
    }
    if a.kind == A_NULL {
        return ok(v_null());
    }
    if a.kind == A_SUB {
        let r = eval_pipe(a.sub[0], dot, frame);
        guard let v = r else let e = err_of(r) { return err(e); }
        if len(a.path) == 0 {
            return ok(v);
        }
        return walk(v, a.path, a.keys, "(…).");
    }
    // a bare function name as an argument: called with no arguments
    return call(a.slot, a.name, []);
}

fn walk(v: Val, path: [str], keys: [bytes], prefix: str) -> result[Val, str] {
    let cur = v;
    let shown = prefix;
    for k in 0..len(path) {
        let f = path[k];
        if k > 0 {
            shown = shown + ".";
        }
        shown = shown + f;
        if cur.kind != V_OBJ {
            return err(shown + ": " + kind_name(cur) + " has no fields");
        }
        let fr = obj_get(cur, f, keys[k]);
        guard let next = fr else { return err(shown + ": no field " + f); }
        cur = next;
    }
    return ok(cur);
}

// ---- functions --------------------------------------------------------------------------

fn want(name: str, args: [Val], n: int) -> result[bool, str] {
    if len(args) != n {
        return err(name + " takes " + to_str(n) + " argument(s), got " + to_str(len(args)));
    }
    return ok(true);
}

fn num_of(v: Val) -> opt[float] {
    if v.kind != V_NUM {
        return none;
    }
    let r = to_float(v.text);
    if let f = r {
        return some(f);
    }
    return none;
}

fn equal(a: Val, b: Val) -> bool {
    if a.kind == V_NUM && b.kind == V_NUM {
        return (num_of(a) ?? 0.0) == (num_of(b) ?? 1.0);
    }
    if (a.kind == V_STR || a.kind == V_SAFE) && (b.kind == V_STR || b.kind == V_SAFE) {
        return a.text == b.text;
    }
    if a.kind != b.kind {
        return false;
    }
    if a.kind == V_BOOL {
        return a.b == b.b;
    }
    if a.kind == V_NULL {
        return true;
    }
    return to_json(a) == to_json(b);
}

// <0, 0, >0 for comparable values (numbers, strings).
fn compare(name: str, a: Val, b: Val) -> result[int, str] {
    if a.kind == V_NUM && b.kind == V_NUM {
        let x = num_of(a) ?? 0.0;
        let y = num_of(b) ?? 0.0;
        if x < y { return ok(-1); }
        if x > y { return ok(1); }
        return ok(0);
    }
    if (a.kind == V_STR || a.kind == V_SAFE) && (b.kind == V_STR || b.kind == V_SAFE) {
        if a.text < b.text { return ok(-1); }
        if a.text > b.text { return ok(1); }
        return ok(0);
    }
    return err(name + " compares two numbers or two strings, not " + kind_name(a) + " and " + kind_name(b));
}

fn call(id: int, name: str, args: [Val]) -> result[Val, str] {
    if id == F_EQ || id == F_NE {
        if len(args) < 2 {
            return err(name + " takes at least 2 arguments");
        }
        let any = false;
        for k in 1..len(args) {
            if equal(args[0], args[k]) {
                any = true;
            }
        }
        if id == F_NE {
            return ok(v_bool(!any));
        }
        return ok(v_bool(any));
    }
    if id == F_LT || id == F_LE || id == F_GT || id == F_GE {
        let w = want(name, args, 2);
        guard let _w = w else let e = err_of(w) { return err(e); }
        let cr = compare(name, args[0], args[1]);
        guard let c = cr else let e = err_of(cr) { return err(e); }
        let r = switch name {
            case "lt" { c < 0 }
            case "le" { c <= 0 }
            case "gt" { c > 0 }
            default { c >= 0 }
        };
        return ok(v_bool(r));
    }
    if id == F_AND || id == F_OR {
        if len(args) < 1 {
            return err(name + " takes at least 1 argument");
        }
        for v in args {
            if (id == F_AND) != truthy(v) {
                return ok(v);
            }
        }
        return ok(args[len(args) - 1]);
    }
    if id == F_NOT {
        let w = want(name, args, 1);
        guard let _w = w else let e = err_of(w) { return err(e); }
        return ok(v_bool(!truthy(args[0])));
    }
    if id == F_LEN {
        let w = want(name, args, 1);
        guard let _w = w else let e = err_of(w) { return err(e); }
        let v = args[0];
        if v.kind == V_LIST || v.kind == V_OBJ { return ok(v_int(count_of(v))); }
        if v.kind == V_STR || v.kind == V_SAFE { return ok(v_int(len(v.text))); }
        return err("len of " + kind_name(v));
    }
    if id == F_UPPER || id == F_LOWER || id == F_TRIM {
        let w = want(name, args, 1);
        guard let _w = w else let e = err_of(w) { return err(e); }
        let s = to_text(args[0]);
        let r = switch name {
            case "upper" { strings.to_upper(s) }
            case "lower" { strings.to_lower(s) }
            default { strings.trim(s) }
        };
        return ok(v_str(r));
    }
    if id == F_DEFAULT {
        let w = want(name, args, 2);
        guard let _w = w else let e = err_of(w) { return err(e); }
        if truthy(args[1]) {
            return ok(args[1]);
        }
        return ok(args[0]);
    }
    if id == F_JOIN {
        let w = want(name, args, 2);
        guard let _w = w else let e = err_of(w) { return err(e); }
        let list = args[0];
        if list.kind != V_LIST {
            return err("join takes a list first");
        }
        let parts: [str] = [];
        let d = doc_of(list);
        let c = list.at + 1;
        for k in 0..d.tape[list.at * STRIDE + 2] {
            push(parts, to_text(val_at(d, c)));
            c = next_of(d, c);
        }
        return ok(v_str(strings.join(parts, to_text(args[1]))));
    }
    if id == F_INDEX {
        let w = want(name, args, 2);
        guard let _w = w else let e = err_of(w) { return err(e); }
        let c = args[0];
        if c.kind == V_LIST {
            let ir = to_int(to_text(args[1]));
            guard let i = ir else { return err("index into a list takes an integer"); }
            if i < 0 || i >= count_of(c) {
                return err("index " + to_str(i) + " out of range for a list of " + to_str(count_of(c)));
            }
            return ok(list_at(c, i));
        }
        if c.kind == V_OBJ {
            let k = to_text(args[1]);
            let fr = obj_get(c, k, to_bytes(k));
            guard let f = fr else { return err("index: no key " + k); }
            return ok(f);
        }
        return err("index into " + kind_name(c));
    }
    if id == F_ADD || id == F_SUB {
        let w = want(name, args, 2);
        guard let _w = w else let e = err_of(w) { return err(e); }
        let ar = to_int(to_text(args[0]));
        let br = to_int(to_text(args[1]));
        guard let a = ar else { return err(name + " takes integers"); }
        guard let b = br else { return err(name + " takes integers"); }
        if id == F_ADD {
            return ok(v_int(a + b));
        }
        return ok(v_int(a - b));
    }
    if id == F_JSON {
        let w = want(name, args, 1);
        guard let _w = w else let e = err_of(w) { return err(e); }
        return ok(v_str(to_json(args[0])));
    }
    if id == F_URLQUERY {
        let w = want(name, args, 1);
        guard let _w = w else let e = err_of(w) { return err(e); }
        return ok(v_str(url_component(to_text(args[0]))));
    }
    if id == F_RAW {
        let w = want(name, args, 1);
        guard let _w = w else let e = err_of(w) { return err(e); }
        let v = v_str(to_text(args[0]));
        v.kind = V_SAFE;
        return ok(v);
    }
    if id == F_PRINT {
        return ok(v_str(sprint(args)));
    }
    if id == F_PRINTF {
        if len(args) < 1 {
            return err("printf takes a format first");
        }
        return sprintf(to_text(args[0]), args);
    }
    return err("no function \"" + name + "\"");
}

// ---- escapers ---------------------------------------------------------------------------

fn escape_for(ctx: int, v: Val) -> str {
    if ctx == C_PLAIN {
        return to_text(v);
    }
    if ctx == C_TEXT || ctx == C_ATTR {
        if v.kind == V_STR {
            return strings.escape_html(v.text);
        }
        if v.kind == V_SAFE && ctx == C_TEXT {
            return v.text;
        }
        // a number or a bool needs no escaping
        if v.kind == V_NUM || v.kind == V_BOOL || v.kind == V_NULL {
            return to_text(v);
        }
        return strings.escape_html(to_text(v));
    }
    if ctx == C_URL_START {
        return html_escape(url_normalize(url_filter(to_text(v))));
    }
    if ctx == C_URL_REST {
        return html_escape(url_component(to_text(v)));
    }
    if ctx == C_JS {
        return js_value(v);
    }
    if ctx == C_JS_ATTR {
        return html_escape(js_value(v));
    }
    if ctx == C_JS_STR {
        return js_string(to_text(v));
    }
    if ctx == C_JS_STR_ATTR {
        return html_escape(js_string(to_text(v)));
    }
    if ctx == C_CSS {
        return css_filter(to_text(v));
    }
    if ctx == C_CSS_ATTR {
        return html_escape(css_filter(to_text(v)));
    }
    return html_escape(to_text(v));
}

fn html_escape(s: str) -> str {
    return strings.escape_html(s);
}

// A URL whose scheme is not http, https, mailto or tel is replaced: the
// scheme is what makes javascript: and data: dangerous.
fn url_filter(s: str) -> str {
    let b = to_bytes(s);
    for i in 0..len(b) {
        let c = b[i];
        if c == 58 {
            let scheme = strings.to_lower(strings.trim(strings.from_bytes(b, 0, i)));
            if scheme == "http" || scheme == "https" || scheme == "mailto" || scheme == "tel" {
                return s;
            }
            return "about:invalid#blocked";
        }
        if c == 47 || c == 63 || c == 35 {
            return s;   // a relative URL: no scheme
        }
    }
    return s;
}

// Percent-encode what may not appear in a URL, keeping its structure
// (/ ? # & = and existing %XX escapes).
fn url_normalize(s: str) -> str {
    let b = to_bytes(s);
    let out = builder.new_str();
    let run = 0;
    for i in 0..len(b) {
        let c = b[i];
        let keep = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) ||
                   c == 45 || c == 46 || c == 95 || c == 126 || c == 58 || c == 47 || c == 63 ||
                   c == 35 || c == 91 || c == 93 || c == 64 || c == 33 || c == 36 || c == 38 ||
                   c == 40 || c == 41 || c == 42 || c == 43 || c == 44 || c == 59 || c == 61 || c == 37;
        if keep {
            continue;
        }
        if i > run { out.write(strings.from_bytes(b, run, i)); }
        out.write("%" + strings.to_upper(hex2(c)));
        run = i + 1;
    }
    if run < len(b) { out.write(strings.from_bytes(b, run, len(b))); }
    return out.finish();
}

// Everything but A-Z a-z 0-9 - . _ ~ percent-encoded: for a value placed
// inside a URL (a path segment or a query value).
fn url_component(s: str) -> str {
    return encoding.url_encode(s);
}

// The value as a JavaScript literal (JSON), with the characters that could
// end a script, an attribute or a line written as \u escapes.
fn js_value(v: Val) -> str {
    if v.kind == V_STR || v.kind == V_SAFE {
        return "\"" + strings.escape_js(v.text) + "\"";
    }
    if v.kind != V_LIST && v.kind != V_OBJ {
        // null, true, false, and numbers as json.encode wrote them
        return to_json(v);
    }
    return js_safe(to_json(v));
}

fn js_safe(s: str) -> str {
    let r = s;
    if strings.contains(r, "<") { r = strings.replace(r, "<", "\\u003c"); }
    if strings.contains(r, ">") { r = strings.replace(r, ">", "\\u003e"); }
    if strings.contains(r, "&") { r = strings.replace(r, "&", "\\u0026"); }
    if strings.contains(r, "'") { r = strings.replace(r, "'", "\\u0027"); }
    let ls = to_str(b"\xe2\x80\xa8");
    let ps = to_str(b"\xe2\x80\xa9");
    if strings.contains(r, ls) { r = strings.replace(r, ls, "\\u2028"); }
    if strings.contains(r, ps) { r = strings.replace(r, ps, "\\u2029"); }
    return r;
}

// The text as the inside of a JavaScript string, whatever its quotes.
fn js_string(s: str) -> str {
    return strings.escape_js(s);
}

// Values in CSS: a conservative set, else a harmless placeholder.
fn css_filter(s: str) -> str {
    let b = to_bytes(s);
    for i in 0..len(b) {
        let c = b[i];
        let ok_char = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) ||
                      c == 35 || c == 37 || c == 46 || c == 44 || c == 45 || c == 32;
        if !ok_char {
            return "ZgotmplZ";
        }
    }
    return s;
}

// ---- print, printf --------------------------------------------------------------------

// Go's fmt.Sprint: operands side by side, with a space between two
// operands when neither is a string.
fn sprint(args: [Val]) -> str {
    let out = builder.new_str();
    for k in 0..len(args) {
        let a = args[k];
        if k > 0 && !is_text(a) && !is_text(args[k - 1]) {
            out.write(" ");
        }
        out.write(to_text(a));
    }
    return out.finish();
}

fn is_text(v: Val) -> bool {
    return v.kind == V_STR || v.kind == V_SAFE;
}

// A subset of Go's fmt verbs, which covers what templates use: %s and %v
// (the value as text), %d (an integer), %f and %.Nf (a number, six or N
// decimals), %q (a quoted string), %x (hex of an integer, or of a
// string's bytes), %t (a bool), and %%. A verb without its operand, or
// an operand left over, is an error rather than Go's %!(…) noise in the
// page.
fn sprintf(format: str, args: [Val]) -> result[Val, str] {
    let b = to_bytes(format);
    let out = builder.new_str();
    let next = 1;
    let run = 0;
    let i = 0;
    while i < len(b) {
        if b[i] != 37 {
            i += 1;
            continue;
        }
        if i > run {
            out.write(strings.from_bytes(b, run, i));
        }
        i += 1;
        if i >= len(b) {
            return err("printf: a % at the end of the format");
        }
        let prec = -1;
        if b[i] == 46 {
            i += 1;
            prec = 0;
            while i < len(b) && b[i] >= 48 && b[i] <= 57 {
                prec = prec * 10 + (b[i] - 48);
                i += 1;
            }
            if i >= len(b) {
                return err("printf: a % at the end of the format");
            }
        }
        let verb = b[i];
        i += 1;
        run = i;
        if verb == 37 {
            out.write("%");
            continue;
        }
        if next >= len(args) {
            return err("printf: %" + strings.from_bytes(b, i - 1, i) + " has no operand");
        }
        let a = args[next];
        next += 1;
        if verb == 115 || verb == 118 {
            out.write(to_text(a));
        } else if verb == 100 {
            let ir = to_int(to_text(a));
            guard let n = ir else { return err("printf: %d of " + kind_name(a)); }
            out.write(to_str(n));
        } else if verb == 102 {
            let fr = to_float(to_text(a));
            guard let f = fr else { return err("printf: %f of " + kind_name(a)); }
            let p = prec;
            if p < 0 {
                p = 6;
            }
            out.write(math.format_fixed(f, p));
        } else if verb == 113 {
            out.write(json_quote(to_text(a)));
        } else if verb == 120 {
            let ir = to_int(to_text(a));
            guard let n = ir else {
                out.write(encoding.hex_encode(to_bytes(to_text(a))));
                continue;
            }
            out.write(hex_of(n));
        } else if verb == 116 {
            if a.kind != V_BOOL {
                return err("printf: %t of " + kind_name(a));
            }
            out.write(to_text(a));
        } else {
            return err("printf: unknown verb %" + strings.from_bytes(b, i - 1, i));
        }
    }
    if run < len(b) {
        out.write(strings.from_bytes(b, run, len(b)));
    }
    if next < len(args) {
        return err("printf: " + to_str(len(args) - next) + " operand(s) left over");
    }
    return ok(v_str(out.finish()));
}

fn hex_of(n: int) -> str {
    if n == 0 {
        return "0";
    }
    let digits = to_bytes("0123456789abcdef");
    let neg = n < 0;
    let x = n;
    if neg {
        x = -n;
    }
    let out: [int] = [];
    while x > 0 {
        push(out, digits[x % 16]);
        x = x / 16;
    }
    let b = strings.bytes_zero(len(out));
    for k in 0..len(out) {
        b[k] = out[len(out) - 1 - k];
    }
    if neg {
        return "-" + to_str(b);
    }
    return to_str(b);
}
