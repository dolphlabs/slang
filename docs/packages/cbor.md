# cbor

> Package cbor.

MessagePack and CBOR (RFC 8949), the two common binary forms of JSON's
data model, with binary strings added. CBOR also has tags; COSE,
WebAuthn and CWT are built on it.

```slang
import "cbor";
import "msgpack";

// streaming: nothing allocated but the output
let w = msgpack.writer();
msgpack.write_map(w, 1);
msgpack.write_str(w, "id");
msgpack.write_int(w, 42);
let data = msgpack.finish(w);

let r = msgpack.reader(data);
let pairs = msgpack.read_map(r) ?? 0;
let key = msgpack.read_str(r) ?? "";
let id = msgpack.read_int(r) ?? 0;

// or as a tree
let v = cbor.decode(bytes_in) ?? cbor.null_value();
let temp = cbor.get(v, "temp");
```

- **Writers** (`write_int`, `write_str`/`write_text`, `write_bin`/
  `write_bytes`, `write_float`, `write_array`, `write_map`, and so on)
  always use the shortest form. CBOR writes a float in the smallest of
  half, single or double precision that holds it exactly, its preferred
  serialization. MessagePack has `write_ext` and `write_timestamp`; CBOR
  has `write_tag`.
- **Readers** read one value at a time (`peek`/`peek_major` says what
  comes next) and `skip` past what is not needed. CBOR reads
  indefinite-length strings and containers (`-1` from `read_array` /
  `read_map`, then items until `at_break`).
- **Values:** `decode`/`encode` and `read_value`/`write_value` work on a
  `Value` tree; `get(v, key)` finds a map entry.
- **Untrusted input:** every length is checked against the bytes left
  before anything is allocated, so a five-byte "array of 4 billion"
  fails at once. Nesting is limited to `MAX_DEPTH` (512), and CBOR text
  must be UTF-8. Both are checked against the specifications' example
  vectors.

## API

### `let MAX_DEPTH = 512;`

### `let M_UINT = 0;`

### `let M_NEG = 1;`

### `let M_BYTES = 2;`

### `let M_TEXT = 3;`

### `let M_ARRAY = 4;`

### `let M_MAP = 5;`

### `let M_TAG = 6;`

### `let M_SIMPLE = 7; // false, true, null, undefined, floats, break`

### `gc struct Writer`

### `fn writer() -> Writer`

### `fn finish(w: Writer) -> bytes`

### `fn write_uint(w: Writer, v: u64)`

### `fn write_int(w: Writer, v: int)`

### `fn write_bytes(w: Writer, b: bytes)`

### `fn write_text(w: Writer, s: str)`

### `fn write_array(w: Writer, n: int)`

### `fn write_map(w: Writer, n: int)`

### `fn write_tag(w: Writer, tag: u64)`

A tag on the next item (1: epoch time, 2/3: bignums, 32: URI, ...).

### `fn write_bool(w: Writer, v: bool)`

### `fn write_null(w: Writer)`

### `fn write_undefined(w: Writer)`

### `fn write_float(w: Writer, v: float)`

The smallest of half, single and double precision that holds v exactly.

### `gc struct Reader`

### `fn reader(b: bytes) -> Reader`

### `fn remaining(r: Reader) -> int`

### `fn peek_major(r: Reader) -> int`

The major type of the next item, -1 at the end of the input.

### `fn at_break(r: Reader) -> bool`

Whether the next byte is the break that ends an indefinite-length item.

### `fn read_break(r: Reader) -> result[bool, str]`

### `fn read_uint(r: Reader) -> result[u64, str]`

### `fn read_int(r: Reader) -> result[int, str]`

An unsigned or negative integer that fits int.

### `fn read_bytes(r: Reader) -> result[bytes, str]`

### `fn read_text(r: Reader) -> result[str, str]`

### `fn read_array(r: Reader) -> result[int, str]`

An array header: its count, or -1 for an indefinite array (read items until at_break, then read_break).

### `fn read_map(r: Reader) -> result[int, str]`

A map header: its pair count, or -1 for an indefinite map.

### `fn read_tag(r: Reader) -> result[u64, str]`

### `fn read_bool(r: Reader) -> result[bool, str]`

### `fn read_null(r: Reader) -> result[bool, str]`

null or undefined.

### `fn read_float(r: Reader) -> result[float, str]`

A half, single or double float; an integer is read as its float too.

### `fn skip(r: Reader) -> result[bool, str]`

### `let K_UINT = 0;`

### `let K_NEG = 1; // n is -1 - u (beyond int's range: read u)`

### `let K_BYTES = 2;`

### `let K_TEXT = 3;`

### `let K_ARRAY = 4;`

### `let K_MAP = 5;`

### `let K_TAG = 6; // tag, with the tagged item as items[0]`

### `let K_BOOL = 7;`

### `let K_NULL = 8;`

### `let K_UNDEFINED = 9;`

### `let K_FLOAT = 10;`

### `let K_SIMPLE = 11; // another simple value, in u`

### `gc struct Value`

### `fn int_value(v: int) -> Value`

### `fn text_value(s: str) -> Value`

### `fn bytes_value(b: bytes) -> Value`

### `fn float_value(f: float) -> Value`

### `fn bool_value(b: bool) -> Value`

### `fn null_value() -> Value`

### `fn array_value(items: [Value]) -> Value`

### `fn map_value(keys: [Value], vals: [Value]) -> Value`

### `fn tag_value(tag: u64, item: Value) -> Value`

### `fn as_int(v: Value) -> opt[int]`

An integer value as int, if it fits.

### `fn get(v: Value, key: str) -> opt[Value]`

The value of a map entry whose key is the text key.

### `fn decode(b: bytes) -> result[Value, str]`

### `fn read_value(r: Reader, depth: int) -> result[Value, str]`

### `fn encode(v: Value) -> bytes`

### `fn write_value(w: Writer, v: Value)`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
