# xml

> Package xml.

XML 1.0 with namespaces, for the APIs that still speak it: SOAP, payment
gateways, SAML, RSS and Atom, sitemaps. Parse into a tree, read it, write
one back.

```slang
import "xml";

let r = xml.parse(body);
guard let doc = r else let e = err_of(r) { panic(e); }   // "xml: line 3 col 9: ..."
let title = doc.find("channel/title") ?? doc;              // a path of local names
for item in doc.find_all("channel/item") {
    println(item.child_text("link"));
}
let env = xml.parse(soap) ?? doc;
let body_el = env.child_ns("http://schemas.xmlsoap.org/soap/envelope/", "Body");

let out = xml.element("note").set_attr("id", "7").add(xml.element("to").add_text("Ada & Bob"));
xml.write(out);                          // ok("<note id=\"7\"><to>Ada &amp; Bob</to></note>")
```

A `Node` is an `Element`, `Text`, `Comment` or `Pi` (`n.kind`), with
`name` as written, `local`, `ns` (the namespace URI), `attrs`, `children`
and `text`. `attr(name)`, `attr_ns(ns, local)`, `child(local)`,
`child_ns`, `children_named`, `elements()`, `text_content()` and
`child_text(local)` read it. Adjacent text, CDATA and references are one
`Text` node. Comments and PIs are dropped unless `Limits.keep_comments`.

**What it refuses.** A DOCTYPE, by default: DTDs are how entity expansion
("billion laughs") and external entities (XXE) get in.
`Limits.skip_doctype` skips one without an internal subset (old RSS feeds
carry one), and an internal subset is always refused. Entities other than
the five predefined ones and character references are refused, and so is
anything not well-formed: mismatched tags, duplicate attributes, an
unbound prefix, `<` in an attribute, `]]>` in text, `--` in a comment, a
control character, content after the root. Encodings other than UTF-8
(and US-ASCII) are refused. Limits: 16 MiB, 256 levels, 1024 attributes
on an element, a million nodes. Every error names the line and column.
`tests/xml_parity` checks 64 documents against Python's expat: the same
verdicts, and the same tree for the accepted ones (one deliberate
difference: an `ISO-8859-1` declaration).

**Writing** escapes text and attribute values. A name that is not an XML
name, a comment holding `--`, or a control character is an `err`, never
a broken document. Declare namespaces as attributes (`xmlns:p`).

**Cost.** On a 3.5 MB RSS feed of 20,000 items, `parse` took 410-470 ms
here, against about 150 ms for Go's `encoding/xml` into a generic tree and 89
ms for Python's ElementTree (C expat). Most of the gap is the collector
tracing a large tree as it grows. Parse documents of that size off the
request path.

## API

### `gc struct Attr`

### `gc struct Node`

### `struct Limits`

### `fn default_limits() -> Limits`

### `fn parse(text: str) -> result[Node, str]`

The document's root element.

### `fn parse_with(text: str, lim: Limits) -> result[Node, str]`

### `fn attr(self: Node, name: str) -> opt[str]`

An attribute's value by its name as written ("id", "xml:lang").

### `fn attr_ns(self: Node, ns: str, local: str) -> opt[str]`

An attribute's value by namespace URI and local name.

### `fn elements(self: Node) -> [Node]`

Child elements, in order, without text, comments or PIs.

### `fn child(self: Node, local: str) -> opt[Node]`

The first child element with this local name, in any namespace.

### `fn child_ns(self: Node, ns: str, local: str) -> opt[Node]`

The first child element with this namespace and local name.

### `fn children_named(self: Node, local: str) -> [Node]`

Every child element with this local name.

### `fn text_content(self: Node) -> str`

The text of this node and everything under it, in document order.

### `fn child_text(self: Node, local: str) -> str`

The trimmed text of the first child element named `local`, or "".

### `fn find(self: Node, path: str) -> opt[Node]`

The first element at a path of local names below this one: "channel/item/title". none when any step is missing.

### `fn find_all(self: Node, path: str) -> [Node]`

Every element at a path of local names below this one, in document order.

### `fn element(name: str) -> Node`

A new element named `name` (prefix included, if any). Declare its namespaces as attributes: set_attr("xmlns", uri), set_attr("xmlns:p", uri).

### `fn text_node(s: str) -> Node`

### `fn set_attr(self: Node, name: str, value: str) -> Node`

Sets an attribute, replacing one of the same name. Returns the node.

### `fn add(self: Node, child: Node) -> Node`

Appends a child node. Returns this node, so calls chain.

### `fn add_text(self: Node, s: str) -> Node`

### `fn escape_text(s: str) -> str`

Text for element content: & < > escaped (> too, so "]]>" never appears).

### `fn escape_attr(s: str) -> str`

Text for a double-quoted attribute value. Tab, LF and CR are written as references, or a reader would turn them into spaces.

### `fn write(n: Node) -> result[str, str]`

The element and everything under it, as compact XML. Names are written as given; text and attribute values are escaped. A comment containing "--" or a PI containing "?>" cannot be written and is an error, as is a name that is not an XML name or a control character in text.

### `fn write_document(root: Node) -> result[str, str]`

write, after an XML declaration.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
