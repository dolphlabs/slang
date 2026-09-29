# json

> Package json.

`json.decode`/`json.encode` (de)serialize `str`/`bytes` against a
concrete slang type — the target type for `decode` is inferred from
the binding's annotation, the same mechanism `ok()`/`err()` already
use to infer `result[T,E]`. There is no dynamic "JSON value" type:
every decode is checked field-by-field against the struct shape you
asked for, and a mismatch is a `result` error, not a silent `null` or
a runtime panic.

```slang
import "json";

gc struct Address { city: str, zip: str }
gc struct Person {
    name: str,
    age: i32,
    email: opt[str],      // JSON null / missing key <-> none
    tags: [str],
    addr: Address,         // structs nest
}

let p = Person{ name: "Ada", age: 36, email: some("ada@example.com"),
                tags: ["math"], addr: Address{ city: "London", zip: "SW1" } };
let s: str = json.encode(p);

let r: result[Person, str] = json.decode(s);
guard let p2 = r else { exit(1); }
```

Supported: `gc struct` (a plain `struct` is a compile error naming it, since
the codecs read and build structs through a pointer), `opt[T]`, `[T]`,
`map[str, V]` (JSON object keys
are always strings — a map with any other key type is a compile
error), every scalar, and `bytes` (RFC 4648 base64 strings on the
wire). `rawptr`, `chan[T]`, and
`result[T,E]` can't appear anywhere in a decode/encode target type. A
missing JSON key defaults an `opt[T]` field to `none`; for any other
field type it's a decode error. Unknown JSON keys are ignored. Every
decode error names where it happened, composed through nesting —
`json.decode` on `{"addr":{"city":5}}` against the `Person` shape
above fails with `field 'addr': field 'city': expected a string, got
a number`. Malformed input is a decode error, never a crash — the
parser caps nesting depth at 512 so adversarial input can't blow the
C stack.

Integers decode exactly, from the number as written: a 64-bit id such
as `9007199254740993` arrives intact (it is not routed through a
`double`, which is exact only up to 2^53), and every value an integer
type can hold is accepted, its limits included. A whole number written
with a fraction or exponent is still an integer (`1e3` is 1000, `5.0`
is 5); `1.5` or `1e-1` is `expected an integer`, and a value outside
the target type's range is `value … out of range for i8` (or `int`,
`u64`, …). Floats decode through a `double`, as before.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
