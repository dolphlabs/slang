# yaml

> Package yaml.

YAML 1.2 for configuration files: decode into your own types, or convert
to JSON.

```slang
import "yaml";

struct Db { host: str, port: int, replicas: [str], timeout_ms: opt[int] }
struct Config { name: str, db: Db }

let r: result[Config, str] = yaml.decode(text);
guard let cfg = r else let e = err_of(r) { panic(e); }   // "yaml: line 4: ..."

yaml.to_json(text);              // result[str, str]: the stream's one document
yaml.to_json_all(text);          // result[[str], str]: every document (--- between them)
let all: result[[Config], str] = yaml.decode_all(text);
```

`decode` is `to_json` then `json.decode`, so a document decodes into
whatever JSON does: structs, `gc struct`s, lists, maps, `opt` (a missing
key is `none`) and enums. Mappings keep their keys in document order.
`to_json` and `decode` take a stream of exactly one document (none reads
as `null`); `to_json_all` and `decode_all` take any number.

**What is read.** Block and flow mappings and sequences; plain, single-
and double-quoted scalars; literal (`|`) and folded (`>`) block scalars
with chomping (`-`, `+`) and indentation indicators; comments; several
documents (`---`, `...`); anchors (`&a`) and aliases (`*a`); merge keys
(`<<: *base`); and the core tags (`!!str`, `!!int`, `!!float`, `!!bool`,
`!!null`, `!!map`, `!!seq`).

**What is refused**, as an error naming the line: other tags (`!custom`,
`%TAG`), explicit keys (`? key`), a mapping or sequence used as a key, a
recursive alias, a duplicate key, and tabs in indentation.

**Plain scalars** resolve by YAML 1.2's core schema, so `yes`, `no`, `on`
and `off` are strings, not booleans as in YAML 1.1. `null`, `~` and an
empty value are null; `true`/`false` (and `True`, `TRUE`, ...) are
booleans; `12`, `-3`, `0o17` and `0x1F` are integers, which must fit 64
bits; `1.5`, `.5`, `1e3`, `.inf` and `.nan` are floats, the last two
`null` in JSON, as `json.encode` writes them. Anything else, dates
included, is a string. A key's JSON name is its text, so `1:` and `"1":`
are the same key.

**Aliases** share the node they name; writing the JSON expands them.
Expanding to more than four times the document's own nodes (at least a
million) is an error, so a few lines of nested aliases ("billion laughs")
cannot blow up. Anchors belong to their document. Nesting is limited to
256 levels.

**Checked** against ruamel.yaml (YAML 1.2) on 732 streams in
tests/yaml_parity: config files and edge cases, invalid streams for each
rule, and seeded random and mutated ones. Where ruamel departs from YAML
1.2 (`1_000` and `0b101` as numbers, timestamps, tabs after `key:`), this
package follows the spec.

**Cost.** One pass builds a tree of each value's JSON text; a one-line
plain scalar, a quoted string without escapes and a plain integer are a
single copy of their source. On a 1.1 MB document of 5,000 entries,
`to_json` took about 230 ms against about 160 ms for Go's `gopkg.in/yaml.v3`
decoding into `any` (Linux container; ratios, the host was throttled). A
config file of a few KB parses in well under a millisecond.

## API

### `fn to_json(text: str) -> result[str, str]`

The stream's one document as JSON: null if it has none, an error if it has more than one.

### `fn to_json_all(text: str) -> result[[str], str]`

Every document in the stream, as JSON.

### `fn decode[T](text: str) -> result[T, str]`

The one document decoded into T, as json.decode would decode its JSON.

### `fn decode_all[T](text: str) -> result[[T], str]`

Every document decoded into T.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
