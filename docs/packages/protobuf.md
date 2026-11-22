# protobuf

> Package protobuf.

The Protocol Buffers wire format, written and read field by field
without generated code: for talking to a gRPC or protobuf service whose
messages are few, or for building a codec on top.

```slang
import "protobuf";

// message User { int64 id = 1; string name = 2; repeated sint32 deltas = 3; }
let w = protobuf.writer();
protobuf.write_int64(w, 1, 42);
protobuf.write_string(w, 2, "ada");
protobuf.write_packed_sint(w, 3, [-1, 5, -9]);
let data = protobuf.finish(w);

let r = protobuf.reader(data);
while protobuf.more(r) {
    let fr = protobuf.next(r);              // field number and wire type
    guard let f = fr else { break; }
    if f.num == 2 {
        name = protobuf.read_string(r) ?? "";
    } else {
        protobuf.skip(r, f.wire);           // a field this reader does not use
    }
}
```

There are writers for every scalar type (`write_int64`,
`write_uint64`, `write_sint` with zigzag, `write_bool`, `write_fixed64`,
`write_fixed32`, `write_double`, `write_float`), plus `write_bytes`,
`write_string` and packed repeated fields. A nested message is its own
`Writer`, passed to `write_bytes`. The readers mirror them;
`read_packed_*` also accept an unpacked element, as parsers must. Lengths
are checked against the input and varints against their ten-byte limit.
Groups (wire types 3 and 4) are not read.

## API

### `let WIRE_VARINT = 0;`

### `let WIRE_I64 = 1;`

### `let WIRE_LEN = 2;`

### `let WIRE_I32 = 5;`

### `gc struct Writer`

### `fn writer() -> Writer`

### `fn finish(w: Writer) -> bytes`

### `fn size(w: Writer) -> int`

The bytes written so far, without emptying the writer.

### `fn write_int64(w: Writer, field: int, v: int)`

int32, int64, uint32, uint64 and enum fields. A negative int32 or int64 takes ten bytes, as the format says; use write_sint for fields declared sint32/sint64.

### `fn write_uint64(w: Writer, field: int, v: u64)`

### `fn write_sint(w: Writer, field: int, v: int)`

sint32 and sint64 fields: zigzag, so small negatives stay small.

### `fn write_bool(w: Writer, field: int, v: bool)`

### `fn write_fixed64(w: Writer, field: int, v: u64)`

fixed64, sfixed64.

### `fn write_fixed32(w: Writer, field: int, v: int)`

fixed32, sfixed32 (the low 32 bits of v).

### `fn write_double(w: Writer, field: int, v: float)`

### `fn write_float(w: Writer, field: int, v: float)`

### `fn write_bytes(w: Writer, field: int, b: bytes)`

bytes fields and nested messages (a finished Writer's bytes).

### `fn write_string(w: Writer, field: int, s: str)`

### `fn write_packed_int(w: Writer, field: int, vs: [int])`

repeated int32/int64/uint32/uint64/enum/bool, packed.

### `fn write_packed_sint(w: Writer, field: int, vs: [int])`

repeated sint32/sint64, packed.

### `fn write_packed_double(w: Writer, field: int, vs: [float])`

repeated double, packed.

### `gc struct Reader`

### `fn reader(b: bytes) -> Reader`

### `fn more(r: Reader) -> bool`

### `struct Field`

### `fn next(r: Reader) -> result[Field, str]`

The next field's number and wire type; read its value next with the reader for that type, or skip it.

### `fn read_varint(r: Reader) -> result[int, str]`

A varint field: int32/int64/uint*/enum read as int (uint64 values above int's range come back negative; read_uvarint keeps them).

### `fn read_uvarint(r: Reader) -> result[u64, str]`

### `fn read_sint(r: Reader) -> result[int, str]`

A zigzag (sint32/sint64) field.

### `fn read_bool(r: Reader) -> result[bool, str]`

### `fn read_fixed64(r: Reader) -> result[u64, str]`

### `fn read_fixed32(r: Reader) -> result[int, str]`

A fixed32 field as an unsigned value; sfixed32 is read_sfixed32.

### `fn read_sfixed32(r: Reader) -> result[int, str]`

### `fn read_double(r: Reader) -> result[float, str]`

### `fn read_float(r: Reader) -> result[float, str]`

### `fn read_bytes(r: Reader) -> result[bytes, str]`

A length-delimited field: bytes, a string, a nested message, or packed repeated values.

### `fn read_string(r: Reader) -> result[str, str]`

### `fn read_packed_int(r: Reader, wire: int) -> result[[int], str]`

A packed repeated varint field (or a single unpacked element, which a parser must also accept for repeated scalars).

### `fn read_packed_sint(r: Reader, wire: int) -> result[[int], str]`

### `fn skip(r: Reader, wire: int) -> result[bool, str]`

Skips a field's value of the given wire type.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
