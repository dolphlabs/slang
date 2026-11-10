// Contextual escaping: the HTML around each {{ action }} decides how its
// value is escaped. The template's literal text is scanned, in order,
// with a small HTML state machine; each action records the state it sits
// in. Decided once, at parse time, not per render.
//
// Contexts and what a value becomes in them:
//   text, quoted attribute     HTML-escaped (& < > " ')
//   URL attribute, at start    scheme checked (http, https, mailto, tel or
//                              relative; anything else, javascript: above
//                              all, becomes about:invalid#blocked), then
//                              URL-normalised and HTML-escaped
//   URL attribute, later       percent-encoded as a component, HTML-escaped
//   <script>, on* attributes   a JSON literal, with < > & ' escaped as
//                              \u003c and so on, so it cannot end the
//                              script or the attribute
//   inside a JS string         escaped as JS string content
//   <style>, style attribute   only letters, digits and # % . , - space;
//                              anything else becomes ZgotmplZ
// Refused, at parse time: an action in a tag or attribute name, in an
// unquoted attribute value, in an HTML comment, or in a JS comment; and
// branches of an if or range that leave the HTML in different states.

import "strings";

let S_TEXT = 0;
let S_TAG = 1;         // inside <tag …>, between attributes
let S_ATTR = 2;        // inside a quoted attribute value
let S_SCRIPT = 3;      // inside <script>…</script>
let S_STYLE = 4;       // inside <style>…</style>
let S_COMMENT = 5;     // inside <!-- … -->
let S_RCDATA = 6;      // inside <title> or <textarea>
let S_ERROR = 7;

let AK_NORMAL = 0;
let AK_URL = 1;
let AK_JS = 2;
let AK_CSS = 3;

// What escaping an action gets (Node.ctx).
let C_TEXT = 1;
let C_ATTR = 2;
let C_URL_START = 3;
let C_URL_REST = 4;
let C_JS = 5;
let C_JS_ATTR = 6;
let C_JS_STR = 7;
let C_JS_STR_ATTR = 8;
let C_CSS = 9;
let C_CSS_ATTR = 10;
let C_PLAIN = 11;      // text templates: no escaping

struct Ctx {
    st: int,
    attr: int,         // AK_* for S_ATTR
    quote: int,        // the attribute's quote character
    url_start: bool,   // S_ATTR + AK_URL: nothing written in the value yet
    js_quote: int,     // in a JS string: its quote character, else 0
    js_comment: int,   // 1 line comment, 2 block comment, 0 none
    elem: str,         // the raw-text element (script, style, title, textarea)
    why: str,          // S_ERROR: what went wrong
}

fn ctx_text() -> Ctx {
    return Ctx { st: S_TEXT, attr: 0, quote: 0, url_start: false, js_quote: 0, js_comment: 0,
                 elem: "", why: "" };
}

fn ctx_eq(a0: Ctx, b0: Ctx) -> bool {
    let a = canon(a0);
    let b = canon(b0);
    return a.st == b.st && a.attr == b.attr && a.quote == b.quote && a.url_start == b.url_start &&
           a.js_quote == b.js_quote && a.js_comment == b.js_comment && a.elem == b.elem;
}

fn ctx_key(c: Ctx) -> str {
    return to_str(c.st) + "/" + to_str(c.attr) + "/" + to_str(c.quote) + "/" +
           to_str(c.url_start) + "/" + to_str(c.js_quote) + "/" + to_str(c.js_comment) + "/" + c.elem;
}

fn ctx_name(c: Ctx) -> str {
    return switch c.st {
        case 0 { "text" }
        case 1 { "a tag" }
        case 2 { "an attribute value" }
        case 3 { "a script" }
        case 4 { "a style element" }
        case 5 { "an HTML comment" }
        case 6 { "a title or textarea" }
        default { "an error state" }
    };
}

// The escaping an action gets in context c, or an error.
fn action_ctx(c: Ctx) -> result[int, str] {
    if c.st == S_TEXT || c.st == S_RCDATA {
        return ok(C_TEXT);
    }
    if c.st == S_TAG {
        return err("an action inside a tag must be inside a quoted attribute value");
    }
    if c.st == S_COMMENT {
        return err("an action inside an HTML comment is not allowed");
    }
    if c.st == S_SCRIPT {
        if c.js_comment != 0 {
            return err("an action inside a JavaScript comment is not allowed");
        }
        if c.js_quote != 0 {
            return ok(C_JS_STR);
        }
        return ok(C_JS);
    }
    if c.st == S_STYLE {
        return ok(C_CSS);
    }
    if c.st == S_ATTR {
        if c.quote == 0 {
            return err("an action in an unquoted attribute value is not allowed: quote the attribute");
        }
        if c.attr == AK_URL {
            if c.url_start {
                return ok(C_URL_START);
            }
            return ok(C_URL_REST);
        }
        if c.attr == AK_JS {
            if c.js_comment != 0 {
                return err("an action inside a JavaScript comment is not allowed");
            }
            if c.js_quote != 0 {
                return ok(C_JS_STR_ATTR);
            }
            return ok(C_JS_ATTR);
        }
        if c.attr == AK_CSS {
            return ok(C_CSS_ATTR);
        }
        return ok(C_ATTR);
    }
    return err(c.why);
}

// After an action's value is written, the context moves on: a URL
// attribute is no longer at its start.
fn after_action(c: Ctx) -> Ctx {
    let n = c;
    if n.st == S_ATTR && n.attr == AK_URL {
        n.url_start = false;
    }
    return n;
}

fn url_attr(name: str) -> bool {
    return name == "href" || name == "src" || name == "action" || name == "formaction" ||
           name == "cite" || name == "poster" || name == "background" || name == "data" ||
           name == "codebase" || name == "longdesc" || name == "usemap" || name == "manifest" ||
           name == "xmlns" || name == "ping" || name == "srcset" || name == "icon";
}

fn lower_ascii_byte(c: int) -> int {
    if c >= 65 && c <= 90 {
        return c + 32;
    }
    return c;
}

// b[i..] starts with s, ignoring ASCII case.
fn starts_ci(b: bytes, i: int, s: str) -> bool {
    let w = to_bytes(s);
    if i + len(w) > len(b) {
        return false;
    }
    for k in 0..len(w) {
        if lower_ascii_byte(b[i + k]) != w[k] {
            return false;
        }
    }
    return true;
}

// Advance c over literal text.
fn scan_text(c0: Ctx, text: str) -> Ctx {
    let c = c0;
    let b = to_bytes(text);
    let i = 0;
    while i < len(b) {
        let ch = b[i];
        if c.st == S_TEXT {
            if ch == 60 {
                if starts_ci(b, i, "<!--") {
                    c.st = S_COMMENT;
                    i += 4;
                    continue;
                }
                if i + 1 < len(b) && (b[i + 1] == 47 || is_alpha(b[i + 1])) {
                    let closing = b[i + 1] == 47;
                    let ns = i + 1;
                    if closing {
                        ns += 1;
                    }
                    let ne = ns;
                    while ne < len(b) && (is_alpha(b[ne]) || (b[ne] >= 48 && b[ne] <= 57) || b[ne] == 45) {
                        ne += 1;
                    }
                    let tag = strings.to_lower(strings.from_bytes(b, ns, ne));
                    c.st = S_TAG;
                    c.elem = "";
                    if !closing && (tag == "script" || tag == "style" || tag == "title" || tag == "textarea") {
                        c.elem = tag;
                    }
                    i = ne;
                    if ne == ns {
                        // "<" then a non-letter after "</": just text
                        c.st = S_TEXT;
                    }
                    continue;
                }
            }
            i += 1;
            continue;
        }
        if c.st == S_COMMENT {
            if starts_ci(b, i, "-->") {
                c.st = S_TEXT;
                i += 3;
                continue;
            }
            i += 1;
            continue;
        }
        if c.st == S_TAG {
            if is_space(ch) || ch == 47 {
                i += 1;
                continue;
            }
            if ch == 62 {
                i += 1;
                if c.elem == "script" {
                    c.st = S_SCRIPT;
                } else if c.elem == "style" {
                    c.st = S_STYLE;
                } else if c.elem != "" {
                    c.st = S_RCDATA;
                } else {
                    c.st = S_TEXT;
                }
                continue;
            }
            // an attribute name
            let ns = i;
            while i < len(b) && !is_space(b[i]) && b[i] != 61 && b[i] != 62 && b[i] != 47 {
                i += 1;
            }
            let aname = strings.to_lower(strings.from_bytes(b, ns, i));
            let kind = AK_NORMAL;
            if strings.has_prefix(aname, "on") {
                kind = AK_JS;
            } else if aname == "style" {
                kind = AK_CSS;
            } else if url_attr(aname) {
                kind = AK_URL;
            }
            while i < len(b) && is_space(b[i]) {
                i += 1;
            }
            if i < len(b) && b[i] == 61 {
                i += 1;
                while i < len(b) && is_space(b[i]) {
                    i += 1;
                }
                if i >= len(b) {
                    // the value starts after this text: an action here is
                    // in an unquoted value
                    c.st = S_ATTR;
                    c.attr = kind;
                    c.quote = 0;
                    c.url_start = true;
                    return c;
                }
                if b[i] == 34 || b[i] == 39 {
                    c.st = S_ATTR;
                    c.attr = kind;
                    c.quote = b[i];
                    c.url_start = true;
                    c.js_quote = 0;
                    c.js_comment = 0;
                    i += 1;
                    continue;
                }
                // an unquoted literal value: skip it
                while i < len(b) && !is_space(b[i]) && b[i] != 62 {
                    i += 1;
                }
            }
            continue;
        }
        if c.st == S_ATTR {
            if c.quote == 0 {
                // a value that began with an action continues unquoted
                if is_space(ch) || ch == 62 {
                    c.st = S_TAG;
                    continue;
                }
                i += 1;
                continue;
            }
            if ch == c.quote {
                c.st = S_TAG;
                c.js_quote = 0;
                c.js_comment = 0;
                i += 1;
                continue;
            }
            if c.attr == AK_URL && !is_space(ch) {
                c.url_start = false;
            }
            if c.attr == AK_JS {
                let st = js_step(c, b, i);
                c = st.c;
                i += st.n;
                continue;
            }
            i += 1;
            continue;
        }
        if c.st == S_SCRIPT {
            // the HTML tokenizer ends a script at any "</script", inside a JS
            // string or comment or not
            if starts_ci(b, i, "</script") {
                c.st = S_TAG;
                c.elem = "";
                c.js_quote = 0;
                c.js_comment = 0;
                i += 8;
                continue;
            }
            let st = js_step(c, b, i);
            c = st.c;
            i += st.n;
            continue;
        }
        if c.st == S_STYLE {
            if starts_ci(b, i, "</style") {
                c.st = S_TAG;
                c.elem = "";
                i += 7;
                continue;
            }
            i += 1;
            continue;
        }
        if c.st == S_RCDATA {
            if starts_ci(b, i, "</" + c.elem) {
                c.st = S_TAG;
                i += 2 + len(c.elem);
                c.elem = "";
                continue;
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    return canon(c);
}

// Clears the fields the state does not use, so that two contexts that
// behave alike compare (and cache) alike.
fn canon(c0: Ctx) -> Ctx {
    let c = c0;
    if c.st != S_ATTR {
        c.attr = AK_NORMAL;
        c.quote = 0;
        c.url_start = false;
    }
    if c.st != S_SCRIPT && !(c.st == S_ATTR && c.attr == AK_JS) {
        c.js_quote = 0;
        c.js_comment = 0;
    }
    if c.st == S_TEXT || c.st == S_COMMENT {
        c.elem = "";
    }
    return c;
}

fn is_alpha(c: int) -> bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

struct JsStep {
    c: Ctx,
    n: int,
}

// One step of JavaScript lexing at b[i]: strings (' " `) and the escapes
// in them, // and /* */ comments. Returns the new context and how many
// bytes were consumed. Regular-expression literals are not tracked: a
// quote inside one would confuse this, as in Go's html/template.
fn js_step(c0: Ctx, b: bytes, i: int) -> JsStep {
    let c = c0;
    let ch = b[i];
    let next = 0;
    if i + 1 < len(b) {
        next = b[i + 1];
    }
    if c.js_comment == 1 {
        if ch == 10 {
            c.js_comment = 0;
        }
        return JsStep { c: c, n: 1 };
    }
    if c.js_comment == 2 {
        if ch == 42 && next == 47 {
            c.js_comment = 0;
            return JsStep { c: c, n: 2 };
        }
        return JsStep { c: c, n: 1 };
    }
    if c.js_quote != 0 {
        if ch == 92 && i + 1 < len(b) {
            return JsStep { c: c, n: 2 };
        }
        if ch == c.js_quote {
            c.js_quote = 0;
        }
        return JsStep { c: c, n: 1 };
    }
    if ch == 34 || ch == 39 || ch == 96 {
        c.js_quote = ch;
        return JsStep { c: c, n: 1 };
    }
    if ch == 47 && next == 47 {
        c.js_comment = 1;
        return JsStep { c: c, n: 2 };
    }
    if ch == 47 && next == 42 {
        c.js_comment = 2;
        return JsStep { c: c, n: 2 };
    }
    return JsStep { c: c, n: 1 };
}
