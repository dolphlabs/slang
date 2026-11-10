# template

> Package template.

HTML templates that escape each value for where it lands, and plain-text
templates for email bodies and other text. The syntax is Go's
(`{{ .field }}`, `if`, `range`, `with`, `define`, pipelines), and so is the
safety model: escaping is decided by the HTML around each action when the
template is parsed, not by the caller remembering to escape.

```slang
import "template";

gc struct Item { name: str, url: str, price: int }
gc struct Page { title: str, items: [Item], user: str }

let r = template.parse("page",
    "<h1>{{ .title }}</h1>" +
    "<ul>{{ range $i, $it := .items }}" +
    "<li><a href=\"{{ $it.url }}\" title=\"{{ $it.name }}\">{{ add $i 1 }}. {{ $it.name }}</a></li>" +
    "{{ else }}<li>nothing yet</li>{{ end }}</ul>" +
    "<script>const user = {{ .user }};</script>");
guard let t = r else let e = err_of(r) { panic(e); }      // syntax and context errors, with line numbers
let html = template.render(t, page);                       // result[str, str]

template.add(t, "layout", "<html><body>{{ template \"page\" . }}</body></html>");
template.render_named(t, "layout", page);

let mail = template.parse_text("welcome", "Hi {{ .name }},\n{{ range .items }}- {{ .name }}\n{{ end }}");
```

Each action is escaped for its context:

| Where | What the value becomes |
|---|---|
| text, quoted attribute | `& < > " '` as character references |
| URL attribute (`href`, `src`, `action`, …), at the start | only `http`, `https`, `mailto`, `tel` or a relative URL; anything else, `javascript:` above all, becomes `about:invalid#blocked` |
| later in a URL | percent-encoded (`/search?q={{ .q }}`) |
| `<script>`, `on*` attributes | a JavaScript literal (JSON), `<` `>` `&` `'` as `\u` escapes |
| inside a JS string | escaped as string content, whatever the quotes |
| `<style>`, `style` attributes | letters, digits and `# % . , -` only, else `ZgotmplZ` |

Refused when the template is parsed: an action in a tag or attribute
name, in an unquoted attribute value, in an HTML or JavaScript comment,
and branches of an `if` or `range` that leave the HTML in different
states (`{{ if .x }}<a href="{{ end }}`). `{{ .html | raw }}` writes
trusted HTML unescaped in text, and escapes it anywhere else.

**Data** is any value `json.encode` takes: a struct's fields are `.name`,
a list ranges, a map's keys are fields (ranged in sorted key order).
A missing field is an error, not an empty string, so a typo does not
render as silence; use `if`, `with` or `default` for data that may be
absent.

**Language.** `{{ if }}`/`{{ else if }}`/`{{ else }}`, `{{ with }}`,
`{{ range }}` (with `$i, $x :=` and `{{ else }}` for empty), `{{ $x := … }}`
and `{{ $x = … }}` with block scope, `$` for the root, pipelines
(`{{ .name | upper }}`), parentheses (`{{ len (index .items 0).tags }}`),
`{{/* comments */}}` and `{{-`/`-}}` to trim whitespace, `{{ define }}`
and `{{ template "name" . }}` (nested up to 64 deep). Functions: `eq ne
lt le gt ge`, `and or not` (short-circuit, as Go's), `len index default
join upper lower trim add sub`, `print printf` (`%s %v %d %f %.2f %q %x
%t`), `json urlquery raw`. An unknown function or variable is a parse
error.

**Cost.** Parsing and escape analysis happen once; a `Template` is safe
to render from many tasks at once. Rendering encodes the data with
`json.encode` and indexes it with `encoding.json_tape` (one C pass, no
allocation per value), resolves variables to slots at parse time, and
escapes with `strings.escape_html`/`escape_js`, which return their input
unchanged when nothing needs escaping. A 100-row table page (15 KB, six
actions a row) rendered in 0.6–0.8 ms, against 1.0–1.2 ms for Go's
`html/template` on the same page, run alternately on one machine.

## API

### `gc struct Template`

A set of named templates, parsed and ready to render: make one with parse or parse_text, grow it with add. Its fields are internal. Safe to render from many tasks at once.

### `fn parse(name: str, src: str) -> result[Template, str]`

An HTML template, escaped by context. src may hold {{ define }} blocks.

### `fn parse_text(name: str, src: str) -> result[Template, str]`

A plain-text template (email bodies, CLI output): nothing is escaped.

### `fn add(t: Template, name: str, src: str) -> result[bool, str]`

Add another named template, such as a partial or a layout, which any template in the set can call with {{ template "name" }} (passing dot, or the value written after the name); its {{ define }} blocks are added too.

### `fn render[T](t: Template, data: T) -> result[str, str]`

Render the template parse was given, with data as its dot.

### `fn render_named[T](t: Template, name: str, data: T) -> result[str, str]`

Render one of the templates (a define or one added with add).

### `fn escape_html(s: str) -> str`

HTML-escape text, for building markup by hand.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
