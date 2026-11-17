// YAML 1.2 for configuration files: decode into your own types, or
// convert to JSON.
//
//     import "yaml";
//
//     struct Db { host: str, port: int, replicas: [str], timeout_ms: opt[int] }
//     struct Config { name: str, db: Db }
//
//     let r: result[Config, str] = yaml.decode(text);
//     guard let cfg = r else let e = err_of(r) { panic(e); }   // "yaml: line 4: ..."
//
//     yaml.to_json(text);              // result[str, str]: the one document
//     yaml.to_json_all(text);          // result[[str], str]: every document
//     yaml.decode_all(text);           // result[[T], str]
//
// decode goes through to_json and json.decode, so a document decodes into
// whatever JSON does: structs, gc structs, lists, maps, opt (a missing
// key is none), enums. Mappings keep their keys in document order.
//
// What is read: block and flow mappings and sequences, plain, single- and
// double-quoted scalars, literal (|) and folded (>) block scalars with
// chomping and indentation indicators, comments, several documents (---
// and ...), anchors and aliases, merge keys (<<), and the core tags
// (!!str, !!int, !!float, !!bool, !!null, !!map, !!seq).
//
// What is refused, with an error naming the line: other tags (!custom,
// %TAG), explicit keys (? key), a mapping or sequence used as a key, a
// recursive alias, a duplicate key, tabs in indentation.
//
// Plain scalars resolve by YAML 1.2's core schema, so yes, no, on and off
// are strings, not booleans (as in YAML 1.1): null, ~ and an empty value
// are null; true and false (and True, TRUE, ...) are booleans; 12, -3,
// 0o17 and 0x1F are integers, which must fit 64 bits; 1.5, .5, 1e3, .inf
// and .nan are floats, the last two null in JSON, as json.encode writes
// them. Everything else, dates included, is a string. A key's JSON name
// is its text: 1: and "1": are the same key.
//
// Aliases share the node they name, and writing the JSON expands them:
// more than four times as many nodes as the document has (at least a
// million) is an error, so a few lines of nested aliases ("billion
// laughs") cannot expand without bound. Nesting is limited to MAX_DEPTH
// levels.

import "builder";
import "json";
import "strings";
import "unicode";

let MAX_DEPTH = 256;
let MIN_EXPANDED = 1000000;

// Node kinds.
let K_MAP = 1;
let K_SEQ = 2;
let K_SCALAR = 3;

// Where a block node starts: at the start of its line, where its
// indentation decides what it is, or after an indicator on the same line.
let AT_LINE = 0;
let AFTER_DASH = 1;
let AFTER_COLON = 2;
let AFTER_DOC = 3;

gc struct Parser {
    b: bytes,
    n: int,
    pos: int,
    // where the current line starts: a node's column is pos - ls
    ls: int,
    // flow collections the parser is inside
    flow: int,
    depth: int,
    // nodes, by id
    kind: [int],
    // a scalar's JSON text; for a string, its contents without the quotes
    // (written around it on output), so a key's name is its text
    text: [str],
    strv: [bool],
    // where a mapping's or a sequence's contents are: an index into the
    // m* lists or into sitems
    slot: [int],
    // a plain scalar without a tag: only such a << is a merge key
    plain: [bool],
    // a collection is done once its last entry is read; an alias to one
    // that is not is recursive
    done: [bool],
    // a mapping's keys (JSON string contents, no quotes) and values in
    // document order, its key index, and the nodes it merges (<<)
    mkeys: [[str]],
    mvals: [[int]],
    mindex: [map[str]int],
    mmerge: [[int]],
    sitems: [[int]],
    anchors: map[str]int,
    // nodes written so far, aliases expanded, and the limit
    written: int,
    limit: int,
    failed: str,
    // the first byte of the last plain scalar read, and whether it was a
    // plain decimal integer that is its own JSON (no sign but -, no
    // leading zero, up to 18 digits)
    pfirst: int,
    pint: bool,
}

// The stream's one document as JSON: null if it has none, an error if it
// has more than one.
pub fn to_json(text: str) -> result[str, str] {
    let r = to_json_all(text);
    guard let docs = r else let e = err_of(r) { return err(e); }
    if len(docs) == 0 {
        return ok("null");
    }
    if len(docs) > 1 {
        return err("yaml: " + to_str(len(docs)) + " documents in the stream; to_json_all reads them all");
    }
    return ok(docs[0]);
}

// Every document in the stream, as JSON.
pub fn to_json_all(text: str) -> result[[str], str] {
    if !unicode.valid(text) {
        return err("yaml: the stream is not valid UTF-8");
    }
    let b = to_bytes(text);
    let p = Parser { b: b, n: len(b), pos: 0, ls: 0, flow: 0, depth: 0, kind: [], text: [], strv: [], slot: [], plain: [],
                     done: [], mkeys: [], mvals: [], mindex: [], mmerge: [], sitems: [], anchors: {}, written: 0,
                     limit: 0, failed: "", pfirst: 0, pint: false };
    let cr = check_printable(p);
    guard let _c = cr else let e = err_of(cr) { return err(e); }
    let sr = stream(p);
    guard let roots = sr else let e = err_of(sr) { return err(e); }
    p.limit = 4 * len(p.kind);
    if p.limit < MIN_EXPANDED {
        p.limit = MIN_EXPANDED;
    }
    let out: [str] = [];
    for root in roots {
        let w = builder.new_str();
        write_node(p, root, w, 0);
        if p.failed != "" {
            return err(p.failed);
        }
        push(out, w.finish());
    }
    return ok(out);
}

// The one document decoded into T, as json.decode would decode its JSON.
pub fn decode[T](text: str) -> result[T, str] {
    let jr = to_json(text);
    guard let j = jr else let e = err_of(jr) { return err(e); }
    let r: result[T, str] = json.decode(j);
    guard let v = r else let e = err_of(r) { return err("yaml: " + e); }
    return ok(v);
}

// Every document decoded into T.
pub fn decode_all[T](text: str) -> result[[T], str] {
    let jr = to_json_all(text);
    guard let docs = jr else let e = err_of(jr) { return err(e); }
    let out: [T] = [];
    let i = 0;
    for j in docs {
        i += 1;
        let r: result[T, str] = json.decode(j);
        guard let v = r else let e = err_of(r) { return err("yaml: document " + to_str(i) + ": " + e); }
        push(out, v);
    }
    return ok(out);
}

// ---------------------------------------------------------------- //
// Nodes                                                              //
// ---------------------------------------------------------------- //

fn new_node(p: Parser, kind: int) -> int {
    let id = len(p.kind);
    let slot = -1;
    if kind == K_MAP {
        slot = len(p.mkeys);
        let ks: [str] = [];
        push(p.mkeys, ks);
        let vs: [int] = [];
        push(p.mvals, vs);
        let ix: map[str]int = {};
        push(p.mindex, ix);
        let ms: [int] = [];
        push(p.mmerge, ms);
    } else if kind == K_SEQ {
        slot = len(p.sitems);
        let its: [int] = [];
        push(p.sitems, its);
    }
    push(p.kind, kind);
    push(p.text, "");
    push(p.strv, false);
    push(p.slot, slot);
    push(p.plain, false);
    push(p.done, kind == K_SCALAR);
    return id;
}

fn scalar_node(p: Parser, json_text: str) -> int {
    let id = new_node(p, K_SCALAR);
    p.text[id] = json_text;
    return id;
}

// A string scalar: contents is its JSON string's contents, escaped.
fn str_node(p: Parser, contents: str) -> int {
    let id = new_node(p, K_SCALAR);
    p.text[id] = contents;
    p.strv[id] = true;
    return id;
}

fn name_anchor(p: Parser, anchor: str, id: int) {
    if anchor != "" {
        p.anchors[anchor] = id;
    }
}

// The JSON name of key node k: a string's contents, or a null, boolean or
// number's text.
fn key_name(p: Parser, k: int) -> result[str, str] {
    if p.kind[k] != K_SCALAR {
        return err(fail(p, "a mapping or sequence as a key is not supported"));
    }
    return ok(p.text[k]);
}

// Key k with value v into mapping m; a << key merges v instead.
fn add_entry(p: Parser, m: int, k: int, v: int) -> result[bool, str] {
    let s = p.slot[m];
    if p.plain[k] && p.strv[k] && p.text[k] == "<<" {
        return add_merge(p, m, v);
    }
    let nr = key_name(p, k);
    guard let name = nr else let e = err_of(nr) { return err(e); }
    if has(p.mindex[s], name) {
        return err(fail(p, "key \"" + name + "\" is defined more than once"));
    }
    p.mindex[s][name] = len(p.mkeys[s]);
    push(p.mkeys[s], name);
    push(p.mvals[s], v);
    return ok(true);
}

// << : *a, or << : [*a, *b]: mappings whose keys m takes where it has none
// of its own (the earlier in the list wins).
fn add_merge(p: Parser, m: int, v: int) -> result[bool, str] {
    let s = p.slot[m];
    if p.kind[v] == K_MAP {
        push(p.mmerge[s], v);
        return ok(true);
    }
    if p.kind[v] == K_SEQ {
        for it in p.sitems[p.slot[v]] {
            if p.kind[it] != K_MAP {
                return err(fail(p, "a merge key (<<) takes mappings"));
            }
            push(p.mmerge[s], it);
        }
        return ok(true);
    }
    return err(fail(p, "a merge key (<<) takes a mapping or a sequence of mappings"));
}

// ---------------------------------------------------------------- //
// Stream and documents                                               //
// ---------------------------------------------------------------- //

fn stream(p: Parser) -> result[[int], str] {
    let docs: [int] = [];
    if p.n >= 3 && p.b[0] == 239 && p.b[1] == 187 && p.b[2] == 191 {
        p.pos = 3;
        p.ls = 3;
    }
    while true {
        let br = skip_blank(p);
        guard let _b = br else let e = err_of(br) { return err(e); }
        if p.pos >= p.n {
            break;
        }
        let directives = false;
        while p.pos < p.n && p.pos == p.ls && p.b[p.pos] == 37 {
            if starts(p, "%TAG") {
                return err(fail(p, "%TAG directives are not supported"));
            }
            if starts(p, "%YAML") && !(starts(p, "%YAML 1.") || starts(p, "%YAML\t1.")) {
                return err(fail(p, "only YAML 1.x is supported"));
            }
            while p.pos < p.n && !is_break(p.b[p.pos]) {
                p.pos += 1;
            }
            directives = true;
            let br2 = skip_blank(p);
            guard let _b2 = br2 else let e = err_of(br2) { return err(e); }
        }
        if p.pos >= p.n {
            if directives {
                return err(fail(p, "a directive without a document"));
            }
            break;
        }
        let ctx = AT_LINE;
        if marker(p, 45) {
            p.pos += 3;
            ctx = AFTER_DOC;
        } else if marker(p, 46) {
            if directives {
                return err(fail(p, "expected --- after the directives"));
            }
            p.pos += 3;
            continue;
        } else if directives {
            return err(fail(p, "expected --- after the directives"));
        }
        let fresh: map[str]int = {};
        p.anchors = fresh;
        let nr = block_node(p, -1, ctx, false);
        guard let root = nr else let e = err_of(nr) { return err(e); }
        push(docs, root);
        let br3 = skip_blank(p);
        guard let _b3 = br3 else let e = err_of(br3) { return err(e); }
        if p.pos >= p.n {
            break;
        }
        if marker(p, 46) {
            p.pos += 3;
            let er = line_rest(p);
            guard let _e = er else let e = err_of(er) { return err(e); }
            continue;
        }
        if marker(p, 45) {
            continue;
        }
        return err(fail(p, "expected the end of the document, found " + describe(p)));
    }
    return ok(docs);
}

// After ... : only spaces and a comment before the line ends.
fn line_rest(p: Parser) -> result[bool, str] {
    skip_space(p);
    if p.pos < p.n && p.b[p.pos] == 35 {
        skip_comment(p);
    }
    if p.pos < p.n && !is_break(p.b[p.pos]) {
        return err(fail(p, "expected the end of the line, found " + describe(p)));
    }
    return ok(true);
}

// ---------------------------------------------------------------- //
// Block nodes                                                        //
// ---------------------------------------------------------------- //

// A node in block context whose parent is indented n. seq_at_n: a block
// sequence may sit at the parent's own indentation (a mapping's value:
// "key:" then "- item" lines under it).
fn block_node(p: Parser, n: int, ctx: int, seq_at_n: bool) -> result[int, str] {
    p.depth += 1;
    if p.depth > MAX_DEPTH {
        return err(fail(p, "nested more than " + to_str(MAX_DEPTH) + " levels deep"));
    }
    let r = block_node_in(p, n, ctx, seq_at_n);
    p.depth -= 1;
    return r;
}

fn block_node_in(p: Parser, n: int, ctx: int, seq_at_n: bool) -> result[int, str] {
    let anchor = "";
    let tag = "";
    // the line the properties were on: properties on a key's own line
    // belong to the key, not to a mapping it starts
    let prop_line = -1;
    let at_line = ctx == AT_LINE;
    // the node's line holds nothing before it but indentation and its
    // own properties: a mapping may start here
    let own_line = at_line;
    // where the properties on the node's line start: a mapping whose
    // first key they belong to is indented to there
    let prop_col = -1;
    while true {
        if !at_line {
            skip_space(p);
            if at_line_end(p) {
                let br = skip_blank(p);
                guard let _b = br else let e = err_of(br) { return err(e); }
                at_line = true;
                own_line = true;
            }
        }
        if p.pos >= p.n || (at_line && (marker(p, 45) || marker(p, 46) || col(p) < n ||
                                         (col(p) == n && !(seq_at_n && is_dash(p))))) {
            break;
        }
        let c = p.b[p.pos];
        if (c == 38 && anchor == "") || (c == 33 && tag == "") {
            if prop_line != p.ls {
                prop_col = col(p);
            }
            if c == 38 {
                let ar = name_token(p);
                guard let a = ar else let e = err_of(ar) { return err(e); }
                anchor = a;
            } else {
                tag = tag_token(p);
            }
            prop_line = p.ls;
            at_line = false;
            continue;
        }
        break;
    }
    if p.pos >= p.n || (at_line && (marker(p, 45) || marker(p, 46) || col(p) < n ||
                                     (col(p) == n && !(seq_at_n && is_dash(p))))) {
        let er = empty_scalar(p, tag);
        guard let id = er else let e = err_of(er) { return err(e); }
        name_anchor(p, anchor, id);
        return ok(id);
    }
    let c = p.b[p.pos];
    let column = col(p);
    if is_dash(p) {
        if !at_line && ctx != AFTER_DASH {
            return err(fail(p, "a block sequence cannot start on this line"));
        }
        let cr = collection_tag(p, tag, K_SEQ);
        guard let _t = cr else let e = err_of(cr) { return err(e); }
        return block_seq(p, column, anchor);
    }
    if c == 63 && ws_or_end(p, p.pos + 1) {
        return err(fail(p, "explicit keys (? key) are not supported"));
    }
    if c == 124 || c == 62 {
        let sr = block_scalar(p, n);
        guard let s = sr else let e = err_of(sr) { return err(e); }
        return tagged_scalar(p, s, false, tag, anchor);
    }
    if c == 91 || c == 123 {
        let fr = flow_node(p);
        guard let f = fr else let e = err_of(fr) { return err(e); }
        if p.flow == 0 {
            skip_space(p);
            if p.pos < p.n && p.b[p.pos] == 58 && ws_or_end(p, p.pos + 1) {
                return err(fail(p, "a mapping or sequence as a key is not supported"));
            }
        }
        let cr = collection_tag(p, tag, p.kind[f]);
        guard let _t = cr else let e = err_of(cr) { return err(e); }
        name_anchor(p, anchor, f);
        return ok(f);
    }
    if is_implicit_key(p) {
        // a mapping starts its own line, or follows "- " (a compact one)
        if !own_line && ctx != AFTER_DASH {
            return err(fail(p, "a mapping cannot start on the same line as its key"));
        }
        if prop_line == p.ls {
            // properties on the key's own line belong to the key
            return block_map(p, prop_col, "", anchor, tag);
        }
        let cr = collection_tag(p, tag, K_MAP);
        guard let _t = cr else let e = err_of(cr) { return err(e); }
        return block_map(p, column, anchor, "", "");
    }
    if c == 42 {
        return alias(p);
    }
    if c == 34 {
        let qr = double_quoted(p);
        guard let q = qr else let e = err_of(qr) { return err(e); }
        return tagged_scalar(p, q, false, tag, anchor);
    }
    if c == 39 {
        let qr = single_quoted(p);
        guard let q = qr else let e = err_of(qr) { return err(e); }
        return tagged_scalar(p, q, false, tag, anchor);
    }
    let pr = plain(p, n);
    guard let raw = pr else let e = err_of(pr) { return err(e); }
    return tagged_scalar(p, raw, true, tag, anchor);
}

// A block mapping whose keys are at column indent. Its first key's
// properties, if they were on the key's line, come in key_anchor/key_tag.
fn block_map(p: Parser, indent: int, anchor: str, key_anchor: str, key_tag: str) -> result[int, str] {
    let m = new_node(p, K_MAP);
    name_anchor(p, anchor, m);
    let ka = key_anchor;
    let kt = key_tag;
    while true {
        // properties of this key
        while p.pos < p.n && (p.b[p.pos] == 38 || p.b[p.pos] == 33) {
            if p.b[p.pos] == 38 {
                let ar = name_token(p);
                guard let a = ar else let e = err_of(ar) { return err(e); }
                ka = a;
            } else {
                kt = tag_token(p);
            }
            skip_space(p);
        }
        if p.pos >= p.n {
            return err(fail(p, "expected a mapping key"));
        }
        let c = p.b[p.pos];
        if c == 63 && ws_or_end(p, p.pos + 1) {
            return err(fail(p, "explicit keys (? key) are not supported"));
        }
        if c == 91 || c == 123 {
            return err(fail(p, "a mapping or sequence as a key is not supported"));
        }
        if !is_implicit_key(p) {
            return err(fail(p, "expected a mapping key (key: value), found " + describe(p)));
        }
        let k = -1;
        if c == 42 {
            let ar = alias(p);
            guard let a = ar else let e = err_of(ar) { return err(e); }
            k = a;
        } else if c == 34 {
            let qr = double_quoted(p);
            guard let q = qr else let e = err_of(qr) { return err(e); }
            let tr = tagged_scalar(p, q, false, kt, ka);
            guard let t = tr else let e = err_of(tr) { return err(e); }
            k = t;
        } else if c == 39 {
            let qr = single_quoted(p);
            guard let q = qr else let e = err_of(qr) { return err(e); }
            let tr = tagged_scalar(p, q, false, kt, ka);
            guard let t = tr else let e = err_of(tr) { return err(e); }
            k = t;
        } else {
            let pr = plain_key(p);
            guard let raw = pr else let e = err_of(pr) { return err(e); }
            let tr = tagged_scalar(p, raw, true, kt, ka);
            guard let t = tr else let e = err_of(tr) { return err(e); }
            k = t;
        }
        ka = "";
        kt = "";
        skip_space(p);
        if p.pos >= p.n || p.b[p.pos] != 58 || !ws_or_end(p, p.pos + 1) {
            return err(fail(p, "expected : and a space after a mapping key, found " + describe(p)));
        }
        p.pos += 1;
        let vr = block_node(p, indent, AFTER_COLON, true);
        guard let v = vr else let e = err_of(vr) { return err(e); }
        let er = add_entry(p, m, k, v);
        guard let _e = er else let e = err_of(er) { return err(e); }
        let br = skip_blank(p);
        guard let _b = br else let e = err_of(br) { return err(e); }
        if p.pos >= p.n || marker(p, 45) || marker(p, 46) {
            break;
        }
        if !line_fresh(p) {
            return err(fail(p, "unexpected " + describe(p) + " after a mapping value"));
        }
        let c2 = col(p);
        if c2 < indent {
            break;
        }
        if c2 > indent {
            return err(fail(p, "a mapping entry indented more than the ones before it"));
        }
        if is_dash(p) {
            break;
        }
        let tr2 = tab_check(p);
        guard let _t2 = tr2 else let e = err_of(tr2) { return err(e); }
    }
    p.done[m] = true;
    return ok(m);
}

// A block sequence whose dashes are at column indent.
fn block_seq(p: Parser, indent: int, anchor: str) -> result[int, str] {
    let s = new_node(p, K_SEQ);
    name_anchor(p, anchor, s);
    while true {
        p.pos += 1;
        let ir = block_node(p, indent, AFTER_DASH, false);
        guard let it = ir else let e = err_of(ir) { return err(e); }
        push(p.sitems[p.slot[s]], it);
        let br = skip_blank(p);
        guard let _b = br else let e = err_of(br) { return err(e); }
        if p.pos >= p.n || marker(p, 45) || marker(p, 46) {
            break;
        }
        if !line_fresh(p) {
            return err(fail(p, "unexpected " + describe(p) + " after a sequence entry"));
        }
        let c = col(p);
        if c < indent {
            break;
        }
        if c > indent {
            return err(fail(p, "a sequence entry indented more than the ones before it"));
        }
        if !is_dash(p) {
            break;
        }
    }
    p.done[s] = true;
    return ok(s);
}

// Does the current line, from p.pos, hold an implicit key: a scalar or
// alias followed on the same line by ": " (or ":" at the line's end)?
fn is_implicit_key(p: Parser) -> bool {
    let i = p.pos;
    let c = p.b[i];
    if c == 34 || c == 39 {
        i += 1;
        while i < p.n && !is_break(p.b[i]) {
            if c == 34 && p.b[i] == 92 {
                i += 2;
                continue;
            }
            if p.b[i] == c {
                if c == 39 && i + 1 < p.n && p.b[i + 1] == 39 {
                    i += 2;
                    continue;
                }
                break;
            }
            i += 1;
        }
        if i >= p.n || p.b[i] != c {
            return false;
        }
        i += 1;
        while i < p.n && is_blank(p.b[i]) {
            i += 1;
        }
        return i < p.n && p.b[i] == 58 && ws_or_end(p, i + 1);
    }
    if c == 91 || c == 123 || c == 35 {
        return false;
    }
    if c == 42 {
        i += 1;
        while i < p.n && !is_ws(p.b[i]) && !is_flow_indicator(p.b[i]) {
            i += 1;
        }
        while i < p.n && is_blank(p.b[i]) {
            i += 1;
        }
        return i < p.n && p.b[i] == 58 && ws_or_end(p, i + 1);
    }
    while i < p.n && !is_break(p.b[i]) {
        let d = p.b[i];
        if d == 58 && ws_or_end(p, i + 1) {
            return true;
        }
        if d == 35 && i > p.pos && is_blank(p.b[i - 1]) {
            return false;
        }
        i += 1;
    }
    return false;
}

// ---------------------------------------------------------------- //
// Flow nodes                                                         //
// ---------------------------------------------------------------- //

fn flow_node(p: Parser) -> result[int, str] {
    p.depth += 1;
    if p.depth > MAX_DEPTH {
        return err(fail(p, "nested more than " + to_str(MAX_DEPTH) + " levels deep"));
    }
    let r = flow_node_in(p);
    p.depth -= 1;
    return r;
}

fn flow_node_in(p: Parser) -> result[int, str] {
    let anchor = "";
    let tag = "";
    while true {
        let wr = skip_flow_space(p);
        guard let _w = wr else let e = err_of(wr) { return err(e); }
        if p.pos >= p.n {
            return err(fail(p, "a flow collection that is never closed"));
        }
        let c = p.b[p.pos];
        if c == 38 && anchor == "" {
            let ar = name_token(p);
            guard let a = ar else let e = err_of(ar) { return err(e); }
            anchor = a;
            continue;
        }
        if c == 33 && tag == "" {
            tag = tag_token(p);
            continue;
        }
        break;
    }
    let c = p.b[p.pos];
    if c == 91 {
        let cr = collection_tag(p, tag, K_SEQ);
        guard let _t = cr else let e = err_of(cr) { return err(e); }
        return flow_seq(p, anchor);
    }
    if c == 123 {
        let cr = collection_tag(p, tag, K_MAP);
        guard let _t = cr else let e = err_of(cr) { return err(e); }
        return flow_map(p, anchor);
    }
    if c == 42 {
        return alias(p);
    }
    if c == 44 || c == 93 || c == 125 || (c == 58 && flow_colon(p, p.pos)) {
        let er = empty_scalar(p, tag);
        guard let id = er else let e = err_of(er) { return err(e); }
        name_anchor(p, anchor, id);
        return ok(id);
    }
    if c == 63 && (ws_or_end(p, p.pos + 1) || is_flow_indicator(p.b[p.pos + 1])) {
        return err(fail(p, "explicit keys (? key) are not supported"));
    }
    if c == 34 {
        let qr = double_quoted(p);
        guard let q = qr else let e = err_of(qr) { return err(e); }
        return tagged_scalar(p, q, false, tag, anchor);
    }
    if c == 39 {
        let qr = single_quoted(p);
        guard let q = qr else let e = err_of(qr) { return err(e); }
        return tagged_scalar(p, q, false, tag, anchor);
    }
    let pr = plain(p, -1);
    guard let raw = pr else let e = err_of(pr) { return err(e); }
    return tagged_scalar(p, raw, true, tag, anchor);
}

// [a, b]: an entry "k: v" is a mapping of one pair.
fn flow_seq(p: Parser, anchor: str) -> result[int, str] {
    let s = new_node(p, K_SEQ);
    name_anchor(p, anchor, s);
    p.pos += 1;
    p.flow += 1;
    while true {
        let wr = skip_flow_space(p);
        guard let _w = wr else let e = err_of(wr) { return err(e); }
        if p.pos >= p.n {
            return err(fail(p, "a flow sequence that is never closed"));
        }
        if p.b[p.pos] == 93 {
            break;
        }
        if p.b[p.pos] == 44 {
            return err(fail(p, "an empty entry in a flow sequence"));
        }
        let start = p.pos;
        let nr = flow_node(p);
        guard let k = nr else let e = err_of(nr) { return err(e); }
        let wr2 = skip_flow_space(p);
        guard let _w2 = wr2 else let e = err_of(wr2) { return err(e); }
        if p.pos < p.n && p.b[p.pos] == 58 && (flow_colon(p, p.pos) || adjacent_json_key(p, start)) {
            p.pos += 1;
            let vr = flow_value(p, 93);
            guard let v = vr else let e = err_of(vr) { return err(e); }
            let m = new_node(p, K_MAP);
            let er = add_entry(p, m, k, v);
            guard let _e = er else let e = err_of(er) { return err(e); }
            p.done[m] = true;
            push(p.sitems[p.slot[s]], m);
        } else {
            push(p.sitems[p.slot[s]], k);
        }
        let wr3 = skip_flow_space(p);
        guard let _w3 = wr3 else let e = err_of(wr3) { return err(e); }
        if p.pos < p.n && p.b[p.pos] == 44 {
            p.pos += 1;
            continue;
        }
        if p.pos < p.n && p.b[p.pos] == 93 {
            break;
        }
        return err(fail(p, "expected , or ] in a flow sequence, found " + describe(p)));
    }
    p.pos += 1;
    p.flow -= 1;
    p.done[s] = true;
    return ok(s);
}

// {k: v, k2}: a key without a value has a null one.
fn flow_map(p: Parser, anchor: str) -> result[int, str] {
    let m = new_node(p, K_MAP);
    name_anchor(p, anchor, m);
    p.pos += 1;
    p.flow += 1;
    while true {
        let wr = skip_flow_space(p);
        guard let _w = wr else let e = err_of(wr) { return err(e); }
        if p.pos >= p.n {
            return err(fail(p, "a flow mapping that is never closed"));
        }
        if p.b[p.pos] == 125 {
            break;
        }
        if p.b[p.pos] == 44 {
            return err(fail(p, "an empty entry in a flow mapping"));
        }
        let start = p.pos;
        let kr = flow_node(p);
        guard let k = kr else let e = err_of(kr) { return err(e); }
        let wr2 = skip_flow_space(p);
        guard let _w2 = wr2 else let e = err_of(wr2) { return err(e); }
        let v = -1;
        if p.pos < p.n && p.b[p.pos] == 58 && (flow_colon(p, p.pos) || adjacent_json_key(p, start)) {
            p.pos += 1;
            let vr = flow_value(p, 125);
            guard let fv = vr else let e = err_of(vr) { return err(e); }
            v = fv;
        } else {
            v = scalar_node(p, "null");
        }
        let er = add_entry(p, m, k, v);
        guard let _e = er else let e = err_of(er) { return err(e); }
        let wr3 = skip_flow_space(p);
        guard let _w3 = wr3 else let e = err_of(wr3) { return err(e); }
        if p.pos < p.n && p.b[p.pos] == 44 {
            p.pos += 1;
            continue;
        }
        if p.pos < p.n && p.b[p.pos] == 125 {
            break;
        }
        return err(fail(p, "expected , or } in a flow mapping, found " + describe(p)));
    }
    p.pos += 1;
    p.flow -= 1;
    p.done[m] = true;
    return ok(m);
}

// The value after a flow key's colon: empty (null) before , or the
// closing bracket.
fn flow_value(p: Parser, close: int) -> result[int, str] {
    let wr = skip_flow_space(p);
    guard let _w = wr else let e = err_of(wr) { return err(e); }
    if p.pos < p.n && (p.b[p.pos] == 44 || p.b[p.pos] == close) {
        return ok(scalar_node(p, "null"));
    }
    return flow_node(p);
}

// A colon in flow context that separates a key from its value: followed
// by space, the end, or a flow indicator.
fn flow_colon(p: Parser, i: int) -> bool {
    return ws_or_end(p, i + 1) || is_flow_indicator(p.b[i + 1]);
}

// "key":value -- a quoted key or a flow collection may have its colon
// right after it, with no space.
fn adjacent_json_key(p: Parser, start: int) -> bool {
    let c = p.b[start];
    return c == 34 || c == 39 || c == 91 || c == 123;
}

// ---------------------------------------------------------------- //
// Aliases, anchors, tags                                             //
// ---------------------------------------------------------------- //

fn alias(p: Parser) -> result[int, str] {
    let nr = name_token(p);
    guard let name = nr else let e = err_of(nr) { return err(e); }
    if !has(p.anchors, name) {
        return err(fail(p, "an alias to an unknown anchor *" + name));
    }
    let id = p.anchors[name];
    if !p.done[id] {
        return err(fail(p, "a recursive alias *" + name));
    }
    return ok(id);
}

// &name or *name at p.pos: the name.
fn name_token(p: Parser) -> result[str, str] {
    p.pos += 1;
    let start = p.pos;
    while p.pos < p.n && !is_ws(p.b[p.pos]) && !is_flow_indicator(p.b[p.pos]) {
        p.pos += 1;
    }
    if p.pos == start {
        return err(fail(p, "an anchor or alias without a name"));
    }
    return ok(strings.from_bytes(p.b, start, p.pos));
}

// !tag at p.pos: its text.
fn tag_token(p: Parser) -> str {
    let start = p.pos;
    while p.pos < p.n && !is_ws(p.b[p.pos]) && !(p.flow > 0 && is_flow_indicator(p.b[p.pos])) {
        p.pos += 1;
    }
    return strings.from_bytes(p.b, start, p.pos);
}

fn collection_tag(p: Parser, tag: str, kind: int) -> result[bool, str] {
    if tag == "" || (tag == "!!map" && kind == K_MAP) || (tag == "!!seq" && kind == K_SEQ) {
        return ok(true);
    }
    return err(fail(p, "tag " + tag + " is not supported on a " + kind_name(kind)));
}

fn kind_name(k: int) -> str {
    if k == K_MAP {
        return "mapping";
    }
    if k == K_SEQ {
        return "sequence";
    }
    return "scalar";
}

// A scalar node: raw is a plain scalar's text (resolved by the core
// schema), or else a quoted or block scalar's JSON string contents.
fn tagged_scalar(p: Parser, raw: str, is_plain: bool, tag: str, anchor: str) -> result[int, str] {
    let text = raw;
    let is_str = !is_plain;
    if is_plain {
        if tag == "!" || tag == "!!str" {
            text = escape_contents(raw);
            is_str = true;
        } else {
            let rr = resolve(p, raw);
            guard let lit = rr else let e = err_of(rr) { return err(e); }
            if tag != "" {
                let tr = check_tag(p, tag, lit, raw);
                guard let _t = tr else let e = err_of(tr) { return err(e); }
            }
            if lit == "" {
                text = escape_contents(raw);
                is_str = true;
            } else {
                text = lit;
                is_str = false;
            }
        }
    } else if tag != "" && tag != "!" && tag != "!!str" {
        // a quoted value under !!int and the like: resolve what it holds
        let jr: result[str, str] = json.decode("\"" + raw + "\"");
        guard let s = jr else { return err(fail(p, "tag " + tag + " on a string")); }
        p.pfirst = first_byte(s);
        p.pint = false;
        let rr = resolve(p, s);
        guard let lit = rr else let e = err_of(rr) { return err(e); }
        let tr = check_tag(p, tag, lit, s);
        guard let _t = tr else let e = err_of(tr) { return err(e); }
        if lit != "" {
            text = lit;
            is_str = false;
        }
    }
    let id = new_node(p, K_SCALAR);
    p.text[id] = text;
    p.strv[id] = is_str;
    p.plain[id] = is_plain && tag == "";
    name_anchor(p, anchor, id);
    return ok(id);
}

fn first_byte(s: str) -> int {
    if s == "" {
        return 0;
    }
    let b = to_bytes(strings.slice(s, 0, 1));
    return b[0];
}

// A plain string's JSON contents: itself unless it holds " \, a tab or a
// line break (a folded multi-line scalar).
fn escape_contents(s: str) -> str {
    if !strings.contains(s, "\"") && !strings.contains(s, "\\") && !strings.contains(s, "\t") &&
       !strings.contains(s, "\n") {
        return s;
    }
    let out = builder.new_str();
    let b = to_bytes(s);
    write_raw(out, b, 0, len(b));
    return out.finish();
}

// A resolved value under !!int, !!float, !!bool or !!null; lit is ""
// for a string.
fn check_tag(p: Parser, tag: str, lit: str, raw: str) -> result[bool, str] {
    let k = 1;
    if lit != "" {
        k = json_kind(lit);
    }
    if tag == "!!int" && k == 3 && !strings.contains(lit, ".") && !strings.contains(lit, "e") {
        return ok(true);
    }
    if tag == "!!float" && (k == 3 || (lit == "null" && is_special_float(raw))) {
        return ok(true);
    }
    if tag == "!!bool" && k == 2 {
        return ok(true);
    }
    if tag == "!!null" && lit == "null" {
        return ok(true);
    }
    if tag == "!!int" || tag == "!!float" || tag == "!!bool" || tag == "!!null" {
        return err(fail(p, raw + " is not a valid " + tag));
    }
    return err(fail(p, "tag " + tag + " is not supported"));
}

// 1 string, 2 bool, 3 number, 4 null.
fn json_kind(j: str) -> int {
    if j == "null" {
        return 4;
    }
    if j == "true" || j == "false" {
        return 2;
    }
    if strings.has_prefix(j, "\"") {
        return 1;
    }
    return 3;
}

fn is_special_float(raw: str) -> bool {
    let s = raw;
    if strings.has_prefix(s, "+") || strings.has_prefix(s, "-") {
        s = strings.slice(s, 1, len(s));
    }
    return s == ".inf" || s == ".Inf" || s == ".INF" || s == ".nan" || s == ".NaN" || s == ".NAN";
}

// An empty node: null, or "" under !!str.
fn empty_scalar(p: Parser, tag: str) -> result[int, str] {
    if tag == "" || tag == "!!null" {
        return ok(scalar_node(p, "null"));
    }
    if tag == "!" || tag == "!!str" {
        return ok(str_node(p, ""));
    }
    return err(fail(p, "tag " + tag + " on an empty value"));
}

// ---------------------------------------------------------------- //
// The core schema                                                    //
// ---------------------------------------------------------------- //

// A plain scalar's JSON literal -- null, a boolean or a number -- or ""
// for a string. p.pfirst is its first byte.
fn resolve(p: Parser, s: str) -> result[str, str] {
    let fb = p.pfirst;
    if s != "" && !(is_digit(fb) || fb == 43 || fb == 45 || fb == 46 || fb == 126 || fb == 110 || fb == 78 ||
                    fb == 116 || fb == 84 || fb == 102 || fb == 70) {
        return ok("");
    }
    if p.pint {
        p.pint = false;
        return ok(s);
    }
    if s == "" || s == "~" || s == "null" || s == "Null" || s == "NULL" {
        return ok("null");
    }
    if s == "true" || s == "True" || s == "TRUE" {
        return ok("true");
    }
    if s == "false" || s == "False" || s == "FALSE" {
        return ok("false");
    }
    let sb = to_bytes(s);
    let m = len(sb);
    let c = sb[0];
    if !(is_digit(c) || c == 43 || c == 45 || c == 46) {
        return ok("");
    }
    if is_special_float(s) {
        return ok("null");
    }
    // 0o17, 0x1F
    if m > 2 && c == 48 && (sb[1] == 111 || sb[1] == 120) {
        let base = 8;
        if sb[1] == 120 {
            base = 16;
        }
        let v = 0;
        for i in 2..m {
            let d = hex_val(sb[i]);
            if d < 0 || d >= base {
                return ok("");
            }
            if v > (9223372036854775807 - d) / base {
                return err(fail(p, "an integer outside 64 bits " + s));
            }
            v = v * base + d;
        }
        return ok(to_str(v));
    }
    // [-+]?[0-9]+
    let i = 0;
    if c == 43 || c == 45 {
        i = 1;
    }
    let ds = i;
    while i < m && is_digit(sb[i]) {
        i += 1;
    }
    let int_digits = i - ds;
    if i == m && int_digits > 0 {
        let t = s;
        if c == 43 {
            t = strings.slice(s, 1, m);
        }
        let ir = to_int(t);
        guard let v = ir else { return err(fail(p, "an integer outside 64 bits " + s)); }
        return ok(to_str(v));
    }
    // [-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?
    let frac_digits = 0;
    if i < m && sb[i] == 46 {
        i += 1;
        let fs = i;
        while i < m && is_digit(sb[i]) {
            i += 1;
        }
        frac_digits = i - fs;
    }
    if int_digits == 0 && frac_digits == 0 {
        return ok("");
    }
    if i < m && (sb[i] == 101 || sb[i] == 69) {
        i += 1;
        if i < m && (sb[i] == 43 || sb[i] == 45) {
            i += 1;
        }
        let es = i;
        while i < m && is_digit(sb[i]) {
            i += 1;
        }
        if i == es {
            return ok("");
        }
    }
    if i != m {
        return ok("");
    }
    // to_float wants a digit on each side of the point
    let t = s;
    if strings.contains(t, ".e") || strings.contains(t, ".E") {
        t = strings.replace(t, ".e", ".0e");
        t = strings.replace(t, ".E", ".0E");
    }
    if strings.has_suffix(t, ".") {
        t = t + "0";
    }
    if strings.has_prefix(t, ".") {
        t = "0" + t;
    } else if strings.has_prefix(t, "-.") || strings.has_prefix(t, "+.") {
        t = strings.slice(t, 0, 1) + "0" + strings.slice(t, 1, len(t));
    }
    if strings.has_prefix(t, "+") {
        t = strings.slice(t, 1, len(t));
    }
    let fr = to_float(t);
    guard let f = fr else { return err(fail(p, "a float out of range " + s)); }
    return ok(to_str(f));
}

// ---------------------------------------------------------------- //
// Scalars                                                            //
// ---------------------------------------------------------------- //

// A plain scalar's text, folded over its lines. In block context, a line
// continues it only if indented more than n.
fn plain(p: Parser, n: int) -> result[str, str] {
    let c = p.b[p.pos];
    p.pfirst = c;
    if is_indicator(c) {
        let safe = p.pos + 1 < p.n && !is_ws(p.b[p.pos + 1]) &&
                   !(p.flow > 0 && is_flow_indicator(p.b[p.pos + 1]));
        if !((c == 45 || c == 63 || c == 58) && safe) {
            return err(fail(p, "unexpected " + describe(p)));
        }
    }
    let out = builder.new_str();
    let first = true;
    let one_line = "";
    while true {
        // one line's worth
        let start = p.pos;
        let end = p.pos;
        let i = p.pos;
        while i < p.n {
            let d = p.b[i];
            if is_break(d) {
                break;
            }
            if d == 58 && (ws_or_end(p, i + 1) || (p.flow > 0 && is_flow_indicator(p.b[i + 1]))) {
                break;
            }
            if d == 35 && i > start && is_blank(p.b[i - 1]) {
                break;
            }
            if p.flow > 0 && is_flow_indicator(d) {
                break;
            }
            i += 1;
            if !is_blank(d) {
                end = i;
            }
        }
        let piece = strings.from_bytes(p.b, start, end);
        if first {
            one_line = piece;
            p.pint = is_plain_int(p.b, start, end);
        } else {
            out.write(piece);
        }
        p.pos = end;
        // a line break: does the next line continue the scalar?
        let j = end;
        while j < p.n && is_blank(p.b[j]) {
            j += 1;
        }
        if j >= p.n || !is_break(p.b[j]) {
            break;
        }
        let save_pos = p.pos;
        let save_ls = p.ls;
        p.pos = j;
        let empties = 0;
        while true {
            newline(p);
            let k = p.pos;
            while k < p.n && is_blank(p.b[k]) {
                k += 1;
            }
            if k < p.n && is_break(p.b[k]) {
                empties += 1;
                p.pos = k;
                continue;
            }
            p.pos = k;
            break;
        }
        let go_on = p.pos < p.n && p.b[p.pos] != 35 && !marker_at(p, p.ls);
        if go_on && p.flow == 0 {
            go_on = indent_of(p) > n && !has_tab_indent(p);
        }
        if go_on && p.flow > 0 {
            let d = p.b[p.pos];
            go_on = !is_flow_indicator(d) && !(d == 58 && flow_colon(p, p.pos));
        }
        if go_on && p.flow == 0 && p.b[p.pos] == 58 && ws_or_end(p, p.pos + 1) {
            go_on = false;
        }
        if !go_on {
            p.pos = save_pos;
            p.ls = save_ls;
            break;
        }
        if first {
            out.write(one_line);
            first = false;
            p.pint = false;
        }
        if empties == 0 {
            out.write(" ");
        } else {
            for _e in 0..empties {
                out.write("\n");
            }
        }
    }
    if first {
        // it fits on one line: no builder
        return ok(one_line);
    }
    return ok(out.finish());
}

// A plain implicit key: its text up to the ": " on the same line.
fn plain_key(p: Parser) -> result[str, str] {
    let c = p.b[p.pos];
    p.pfirst = c;
    if is_indicator(c) && !((c == 45 || c == 63 || c == 58) && p.pos + 1 < p.n && !is_ws(p.b[p.pos + 1])) {
        return err(fail(p, "unexpected " + describe(p)));
    }
    let start = p.pos;
    let end = p.pos;
    while p.pos < p.n && !is_break(p.b[p.pos]) {
        let d = p.b[p.pos];
        if d == 58 && ws_or_end(p, p.pos + 1) {
            break;
        }
        p.pos += 1;
        if !is_blank(d) {
            end = p.pos;
        }
    }
    p.pos = end;
    p.pint = is_plain_int(p.b, start, end);
    return ok(strings.from_bytes(p.b, start, end));
}

// b[from..to] is -?[1-9][0-9]{0,17} or 0: an int whose text is its JSON.
fn is_plain_int(b: bytes, from: int, to: int) -> bool {
    let i = from;
    if i < to && b[i] == 45 {
        i += 1;
    }
    let nd = to - i;
    if nd < 1 || nd > 18 || (b[i] == 48 && (nd > 1 || i > from)) {
        return false;
    }
    for k in i..to {
        if !is_digit(b[k]) {
            return false;
        }
    }
    return true;
}

// "...": escapes, and line breaks folded.
fn double_quoted(p: Parser) -> result[str, str] {
    p.pos += 1;
    // most have no escape and no line break: their bytes are the contents
    let q = p.pos;
    while q < p.n {
        let c = p.b[q];
        if c == 34 || c == 92 || c == 9 || is_break(c) {
            break;
        }
        q += 1;
    }
    if q < p.n && p.b[q] == 34 {
        let fast = strings.from_bytes(p.b, p.pos, q);
        p.pos = q + 1;
        return ok(fast);
    }
    let out = builder.new_str();
    while true {
        if p.pos >= p.n {
            return err(fail(p, "a double-quoted string that is never closed"));
        }
        let c = p.b[p.pos];
        if c == 34 {
            p.pos += 1;
            break;
        }
        if c == 92 {
            if p.pos + 1 < p.n && is_break(p.b[p.pos + 1]) {
                // an escaped line break: nothing, and the next line's
                // leading whitespace dropped
                p.pos += 1;
                let fr = fold_break(p, out, false);
                guard let _f = fr else let e = err_of(fr) { return err(e); }
                continue;
            }
            let er = escape(p, out);
            guard let _e = er else let e = err_of(er) { return err(e); }
            continue;
        }
        if is_blank(c) {
            let j = p.pos;
            while j < p.n && is_blank(p.b[j]) {
                j += 1;
            }
            if j < p.n && is_break(p.b[j]) {
                p.pos = j;
                continue;
            }
            write_raw(out, p.b, p.pos, j);
            p.pos = j;
            continue;
        }
        if is_break(c) {
            let fr = fold_break(p, out, true);
            guard let _f = fr else let e = err_of(fr) { return err(e); }
            continue;
        }
        let j = p.pos;
        while j < p.n {
            let d = p.b[j];
            if d == 34 || d == 92 || is_blank(d) || is_break(d) {
                break;
            }
            j += 1;
        }
        write_raw(out, p.b, p.pos, j);
        p.pos = j;
    }
    return ok(out.finish());
}

// '...': '' is a quote, and line breaks folded.
fn single_quoted(p: Parser) -> result[str, str] {
    p.pos += 1;
    let q = p.pos;
    while q < p.n {
        let c = p.b[q];
        if c == 39 || c == 34 || c == 92 || c == 9 || is_break(c) {
            break;
        }
        q += 1;
    }
    if q < p.n && p.b[q] == 39 && !(q + 1 < p.n && p.b[q + 1] == 39) {
        let fast = strings.from_bytes(p.b, p.pos, q);
        p.pos = q + 1;
        return ok(fast);
    }
    let out = builder.new_str();
    while true {
        if p.pos >= p.n {
            return err(fail(p, "a single-quoted string that is never closed"));
        }
        let c = p.b[p.pos];
        if c == 39 {
            if p.pos + 1 < p.n && p.b[p.pos + 1] == 39 {
                out.write("'");
                p.pos += 2;
                continue;
            }
            p.pos += 1;
            break;
        }
        if is_blank(c) {
            let j = p.pos;
            while j < p.n && is_blank(p.b[j]) {
                j += 1;
            }
            if j < p.n && is_break(p.b[j]) {
                p.pos = j;
                continue;
            }
            write_raw(out, p.b, p.pos, j);
            p.pos = j;
            continue;
        }
        if is_break(c) {
            let fr = fold_break(p, out, true);
            guard let _f = fr else let e = err_of(fr) { return err(e); }
            continue;
        }
        let j = p.pos;
        while j < p.n {
            let d = p.b[j];
            if d == 39 || is_blank(d) || is_break(d) {
                break;
            }
            j += 1;
        }
        write_raw(out, p.b, p.pos, j);
        p.pos = j;
    }
    return ok(out.finish());
}

// A line break inside a quoted scalar (p.pos on it), and the empty lines
// and indentation after it: a space if no empty line follows, else a
// newline per empty line (nothing for an escaped break with none).
fn fold_break(p: Parser, out: builder.Str, space: bool) -> result[bool, str] {
    newline(p);
    let empties = 0;
    while true {
        while p.pos < p.n && is_blank(p.b[p.pos]) {
            p.pos += 1;
        }
        if p.pos < p.n && is_break(p.b[p.pos]) {
            empties += 1;
            newline(p);
            continue;
        }
        break;
    }
    if p.pos == p.ls && marker_at(p, p.ls) {
        return err(fail(p, "a document marker inside a quoted string"));
    }
    if empties == 0 {
        if space {
            out.write(" ");
        }
    } else {
        for _e in 0..empties {
            out.write("\\n");
        }
    }
    return ok(true);
}

// One escape at p.pos (the backslash), written as JSON.
fn escape(p: Parser, out: builder.Str) -> result[bool, str] {
    if p.pos + 1 >= p.n {
        return err(fail(p, "a double-quoted string that is never closed"));
    }
    let c = p.b[p.pos + 1];
    p.pos += 2;
    if c == 48 {
        out.write("\\u0000");
    } else if c == 97 {
        out.write("\\u0007");
    } else if c == 98 {
        out.write("\\b");
    } else if c == 116 || c == 9 {
        out.write("\\t");
    } else if c == 110 {
        out.write("\\n");
    } else if c == 118 {
        out.write("\\u000b");
    } else if c == 102 {
        out.write("\\f");
    } else if c == 114 {
        out.write("\\r");
    } else if c == 101 {
        out.write("\\u001b");
    } else if c == 32 {
        out.write(" ");
    } else if c == 34 {
        out.write("\\\"");
    } else if c == 47 {
        out.write("/");
    } else if c == 92 {
        out.write("\\\\");
    } else if c == 78 {
        out.write(unicode.encode(133) ?? "");
    } else if c == 95 {
        out.write(unicode.encode(160) ?? "");
    } else if c == 76 {
        out.write(unicode.encode(8232) ?? "");
    } else if c == 80 {
        out.write(unicode.encode(8233) ?? "");
    } else if c == 120 || c == 117 || c == 85 {
        let digits = 2;
        if c == 117 {
            digits = 4;
        } else if c == 85 {
            digits = 8;
        }
        if p.pos + digits > p.n {
            return err(fail(p, "a \\" + strings.from_bytes(p.b, p.pos - 1, p.pos) + " escape needs " + to_str(digits) + " hex digits"));
        }
        let cp = 0;
        for i in 0..digits {
            let h = hex_val(p.b[p.pos + i]);
            if h < 0 {
                return err(fail(p, "an escape needs " + to_str(digits) + " hex digits"));
            }
            cp = cp * 16 + h;
        }
        p.pos += digits;
        if cp > 1114111 || (cp >= 55296 && cp <= 57343) {
            return err(fail(p, "an escape of " + to_str(cp) + ", which is not a Unicode scalar value"));
        }
        write_code_point(out, cp);
    } else {
        p.pos -= 1;
        return err(fail(p, "an unknown escape in a double-quoted string"));
    }
    return ok(true);
}

fn write_code_point(out: builder.Str, cp: int) {
    if cp == 34 {
        out.write("\\\"");
    } else if cp == 92 {
        out.write("\\\\");
    } else if cp == 8 {
        out.write("\\b");
    } else if cp == 9 {
        out.write("\\t");
    } else if cp == 10 {
        out.write("\\n");
    } else if cp == 12 {
        out.write("\\f");
    } else if cp == 13 {
        out.write("\\r");
    } else if cp < 32 {
        out.write("\\u00");
        out.write(hex_digit(cp / 16));
        out.write(hex_digit(cp % 16));
    } else {
        out.write(unicode.encode(cp) ?? "");
    }
}

fn hex_digit(d: int) -> str {
    return strings.slice("0123456789abcdef", d, d + 1);
}

// b[from..to] (printable, no line breaks) into a JSON string.
fn write_raw(out: builder.Str, b: bytes, from: int, to: int) {
    let run = from;
    for i in from..to {
        let c = b[i];
        if c == 34 || c == 92 || c == 9 || c == 10 {
            out.write(strings.from_bytes(b, run, i));
            if c == 34 {
                out.write("\\\"");
            } else if c == 92 {
                out.write("\\\\");
            } else if c == 9 {
                out.write("\\t");
            } else {
                out.write("\\n");
            }
            run = i + 1;
        }
    }
    out.write(strings.from_bytes(b, run, to));
}

// | or > and the lines after it, as a JSON string: the parent node is
// indented n, so the content is indented more.
fn block_scalar(p: Parser, n: int) -> result[str, str] {
    let folded = p.b[p.pos] == 62;
    p.pos += 1;
    // chomping: 0 clip, 1 strip (-), 2 keep (+)
    let chomp = 0;
    let explicit = 0;
    for _k in 0..2 {
        if p.pos >= p.n {
            break;
        }
        let c = p.b[p.pos];
        if (c == 45 || c == 43) && chomp == 0 {
            chomp = 1;
            if c == 43 {
                chomp = 2;
            }
            p.pos += 1;
        } else if c >= 49 && c <= 57 && explicit == 0 {
            explicit = c - 48;
            p.pos += 1;
        } else if c == 48 {
            return err(fail(p, "a block scalar's indentation indicator is 1 to 9"));
        }
    }
    let er = line_rest(p);
    guard let _e = er else let e = err_of(er) { return err(e); }
    newline(p);
    // the content's indentation: given, or that of the first non-empty
    // line (or of a deeper empty line before it), as libyaml decides it
    let indent = 0;
    if explicit > 0 {
        indent = explicit;
        if n >= 0 {
            indent = n + explicit;
        }
    } else {
        let i = p.pos;
        while true {
            let k = i;
            while k < p.n && p.b[k] == 32 {
                k += 1;
            }
            if k - i > indent {
                indent = k - i;
            }
            if k < p.n && is_break(p.b[k]) {
                i = k + 1;
                if p.b[k] == 13 && i < p.n && p.b[i] == 10 {
                    i += 1;
                }
                continue;
            }
            break;
        }
        if indent < n + 1 {
            indent = n + 1;
        }
        if indent < 1 {
            indent = 1;
        }
    }
    // libyaml's assembly: a line break is held in leading_break and the
    // empty lines after it counted in trailing, until the next content
    // line decides how they read
    let out = builder.new_str();
    let leading_break = false;
    let trailing = 0;
    let leading_blank = false;
    while true {
        let k = p.pos;
        while k < p.n && p.b[k] == 32 && k - p.ls < indent {
            k += 1;
        }
        if k < p.n && is_break(p.b[k]) {
            p.pos = k;
            trailing += 1;
            newline(p);
            continue;
        }
        if k >= p.n || k - p.ls < indent || marker_at(p, p.ls) {
            // the end, or a line indented less: not part of the scalar
            p.pos = p.ls;
            if k >= p.n {
                p.pos = p.n;
            }
            break;
        }
        p.pos = k;
        let trailing_blank = is_blank(p.b[p.pos]);
        if folded && leading_break && !leading_blank && !trailing_blank {
            if trailing == 0 {
                out.write(" ");
            }
        } else if leading_break {
            out.write("\\n");
        }
        for _t in 0..trailing {
            out.write("\\n");
        }
        trailing = 0;
        leading_blank = trailing_blank;
        let j = p.pos;
        while j < p.n && !is_break(p.b[j]) {
            j += 1;
        }
        write_raw(out, p.b, p.pos, j);
        p.pos = j;
        leading_break = false;
        if p.pos < p.n {
            leading_break = true;
            newline(p);
        }
    }
    if chomp != 1 && leading_break {
        out.write("\\n");
    }
    if chomp == 2 {
        for _t in 0..trailing {
            out.write("\\n");
        }
    }
    return ok(out.finish());
}

// ---------------------------------------------------------------- //
// Whitespace, comments, lines                                        //
// ---------------------------------------------------------------- //

fn skip_space(p: Parser) {
    while p.pos < p.n && is_blank(p.b[p.pos]) {
        p.pos += 1;
    }
}

fn skip_comment(p: Parser) {
    while p.pos < p.n && !is_break(p.b[p.pos]) {
        p.pos += 1;
    }
}

// At a line's end: a break, the end, or a comment.
fn at_line_end(p: Parser) -> bool {
    return p.pos >= p.n || is_break(p.b[p.pos]) || p.b[p.pos] == 35;
}

// Spaces, comments and line breaks, in block context. A comment must
// follow whitespace or start a line. The content reached, on a new line,
// must not be indented with tabs.
fn skip_blank(p: Parser) -> result[bool, str] {
    let crossed = false;
    while p.pos < p.n {
        let c = p.b[p.pos];
        if is_blank(c) {
            p.pos += 1;
        } else if c == 35 && (p.pos == p.ls || is_blank(p.b[p.pos - 1])) {
            skip_comment(p);
        } else if is_break(c) {
            newline(p);
            crossed = true;
        } else {
            break;
        }
    }
    if crossed && p.pos < p.n && p.flow == 0 {
        return tab_check(p);
    }
    return ok(true);
}

// The current line's indentation (before p.pos) holds no tab.
fn tab_check(p: Parser) -> result[bool, str] {
    if has_tab_indent(p) {
        return err(fail(p, "a tab in indentation"));
    }
    return ok(true);
}

fn has_tab_indent(p: Parser) -> bool {
    for i in p.ls..p.pos {
        if p.b[i] == 9 {
            return true;
        }
    }
    return false;
}

// Spaces, tabs, line breaks and comments inside a flow collection.
fn skip_flow_space(p: Parser) -> result[bool, str] {
    while p.pos < p.n {
        let c = p.b[p.pos];
        if is_blank(c) {
            p.pos += 1;
        } else if is_break(c) {
            newline(p);
            if marker_at(p, p.ls) {
                return err(fail(p, "a document marker inside a flow collection"));
            }
        } else if c == 35 && (p.pos == p.ls || is_blank(p.b[p.pos - 1])) {
            skip_comment(p);
        } else {
            break;
        }
    }
    return ok(true);
}

// LF, CR LF or CR at p.pos: consumed, and the next line begins.
fn newline(p: Parser) {
    if p.pos < p.n && p.b[p.pos] == 13 {
        p.pos += 1;
        if p.pos < p.n && p.b[p.pos] == 10 {
            p.pos += 1;
        }
    } else if p.pos < p.n && p.b[p.pos] == 10 {
        p.pos += 1;
    }
    p.ls = p.pos;
}

// Only whitespace before p.pos on its line: a node ended, and what
// follows starts a line of its own.
fn line_fresh(p: Parser) -> bool {
    for i in p.ls..p.pos {
        if !is_blank(p.b[i]) {
            return false;
        }
    }
    return true;
}

fn col(p: Parser) -> int {
    return p.pos - p.ls;
}

// The spaces at the start of the current line, up to p.pos.
fn indent_of(p: Parser) -> int {
    return p.pos - p.ls;
}

// --- or ... at p.pos, at the start of a line, then whitespace or the end.
fn marker(p: Parser, ch: int) -> bool {
    return p.pos == p.ls && marker_char_at(p, p.pos, ch);
}

fn marker_at(p: Parser, at: int) -> bool {
    return marker_char_at(p, at, 45) || marker_char_at(p, at, 46);
}

fn marker_char_at(p: Parser, at: int, ch: int) -> bool {
    if at + 3 > p.n {
        return false;
    }
    if p.b[at] != ch || p.b[at + 1] != ch || p.b[at + 2] != ch {
        return false;
    }
    return at + 3 == p.n || is_ws(p.b[at + 3]);
}

// "- " (or "-" at a line's end): a block sequence entry.
fn is_dash(p: Parser) -> bool {
    return p.pos < p.n && p.b[p.pos] == 45 && ws_or_end(p, p.pos + 1);
}

fn starts(p: Parser, s: str) -> bool {
    let sb = to_bytes(s);
    if p.pos + len(sb) > p.n {
        return false;
    }
    for i in 0..len(sb) {
        if p.b[p.pos + i] != sb[i] {
            return false;
        }
    }
    return true;
}

fn ws_or_end(p: Parser, i: int) -> bool {
    return i >= p.n || is_ws(p.b[i]);
}

fn is_ws(c: int) -> bool {
    return c == 32 || c == 9 || c == 10 || c == 13;
}

fn is_blank(c: int) -> bool {
    return c == 32 || c == 9;
}

fn is_break(c: int) -> bool {
    return c == 10 || c == 13;
}

fn is_flow_indicator(c: int) -> bool {
    return c == 44 || c == 91 || c == 93 || c == 123 || c == 125;
}

// - ? : , [ ] { } # & * ! | > ' " % @ `
fn is_indicator(c: int) -> bool {
    return c == 45 || c == 63 || c == 58 || c == 44 || c == 91 || c == 93 || c == 123 || c == 125 || c == 35 ||
           c == 38 || c == 42 || c == 33 || c == 124 || c == 62 || c == 39 || c == 34 || c == 37 || c == 64 || c == 96;
}

fn is_digit(c: int) -> bool {
    return c >= 48 && c <= 57;
}

fn hex_val(c: int) -> int {
    if c >= 48 && c <= 57 {
        return c - 48;
    }
    if c >= 97 && c <= 102 {
        return c - 87;
    }
    if c >= 65 && c <= 70 {
        return c - 55;
    }
    return -1;
}

// Characters YAML does not allow anywhere: C0 controls but tab, LF and
// CR; DEL; C1 controls but NEL.
fn check_printable(p: Parser) -> result[bool, str] {
    for i in 0..p.n {
        let c = p.b[i];
        if (c < 32 && c != 9 && c != 10 && c != 13) || c == 127 ||
           (c == 194 && i + 1 < p.n && p.b[i + 1] >= 128 && p.b[i + 1] <= 159 && p.b[i + 1] != 133) {
            p.pos = i;
            p.ls = 0;
            return err(fail(p, "a control character"));
        }
    }
    return ok(true);
}

// ---------------------------------------------------------------- //
// Output and errors                                                  //
// ---------------------------------------------------------------- //

// Node id as JSON, aliases expanded, merge keys applied. Stops at the
// expansion limit, leaving the error in p.failed.
fn write_node(p: Parser, id: int, out: builder.Str, depth: int) {
    if p.failed != "" {
        return;
    }
    p.written += 1;
    if p.written > p.limit || depth > MAX_DEPTH {
        p.failed = "yaml: aliases expand to more than " + to_str(p.limit) + " nodes";
        if depth > MAX_DEPTH {
            p.failed = "yaml: aliases nest more than " + to_str(MAX_DEPTH) + " levels deep";
        }
        return;
    }
    let k = p.kind[id];
    if k == K_SCALAR {
        if p.strv[id] {
            out.write("\"");
            out.write(p.text[id]);
            out.write("\"");
        } else {
            out.write(p.text[id]);
        }
        return;
    }
    if k == K_SEQ {
        out.write("[");
        let first = true;
        for it in p.sitems[p.slot[id]] {
            if !first {
                out.write(",");
            }
            first = false;
            write_node(p, it, out, depth + 1);
        }
        out.write("]");
        return;
    }
    let s = p.slot[id];
    let keys = p.mkeys[s];
    let vals = p.mvals[s];
    if len(p.mmerge[s]) > 0 {
        let mk: [str] = [];
        let mv: [int] = [];
        let mi: map[str]int = {};
        collect(p, id, mk, mv, mi, 0);
        keys = mk;
        vals = mv;
    }
    out.write("{");
    for i in 0..len(keys) {
        if i > 0 {
            out.write(",");
        }
        out.write("\"");
        out.write(keys[i]);
        out.write("\":");
        write_node(p, vals[i], out, depth + 1);
    }
    out.write("}");
}

// Mapping id's entries after its merges, into keys/vals: the merged
// mappings' first (the last in the list first, each overridden by those
// before it), then its own, each key keeping its first place.
fn collect(p: Parser, id: int, keys: [str], vals: [int], idx: map[str]int, depth: int) {
    if depth > MAX_DEPTH {
        p.failed = "yaml: merge keys nest more than " + to_str(MAX_DEPTH) + " levels deep";
        return;
    }
    let s = p.slot[id];
    let ms = p.mmerge[s];
    let i = len(ms) - 1;
    while i >= 0 {
        collect(p, ms[i], keys, vals, idx, depth + 1);
        i -= 1;
    }
    let ks = p.mkeys[s];
    let vs = p.mvals[s];
    for j in 0..len(ks) {
        let key = ks[j];
        if has(idx, key) {
            vals[idx[key]] = vs[j];
        } else {
            idx[key] = len(keys);
            push(keys, key);
            push(vals, vs[j]);
        }
    }
}

fn fail(p: Parser, msg: str) -> str {
    let line = 1;
    let to = p.pos;
    if to > p.n {
        to = p.n;
    }
    for i in 0..to {
        if p.b[i] == 10 || (p.b[i] == 13 && (i + 1 >= p.n || p.b[i + 1] != 10)) {
            line += 1;
        }
    }
    return "yaml: line " + to_str(line) + ": " + msg;
}

fn describe(p: Parser) -> str {
    if p.pos >= p.n {
        return "the end of the stream";
    }
    let c = p.b[p.pos];
    if is_break(c) {
        return "a line break";
    }
    if c < 32 || c == 127 {
        return "a control character";
    }
    if c >= 128 {
        return "a non-ASCII character";
    }
    return "'" + strings.from_bytes(p.b, p.pos, p.pos + 1) + "'";
}
