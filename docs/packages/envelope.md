# envelope

> Package envelope.

Envelope encryption for stored data: each value gets its own random data
key, stored wrapped by a key-encryption key named by an id. Rotating the
key-encryption key then rewrites a few dozen bytes per value, not the
value, and old keys can stay for reading.

```slang
import "envelope";

let kr = envelope.keyring();
envelope.add_key(kr, "2026-11", key_from_kms);         // 32 bytes
let box = envelope.seal(kr, to_bytes(ssn), to_bytes("user:42"));
let back = envelope.open(kr, box ?? b"", to_bytes("user:42"));

envelope.add_key(kr, "2027-01", next_key);              // now the sealing key
let moved = envelope.rewrap(kr, box ?? b"");            // value untouched
```

Both layers are AES-256-GCM through `crypto.seal`, so nonces are always
fresh. The aad binds a value to its context, so a box sealed for
`"user:42"` will not open as `"user:43"`. The wrapped data key is bound
to its key id. `key_id(box)` says which key sealed a box, `use_key`
picks the sealing key, and `remove_key` drops an old one (never the
current one).

## API

### `gc struct Keyring`

### `fn keyring() -> Keyring`

### `fn add_key(kr: Keyring, id: str, key: bytes) -> result[bool, str]`

Adds a 32-byte key-encryption key under id (1 to 255 bytes) and makes it the one new values are sealed with.

### `fn use_key(kr: Keyring, id: str) -> result[bool, str]`

Makes an already added key the one new values are sealed with.

### `fn remove_key(kr: Keyring, id: str) -> result[bool, str]`

Forgets a key: values sealed with it no longer open. Refused for the current key.

### `fn seal(kr: Keyring, plaintext: bytes, aad: bytes) -> result[bytes, str]`

### `fn open(kr: Keyring, box: bytes, aad: bytes) -> result[bytes, str]`

### `fn key_id(box: bytes) -> result[str, str]`

The id of the key a box was sealed with.

### `fn rewrap(kr: Keyring, box: bytes) -> result[bytes, str]`

The box with its data key wrapped by the current key instead; the sealed value itself is unchanged. For rotating keys over stored data.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
