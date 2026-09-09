// HTTP/2 frame layer (RFC 9113 §4, §6).
//
// Every frame is a 9-octet header followed by a payload:
//
//   +-----------------------------------------------+
//   |                 Length (24)                   |
//   +---------------+---------------+---------------+
//   |   Type (8)    |   Flags (8)   |
//   +-+-------------+---------------+-------------------------------+
//   |R|                 Stream Identifier (31)                      |
//   +=+=============================================================+
//   |                   Frame Payload (0...)                      ...
//
// The R bit is reserved and MUST be ignored on receipt, so the stream id
// is always masked with 0x7fffffff rather than read as a full 32 bits.

pub let FRAME_HEADER_LEN = 9;

// Frame types (RFC 9113 §6). PUSH_PROMISE is parsed but never sent:
// server push is deprecated and no major client accepts it any more.
pub let T_DATA = 0x0;
pub let T_HEADERS = 0x1;
pub let T_PRIORITY = 0x2;
pub let T_RST_STREAM = 0x3;
pub let T_SETTINGS = 0x4;
pub let T_PUSH_PROMISE = 0x5;
pub let T_PING = 0x6;
pub let T_GOAWAY = 0x7;
pub let T_WINDOW_UPDATE = 0x8;
pub let T_CONTINUATION = 0x9;

// Flags. The same bit means different things per frame type, which is
// why these are named by type: 0x1 is END_STREAM on DATA/HEADERS but
// ACK on SETTINGS/PING.
pub let FLAG_END_STREAM = 0x1;
pub let FLAG_ACK = 0x1;
pub let FLAG_END_HEADERS = 0x4;
pub let FLAG_PADDED = 0x8;
pub let FLAG_PRIORITY = 0x20;

// Error codes (RFC 9113 §7).
pub let E_NO_ERROR = 0x0;
pub let E_PROTOCOL_ERROR = 0x1;
pub let E_INTERNAL_ERROR = 0x2;
pub let E_FLOW_CONTROL_ERROR = 0x3;
pub let E_SETTINGS_TIMEOUT = 0x4;
pub let E_STREAM_CLOSED = 0x5;
pub let E_FRAME_SIZE_ERROR = 0x6;
pub let E_REFUSED_STREAM = 0x7;
pub let E_CANCEL = 0x8;
pub let E_COMPRESSION_ERROR = 0x9;
pub let E_CONNECT_ERROR = 0xa;
pub let E_ENHANCE_YOUR_CALM = 0xb;
pub let E_INADEQUATE_SECURITY = 0xc;
pub let E_HTTP_1_1_REQUIRED = 0xd;

// Settings parameters (RFC 9113 §6.5.2).
pub let S_HEADER_TABLE_SIZE = 0x1;
pub let S_ENABLE_PUSH = 0x2;
pub let S_MAX_CONCURRENT_STREAMS = 0x3;
pub let S_INITIAL_WINDOW_SIZE = 0x4;
pub let S_MAX_FRAME_SIZE = 0x5;
pub let S_MAX_HEADER_LIST_SIZE = 0x6;

// The connection preface a client must send first (RFC 9113 §3.4).
pub fn preface() -> bytes {
    return b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
}

pub gc struct Frame {
    ftype: int,
    flags: int,
    stream: int,
    payload: bytes,
}

// ---- integer helpers ------------------------------------------------
// Wire order is big-endian throughout ("network byte order").

pub fn be16(b: bytes, off: int) -> int {
    return (b[off] << 8) | b[off + 1];
}

pub fn be24(b: bytes, off: int) -> int {
    return (b[off] << 16) | (b[off + 1] << 8) | b[off + 2];
}

pub fn be32(b: bytes, off: int) -> int {
    return (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
}

pub fn put16(v: int) -> bytes {
    let out = b"\x00\x00";
    out[0] = (v >> 8) & 0xff;
    out[1] = v & 0xff;
    return out;
}

pub fn put24(v: int) -> bytes {
    let out = b"\x00\x00\x00";
    out[0] = (v >> 16) & 0xff;
    out[1] = (v >> 8) & 0xff;
    out[2] = v & 0xff;
    return out;
}

pub fn put32(v: int) -> bytes {
    let out = b"\x00\x00\x00\x00";
    out[0] = (v >> 24) & 0xff;
    out[1] = (v >> 16) & 0xff;
    out[2] = (v >> 8) & 0xff;
    out[3] = v & 0xff;
    return out;
}

// ---- header codec ---------------------------------------------------

// Serialize a frame header. The caller appends the payload.
pub fn header_bytes(ftype: int, flags: int, stream: int, plen: int) -> bytes {
    let out = put24(plen);
    let t = b"\x00\x00";
    t[0] = ftype & 0xff;
    t[1] = flags & 0xff;
    // the reserved bit is always sent as 0
    return out + t + put32(stream & 0x7fffffff);
}

pub fn encode(f: Frame) -> bytes {
    return header_bytes(f.ftype, f.flags, f.stream, len(f.payload))
         + f.payload;
}

// Payload length of the frame starting at `off`, or -1 if the 9-byte
// header is not fully buffered yet.
pub fn peek_length(b: bytes, off: int) -> int {
    if off + FRAME_HEADER_LEN > len(b) {
        return -1;
    }
    return be24(b, off);
}

// Decode one frame at `off`. `max_frame` is our advertised
// SETTINGS_MAX_FRAME_SIZE: a peer exceeding it is a connection error, and
// checking here keeps a bogus length from driving a huge allocation.
pub fn decode(b: bytes, off: int, max_frame: int) -> result[Frame, str] {
    if off + FRAME_HEADER_LEN > len(b) {
        return err("short frame header");
    }
    let plen = be24(b, off);
    if plen > max_frame {
        return err("frame larger than SETTINGS_MAX_FRAME_SIZE");
    }
    if off + FRAME_HEADER_LEN + plen > len(b) {
        return err("short frame payload");
    }
    let ftype = b[off + 3];
    let flags = b[off + 4];
    let stream = be32(b, off + 5) & 0x7fffffff;
    let start = off + FRAME_HEADER_LEN;
    return ok(Frame {
        ftype: ftype,
        flags: flags,
        stream: stream,
        payload: b[start..start + plen]
    });
}

// Strip padding from a DATA or HEADERS payload when FLAG_PADDED is set:
// one length octet, then the field, then that many padding octets.
pub fn strip_padding(payload: bytes, flags: int) -> result[bytes, str] {
    if (flags & FLAG_PADDED) == 0 {
        return ok(payload);
    }
    if len(payload) < 1 {
        return err("padded frame with no pad length");
    }
    let pad = payload[0];
    if 1 + pad > len(payload) {
        return err("pad length exceeds frame payload");
    }
    return ok(payload[1..len(payload) - pad]);
}

// ---- common frames --------------------------------------------------

pub fn settings_ack() -> bytes {
    return header_bytes(T_SETTINGS, FLAG_ACK, 0, 0);
}

pub fn ping_ack(opaque: bytes) -> bytes {
    return header_bytes(T_PING, FLAG_ACK, 0, 8) + opaque;
}

pub fn rst_stream(stream: int, code: int) -> bytes {
    return header_bytes(T_RST_STREAM, 0, stream, 4) + put32(code);
}

pub fn goaway(last_stream: int, code: int, debug: str) -> bytes {
    let body = put32(last_stream & 0x7fffffff) + put32(code) + to_bytes(debug);
    return header_bytes(T_GOAWAY, 0, 0, len(body)) + body;
}

pub fn window_update(stream: int, increment: int) -> bytes {
    return header_bytes(T_WINDOW_UPDATE, 0, stream, 4)
         + put32(increment & 0x7fffffff);
}

// One SETTINGS entry is a 16-bit identifier and a 32-bit value.
pub fn settings_frame(ids: [int], vals: [int]) -> bytes {
    let body = b"";
    for i in 0..len(ids) {
        body = body + put16(ids[i]) + put32(vals[i]);
    }
    return header_bytes(T_SETTINGS, 0, 0, len(body)) + body;
}
