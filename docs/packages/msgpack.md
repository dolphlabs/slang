# msgpack

> Package msgpack.

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

### `gc struct Writer`

### `fn writer() -> Writer`

### `fn finish(w: Writer) -> bytes`

The bytes written so far; the writer is empty again afterwards.

### `fn write_nil(w: Writer)`

### `fn write_bool(w: Writer, v: bool)`

### `fn write_int(w: Writer, v: int)`

### `fn write_uint(w: Writer, v: u64)`

An unsigned value beyond int's range (up to 2^64 - 1).

### `fn write_float(w: Writer, v: float)`

### `fn write_float32(w: Writer, v: float)`

A float32: half the size, for values that fit one.

### `fn write_str(w: Writer, s: str)`

### `fn write_bin(w: Writer, b: bytes)`

### `fn write_array(w: Writer, n: int)`

The header of an array of n values; write the n values next.

### `fn write_map(w: Writer, n: int)`

The header of a map of n pairs; write key, value, key, value, ... next.

### `fn write_ext(w: Writer, kind: int, data: bytes)`

An extension value: an application type -128..127 and its bytes.

### `fn write_timestamp(w: Writer, secs: int, nanos: int)`

A timestamp (extension type -1) for unix seconds and nanoseconds, in the shortest of its three forms.

### `let K_NIL = 0;`

### `let K_BOOL = 1;`

### `let K_INT = 2; // fits int`

### `let K_UINT = 3; // above int's range: read_uint`

### `let K_FLOAT = 4;`

### `let K_STR = 5;`

### `let K_BIN = 6;`

### `let K_ARRAY = 7;`

### `let K_MAP = 8;`

### `let K_EXT = 9;`

### `let K_END = 10; // no bytes left`

### `let K_BAD = 11; // 0xc1, never used`

### `gc struct Reader`

### `fn reader(b: bytes) -> Reader`

### `fn remaining(r: Reader) -> int`

Bytes not yet read.

### `fn peek(r: Reader) -> int`

The kind of the next value, without reading it.

### `fn read_nil(r: Reader) -> result[bool, str]`

### `fn read_bool(r: Reader) -> result[bool, str]`

### `fn read_int(r: Reader) -> result[int, str]`

Any integer encoding that fits int.

### `fn read_uint(r: Reader) -> result[u64, str]`

An unsigned integer, the full u64 range.

### `fn read_float(r: Reader) -> result[float, str]`

A float32 or float64; an integer is read as its float too.

### `fn read_str(r: Reader) -> result[str, str]`

### `fn read_bin(r: Reader) -> result[bytes, str]`

### `fn read_array(r: Reader) -> result[int, str]`

An array header: how many values follow.

### `fn read_map(r: Reader) -> result[int, str]`

A map header: how many key-value pairs follow.

### `struct Ext`

### `fn read_ext(r: Reader) -> result[Ext, str]`

### `struct Timestamp`

### `fn read_timestamp(r: Reader) -> result[Timestamp, str]`

Reads extension type -1 in any of its three forms.

### `fn skip(r: Reader) -> result[bool, str]`

Skips the next value, containers and all.

### `gc struct Value`

Any MessagePack value. kind is one of the K_ constants; the field for it holds the value (items for an array, keys and vals for a map).

### `fn nil_value() -> Value`

### `fn bool_value(v: bool) -> Value`

### `fn int_value(v: int) -> Value`

### `fn float_value(v: float) -> Value`

### `fn str_value(v: str) -> Value`

### `fn bin_value(v: bytes) -> Value`

### `fn array_value(items: [Value]) -> Value`

### `fn map_value(keys: [Value], vals: [Value]) -> Value`

### `fn get(v: Value, key: str) -> opt[Value]`

The value of a map entry whose key is the string key.

### `fn decode(b: bytes) -> result[Value, str]`

One whole value; trailing bytes are an error.

### `fn read_value(r: Reader, depth: int) -> result[Value, str]`

The next value from r as a tree.

### `fn encode(v: Value) -> bytes`

### `fn write_value(w: Writer, v: Value)`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
