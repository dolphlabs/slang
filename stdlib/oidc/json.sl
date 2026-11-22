// A small dynamic JSON reader for the documents OAuth and OpenID Connect
// exchange, whose shapes vary (an ID token's "aud" is a string or an
// array): the json package decodes only into fixed slang types.

import "builder";

let J_NULL = 0;
let J_BOOL = 1;
let J_NUM = 2;
let J_STR = 3;
let J_ARR = 4;
let J_OBJ = 5;

pub gc struct JValue {
    kind: int,
    b: bool,
    n: float,
    s: str,
    items: [JValue],
    keys: [str],
    vals: [JValue],
}

gc struct JParser {
    b: bytes,
    at: int,
}

fn jblank(kind: int) -> JValue {
    let it: [JValue] = [];
    let ks: [str] = [];
    let vs: [JValue] = [];
    return JValue { kind: kind, b: false, n: 0.0, s: "", items: it, keys: ks, vals: vs };
}

fn jparse(text: bytes) -> result[JValue, str] {
    let p = JParser { b: text, at: 0 };
    let vr = jvalue(p, 0);
    guard let v = vr else let e = err_of(vr) { return err(e); }
    jspace(p);
    if p.at != len(p.b) { return err("json: trailing data"); }
    return ok(v);
}

fn jspace(p: JParser) {
    while p.at < len(p.b) {
        let c = p.b[p.at] as int;
        if c == 32 || c == 9 || c == 10 || c == 13 { p.at = p.at + 1; } else { return; }
    }
}

fn jlit(p: JParser, word: str) -> bool {
    let w = to_bytes(word);
    if p.at + len(w) > len(p.b) || p.b[p.at..p.at + len(w)] != w { return false; }
    p.at = p.at + len(w);
    return true;
}

fn jvalue(p: JParser, depth: int) -> result[JValue, str] {
    if depth > 64 { return err("json: nested too deeply"); }
    jspace(p);
    if p.at >= len(p.b) { return err("json: unexpected end"); }
    let c = p.b[p.at] as int;
    if c == 123 {
        p.at = p.at + 1;
        let o = jblank(J_OBJ);
        jspace(p);
        if p.at < len(p.b) && (p.b[p.at] as int) == 125 { p.at = p.at + 1; return ok(o); }
        while true {
            jspace(p);
            let kr = jstring(p);
            guard let k = kr else let ke = err_of(kr) { return err(ke); }
            jspace(p);
            if p.at >= len(p.b) || (p.b[p.at] as int) != 58 { return err("json: expected ':'"); }
            p.at = p.at + 1;
            let vr = jvalue(p, depth + 1);
            guard let v = vr else let ve = err_of(vr) { return err(ve); }
            push(o.keys, k);
            push(o.vals, v);
            jspace(p);
            if p.at < len(p.b) && (p.b[p.at] as int) == 44 { p.at = p.at + 1; continue; }
            if p.at < len(p.b) && (p.b[p.at] as int) == 125 { p.at = p.at + 1; return ok(o); }
            return err("json: expected ',' or '}'");
        }
    }
    if c == 91 {
        p.at = p.at + 1;
        let a = jblank(J_ARR);
        jspace(p);
        if p.at < len(p.b) && (p.b[p.at] as int) == 93 { p.at = p.at + 1; return ok(a); }
        while true {
            let vr = jvalue(p, depth + 1);
            guard let v = vr else let ve = err_of(vr) { return err(ve); }
            push(a.items, v);
            jspace(p);
            if p.at < len(p.b) && (p.b[p.at] as int) == 44 { p.at = p.at + 1; continue; }
            if p.at < len(p.b) && (p.b[p.at] as int) == 93 { p.at = p.at + 1; return ok(a); }
            return err("json: expected ',' or ']'");
        }
    }
    if c == 34 {
        let sr = jstring(p);
        guard let s = sr else let se = err_of(sr) { return err(se); }
        let v = jblank(J_STR);
        v.s = s;
        return ok(v);
    }
    if jlit(p, "true") { let v = jblank(J_BOOL); v.b = true; return ok(v); }
    if jlit(p, "false") { return ok(jblank(J_BOOL)); }
    if jlit(p, "null") { return ok(jblank(J_NULL)); }
    let start = p.at;
    while p.at < len(p.b) {
        let d = p.b[p.at] as int;
        if (d >= 48 && d <= 57) || d == 45 || d == 43 || d == 46 || d == 101 || d == 69 { p.at = p.at + 1; }
        else { break; }
    }
    if p.at == start { return err("json: unexpected character"); }
    let fr = to_float(to_str(p.b[start..p.at]));
    guard let f = fr else { return err("json: bad number"); }
    let v = jblank(J_NUM);
    v.n = f;
    return ok(v);
}

fn jstring(p: JParser) -> result[str, str] {
    if p.at >= len(p.b) || (p.b[p.at] as int) != 34 { return err("json: expected a string"); }
    p.at = p.at + 1;
    let out = builder.new_bytes();
    while p.at < len(p.b) {
        let c = p.b[p.at] as int;
        if c == 34 { p.at = p.at + 1; return ok(to_str(out.finish())); }
        if c < 32 { return err("json: control character in a string"); }
        if c != 92 { out.write_byte(c); p.at = p.at + 1; continue; }
        if p.at + 1 >= len(p.b) { return err("json: bad escape"); }
        let e = p.b[p.at + 1] as int;
        p.at = p.at + 2;
        if e == 34 || e == 92 || e == 47 { out.write_byte(e); }
        else if e == 98 { out.write_byte(8); } else if e == 102 { out.write_byte(12); }
        else if e == 110 { out.write_byte(10); } else if e == 114 { out.write_byte(13); }
        else if e == 116 { out.write_byte(9); }
        else if e == 117 {
            let cp = jhex4(p);
            if cp < 0 { return err("json: bad \\u escape"); }
            if cp >= 0xd800 && cp <= 0xdbff && p.at + 1 < len(p.b) && (p.b[p.at] as int) == 92 &&
               (p.b[p.at + 1] as int) == 117 {
                p.at = p.at + 2;
                let lo = jhex4(p);
                if lo < 0xdc00 || lo > 0xdfff { return err("json: bad surrogate pair"); }
                cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
            }
            utf8(out, cp);
        } else { return err("json: bad escape"); }
    }
    return err("json: unterminated string");
}

fn jhex4(p: JParser) -> int {
    if p.at + 4 > len(p.b) { return -1; }
    let v = 0;
    for i in 0..4 {
        let c = p.b[p.at + i] as int;
        let d = -1;
        if c >= 48 && c <= 57 { d = c - 48; } else if c >= 97 && c <= 102 { d = c - 87; }
        else if c >= 65 && c <= 70 { d = c - 55; }
        if d < 0 { return -1; }
        v = v * 16 + d;
    }
    p.at = p.at + 4;
    return v;
}

fn utf8(out: builder.Bytes, cp: int) {
    if cp < 0x80 { out.write_byte(cp); return; }
    if cp < 0x800 { out.write_byte(0xc0 | (cp >> 6)); out.write_byte(0x80 | (cp & 0x3f)); return; }
    if cp < 0x10000 {
        out.write_byte(0xe0 | (cp >> 12));
        out.write_byte(0x80 | ((cp >> 6) & 0x3f));
        out.write_byte(0x80 | (cp & 0x3f));
        return;
    }
    out.write_byte(0xf0 | (cp >> 18));
    out.write_byte(0x80 | ((cp >> 12) & 0x3f));
    out.write_byte(0x80 | ((cp >> 6) & 0x3f));
    out.write_byte(0x80 | (cp & 0x3f));
}

fn jget(o: JValue, key: str) -> opt[JValue] {
    if o.kind != J_OBJ { return none; }
    for i in 0..len(o.keys) {
        if o.keys[i] == key { return some(o.vals[i]); }
    }
    return none;
}

fn jstr(o: JValue, key: str) -> str {
    if let v = jget(o, key) {
        if v.kind == J_STR { return v.s; }
    }
    return "";
}

fn jnum(o: JValue, key: str) -> int {
    if let v = jget(o, key) {
        if v.kind == J_NUM { return v.n as int; }
    }
    return 0;
}

fn jbool(o: JValue, key: str) -> bool {
    if let v = jget(o, key) {
        if v.kind == J_BOOL { return v.b; }
    }
    return false;
}
