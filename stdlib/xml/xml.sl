// XML 1.0 with namespaces: parse a document into a tree, read it, and
// write one back out. For the APIs that still speak XML (SOAP, payment
// gateways, SAML, RSS and Atom, sitemaps, S3's own errors).
//
//     import "xml";
//
//     let r = xml.parse(body);
//     guard let doc = r else let e = err_of(r) { panic(e); }   // "xml: line 3 col 9: ..."
//     let title = doc.find("channel/title") ?? doc;
//     println(title.text_content());
//     for item in doc.find_all("channel/item") {
//         println(item.child_text("link"));
//     }
//
//     let out = xml.element("note").set_attr("id", "7").add(xml.element("to").add_text("Ada & Bob"));
//     println(xml.write(out));          // <note id="7"><to>Ada &amp; Bob</to></note>
//
// What it refuses, rather than guesses at:
//
//   - A DOCTYPE, by default. Document type definitions are how entity
//     expansion ("billion laughs") and external entities (XXE) get in, and
//     no API this is for needs one. Limits.skip_doctype skips one that has
//     no internal subset (old RSS feeds carry one); an internal subset is
//     always refused.
//   - Any entity but the five predefined ones and character references.
//   - Anything not well-formed: a mismatched or unclosed tag, a duplicate
//     attribute, an unbound namespace prefix, `<` in an attribute value,
//     `]]>` in text, `--` in a comment, a control character, content
//     after the root element.
//   - Any encoding but UTF-8 (and its subset US-ASCII). A byte order mark
//     is skipped.
//   - A document past the limits: 16 MiB, 256 levels deep, 1024
//     attributes on one element, a million nodes.
//
// Line ends become "\n" (XML 1.0 2.11), and tabs and line ends in an
// attribute value become spaces (3.3.3). CDATA sections become text. Names
// are checked by XML's ASCII rules; any non-ASCII character is taken as a
// name character.

import "builder";
import "strings";
import "unicode";

pub enum Kind { Element, Text, Comment, Pi }

pub gc struct Attr {
    // As written, prefix included: "xml:lang".
    name: str,
    local: str,
    // The namespace URI, "" for none (an unprefixed attribute has none).
    ns: str,
    value: str,
}

pub gc struct Node {
    kind: Kind,
    // An element's name as written ("soap:Envelope"); a Pi's target.
    name: str,
    local: str,
    ns: str,
    attrs: [Attr],
    children: [Node],
    // A Text's text, a Comment's or a Pi's content.
    text: str,
    // Where it started, for messages about it.
    line: int,
}

pub struct Limits {
    max_bytes: int,
    max_depth: int,
    max_attrs: int,
    max_nodes: int,
    // Skip a DOCTYPE that has no internal subset instead of refusing it.
    skip_doctype: bool,
    // Keep comments and processing instructions as nodes (dropped by
    // default: few readers want them).
    keep_comments: bool,
}

pub fn default_limits() -> Limits {
    return Limits { max_bytes: 16777216, max_depth: 256, max_attrs: 1024, max_nodes: 1000000,
                    skip_doctype: false, keep_comments: false };
}

let XML_NS = "http://www.w3.org/XML/1998/namespace";
let XMLNS_NS = "http://www.w3.org/2000/xmlns/";

gc struct Scope { prefix: str, uri: str }

gc struct Parser {
    b: bytes,
    n: int,
    pos: int,
    line: int,
    line_start: int,
    nodes: int,
    lim: Limits,
    // In-scope namespace bindings, innermost last.
    scopes: [Scope],
    // Where each attribute of the element being read starts, for messages;
    // reused from element to element.
    apos: [int],
    // The text being gathered for the next Text node: its pieces (one
    // piece, the usual case, is used as is), and where it began. Shared:
    // an element's text is flushed before any child starts.
    tparts: int,
    tfirst: str,
    tbuf: builder.Str,
    tstart: int,
    // Recently seen names and their bytes: a document repeats a few names
    // thousands of times, and a hit here costs no allocation.
    names: [str],
    name_bytes: [bytes],
    name_next: int,
}

let NAME_CACHE = 32;

fn at(p: Parser, pos: int, msg: str) -> str {
    let line = 1;
    let start = 0;
    let i = 0;
    while i < pos && i < p.n {
        if p.b[i] == 10 {
            line += 1;
            start = i + 1;
        }
        i += 1;
    }
    return "xml: line " + to_str(line) + " col " + to_str(pos - start + 1) + ": " + msg;
}

fn here(p: Parser, msg: str) -> str {
    return at(p, p.pos, msg);
}

// ---------------------------------------------------------------- //
// Parsing                                                            //
// ---------------------------------------------------------------- //

// The document's root element.
pub fn parse(text: str) -> result[Node, str] {
    return parse_with(text, default_limits());
}

pub fn parse_with(text: str, lim: Limits) -> result[Node, str] {
    if len(text) > lim.max_bytes {
        return err("xml: the document is larger than " + to_str(lim.max_bytes) + " bytes");
    }
    if !unicode.valid(text) {
        return err("xml: the document is not valid UTF-8");
    }
    let b = to_bytes(text);
    let p = Parser { b: b, n: len(b), pos: 0, line: 1, line_start: 0, nodes: 0, lim: lim, scopes: [], apos: [],
                     tparts: 0, tfirst: "", tbuf: builder.new_str(), tstart: 0,
                     names: [], name_bytes: [], name_next: 0 };
    if p.n >= 3 && b[0] == 239 && b[1] == 187 && b[2] == 191 {
        p.pos = 3;
    }
    if starts(p, "<?xml") && p.pos + 5 < p.n && is_space(b[p.pos + 5]) {
        let dr = declaration(p);
        guard let _d = dr else let e = err_of(dr) { return err(e); }
    }
    let root: opt[Node] = none;
    while true {
        skip_space(p);
        if p.pos >= p.n {
            break;
        }
        if starts(p, "<!--") {
            let cr = comment(p);
            guard let _c = cr else let e = err_of(cr) { return err(e); }
        } else if starts(p, "<?") {
            let pr = pi(p);
            guard let _p = pr else let e = err_of(pr) { return err(e); }
        } else if starts(p, "<!DOCTYPE") {
            if let _r = root {
                return err(here(p, "a DOCTYPE after the root element"));
            }
            let dr = doctype(p);
            guard let _d = dr else let e = err_of(dr) { return err(e); }
        } else if p.b[p.pos] == 60 {
            if let _r = root {
                return err(here(p, "a second root element; a document has exactly one"));
            }
            let er = element_at(p, 1);
            guard let el = er else let e = err_of(er) { return err(e); }
            root = some(el);
        } else {
            return err(here(p, "text outside the root element"));
        }
    }
    guard let r = root else { return err("xml: no root element"); }
    return ok(r);
}

// The byte k past the cursor, or -1 past the end. Markup is recognised
// by these, not by `starts`, which copies its literal: the hot loop sees
// several tests per tag.
fn peek(p: Parser, k: int) -> int {
    let i = p.pos + k;
    if i < p.n {
        return p.b[i];
    }
    return -1;
}

fn at2(p: Parser, a: int, b: int) -> bool {
    return peek(p, 0) == a && peek(p, 1) == b;
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

fn is_space(c: int) -> bool {
    return c == 32 || c == 9 || c == 10 || c == 13;
}

fn skip_space(p: Parser) {
    while p.pos < p.n && is_space(p.b[p.pos]) {
        p.pos += 1;
    }
}

fn is_name_start(c: int) -> bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 58 || c >= 128;
}

fn is_name_char(c: int) -> bool {
    return is_name_start(c) || (c >= 48 && c <= 57) || c == 45 || c == 46;
}

fn name(p: Parser) -> result[str, str] {
    let start = p.pos;
    if p.pos >= p.n || !is_name_start(p.b[p.pos]) {
        return err(here(p, "expected a name"));
    }
    p.pos += 1;
    while p.pos < p.n && is_name_char(p.b[p.pos]) {
        p.pos += 1;
    }
    let n = p.pos - start;
    for i in 0..len(p.names) {
        let nb = p.name_bytes[i];
        if len(nb) != n {
            continue;
        }
        let k = 0;
        while k < n && nb[k] == p.b[start + k] {
            k += 1;
        }
        if k == n {
            return ok(p.names[i]);
        }
    }
    let s = strings.from_bytes(p.b, start, p.pos);
    if len(p.names) < NAME_CACHE {
        push(p.names, s);
        push(p.name_bytes, p.b[start..p.pos]);
    } else {
        p.names[p.name_next] = s;
        p.name_bytes[p.name_next] = p.b[start..p.pos];
        p.name_next = (p.name_next + 1) % NAME_CACHE;
    }
    return ok(s);
}

fn expect(p: Parser, s: str) -> result[bool, str] {
    if !starts(p, s) {
        return err(here(p, "expected " + s));
    }
    p.pos += len(s);
    return ok(true);
}

// <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
fn declaration(p: Parser) -> result[bool, str] {
    p.pos += 5;
    let seen_version = false;
    while true {
        skip_space(p);
        if starts(p, "?>") {
            p.pos += 2;
            break;
        }
        let at = p.pos;
        let nr = name(p);
        guard let key = nr else let e = err_of(nr) { return err(e); }
        skip_space(p);
        let er = expect(p, "=");
        guard let _e = er else let e = err_of(er) { return err(e); }
        skip_space(p);
        let vr = quoted_raw(p);
        guard let v = vr else let e = err_of(vr) { return err(e); }
        if key == "version" {
            if !strings.has_prefix(v, "1.") {
                return err(at(p, at, "XML version " + v + " is not supported; this reads 1.x"));
            }
            seen_version = true;
        } else if key == "encoding" {
            let low = strings.to_lower(v);
            if low != "utf-8" && low != "us-ascii" && low != "ascii" {
                return err(at(p, at, "encoding " + v + " is not supported; send UTF-8"));
            }
        } else if key != "standalone" {
            return err(at(p, at, "unknown declaration field " + key));
        }
    }
    if !seen_version {
        return err(here(p, "the XML declaration has no version"));
    }
    return ok(true);
}

// A quoted value with no references (the declaration's, a DOCTYPE's ids).
fn quoted_raw(p: Parser) -> result[str, str] {
    if p.pos >= p.n || (p.b[p.pos] != 34 && p.b[p.pos] != 39) {
        return err(here(p, "expected a quoted value"));
    }
    let q = p.b[p.pos];
    p.pos += 1;
    let start = p.pos;
    while p.pos < p.n && p.b[p.pos] != q {
        p.pos += 1;
    }
    if p.pos >= p.n {
        return err(at(p, start - 1, "an unclosed quoted value"));
    }
    let v = strings.from_bytes(p.b, start, p.pos);
    p.pos += 1;
    return ok(v);
}

fn doctype(p: Parser) -> result[bool, str] {
    if !p.lim.skip_doctype {
        return err(here(p, "a DOCTYPE is not accepted (DTDs carry entity expansion and XXE); " +
                       "set Limits.skip_doctype to skip one without an internal subset"));
    }
    let start = p.pos;
    p.pos += 9;
    let quote = 0;
    while p.pos < p.n {
        let c = p.b[p.pos];
        if quote != 0 {
            if c == quote {
                quote = 0;
            }
        } else if c == 34 || c == 39 {
            quote = c;
        } else if c == 91 {
            return err(here(p, "a DOCTYPE with an internal subset is never accepted"));
        } else if c == 62 {
            p.pos += 1;
            return ok(true);
        }
        p.pos += 1;
    }
    return err(at(p, start, "an unclosed DOCTYPE"));
}

fn comment(p: Parser) -> result[opt[Node], str] {
    let start = p.pos;
    p.pos += 4;
    let body = p.pos;
    while p.pos + 1 < p.n {
        if p.b[p.pos] == 45 && p.b[p.pos + 1] == 45 {
            if p.pos + 2 < p.n && p.b[p.pos + 2] == 62 {
                let r = check_chars(p, body, p.pos);
                guard let _c = r else let e = err_of(r) { return err(e); }
                let text = normalize_eol(strings.from_bytes(p.b, body, p.pos));
                p.pos += 3;
                return counted(p, Kind.Comment, "", text, start);
            }
            return err(here(p, "-- inside a comment"));
        }
        p.pos += 1;
    }
    return err(at(p, start, "an unclosed comment"));
}

fn pi(p: Parser) -> result[opt[Node], str] {
    let start = p.pos;
    p.pos += 2;
    let nr = name(p);
    guard let target = nr else let e = err_of(nr) { return err(e); }
    if strings.to_lower(target) == "xml" {
        return err(at(p, start, "an XML declaration is allowed only at the very start"));
    }
    let body = p.pos;
    while p.pos + 1 < p.n {
        if p.b[p.pos] == 63 && p.b[p.pos + 1] == 62 {
            let r = check_chars(p, body, p.pos);
            guard let _c = r else let e = err_of(r) { return err(e); }
            let text = strings.trim_start(normalize_eol(strings.from_bytes(p.b, body, p.pos)));
            p.pos += 2;
            return counted(p, Kind.Pi, target, text, start);
        }
        p.pos += 1;
    }
    return err(at(p, start, "an unclosed processing instruction"));
}

// A comment or PI node when they are kept, else none; counted either way.
fn counted(p: Parser, k: Kind, nm: str, text: str, start: int) -> result[opt[Node], str] {
    p.nodes += 1;
    if p.nodes > p.lim.max_nodes {
        return err(at(p, start, "more than " + to_str(p.lim.max_nodes) + " nodes"));
    }
    if !p.lim.keep_comments {
        return ok(none);
    }
    return ok(some(Node { kind: k, name: nm, local: nm, ns: "", attrs: [], children: [], text: text,
                          line: line_of(p, start) }));
}

fn line_of(p: Parser, pos: int) -> int {
    // Lines are counted forward from the last position asked about, so a
    // document's nodes cost one pass over it in all.
    if pos < p.line_start {
        p.line = 1;
        p.line_start = 0;
    }
    let i = p.line_start;
    while i < pos {
        if p.b[i] == 10 {
            p.line += 1;
        }
        i += 1;
    }
    p.line_start = pos;
    return p.line;
}

// Control characters XML 1.0 forbids (2.2): below 0x20 except tab, LF, CR.
fn check_chars(p: Parser, from: int, to: int) -> result[bool, str] {
    let i = from;
    while i < to {
        let c = p.b[i];
        if c < 32 && c != 9 && c != 10 && c != 13 {
            return err(at(p, i, "control character " + to_str(c as int) + " is not allowed in XML"));
        }
        // U+FFFE and U+FFFF (EF BF BE / EF BF BF) are not characters.
        if c == 239 && i + 2 < to && p.b[i + 1] == 191 && (p.b[i + 2] == 190 || p.b[i + 2] == 191) {
            return err(at(p, i, "U+FFFE and U+FFFF are not allowed in XML"));
        }
        i += 1;
    }
    return ok(true);
}

fn normalize_eol(s: str) -> str {
    if !strings.contains(s, "\r") {
        return s;
    }
    return strings.replace(strings.replace(s, "\r\n", "\n"), "\r", "\n");
}

fn element_at(p: Parser, depth: int) -> result[Node, str] {
    if depth > p.lim.max_depth {
        return err(here(p, "elements nested deeper than " + to_str(p.lim.max_depth)));
    }
    p.nodes += 1;
    if p.nodes > p.lim.max_nodes {
        return err(here(p, "more than " + to_str(p.lim.max_nodes) + " nodes"));
    }
    let start = p.pos;
    p.pos += 1;
    let nr = name(p);
    guard let qname = nr else let e = err_of(nr) { return err(e); }
    let attrs: [Attr] = [];
    let empty = false;
    while true {
        let had_space = p.pos < p.n && is_space(p.b[p.pos]);
        skip_space(p);
        if p.pos >= p.n {
            return err(at(p, start, "an unclosed start tag <" + qname));
        }
        if p.b[p.pos] == 62 {
            p.pos += 1;
            break;
        }
        if at2(p, 47, 62) {
            p.pos += 2;
            empty = true;
            break;
        }
        if !had_space {
            return err(here(p, "attributes must be separated by whitespace"));
        }
        let at = p.pos;
        let anr = name(p);
        guard let an = anr else let e = err_of(anr) { return err(e); }
        skip_space(p);
        if peek(p, 0) != 61 {
            return err(here(p, "expected = after attribute " + an));
        }
        p.pos += 1;
        skip_space(p);
        let vr = attr_value(p);
        guard let v = vr else let e = err_of(vr) { return err(e); }
        for other in attrs {
            if other.name == an {
                return err(at(p, at, "attribute " + an + " appears twice"));
            }
        }
        let k = len(attrs);
        push(attrs, Attr { name: an, local: an, ns: "", value: v });
        if k < len(p.apos) {
            p.apos[k] = at;
        } else {
            push(p.apos, at);
        }
        if len(attrs) > p.lim.max_attrs {
            return err(at(p, at, "more than " + to_str(p.lim.max_attrs) + " attributes on one element"));
        }
    }
    // Namespace declarations first: they apply to this element's own name
    // and attributes.
    let pushed = 0;
    for k in 0..len(attrs) {
        let ra = attrs[k];
        let prefix = "";
        if ra.name == "xmlns" {
            prefix = "";
        } else if strings.has_prefix(ra.name, "xmlns:") {
            prefix = strings.slice(ra.name, 6, len(ra.name));
            if len(prefix) == 0 || strings.contains(prefix, ":") {
                return err(at(p, p.apos[k], "a bad namespace prefix in " + ra.name));
            }
            if len(ra.value) == 0 {
                return err(at(p, p.apos[k], "prefix " + prefix + " cannot be bound to an empty namespace"));
            }
            if prefix == "xmlns" || (prefix == "xml" && ra.value != XML_NS) {
                return err(at(p, p.apos[k], "prefix " + prefix + " is reserved"));
            }
        } else {
            continue;
        }
        if ra.value == XMLNS_NS || (ra.value == XML_NS && prefix != "xml") {
            return err(at(p, p.apos[k], "namespace " + ra.value + " is reserved"));
        }
        ra.ns = XMLNS_NS;
        push(p.scopes, Scope { prefix: prefix, uri: ra.value });
        pushed += 1;
    }
    let er = split_name(p, qname, start, true);
    guard let parts = er else let e = err_of(er) { return err(e); }
    for k in 0..len(attrs) {
        let ra = attrs[k];
        if ra.ns == XMLNS_NS || !strings.contains(ra.name, ":") {
            continue;
        }
        let ar = split_name(p, ra.name, p.apos[k], false);
        guard let ap = ar else let e = err_of(ar) { return err(e); }
        ra.local = ap.local;
        ra.ns = ap.ns;
        for j in 0..k {
            let other = attrs[j];
            if other.ns == ap.ns && other.local == ap.local {
                return err(at(p, p.apos[k], "attribute " + ra.name + " repeats {" + ap.ns + "}" + ap.local));
            }
        }
    }
    let node = Node { kind: Kind.Element, name: qname, local: parts.local, ns: parts.ns, attrs: attrs,
                      children: [], text: "", line: line_of(p, start) };
    if !empty {
        let cr = content(p, node, depth, start + 1, start + 1 + len(qname));
        guard let _c = cr else let e = err_of(cr) { return err(e); }
    }
    for _i in 0..pushed {
        pop(p.scopes);
    }
    return ok(node);
}

struct Parts { local: str, ns: str }

// prefix:local, the prefix resolved. An element without a prefix is in
// the default namespace; an attribute without one is in none.
fn split_name(p: Parser, qname: str, pos: int, is_element: bool) -> result[Parts, str] {
    let colon = strings.find(qname, ":");
    if colon < 0 {
        if !is_element {
            return ok(Parts { local: qname, ns: "" });
        }
        return ok(Parts { local: qname, ns: lookup(p, "") });
    }
    let prefix = strings.slice(qname, 0, colon);
    let local = strings.slice(qname, colon + 1, len(qname));
    if len(prefix) == 0 || len(local) == 0 || strings.contains(local, ":") ||
       !is_name_start(to_bytes(local)[0]) {
        return err(at(p, pos, "a bad qualified name " + qname));
    }
    if prefix == "xml" {
        return ok(Parts { local: local, ns: XML_NS });
    }
    let uri = lookup(p, prefix);
    if len(uri) == 0 {
        return err(at(p, pos, "namespace prefix " + prefix + " is not bound (no xmlns:" + prefix + ")"));
    }
    return ok(Parts { local: local, ns: uri });
}

fn lookup(p: Parser, prefix: str) -> str {
    let i = len(p.scopes) - 1;
    while i >= 0 {
        if p.scopes[i].prefix == prefix {
            return p.scopes[i].uri;
        }
        i -= 1;
    }
    return "";
}

fn attr_value(p: Parser) -> result[str, str] {
    if p.pos >= p.n || (p.b[p.pos] != 34 && p.b[p.pos] != 39) {
        return err(here(p, "an attribute value must be quoted"));
    }
    let q = p.b[p.pos];
    let open = p.pos;
    p.pos += 1;
    let start = p.pos;
    let plain = true;
    while p.pos < p.n && p.b[p.pos] != q {
        let c = p.b[p.pos];
        if c == 60 {
            return err(here(p, "< is not allowed in an attribute value; write &lt;"));
        }
        if c == 38 || c == 9 || c == 10 || c == 13 {
            plain = false;
        }
        p.pos += 1;
    }
    if p.pos >= p.n {
        return err(at(p, open, "an unclosed attribute value"));
    }
    let end = p.pos;
    p.pos += 1;
    let cr = check_chars(p, start, end);
    guard let _c = cr else let e = err_of(cr) { return err(e); }
    if plain {
        return ok(strings.from_bytes(p.b, start, end));
    }
    return decode_text(p, start, end, true);
}

// Text with references replaced; in an attribute, whitespace characters
// written literally become spaces (a CRLF one space).
fn decode_text(p: Parser, start: int, end: int, in_attr: bool) -> result[str, str] {
    let out = builder.new_bytes();
    let i = start;
    let run = start;
    while i < end {
        let c = p.b[i];
        if c == 38 {
            out.write(p.b[run..i]);
            let semi = i + 1;
            while semi < end && semi - i <= 12 && p.b[semi] != 59 {
                semi += 1;
            }
            if semi >= end || p.b[semi] != 59 {
                return err(at(p, i, "& must start a reference such as &amp;"));
            }
            let ref = strings.from_bytes(p.b, i + 1, semi);
            let rr = reference(p, ref, i);
            guard let s = rr else let e = err_of(rr) { return err(e); }
            out.write(to_bytes(s));
            i = semi + 1;
            run = i;
        } else if c == 13 {
            out.write(p.b[run..i]);
            if in_attr {
                out.write_byte(32);
            } else {
                out.write_byte(10);
            }
            if i + 1 < end && p.b[i + 1] == 10 {
                i += 1;
            }
            i += 1;
            run = i;
        } else if in_attr && (c == 9 || c == 10) {
            out.write(p.b[run..i]);
            out.write_byte(32);
            i += 1;
            run = i;
        } else {
            i += 1;
        }
    }
    out.write(p.b[run..end]);
    return ok(to_str(out.finish()));
}

fn reference(p: Parser, r: str, pos: int) -> result[str, str] {
    if r == "lt" { return ok("<"); }
    if r == "gt" { return ok(">"); }
    if r == "amp" { return ok("&"); }
    if r == "quot" { return ok("\""); }
    if r == "apos" { return ok("'"); }
    if !strings.has_prefix(r, "#") {
        return err(at(p, pos, "entity &" + r + "; is not defined (only &lt; &gt; &amp; &quot; &apos; and &#..;)"));
    }
    let digits = strings.slice(r, 1, len(r));
    let base = 10;
    if strings.has_prefix(digits, "x") {
        base = 16;
        digits = strings.slice(digits, 1, len(digits));
    }
    if len(digits) == 0 || len(digits) > 8 {
        return err(at(p, pos, "a bad character reference &" + r + ";"));
    }
    let cp = 0;
    for d in to_bytes(digits) {
        let v = -1;
        if d >= 48 && d <= 57 {
            v = (d as int) - 48;
        } else if base == 16 && d >= 97 && d <= 102 {
            v = (d as int) - 87;
        } else if base == 16 && d >= 65 && d <= 70 {
            v = (d as int) - 55;
        }
        if v < 0 || v >= base {
            return err(at(p, pos, "a bad character reference &" + r + ";"));
        }
        cp = cp * base + v;
    }
    let legal = cp == 9 || cp == 10 || cp == 13 || (cp >= 32 && cp <= 55295) ||
                (cp >= 57344 && cp <= 65533) || (cp >= 65536 && cp <= 1114111);
    if !legal {
        return err(at(p, pos, "&" + r + "; is not a character XML allows"));
    }
    let er = unicode.encode(cp);
    guard let s = er else { return err(at(p, pos, "&" + r + "; is not a character XML allows")); }
    return ok(s);
}

fn content(p: Parser, node: Node, depth: int, name_from: int, name_to: int) -> result[bool, str] {
    let text_start = p.pos;
    while true {
        if p.pos >= p.n {
            return err(at(p, text_start, "element <" + node.name + "> is not closed"));
        }
        let c = p.b[p.pos];
        if c != 60 {
            let start = p.pos;
            let plain = true;
            while p.pos < p.n && p.b[p.pos] != 60 {
                let d = p.b[p.pos];
                if d == 38 || d == 13 {
                    plain = false;
                }
                if d == 93 && p.pos + 2 < p.n && p.b[p.pos + 1] == 93 && p.b[p.pos + 2] == 62 {
                    return err(here(p, "]]> is not allowed in text; write ]]&gt;"));
                }
                p.pos += 1;
            }
            let cr = check_chars(p, start, p.pos);
            guard let _c = cr else let e = err_of(cr) { return err(e); }
            if plain {
                gather(p, strings.from_bytes(p.b, start, p.pos), start);
            } else {
                let dr = decode_text(p, start, p.pos, false);
                guard let s = dr else let e = err_of(dr) { return err(e); }
                gather(p, s, start);
            }
            continue;
        }
        if at2(p, 60, 47) {
            flush_text(p, node);
            let close = p.pos;
            p.pos += 2;
            // The name is compared in place: the end tag of every element
            // would otherwise copy it.
            let same = p.pos + (name_to - name_from) <= p.n;
            let k = 0;
            while same && k < name_to - name_from {
                if p.b[p.pos + k] != p.b[name_from + k] {
                    same = false;
                }
                k += 1;
            }
            if same && p.pos + k < p.n && is_name_char(p.b[p.pos + k]) {
                same = false;
            }
            if !same {
                let nr = name(p);
                guard let nm = nr else let e = err_of(nr) { return err(e); }
                return err(at(p, close, "</" + nm + "> closes <" + node.name + "> (line " + to_str(node.line) + ")"));
            }
            p.pos += k;
            skip_space(p);
            if peek(p, 0) != 62 {
                return err(here(p, "expected > to end </" + node.name));
            }
            p.pos += 1;
            return ok(true);
        }
        if at2(p, 60, 33) && peek(p, 2) == 91 && starts(p, "<![CDATA[") {
            let start = p.pos + 9;
            let i = start;
            let found = -1;
            while i + 2 < p.n {
                if p.b[i] == 93 && p.b[i + 1] == 93 && p.b[i + 2] == 62 {
                    found = i;
                    break;
                }
                i += 1;
            }
            if found < 0 {
                return err(here(p, "an unclosed CDATA section"));
            }
            let cr = check_chars(p, start, found);
            guard let _c = cr else let e = err_of(cr) { return err(e); }
            gather(p, normalize_eol(strings.from_bytes(p.b, start, found)), p.pos);
            p.pos = found + 3;
            continue;
        }
        if (at2(p, 60, 33) && peek(p, 2) == 45 && peek(p, 3) == 45) || at2(p, 60, 63) {
            let r = comment_or_pi(p);
            guard let maybe = r else let e = err_of(r) { return err(e); }
            if let n = maybe {
                flush_text(p, node);
                push(node.children, n);
            }
            continue;
        }
        if at2(p, 60, 33) {
            return err(here(p, "a declaration is not allowed inside an element"));
        }
        flush_text(p, node);
        let er = element_at(p, depth + 1);
        guard let child = er else let e = err_of(er) { return err(e); }
        push(node.children, child);
        text_start = p.pos;
    }
    return ok(true);
}

fn comment_or_pi(p: Parser) -> result[opt[Node], str] {
    if peek(p, 1) == 33 {
        return comment(p);
    }
    return pi(p);
}

// Adjacent text (with CDATA and references) is one Text node.
fn gather(p: Parser, piece: str, at_pos: int) {
    if len(piece) == 0 {
        return;
    }
    if p.tparts == 0 {
        p.tfirst = piece;
        p.tstart = at_pos;
    } else {
        if p.tparts == 1 {
            p.tbuf.write(p.tfirst);
        }
        p.tbuf.write(piece);
    }
    p.tparts += 1;
}

fn flush_text(p: Parser, node: Node) {
    if p.tparts == 0 {
        return;
    }
    let text = p.tfirst;
    if p.tparts > 1 {
        text = p.tbuf.finish();
        p.tbuf.reset();
    }
    p.tparts = 0;
    p.tfirst = "";
    p.nodes += 1;
    push(node.children, Node { kind: Kind.Text, name: "", local: "", ns: "", attrs: [], children: [],
                               text: text, line: line_of(p, p.tstart) });
}

// ---------------------------------------------------------------- //
// Reading the tree                                                   //
// ---------------------------------------------------------------- //

impl Node {
    // An attribute's value by its name as written ("id", "xml:lang").
    pub fn attr(self: Node, name: str) -> opt[str] {
        for a in self.attrs {
            if a.name == name {
                return some(a.value);
            }
        }
        return none;
    }

    // An attribute's value by namespace URI and local name.
    pub fn attr_ns(self: Node, ns: str, local: str) -> opt[str] {
        for a in self.attrs {
            if a.ns == ns && a.local == local {
                return some(a.value);
            }
        }
        return none;
    }

    // Child elements, in order, without text, comments or PIs.
    pub fn elements(self: Node) -> [Node] {
        let out: [Node] = [];
        for c in self.children {
            if c.kind == Kind.Element {
                push(out, c);
            }
        }
        return out;
    }

    // The first child element with this local name, in any namespace.
    pub fn child(self: Node, local: str) -> opt[Node] {
        for c in self.children {
            if c.kind == Kind.Element && c.local == local {
                return some(c);
            }
        }
        return none;
    }

    // The first child element with this namespace and local name.
    pub fn child_ns(self: Node, ns: str, local: str) -> opt[Node] {
        for c in self.children {
            if c.kind == Kind.Element && c.ns == ns && c.local == local {
                return some(c);
            }
        }
        return none;
    }

    // Every child element with this local name.
    pub fn children_named(self: Node, local: str) -> [Node] {
        let out: [Node] = [];
        for c in self.children {
            if c.kind == Kind.Element && c.local == local {
                push(out, c);
            }
        }
        return out;
    }

    // The text of this node and everything under it, in document order.
    pub fn text_content(self: Node) -> str {
        if self.kind == Kind.Text {
            return self.text;
        }
        if self.kind != Kind.Element {
            return "";
        }
        let out = builder.new_str();
        collect_text(self, out);
        return out.finish();
    }

    // The trimmed text of the first child element named `local`, or "".
    pub fn child_text(self: Node, local: str) -> str {
        guard let c = self.child(local) else { return ""; }
        return strings.trim(c.text_content());
    }

    // The first element at a path of local names below this one:
    // "channel/item/title". none when any step is missing.
    pub fn find(self: Node, path: str) -> opt[Node] {
        let all = self.find_all(path);
        if len(all) == 0 {
            return none;
        }
        return some(all[0]);
    }

    // Every element at a path of local names below this one, in document
    // order.
    pub fn find_all(self: Node, path: str) -> [Node] {
        let level: [Node] = [self];
        let steps = 0;
        for step in strings.split(path, "/") {
            if len(step) == 0 {
                continue;
            }
            steps += 1;
            let next: [Node] = [];
            for n in level {
                for c in n.children {
                    if c.kind == Kind.Element && c.local == step {
                        push(next, c);
                    }
                }
            }
            level = next;
        }
        if steps == 0 {
            let none_found: [Node] = [];
            return none_found;
        }
        return level;
    }
}

fn collect_text(n: Node, out: builder.Str) {
    for c in n.children {
        if c.kind == Kind.Text {
            out.write(c.text);
        } else if c.kind == Kind.Element {
            collect_text(c, out);
        }
    }
}

// ---------------------------------------------------------------- //
// Building and writing                                               //
// ---------------------------------------------------------------- //

// A new element named `name` (prefix included, if any). Declare its
// namespaces as attributes: set_attr("xmlns", uri), set_attr("xmlns:p", uri).
pub fn element(name: str) -> Node {
    return Node { kind: Kind.Element, name: name, local: local_of(name), ns: "", attrs: [], children: [],
                  text: "", line: 0 };
}

pub fn text_node(s: str) -> Node {
    return Node { kind: Kind.Text, name: "", local: "", ns: "", attrs: [], children: [], text: s, line: 0 };
}

fn local_of(name: str) -> str {
    let colon = strings.find(name, ":");
    if colon < 0 {
        return name;
    }
    return strings.slice(name, colon + 1, len(name));
}

impl Node {
    // Sets an attribute, replacing one of the same name. Returns the node.
    pub fn set_attr(self: Node, name: str, value: str) -> Node {
        for a in self.attrs {
            if a.name == name {
                a.value = value;
                return self;
            }
        }
        push(self.attrs, Attr { name: name, local: local_of(name), ns: "", value: value });
        return self;
    }

    // Appends a child node. Returns this node, so calls chain.
    pub fn add(self: Node, child: Node) -> Node {
        push(self.children, child);
        return self;
    }

    pub fn add_text(self: Node, s: str) -> Node {
        push(self.children, text_node(s));
        return self;
    }
}

// Text for element content: & < > escaped (> too, so "]]>" never appears).
pub fn escape_text(s: str) -> str {
    let b = to_bytes(s);
    let dirty = false;
    for c in b {
        if c == 38 || c == 60 || c == 62 || c == 13 {
            dirty = true;
            break;
        }
    }
    if !dirty {
        return s;
    }
    let out = builder.new_bytes();
    let run = 0;
    for i in 0..len(b) {
        let rep = "";
        let c = b[i];
        if c == 38 { rep = "&amp;"; }
        else if c == 60 { rep = "&lt;"; }
        else if c == 62 { rep = "&gt;"; }
        else if c == 13 { rep = "&#13;"; }
        if len(rep) > 0 {
            out.write(b[run..i]);
            out.write(to_bytes(rep));
            run = i + 1;
        }
    }
    out.write(b[run..len(b)]);
    return to_str(out.finish());
}

// Text for a double-quoted attribute value. Tab, LF and CR are written as
// references, or a reader would turn them into spaces.
pub fn escape_attr(s: str) -> str {
    let b = to_bytes(s);
    let out = builder.new_bytes();
    let run = 0;
    for i in 0..len(b) {
        let rep = "";
        let c = b[i];
        if c == 38 { rep = "&amp;"; }
        else if c == 60 { rep = "&lt;"; }
        else if c == 62 { rep = "&gt;"; }
        else if c == 34 { rep = "&quot;"; }
        else if c == 9 { rep = "&#9;"; }
        else if c == 10 { rep = "&#10;"; }
        else if c == 13 { rep = "&#13;"; }
        if len(rep) > 0 {
            out.write(b[run..i]);
            out.write(to_bytes(rep));
            run = i + 1;
        }
    }
    out.write(b[run..len(b)]);
    return to_str(out.finish());
}

// The element and everything under it, as compact XML. Names are written
// as given; text and attribute values are escaped. A comment containing
// "--" or a PI containing "?>" cannot be written and is an error, as is a
// name that is not an XML name or a control character in text.
pub fn write(n: Node) -> result[str, str] {
    let out = builder.new_str();
    let r = write_node(n, out, 0);
    guard let _w = r else let e = err_of(r) { return err(e); }
    return ok(out.finish());
}

// write, after an XML declaration.
pub fn write_document(root: Node) -> result[str, str] {
    let r = write(root);
    guard let body = r else let e = err_of(r) { return err(e); }
    return ok("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + body);
}

fn name_ok(s: str) -> bool {
    let b = to_bytes(s);
    if len(b) == 0 || !is_name_start(b[0]) {
        return false;
    }
    for c in b {
        if !is_name_char(c) {
            return false;
        }
    }
    return true;
}

fn text_ok(s: str) -> bool {
    for c in to_bytes(s) {
        if c < 32 && c != 9 && c != 10 && c != 13 {
            return false;
        }
    }
    return true;
}

fn write_node(n: Node, out: builder.Str, depth: int) -> result[bool, str] {
    if depth > 1024 {
        return err("xml: write: the tree is deeper than 1024 levels");
    }
    switch n.kind {
        case Kind.Text {
            if !text_ok(n.text) {
                return err("xml: write: a control character in text");
            }
            out.write(escape_text(n.text));
        }
        case Kind.Comment {
            if strings.contains(n.text, "--") || strings.has_suffix(n.text, "-") || !text_ok(n.text) {
                return err("xml: write: a comment cannot contain -- or end in -");
            }
            out.write("<!--").write(n.text).write("-->");
        }
        case Kind.Pi {
            if !name_ok(n.name) || strings.to_lower(n.name) == "xml" || strings.contains(n.text, "?>") {
                return err("xml: write: a bad processing instruction " + n.name);
            }
            out.write("<?").write(n.name);
            if len(n.text) > 0 {
                out.write(" ").write(n.text);
            }
            out.write("?>");
        }
        case Kind.Element {
            if !name_ok(n.name) {
                return err("xml: write: " + n.name + " is not an XML name");
            }
            out.write("<").write(n.name);
            for a in n.attrs {
                if !name_ok(a.name) {
                    return err("xml: write: " + a.name + " is not an XML name");
                }
                if !text_ok(a.value) {
                    return err("xml: write: a control character in attribute " + a.name);
                }
                out.write(" ").write(a.name).write("=\"").write(escape_attr(a.value)).write("\"");
            }
            if len(n.children) == 0 {
                out.write("/>");
                return ok(true);
            }
            out.write(">");
            for c in n.children {
                let r = write_node(c, out, depth + 1);
                guard let _w = r else let e = err_of(r) { return err(e); }
            }
            out.write("</").write(n.name).write(">");
        }
    }
    return ok(true);
}
