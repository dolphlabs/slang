// Unit tests: `slangc test stdlib/template`.

gc struct Item {
    name: str,
    price: int,
    tags: [str],
}

gc struct Data {
    s: str,
    n: int,
    f: float,
    yes: bool,
    no: bool,
    items: [Item],
    empty: [str],
    nick: opt[str],
    html: str,
}

fn data() -> Data {
    return Data {
        s: "<script>alert('x')</script> & \"q\"",
        n: 42,
        f: 1.5,
        yes: true,
        no: false,
        items: [Item { name: "pen", price: 3, tags: ["a", "b"] }, Item { name: "ink", price: 12, tags: [] }],
        empty: [],
        nick: none,
        html: "<em>ok</em>"
    };
}

fn t_of(src: str) -> Template {
    let r = parse("t", src);
    guard let t = r else let e = err_of(r) { panic("parse: " + e); }
    return t;
}

fn out(src: str) -> str {
    let r = render(t_of(src), data());
    guard let s = r else let e = err_of(r) { panic("render: " + e); }
    return s;
}

fn parse_error(src: str) -> str {
    let r = parse("t", src);
    guard let t = r else let e = err_of(r) { return e; }
    let rr = render(t, data());
    guard let _s = rr else let e = err_of(rr) { return e; }
    panic("expected an error for: " + src);
}

fn render_error(src: str) -> str {
    let rr = render(t_of(src), data());
    guard let _s = rr else let e = err_of(rr) { return e; }
    panic("expected a render error for: " + src);
}

// ---- escaping by context -------------------------------------------------------

fn test_should_escape_text_and_attributes() {
    assert(out("<p>{{ .s }}</p>") == "<p>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &#34;q&#34;</p>", out("<p>{{ .s }}</p>"));
    assert(out("<p title=\"{{ .s }}\">") == "<p title=\"&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &#34;q&#34;\">", "attribute");
    assert(out("<textarea>{{ .s }}</textarea>") == "<textarea>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &#34;q&#34;</textarea>", "rcdata");
}

fn test_should_check_url_schemes() {
    let t = t_of("<a href=\"{{ .u }}\">");
    let cases = ["javascript:alert(1)", " JavaScript:alert(1)", "data:text/html,<x>", "vbscript:x"];
    for u in cases {
        let m: map[str]str = {};
        m["u"] = u;
        let r = render(t, m) ?? "";
        assert(r == "<a href=\"about:invalid#blocked\">", u + " -> " + r);
    }
    let ok_cases: map[str]str = {};
    ok_cases["https://x.example/a?b=c&d=e"] = "<a href=\"https://x.example/a?b=c&amp;d=e\">";
    ok_cases["/rel/path"] = "<a href=\"/rel/path\">";
    ok_cases["mailto:a@b.c"] = "<a href=\"mailto:a@b.c\">";
    ok_cases["https://x/a b\"c"] = "<a href=\"https://x/a%20b%22c\">";
    for u, want in ok_cases {
        let m: map[str]str = {};
        m["u"] = u;
        let r = render(t, m) ?? "";
        assert(r == want, u + " -> " + r);
    }
}

fn test_should_percent_encode_values_inside_urls() {
    let t = t_of("<a href=\"/search?q={{ .q }}&p=/x/{{ .q }}\">");
    let m: map[str]str = {};
    m["q"] = "a b&c=d/e?\"";
    let r = render(t, m) ?? "";
    assert(r == "<a href=\"/search?q=a%20b%26c%3Dd%2Fe%3F%22&p=/x/a%20b%26c%3Dd%2Fe%3F%22\">", r);
}

fn test_should_write_json_in_scripts() {
    assert(out("<script>var d = {{ .items }};</script>") ==
           "<script>var d = [{\"name\":\"pen\",\"price\":3,\"tags\":[\"a\",\"b\"]},{\"name\":\"ink\",\"price\":12,\"tags\":[]}];</script>",
           out("<script>var d = {{ .items }};</script>"));
    assert(out("<script>var s = {{ .s }};</script>") ==
           "<script>var s = \"\\u003cscript\\u003ealert(\\u0027x\\u0027)\\u003c/script\\u003e \\u0026 \\u0022q\\u0022\";</script>",
           out("<script>var s = {{ .s }};</script>"));
    assert(out("<script>var n = {{ .n }}, b = {{ .no }};</script>") == "<script>var n = 42, b = false;</script>", "numbers and bools");
}

fn test_should_escape_inside_js_strings() {
    let r = out("<script>var s = \"x{{ .s }}y\"; var t = 'p{{ .s }}';</script>");
    assert(!strings.contains(r, "</script> &"), r);
    assert(strings.contains(r, "\"x\\u003cscript\\u003ealert(\\u0027x\\u0027)\\u003c/script\\u003e \\u0026 \\u0022q\\u0022y\""), r);
    let attr = out("<button onclick=\"go({{ .s }})\">");
    assert(strings.contains(attr, "onclick=\"go(&#34;\\u003cscript"), attr);
}

fn test_should_end_a_script_at_close_tag_inside_a_js_string() {
    // the browser ends the script at </script> even inside the string, so
    // the action after it is HTML text, not JS
    let r = out("<script>var s = \"</script>{{ .s }}");
    assert(strings.has_suffix(r, "</script>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &#34;q&#34;"), r);
}

fn test_should_filter_css_values() {
    let t = t_of("<p style=\"color: {{ .c }}\"><style>p { width: {{ .c }} }</style>");
    let m: map[str]str = {};
    m["c"] = "red";
    assert((render(t, m) ?? "") == "<p style=\"color: red\"><style>p { width: red }</style>", "plain value");
    m["c"] = "expression(alert(1))";
    assert((render(t, m) ?? "") == "<p style=\"color: ZgotmplZ\"><style>p { width: ZgotmplZ }</style>", "blocked");
}

fn test_should_refuse_actions_where_no_escaping_is_safe() {
    // "<" then an action is text, as a browser reads it: the value is escaped
    assert(out("<{{ .s }}>") == "<&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &#34;q&#34;>", out("<{{ .s }}>"));
    assert(strings.contains(parse_error("<p{{ .s }}>"), "inside a tag"), "tag name");
    assert(strings.contains(parse_error("<p {{ .s }}>"), "inside a tag"), "attribute name");
    assert(strings.contains(parse_error("<p title={{ .s }}>"), "unquoted"), "unquoted value");
    assert(strings.contains(parse_error("<!-- {{ .s }} -->"), "comment"), "html comment");
    assert(strings.contains(parse_error("<script>// {{ .s }}\n</script>"), "JavaScript comment"), "js comment");
}

fn test_should_refuse_branches_that_end_in_different_contexts() {
    assert(strings.contains(parse_error("{{ if .yes }}<a href=\"{{ end }}x"), "different contexts"), "if");
    assert(strings.contains(parse_error("{{ range .items }}<p title=\"{{ end }}"), "range body"), "range");
}

fn test_should_pass_raw_html_only_in_text() {
    assert(out("<div>{{ .html | raw }}</div>") == "<div><em>ok</em></div>", "raw in text");
    assert(out("<div title=\"{{ .html | raw }}\">") == "<div title=\"&lt;em&gt;ok&lt;/em&gt;\">", "raw in an attribute is still escaped");
}

// ---- control flow -------------------------------------------------------------------

fn test_should_branch_and_range() {
    assert(out("{{ if .yes }}Y{{ else }}N{{ end }}{{ if .no }}Y{{ else if .n }}M{{ else }}N{{ end }}") == "YM", "if/else if");
    assert(out("{{ range .items }}[{{ .name }}:{{ .price }}]{{ end }}") == "[pen:3][ink:12]", "range dot");
    assert(out("{{ range $i, $it := .items }}{{ $i }}={{ $it.name }} {{ end }}") == "0=pen 1=ink ", "range vars");
    assert(out("{{ range .empty }}x{{ else }}none{{ end }}") == "none", "range else");
    assert(out("{{ with .nick }}{{ . }}{{ else }}anonymous{{ end }}") == "anonymous", "with else");
    assert(out("{{ range .items }}{{ range .tags }}{{ . }}{{ end }}|{{ end }}") == "ab||", "nested range");
    assert(out("{{ range .items }}{{ $.n }}{{ end }}") == "4242", "$ is the root");
    // a body that passes through a URL attribute still ends in plain text
    assert(out("{{ range .items }}<a href=\"/p/{{ .name }}\" onclick=\"f()\">{{ .name }}</a>{{ end }}") ==
           "<a href=\"/p/pen\" onclick=\"f()\">pen</a><a href=\"/p/ink\" onclick=\"f()\">ink</a>", "url attribute in a range");
}

fn test_should_declare_assign_and_scope_variables() {
    assert(out("{{ $x := .n }}{{ $x }} {{ $x = \"b\" }}{{ $x }}") == "42 b", "declare and assign");
    // an assignment inside a block changes the outer variable
    assert(out("{{ $t := 0 }}{{ range .items }}{{ $t = add $t .price }}{{ end }}{{ $t }}") == "15", "accumulate");
    // a declaration inside a block ends with it
    assert(strings.contains(parse_error("{{ if .yes }}{{ $y := 1 }}{{ end }}{{ $y }}"), "undefined variable $y"), "block scope");
    assert(strings.contains(parse_error("{{ range $i, $x := .items }}{{ end }}{{ $x }}"), "undefined variable $x"), "range scope");
    assert(out("{{ if $m := .nick }}{{ $m }}{{ else }}[{{ $m }}]{{ end }}") == "[]", "if declaration in every branch");
    assert(out("{{ with $f := .f }}{{ $f }}={{ . }}{{ end }}") == "1.5=1.5", "with declaration");
    // a shadowing declaration is the innermost
    assert(out("{{ $v := 1 }}{{ range .items }}{{ $v := .name }}{{ $v }}{{ end }}{{ $v }}") == "penink1", "shadowing");
    // a define starts with only $
    assert(strings.contains(parse_error("{{ $z := 1 }}{{ define \"d\" }}{{ $z }}{{ end }}"), "undefined variable $z"), "define scope");
    assert(strings.contains(parse_error("{{ $q = 1 }}"), "undefined variable $q"), "assign undeclared");
    assert(strings.contains(parse_error("{{ $a-b := 1 }}"), "bad variable name"), "bad name");
}

fn test_should_trim_whitespace_and_skip_comments() {
    assert(out("a  {{- .n -}}  b") == "a42b", "trim both");
    assert(out("a {{/* note */}} b") == "a  b", "comment");
    assert(out("<ul>\n  {{- range .items }}\n  <li>{{ .name }}</li>\n  {{- end }}\n</ul>") ==
           "<ul>\n  <li>pen</li>\n  <li>ink</li>\n</ul>", "list layout");
}

fn test_should_call_functions_and_pipelines() {
    assert(out("{{ .items | len }} {{ len .s }}") == "2 33", "len");
    assert(out("{{ \"Ab\" | upper }} {{ lower \"Ab\" }} {{ trim \"  x \" }}") == "AB ab x", "case and trim");
    assert(out("{{ default \"anon\" .nick }} {{ default \"x\" .n }}") == "anon 42", "default");
    assert(out("{{ if and .yes .n }}A{{ end }}{{ if or .no .empty }}B{{ else }}C{{ end }}{{ if not .no }}D{{ end }}") == "ACD", "and or not");
    assert(out("{{ if eq .n 42 }}E{{ end }}{{ if ne .s \"x\" }}N{{ end }}{{ if lt .f 2 }}L{{ end }}{{ if ge .n 42 }}G{{ end }}") == "ENLG", "comparisons");
    assert(out("{{ if eq .n 1 2 42 }}any{{ end }}") == "any", "eq with several");
    assert(out("{{ index .items 1 | json }}") == "{&#34;name&#34;:&#34;ink&#34;,&#34;price&#34;:12,&#34;tags&#34;:[]}", "index and json");
    assert(out("{{ range $i, $x := .items }}{{ add $i 1 }}{{ end }}") == "12", "add");
    assert(out("{{ urlquery .s }}") == "%3Cscript%3Ealert%28%27x%27%29%3C%2Fscript%3E%20%26%20%22q%22", "urlquery");
}

fn test_should_evaluate_parenthesised_pipelines() {
    assert(out("{{ len (index .items 0).tags }} {{ (index .items 1).name | upper }} {{ add (len .items) (add 1 2) }}") == "2 INK 5",
           out("{{ len (index .items 0).tags }} {{ (index .items 1).name | upper }} {{ add (len .items) (add 1 2) }}"));
    assert(out("{{ join (index .items 0).tags \"+\" }}") == "a+b", "join");
    assert(out("{{ if (eq (len .items) 2) }}two{{ end }}") == "two", "condition");
    assert(strings.contains(render_error("{{ (index .items 0).nope }}"), "(…).nope: no field nope"), "missing field");
    assert(strings.contains(parse_error("{{ len (index .items 0 }}"), "unclosed parenthesis"), "unclosed");
    assert(strings.contains(parse_error("{{ len () }}"), "empty parentheses"), "empty");
    assert(strings.contains(parse_error("{{ len .items) }}"), "unexpected ')'"), "stray close");
}

fn test_should_short_circuit_and_or() {
    // .nick is null: and stops there, so .nick.first is never looked up
    assert(out("{{ if and .nick .nick.first }}x{{ else }}y{{ end }}") == "y", "and stops at the first false");
    assert(out("{{ if or .yes .nope }}x{{ end }}") == "x", "or stops at the first true");
    assert(out("{{ or .no .empty \"fallback\" }}") == "fallback", "or returns the deciding value");
    assert(out("{{ and .yes .n }}") == "42", "and returns the last value");
    assert(strings.contains(render_error("{{ and .yes .nope }}"), "no field nope"), "and evaluates up to the decider");
}

fn test_should_print_and_printf() {
    assert(out("{{ print .n .f \"x\" .yes }}") == "42 1.5xtrue", out("{{ print .n .f \"x\" .yes }}"));
    assert(out("{{ printf \"%s has %d items at %.2f %q %x %t 100%%\" \"cart\" 2 3.14159 \"a\" 255 .yes }}") ==
           "cart has 2 items at 3.14 &#34;a&#34; ff true 100%",
           out("{{ printf \"%s has %d items at %.2f %q %x %t 100%%\" \"cart\" 2 3.14159 \"a\" 255 .yes }}"));
    assert(out("{{ printf \"%.0f|%f|%.1f\" 2.5 -1.25 -0.04 }}") == "2|-1.250000|-0.0", out("{{ printf \"%.0f|%f|%.1f\" 2.5 -1.25 -0.04 }}"));
    assert(out("{{ range .items }}{{ .price | printf \"[%d]\" }}{{ end }}") == "[3][12]", "piped operand comes last");
    assert(strings.contains(render_error("{{ printf \"%d %d\" 1 }}"), "has no operand"), "missing operand");
    assert(strings.contains(render_error("{{ printf \"%d\" 1 2 }}"), "left over"), "extra operand");
    assert(strings.contains(render_error("{{ printf \"%y\" 1 }}"), "unknown verb"), "bad verb");
    // the result is escaped for where it lands, like any value
    assert(out("{{ printf \"%s\" .html }}") == "&lt;em&gt;ok&lt;/em&gt;", "escaped");
}

fn test_should_report_missing_fields_and_bad_calls() {
    assert(strings.contains(render_error("{{ .nope }}"), ".nope: no field nope"), "missing field");
    assert(strings.contains(render_error("{{ .s.x }}"), "has no fields"), "field of a string");
    assert(strings.contains(parse_error("{{ nofunc .n }}"), "no function \"nofunc\""), "unknown function");
    assert(strings.contains(render_error("{{ lt .s .n }}"), "compares two numbers or two strings"), "mixed compare");
    assert(strings.contains(render_error("{{ index .items 9 }}"), "out of range"), "index range");
    assert(strings.contains(render_error("{{ range .n }}{{ end }}"), "range over a number"), "range a number");
    assert(strings.contains(parse_error("{{ $nope }}"), "undefined variable"), "variable");
    let deep = render_error("{{ range $i, $it := .items }}{{ $it.name.x }}{{ end }}");
    assert(strings.contains(deep, "$it.name.x: a string has no fields"), deep);
}

fn test_should_report_parse_errors_with_lines() {
    assert(strings.contains(parse_error("a\n{{ .s"), "t:2: unclosed {{"), "unclosed");
    assert(strings.contains(parse_error("{{ if .yes }}x"), "not closed by {{ end }}"), "no end");
    assert(strings.contains(parse_error("{{ end }}"), "without an open block"), "stray end");
    assert(strings.contains(parse_error("{{ .s | }}"), "empty"), "empty pipeline");
    assert(strings.contains(parse_error("{{ template \"nope\" }}"), "no template named"), "unknown template");
}

// ---- templates calling templates ------------------------------------------------

fn test_should_include_defines_and_added_templates() {
    let t = t_of("{{ define \"item\" }}<li title=\"{{ .name }}\">{{ .name }}</li>{{ end }}<ul>{{ range .items }}{{ template \"item\" . }}{{ end }}</ul>");
    assert((render(t, data()) ?? "") == "<ul><li title=\"pen\">pen</li><li title=\"ink\">ink</li></ul>", render(t, data()) ?? "err");
    let a = add(t, "layout", "<html>{{ template \"t\" . }}</html>");
    guard let _a = a else let e = err_of(a) { panic(e); }
    assert(strings.has_prefix(render_named(t, "layout", data()) ?? "", "<html><ul><li"), "layout");
    // the same partial used in text and in an attribute is escaped for each
    let u = t_of("{{ define \"v\" }}{{ .s }}{{ end }}<p title=\"{{ template \"v\" . }}\">{{ template \"v\" . }}</p>");
    let both = render(u, data()) ?? "";
    assert(strings.contains(both, "title=\"&lt;script&gt;") && strings.contains(both, "\">&lt;script&gt;"), both);
}

fn test_should_stop_runaway_recursion() {
    let t = t_of("{{ define \"r\" }}x{{ template \"r\" . }}{{ end }}{{ template \"r\" . }}");
    let r = render(t, data());
    assert(strings.contains(err_of(r), "nested more than 64 deep"), err_of(r));
}

// ---- text mode and concurrency -------------------------------------------------------

fn test_should_not_escape_text_templates() {
    let r = parse_text("mail", "Hello {{ .s }},\n{{ range .items }}- {{ .name }} $" + "{{ .price }}\n{{ end }}");
    guard let t = r else let e = err_of(r) { panic(e); }
    assert((render(t, data()) ?? "") == "Hello <script>alert('x')</script> & \"q\",\n- pen $3\n- ink $12\n", render(t, data()) ?? "");
}

fn worker(t: Template, n: int, done: chan[int]) {
    let ok_count = 0;
    for i in 0..200 {
        let r = render(t, data()) ?? "";
        if r == "[pen:3][ink:12]" {
            ok_count += 1;
        }
    }
    chan_send(done, ok_count);
}

fn test_should_render_one_template_from_many_tasks() {
    let t = t_of("{{ range .items }}[{{ .name }}:{{ .price }}]{{ end }}");
    let done: chan[int] = make_chan(8);
    for k in 0..8 {
        spawn worker(t, k, done);
    }
    let total = 0;
    for k in 0..8 {
        total += chan_recv(done) ?? 0;
    }
    assert(total == 1600, to_str(total));
}

fn test_should_print_values_by_kind() {
    assert(out("{{ .n }} {{ .f }} {{ .yes }} {{ .nick }}|") == "42 1.5 true |", out("{{ .n }} {{ .f }} {{ .yes }} {{ .nick }}|"));
    assert(out("{{ index .items 0 }}") == "{&#34;name&#34;:&#34;pen&#34;,&#34;price&#34;:3,&#34;tags&#34;:[&#34;a&#34;,&#34;b&#34;]}", "object as JSON");
}
