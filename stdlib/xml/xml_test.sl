import "strings";
import "unicode";

fn cp(n: int) -> str { return unicode.encode(n) ?? ""; }

// s with the byte at i replaced by v.
fn with_byte(s: str, i: int, v: int) -> str {
    let b = to_bytes(s);
    b[i] = v as u8;
    return to_str(b);
}

fn parsed(s: str) -> Node {
    let r = parse(s);
    guard let n = r else let e = err_of(r) { panic(e); }
    return n;
}

fn refused(s: str) -> str {
    let r = parse(s);
    guard let _n = r else let e = err_of(r) { return e; }
    panic("accepted: " + s);
}

fn written(n: Node) -> str {
    let r = write(n);
    guard let s = r else let e = err_of(r) { panic(e); }
    return s;
}

fn test_parse_elements_attributes_and_text() {
    let doc = parsed("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!-- top -->\n" +
                     "<rss version=\"2.0\"><channel><title>News &amp; notes</title>" +
                     "<item><title>One</title><link>https://a.example/1</link></item>" +
                     "<item><title>Two</title><link> https://a.example/2 </link></item></channel></rss>\n");
    assert(doc.name == "rss" && (doc.attr("version") ?? "") == "2.0");
    let title = doc.find("channel/title") ?? doc;
    assert(title.text_content() == "News & notes", title.text_content());
    let items = doc.find_all("channel/item");
    assert(len(items) == 2 && items[1].child_text("link") == "https://a.example/2");
    guard let _x = doc.find("channel/missing") else {
        assert(len(doc.find_all("")) == 0);
        return;
    }
    panic("found a missing element");
}

fn test_references_cdata_and_line_ends() {
    let d = parsed("<a x='1 &lt; 2&#x9;&#10;' y=\"tab\there\r\nnext\">A&#65;&#x1F600;<![CDATA[<raw> & ]]>\r\nz\rq</a>");
    assert((d.attr("x") ?? "") == "1 < 2\t\n", d.attr("x") ?? "");
    assert((d.attr("y") ?? "") == "tab here next", d.attr("y") ?? "");
    assert(d.text_content() == "AA" + cp(128512) + "<raw> & \nz\nq", d.text_content());
    assert(len(d.children) == 1, "adjacent text and CDATA are one node");
}

fn test_namespaces_resolve() {
    let d = parsed("<soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns=\"urn:default\">" +
                   "<soap:Body><Get xmlns:x=\"urn:x\" x:id=\"7\" plain=\"p\" xml:lang=\"en\"/></soap:Body></soap:Envelope>");
    assert(d.local == "Envelope" && d.ns == "http://schemas.xmlsoap.org/soap/envelope/");
    let body = d.child_ns("http://schemas.xmlsoap.org/soap/envelope/", "Body") ?? d;
    let get = body.child("Get") ?? d;
    assert(get.ns == "urn:default", "unprefixed elements take the default namespace");
    assert((get.attr_ns("urn:x", "id") ?? "") == "7");
    assert((get.attr_ns("", "plain") ?? "") == "p", "unprefixed attributes have no namespace");
    assert((get.attr_ns("http://www.w3.org/XML/1998/namespace", "lang") ?? "") == "en");
    // A default namespace undeclared below.
    let u = parsed("<a xmlns=\"urn:a\"><b xmlns=\"\"/></a>");
    assert(((u.child("b") ?? u).ns) == "");
}

fn test_comments_and_pis_kept_on_request() {
    let lim = default_limits();
    lim.keep_comments = true;
    let r = parse_with("<a><!-- c --><?app run fast?>t</a>", lim);
    guard let d = r else let e = err_of(r) { panic(e); }
    assert(len(d.children) == 3 && d.children[0].kind == Kind.Comment && d.children[0].text == " c ");
    assert(d.children[1].kind == Kind.Pi && d.children[1].name == "app" && d.children[1].text == "run fast");
    assert(len(parsed("<a><!-- c -->t</a>").children) == 1, "dropped by default");
}

fn test_doctype_refused_unless_skipped() {
    assert(strings.contains(refused("<!DOCTYPE rss SYSTEM \"x.dtd\"><rss/>"), "DOCTYPE is not accepted"));
    let lim = default_limits();
    lim.skip_doctype = true;
    let r = parse_with("<!DOCTYPE rss PUBLIC \"-//N//DTD RSS 0.91//EN\" \"http://x/rss-0.91.dtd\"><rss/>", lim);
    guard let _d = r else let e = err_of(r) { panic(e); }
    let bomb = "<!DOCTYPE l [<!ENTITY a \"aaaa\"><!ENTITY b \"&a;&a;\">]><l>&b;</l>";
    let br = parse_with(bomb, lim);
    guard let _b = br else let e = err_of(br) { assert(strings.contains(e, "internal subset"), e); return; }
    panic("accepted an internal subset");
}

fn test_malformed_documents_are_refused_with_a_position() {
    let cases = [
        ["<a><b></a>", "closes <b>"],
        ["<a>", "not closed"],
        ["<a x=\"1\" x=\"2\"/>", "appears twice"],
        ["<a x=1/>", "must be quoted"],
        ["<a x=\"<\"/>", "< is not allowed"],
        ["<a>]]></a>", "]]> is not allowed"],
        ["<a><!-- a -- b --></a>", "-- inside a comment"],
        ["<a>&nbsp;</a>", "not defined"],
        ["<a>&#0;</a>", "not a character"],
        ["<a>&#xD800;</a>", "not a character"],
        ["<a>& b</a>", "must start a reference"],
        [with_byte("<a>.</a>", 3, 1), "control character"],
        ["<a/><b/>", "second root"],
        ["<a/>text", "outside the root"],
        ["", "no root element"],
        ["<p:a/>", "not bound"],
        ["<a xmlns:p=\"\"/>", "empty namespace"],
        ["<a xmlns:p=\"urn:1\" xmlns:q=\"urn:1\" p:x=\"1\" q:x=\"2\"/>", "repeats"],
        ["<a b=\"1\"c=\"2\"/>", "separated by whitespace"],
        ["<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a/>", "send UTF-8"],
        ["<?xml version=\"2.0\"?><a/>", "not supported"],
        ["<a/><?xml version=\"1.0\"?>", "only at the very start"],
        ["<a><!ELEMENT x ANY></a>", "declaration is not allowed"],
        ["<1a/>", "expected a name"]
    ];
    for c in cases {
        let e = refused(c[0]);
        assert(strings.contains(e, c[1]) && strings.has_prefix(e, "xml: "), c[0] + " -> " + e);
    }
    let e = refused("<a>\n  <b>\n</a>");
    assert(strings.has_prefix(e, "xml: line 3 col 1: </a> closes <b> (line 2)"), e);
}

fn test_limits() {
    let deep = strings.repeat("<a>", 300) + strings.repeat("</a>", 300);
    assert(strings.contains(refused(deep), "deeper than 256"));
    let lim = default_limits();
    lim.max_nodes = 10;
    let wide = "<r>" + strings.repeat("<i/>", 20) + "</r>";
    let r = parse_with(wide, lim);
    guard let _w = r else let e = err_of(r) { assert(strings.contains(e, "more than 10 nodes"), e); return; }
    panic("past max_nodes");
}

fn test_bom_and_invalid_utf8() {
    let d = parsed(cp(65279) + "<a/>");
    assert(d.name == "a");
    let bad = with_byte("<a>.</a>", 3, 255);
    assert(strings.contains(refused(bad), "not valid UTF-8"));
}

fn test_write_round_trips() {
    let n = element("p:note").set_attr("xmlns:p", "urn:p").set_attr("id", "a\"b<c>&\td\n")
        .add(element("to").add_text("Ada & <Bob> ]]>"))
        .add(element("empty"));
    let s = written(n);
    assert(s == "<p:note xmlns:p=\"urn:p\" id=\"a&quot;b&lt;c&gt;&amp;&#9;d&#10;\"><to>Ada &amp; &lt;Bob&gt; ]]&gt;</to><empty/></p:note>", s);
    let back = parsed(s);
    assert((back.attr("id") ?? "") == "a\"b<c>&\td\n" && back.child_text("to") == "Ada & <Bob> ]]>");
    assert(back.ns == "urn:p" && back.local == "note");
    let d = write_document(element("a")) ?? "";
    assert(d == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a/>", d);
    // Unwritable trees are errors, not broken documents.
    let r1 = write(element("bad name"));
    guard let _a = r1 else {
        let c = element("a");
        push(c.children, Node { kind: Kind.Comment, name: "", local: "", ns: "", attrs: [], children: [],
                                text: "x -- y", line: 0 });
        let r2 = write(c);
        guard let _b = r2 else {
            let r3 = write(element("a").add_text(with_byte("bell.", 4, 7)));
            guard let _c = r3 else { return; }
            panic("wrote a control character");
        }
        panic("wrote -- in a comment");
    }
    panic("wrote a bad name");
}
