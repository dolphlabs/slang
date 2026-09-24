import "builder";
import "byteutil";
import "strings";

// `raw_headers` is exactly the CRLF-separated "name: value" lines this
// request's header block was made of, unparsed -- not a map[str]str.
// Building a map costs an allocation for the map plus roughly two more
// per header, on every request, whether or not anything ever reads a
// header; most requests never do. `header`/`header_or` scan this
// directly (strings.find_field, no allocation for the search itself);
// `headers()` builds a map from it on demand for a caller that
// genuinely wants one. Constructed only by `parse`/`read` (off the
// wire) or `request` (validated, from a map) -- never assign this field
// directly from unvalidated bytes; a value containing "\r\n" inside a
// hand-built block is a second header no map ever held.
pub gc struct Request {
    method: str,
    path: str,
    version: str,
    raw_headers: bytes,
    body: bytes,
}

pub gc struct Incoming {
    req: Request,
    filled: int,
}

pub gc struct Response {
    status: i32,
    status_text: str,
    headers: map[str]str,
    body: bytes,
}

fn lower_byte(b: int) -> int {
    if b >= 65 && b <= 90 {
        return b + 32;
    }
    return b;
}

fn lower_ascii(s: str) -> str {
    let b = to_bytes(s);
    let i = 0;
    while i < len(b) {
        b[i] = lower_byte(b[i]);
        i = i + 1;
    }
    return to_str(b);
}

// A header name, lowercased, in one allocation straight off the wire.
//
// This was `lower_ascii(to_str(raw[lo..hi]))`: a slice, a str, the bytes
// lower_ascii copied it back into, and the str it returned -- four
// allocations and three passes over the same few characters, per header,
// per request. `strings.from_bytes_lower` cut that to one; the wire
// form below keeps the one allocation but skips the bytes copy too,
// since the head already sits in the caller's arena buffer.
fn header_name(raw: bytes, lo: int, hi: int) -> str {
    return strings.from_bytes_lower(raw, lo, hi);
}

fn header_name_wire(raw: wire, lo: int, hi: int) -> str {
    return strings.from_wire_lower(raw, lo, hi);
}

fn is_ows(b: int) -> bool {
    return b == 32 || b == 9;
}

fn find_crlf_wire(b: wire, from: int) -> int {
    let n = len(b);
    let i = from;
    while i + 1 < n {
        if b[i] == 13 && b[i + 1] == 10 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

// Bounded twin: searches only `buf[from..n]`, for walkers over bytes
// that have arrived but a wire that is larger. Unbounded find_crlf_wire
// above is for the head scan, where `filled == n` already.
fn find_crlf_wire_n(buf: wire, from: int, n: int) -> int {
    if n > len(buf) {
        n = len(buf);
    }
    let i = from;
    while i + 1 < n {
        if buf[i] == 13 && buf[i + 1] == 10 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn find_crlf(b: bytes, from: int) -> int {
    let i = from;
    while i + 1 < len(b) {
        if b[i] == 13 && b[i + 1] == 10 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn find_blank_line(b: bytes) -> int {
    let i = 0;
    let n = len(b);
    while i + 3 < n {
        if b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

// Same scan as find_blank_line, directly on the socket buffer: read()'s
// only use of copy_wire used to be so it had bytes to search, which
// meant copying the body along with the head just to find where the
// head ends. `n` is `filled`, not `len(w)` -- the buffer usually has
// unread capacity past what's actually arrived, and this must not match
// inside it.
fn find_blank_line_wire(w: wire, n: int) -> int {
    if n > len(w) {
        n = len(w);
    }
    let i = 0;
    while i + 3 < n {
        if w[i] == 13 && w[i + 1] == 10 && w[i + 2] == 13 && w[i + 3] == 10 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

// Digits only, and at most 18 of them. Unbounded, `n * 10 + d` wrapped:
// "Content-Length: 18446744073709551619" (2^64 + 3) framed as 3 bytes, and
// the rest of the body was read as the NEXT request -- a request-smuggling
// primitive against any proxy that computes the length correctly. 18
// digits cannot overflow a 64-bit int, and no real body is an exabyte.
//
// Takes the range directly rather than a str: the only caller has a
// Content-Length value sitting in the request's own bytes already, and
// to_bytes(str) to get back to bytes just to read digits off it was a
// copy this never needed to make.
fn parse_digits(raw: bytes, lo: int, hi: int) -> result[int, str] {
    if hi <= lo {
        return err("empty number");
    }
    if hi - lo > 18 {
        return err("number too large");
    }
    let n = 0;
    let i = lo;
    while i < hi {
        let d = raw[i];
        if d < 48 || d > 57 {
            return err("bad number");
        }
        n = n * 10 + (d - 48);
        i = i + 1;
    }
    return ok(n);
}

fn parse_digits_wire(raw: wire, lo: int, hi: int) -> result[int, str] {
    if hi <= lo {
        return err("empty number");
    }
    let v = 0;
    let i = lo;
    while i < hi {
        let d = raw[i] - 48;
        if d < 0 || d > 9 {
            return err("bad digit");
        }
        v = v * 10 + d;
        i = i + 1;
    }
    return ok(v);
}

fn trim_ows(b: bytes) -> bytes {
    let lo = 0;
    let hi = len(b);
    while lo < hi && is_ows(b[lo]) {
        lo = lo + 1;
    }
    while hi > lo && is_ows(b[hi - 1]) {
        hi = hi - 1;
    }
    return b[lo..hi];
}

fn copy_wire(w: wire, n: int) -> bytes {
    // One copy. This was `out = out + one_byte` for every byte, run on every
    // recv: quadratic in the request size, and so a denial of service -- a
    // single 200KB POST cost about fifteen seconds of CPU.
    return to_bytes(w[0..n]);
}

fn recv_fault(deadline: until) -> fault {
    if until_hit(deadline) {
        return fault_timeout();
    }
    return fault_io();
}

// What one pass over a header block needs to hand back to build both a
// Request (raw_headers, unparsed) and answer frame()'s two questions
// (is there a Content-Length or a Transfer-Encoding, and what does each
// say) without extracting either as a string unless frame() actually
// needs to -- most requests have neither on the hot GET path, and a POST
// has one, not both.
gc struct HeaderScan {
    raw_headers: bytes,
    has_content_length: bool,
    cl_lo: int,
    cl_hi: int,
    has_transfer_encoding: bool,
    te_is_chunked: bool,
    end: int,
}

// Zero-allocation case-insensitive compares against the handful of fixed
// literals the parser itself cares about (as opposed to `header_name`,
// which lowercases and allocates ANY header name a caller might later
// ask `header()` for by an arbitrary str -- see its own comment). These
// three are the entire fixed set scan_headers and frame() ever compare
// against, so hand-writing each as a length check plus a chain of byte
// compares costs nothing per call and, unlike header_name, nothing per
// header line scanned either. Generated from the literal's own ASCII
// codes rather than typed by hand, to keep a single mistyped digit out
// of code that decides where a request's body starts.
fn value_is_chunked(raw: bytes, lo: int, hi: int) -> bool {
    if hi - lo != 7 {
        return false;
    }
    return lower_byte(raw[lo]) == 99 && lower_byte(raw[lo + 1]) == 104 &&
           lower_byte(raw[lo + 2]) == 117 && lower_byte(raw[lo + 3]) == 110 &&
           lower_byte(raw[lo + 4]) == 107 && lower_byte(raw[lo + 5]) == 101 &&
           lower_byte(raw[lo + 6]) == 100;
}

fn is_content_length_wire(raw: wire, lo: int, hi: int) -> bool {
    if hi - lo != 14 {
        return false;
    }
    return lower_byte(raw[lo + 0]) == 99 &&
           lower_byte(raw[lo + 1]) == 111 &&
           lower_byte(raw[lo + 2]) == 110 &&
           lower_byte(raw[lo + 3]) == 116 &&
           lower_byte(raw[lo + 4]) == 101 &&
           lower_byte(raw[lo + 5]) == 110 &&
           lower_byte(raw[lo + 6]) == 116 &&
           lower_byte(raw[lo + 7]) == 45 &&
           lower_byte(raw[lo + 8]) == 108 &&
           lower_byte(raw[lo + 9]) == 101 &&
           lower_byte(raw[lo + 10]) == 110 &&
           lower_byte(raw[lo + 11]) == 103 &&
           lower_byte(raw[lo + 12]) == 116 &&
           lower_byte(raw[lo + 13]) == 104;
}

fn is_transfer_encoding_wire(raw: wire, lo: int, hi: int) -> bool {
    if hi - lo != 17 {
        return false;
    }
    return lower_byte(raw[lo + 0]) == 116 &&
           lower_byte(raw[lo + 1]) == 114 &&
           lower_byte(raw[lo + 2]) == 97 &&
           lower_byte(raw[lo + 3]) == 110 &&
           lower_byte(raw[lo + 4]) == 115 &&
           lower_byte(raw[lo + 5]) == 102 &&
           lower_byte(raw[lo + 6]) == 101 &&
           lower_byte(raw[lo + 7]) == 114 &&
           lower_byte(raw[lo + 8]) == 45 &&
           lower_byte(raw[lo + 9]) == 101 &&
           lower_byte(raw[lo + 10]) == 110 &&
           lower_byte(raw[lo + 11]) == 99 &&
           lower_byte(raw[lo + 12]) == 111 &&
           lower_byte(raw[lo + 13]) == 100 &&
           lower_byte(raw[lo + 14]) == 105 &&
           lower_byte(raw[lo + 15]) == 110 &&
           lower_byte(raw[lo + 16]) == 103;
}

// Same, directly on the socket buffer: `read` already framed the
// value there and only needs the match, not a `str` for it.
fn value_is_chunked_wire(raw: wire, lo: int, hi: int) -> bool {
    let i = lo;
    while i < hi {
        while i < hi && (raw[i] == 32 || raw[i] == 9 || raw[i] == 44) {
            i = i + 1;
        }
        let s = i;
        while i < hi && raw[i] != 32 && raw[i] != 9 && raw[i] != 44 {
            i = i + 1;
        }
        if i - s == 7 {
            if lower_byte(raw[s]) == 99 && lower_byte(raw[s + 1]) == 104
                && lower_byte(raw[s + 2]) == 117 && lower_byte(raw[s + 3]) == 110
                && lower_byte(raw[s + 4]) == 107 && lower_byte(raw[s + 5]) == 101
                && lower_byte(raw[s + 6]) == 100 {
                return true;
            }
        }
    }
    return false;
}

fn value_at_wire(raw: wire, at: int) -> str {
    let end = find_crlf_wire(raw, at);
    if end < 0 {
        end = len(raw);
    }
    return strings.from_wire(raw, at, end);
}

fn scan_headers_wire(raw: wire, start: int, sep: int) -> result[HeaderScan, str] {
    let i = start;
    let has_cl = false;
    let cl_lo = 0;
    let cl_hi = 0;
    let has_te = false;
    let te_chunked = false;
    while i < sep {
        let eol = find_crlf_wire(raw, i);
        if eol < 0 || eol > sep {
            return err("malformed header");
        }
        if eol == i {
            break;
        }
        if is_ows(raw[i]) {
            return err("folded header");
        }
        let colon = byteutil.find_wire(raw, i, 58);
        if colon < 0 || colon >= eol || colon == i {
            return err("malformed header");
        }
        let vlo = colon + 1;
        let vhi = eol;
        while vlo < vhi && is_ows(raw[vlo]) {
            vlo = vlo + 1;
        }
        while vhi > vlo && is_ows(raw[vhi - 1]) {
            vhi = vhi - 1;
        }
        if is_content_length_wire(raw, i, colon) {
            if has_cl {
                return err("repeated content-length header");
            }
            has_cl = true;
            cl_lo = vlo;
            cl_hi = vhi;
        } else if is_transfer_encoding_wire(raw, i, colon) {
            if has_te {
                return err("repeated transfer-encoding header");
            }
            has_te = true;
            te_chunked = value_is_chunked_wire(raw, vlo, vhi);
        }
        i = eol + 2;
    }
    return ok(HeaderScan {
        raw_headers: b"",
        has_content_length: has_cl, cl_lo: cl_lo, cl_hi: cl_hi,
        has_transfer_encoding: has_te, te_is_chunked: te_chunked,
        end: i
    });
}

fn is_content_length(raw: bytes, lo: int, hi: int) -> bool {
    if hi - lo != 14 {
        return false;
    }
    return lower_byte(raw[lo + 0]) == 99 &&
           lower_byte(raw[lo + 1]) == 111 &&
           lower_byte(raw[lo + 2]) == 110 &&
           lower_byte(raw[lo + 3]) == 116 &&
           lower_byte(raw[lo + 4]) == 101 &&
           lower_byte(raw[lo + 5]) == 110 &&
           lower_byte(raw[lo + 6]) == 116 &&
           lower_byte(raw[lo + 7]) == 45 &&
           lower_byte(raw[lo + 8]) == 108 &&
           lower_byte(raw[lo + 9]) == 101 &&
           lower_byte(raw[lo + 10]) == 110 &&
           lower_byte(raw[lo + 11]) == 103 &&
           lower_byte(raw[lo + 12]) == 116 &&
           lower_byte(raw[lo + 13]) == 104;
}

fn is_transfer_encoding(raw: bytes, lo: int, hi: int) -> bool {
    if hi - lo != 17 {
        return false;
    }
    return lower_byte(raw[lo + 0]) == 116 &&
           lower_byte(raw[lo + 1]) == 114 &&
           lower_byte(raw[lo + 2]) == 97 &&
           lower_byte(raw[lo + 3]) == 110 &&
           lower_byte(raw[lo + 4]) == 115 &&
           lower_byte(raw[lo + 5]) == 102 &&
           lower_byte(raw[lo + 6]) == 101 &&
           lower_byte(raw[lo + 7]) == 114 &&
           lower_byte(raw[lo + 8]) == 45 &&
           lower_byte(raw[lo + 9]) == 101 &&
           lower_byte(raw[lo + 10]) == 110 &&
           lower_byte(raw[lo + 11]) == 99 &&
           lower_byte(raw[lo + 12]) == 111 &&
           lower_byte(raw[lo + 13]) == 100 &&
           lower_byte(raw[lo + 14]) == 105 &&
           lower_byte(raw[lo + 15]) == 110 &&
           lower_byte(raw[lo + 16]) == 103;
}

// One pass, same structural rules parse_headers always enforced (folded
// header, no colon, missing terminator, a repeated Content-Length or
// Transfer-Encoding) -- this removes the allocations that rule enforced
// them, not the rule. `header_name` still costs one allocation per line
// (it's how every line's name is compared against the two names that
// matter here), which is the one allocation scan_headers spends; nothing
// beyond it is extracted unless it's the CL/TE value, and even those are
// offsets, never a string, here.
fn scan_headers(raw: bytes, start: int, sep: int) -> result[HeaderScan, str] {
    // Walked in `raw`'s own absolute positions, not a block pre-sliced to
    // `raw[start..sep]` -- for any request with at least one header, the
    // LAST header's own terminating "\r\n" is not separate from the blank
    // line's: find_blank_line's 4-byte match sits exactly where a header
    // section ends and the blank line begins, so that "\r\n" is shared
    // between the two, and slicing at `sep` cuts it off the block
    // entirely, silently. `eol > sep` (not `>=`) is what let the ORIGINAL
    // parse_headers accept a last header line whose own eol lands
    // exactly on `sep` -- this keeps that, and the header block sliced
    // out below is exactly as much of `raw` as this loop actually
    // consumed, however that boundary fell.
    let i = start;
    let has_cl = false;
    let cl_lo = 0;
    let cl_hi = 0;
    let has_te = false;
    let te_chunked = false;
    while i < sep {
        let eol = find_crlf(raw, i);
        if eol < 0 || eol > sep {
            return err("malformed header");
        }
        if eol == i {
            break;
        }
        if is_ows(raw[i]) {
            return err("folded header");
        }
        let colon = byteutil.find(raw, i, 58);
        if colon < 0 || colon >= eol || colon == i {
            return err("malformed header");
        }
        let vlo = colon + 1;
        let vhi = eol;
        while vlo < vhi && is_ows(raw[vlo]) {
            vlo = vlo + 1;
        }
        while vhi > vlo && is_ows(raw[vhi - 1]) {
            vhi = vhi - 1;
        }
        // Compared against the two fixed names directly, not through
        // header_name(): that allocates a lowercased copy of EVERY
        // header's name to compare it against these same two literals,
        // which is the one cost scan_headers still had after the first
        // pass at this file -- most headers are neither of these two, so
        // most of that allocation bought nothing. is_content_length/
        // is_transfer_encoding compare in place instead.
        //
        // The two headers that decide where a request ENDS may not repeat.
        // Other headers still take the last value, as before; these two
        // did too, so two disagreeing Content-Lengths were accepted with
        // the last silently winning -- while a proxy honouring the first
        // framed the same bytes differently. RFC 9112 section 6.3: reject.
        // The offsets recorded here (cl_lo/cl_hi) are into `raw`, same as
        // vlo/vhi -- NOT re-based to the sliced block below, which is why
        // frame() is handed `raw` alongside the scan result rather than
        // reading through raw_headers alone.
        if is_content_length(raw, i, colon) {
            if has_cl {
                return err("repeated content-length header");
            }
            has_cl = true;
            cl_lo = vlo;
            cl_hi = vhi;
        } else if is_transfer_encoding(raw, i, colon) {
            if has_te {
                return err("repeated transfer-encoding header");
            }
            has_te = true;
            te_chunked = value_is_chunked(raw, vlo, vhi);
        }
        i = eol + 2;
    }
    // `i` is exactly as far as the loop above actually consumed: for one
    // or more headers, the position right after the last one's own
    // "\r\n" (which, per the comment at the top of this function, is
    // always sep + 2 for a well-formed section, but this reads the
    // position the loop actually reached rather than trusting a formula
    // to agree with it); for zero headers, the loop body never ran and i
    // is still `start`, giving an empty slice.
    return ok(HeaderScan {
        raw_headers: raw[start..i],
        has_content_length: has_cl, cl_lo: cl_lo, cl_hi: cl_hi,
        has_transfer_encoding: has_te, te_is_chunked: te_chunked,
        end: i
    });
}

// ---- framing: where does this request's body end? ----------------------
//
// `frame` answers it for `parse()` (bytes already in hand); `read`
// answers it for the socket path with the wire twin below. Same rules
// (folded/no-colon/terminator/repeated-CL-or-TE) in both; the recorded
// offsets are into `raw`'s own positions either way.
// but a security one: if a front proxy and this server frame a request
// differently, the leftover bytes are read as a second request the proxy
// never saw -- request smuggling.
//
// Rules (RFC 9112 section 6):
//   - Transfer-Encoding: chunked, and nothing else. Any other coding, or a
//     list of codings, is refused rather than guessed at.
//   - Transfer-Encoding AND Content-Length together: refused. RFC 9112 lets
//     a server pick Transfer-Encoding; refusing is the choice that cannot
//     disagree with anyone.
//   - Transfer-Encoding in an HTTP/1.0 request: refused (section 6.1).
//   - Otherwise Content-Length, or no body.

// Chunk-size lines (with extensions) and the trailer section have their own
// ceilings: the buffer bounds the total, but without these one oversized
// line would be waited on until the buffer filled.
let MAX_CHUNK_LINE = 1024;
let MAX_TRAILERS = 8192;

gc struct Framing {
    complete: bool,
    end: int,      // offset one past the message, when complete
    need: int,     // total size when known up front (Content-Length), else -1
    body: bytes,
    body_lo: int,  // wire twin only: body start for the caller's own copy
}

fn incomplete(need: int) -> Framing {
    return Framing { complete: false, end: 0, need: need, body: b"", body_lo: 0 };
}

fn need_more(need: int) -> Framing {
    return Framing { complete: false, end: 0, need: need, body: b"", body_lo: 0 };
}

fn hex_val(b: int) -> int {
    if b >= 48 && b <= 57 { return b - 48; }
    if b >= 97 && b <= 102 { return b - 87; }
    if b >= 65 && b <= 70 { return b - 55; }
    return -1;
}

// Wire twin of scan_chunked: same ceilings, same errors, same refusal
// rules, but offsets are into `buf[0..n]` and bounded by `n`, never by
// the wire's full capacity -- bytes past `n` haven't arrived yet and
// must not be read. Chunk data is described by (body_lo, end) for the
// caller's own single copy instead of being assembled here. Chunked
// request bodies are rare on this path (and bounded by the buffer
// either way); keeping one framing decision and one copy is the volume
// win, not re-implementing the walker twice.
fn scan_chunked_wire(buf: wire, n: int, start: int) -> result[Framing, str] {
    let cap = len(buf);
    if n > cap {
        n = cap;
    }
    let i = start;
    while true {
        let eol = find_crlf_wire_n(buf, i, n);
        if eol < 0 {
            if bare_lf_wire(buf, i, n) {
                return err("bare LF in chunk size line");
            }
            if n - i > MAX_CHUNK_LINE {
                return err("chunk size line too long");
            }
            return ok(incomplete(-1));
        }
        if eol + 2 - i > MAX_CHUNK_LINE {
            return err("chunk size line too long");
        }
        if bare_lf_wire(buf, i, eol) {
            return err("bare LF in chunk size line");
        }
        let size = 0;
        let digits = 0;
        let j = i;
        while j < eol && hex_val(buf[j]) >= 0 {
            if digits == 15 {
                return err("chunk size too large");
            }
            size = size * 16 + hex_val(buf[j]);
            digits = digits + 1;
            j = j + 1;
        }
        if digits == 0 {
            return err("malformed chunk size");
        }
        while j < eol && is_ows(buf[j]) {
            j = j + 1;
        }
        if j < eol && buf[j] != 59 {
            return err("malformed chunk size");
        }
        i = eol + 2;

        if size == 0 {
            let tstart = i;
            while true {
                let teol = find_crlf_wire_n(buf, i, n);
                if teol < 0 {
                    if bare_lf_wire(buf, i, n) {
                        return err("bare LF in trailer");
                    }
                    if n - tstart > MAX_TRAILERS {
                        return err("trailers too large");
                    }
                    return ok(incomplete(-1));
                }
                if bare_lf_wire(buf, i, teol) {
                    return err("bare LF in trailer");
                }
                if teol == i {
                    return ok(Framing { complete: true, end: i + 2, need: -1,
                                        body: b"", body_lo: start });
                }
                if teol + 2 - tstart > MAX_TRAILERS {
                    return err("trailers too large");
                }
                i = teol + 2;
            }
        }

        if i + size + 2 > n {
            return ok(incomplete(-1));
        }
        if buf[i + size] != 13 || buf[i + size + 1] != 10 {
            return err("chunk data not followed by CRLF");
        }
        i = i + size + 2;
    }
    return err("unreachable");
}

fn bare_lf_wire(raw: wire, from: int, to: int) -> bool {
    let i = from;
    while i < to {
        if raw[i] == 10 {
            if i == from || raw[i - 1] != 13 {
                return true;
            }
        }
        i = i + 1;
    }
    return false;
}

// A line feed without its carriage return. Lenient parsers accept it and
// strict ones do not, which is exactly the disagreement smuggling needs.
fn bare_lf(raw: bytes, from: int, to: int) -> bool {
    let i = from;
    while i < to {
        if raw[i] == 10 && (i == 0 || raw[i - 1] != 13) {
            return true;
        }
        i = i + 1;
    }
    return false;
}

// Joined pairwise rather than appended one by one: a body of many tiny
// chunks would otherwise be copied once per chunk.
fn concat_parts(parts: [bytes]) -> bytes {
    if len(parts) == 0 {
        return b"";
    }
    let cur = parts;
    while len(cur) > 1 {
        let next: [bytes] = [];
        let k = 0;
        while k + 1 < len(cur) {
            push(next, cur[k] + cur[k + 1]);
            k = k + 2;
        }
        if k < len(cur) {
            push(next, cur[k]);
        }
        cur = next;
    }
    return cur[0];
}

fn scan_chunked(raw: bytes, start: int) -> result[Framing, str] {
    let i = start;
    let parts: [bytes] = [];
    while true {
        let eol = find_crlf(raw, i);
        if eol < 0 {
            if bare_lf(raw, i, len(raw)) {
                return err("bare LF in chunk size line");
            }
            if len(raw) - i > MAX_CHUNK_LINE {
                return err("chunk size line too long");
            }
            return ok(incomplete(-1));
        }
        if eol - i > MAX_CHUNK_LINE {
            return err("chunk size line too long");
        }
        if bare_lf(raw, i, eol) {
            return err("bare LF in chunk size line");
        }
        let size = 0;
        let digits = 0;
        let j = i;
        while j < eol && hex_val(raw[j]) >= 0 {
            // 15 hex digits cannot overflow; no chunk is anywhere near that
            if digits == 15 {
                return err("chunk size too large");
            }
            size = size * 16 + hex_val(raw[j]);
            digits = digits + 1;
            j = j + 1;
        }
        if digits == 0 {
            return err("malformed chunk size");
        }
        while j < eol && is_ows(raw[j]) {
            j = j + 1;
        }
        if j < eol && raw[j] != 59 {           // anything but ';' extensions
            return err("malformed chunk size");
        }
        i = eol + 2;

        if size == 0 {
            // Trailer fields, then an empty line. Read and discarded: merging
            // them into headers the handler already trusts would let a
            // trailer rewrite a header after it was checked.
            let tstart = i;
            while true {
                let teol = find_crlf(raw, i);
                if teol < 0 {
                    if bare_lf(raw, i, len(raw)) {
                        return err("bare LF in trailer");
                    }
                    if len(raw) - tstart > MAX_TRAILERS {
                        return err("trailers too large");
                    }
                    return ok(incomplete(-1));
                }
                if bare_lf(raw, i, teol) {
                    return err("bare LF in trailer");
                }
                if teol == i {
                    return ok(Framing { complete: true, end: i + 2, need: -1,
                                        body: concat_parts(parts), body_lo: 0 });
                }
                if teol + 2 - tstart > MAX_TRAILERS {
                    return err("trailers too large");
                }
                i = teol + 2;
            }
        }

        if i + size + 2 > len(raw) {
            return ok(incomplete(-1));
        }
        if raw[i + size] != 13 || raw[i + size + 1] != 10 {
            return err("chunk data not followed by CRLF");
        }
        push(parts, raw[i..i + size]);
        i = i + size + 2;
    }
    return err("unreachable");
}

fn frame_head_wire(buf: wire, n: int) -> result[Head, str] {
    let sep = find_blank_line_wire(buf, n);
    if sep < 0 {
        return err("need more");
    }
    let hd = parse_head_wire(buf, sep, n);
    guard let h = hd else {
        return err(err_of(hd));
    }
    return ok(h);
}

fn frame(raw: bytes, hs: HeaderScan, sep: int,
         version: str) -> result[Framing, str] {
    let body_start = sep + 4;
    if hs.has_transfer_encoding {
        if !hs.te_is_chunked {
            // The value is NOT echoed: it is client-controlled, and servers
            // pass read errors to bad_request, which embeds the message in a
            // JSON string unescaped.
            return err("unsupported Transfer-Encoding");
        }
        if hs.has_content_length {
            return err("both Transfer-Encoding and Content-Length");
        }
        if version == "HTTP/1.0" {
            return err("Transfer-Encoding in an HTTP/1.0 request");
        }
        return scan_chunked(raw, body_start);
    }
    if !hs.has_content_length {
        return ok(Framing { complete: true, end: body_start, need: body_start,
                            body: b"", body_lo: body_start });
    }
    // cl_lo/cl_hi are offsets into `raw` (scan_headers walked it directly,
    // not the sliced-out raw_headers), so they're read from raw here, not
    // from hs.raw_headers.
    let clr = parse_digits(raw, hs.cl_lo, hs.cl_hi);
    guard let cl = clr else let e = err_of(clr) {
        return err("bad Content-Length: " + e);
    }
    let end = body_start + cl;
    if len(raw) < end {
        return ok(incomplete(end));
    }
    return ok(Framing { complete: true, end: end, need: end,
                        body: raw[body_start..end], body_lo: body_start });
}

gc struct Head {
    method: str,
    path: str,
    version: str,
    hs: HeaderScan,
    headers: bytes,
    sep: int,
}

fn parse_head_wire(raw: wire, sep: int, n: int) -> result[Head, str] {
    let cap = len(raw);
    if n > cap {
        n = cap;
    }
    if sep > n {
        return err("need more");
    }
    let eol = find_crlf_wire(raw, 0);
    if eol < 0 || eol >= sep {
        return err("malformed request line");
    }
    let sp1 = -1;
    let i = 0;
    while i < eol {
        if raw[i] == 32 {
            sp1 = i;
            break;
        }
        i = i + 1;
    }
    if sp1 <= 0 {
        return err("malformed request line");
    }
    let sp2 = -1;
    let j = eol - 1;
    while j > sp1 {
        if raw[j] == 32 {
            sp2 = j;
            break;
        }
        j = j - 1;
    }
    if sp2 <= sp1 + 1 || sp2 + 1 >= eol {
        return err("malformed request line");
    }
    if eol + 2 > sep {
        return err("malformed request line");
    }
    // One allocation per field, sized once and copied straight out of
    // the socket buffer -- no intermediate bytes slice per field.
    // `n` bounds every read: bytes past it haven't arrived yet even
    // when the wire is larger.
    let method = strings.from_wire(raw, 0, sp1);
    let path = strings.from_wire(raw, sp1 + 1, sp2);
    let version = strings.from_wire(raw, sp2 + 1, eol);
    if version != "HTTP/1.1" && version != "HTTP/1.0" {
        return err("unsupported version");
    }
    if len(path) == 0 {
        return err("empty path");
    }
    let scan = scan_headers_wire(raw, eol + 2, sep);
    guard let hs = scan else {
        return err(err_of(scan));
    }
    // The header block is one bytes copy for the block `header()`
    // searches, not one per field. Consumed length is hs.end - start
    // (the blank line's own CRLF excluded, same as the bytes path).
    let start = eol + 2;
    let hb = to_bytes(raw[start..hs.end]);
    return ok(Head {
        method: method, path: path, version: version, hs: hs, headers: hb,
        sep: sep
    });
}

fn parse_head(raw: bytes, sep: int) -> result[Head, str] {
    let line_end = find_crlf(raw, 0);
    if line_end < 0 || line_end > sep {
        return err("malformed request line");
    }
    let sp1 = byteutil.find(raw, 0, 32);
    if sp1 < 0 || sp1 >= line_end {
        return err("malformed request line: no method");
    }
    let sp2 = byteutil.find(raw, sp1 + 1, 32);
    if sp2 < 0 || sp2 >= line_end {
        return err("malformed request line: no path");
    }
    if sp1 == 0 || sp2 == sp1 + 1 {
        return err("malformed request line");
    }
    // Trimmed by moving the bounds, not by slicing: same tolerance for
    // trailing OWS the trim_ows call here used to give, without the two
    // allocations it cost.
    let vlo2 = sp2 + 1;
    let vhi2 = line_end;
    while vlo2 < vhi2 && is_ows(raw[vlo2]) {
        vlo2 = vlo2 + 1;
    }
    while vhi2 > vlo2 && is_ows(raw[vhi2 - 1]) {
        vhi2 = vhi2 - 1;
    }
    let ver = strings.from_bytes(raw, vlo2, vhi2);
    if ver != "HTTP/1.0" && ver != "HTTP/1.1" {
        return err("unsupported HTTP version");
    }
    let hr = scan_headers(raw, line_end + 2, sep);
    guard let hs = hr else let e = err_of(hr) {
        return err("header: " + e);
    }
    return ok(Head { method: strings.from_bytes(raw, 0, sp1),
                     path: strings.from_bytes(raw, sp1 + 1, sp2),
                     version: ver, hs: hs, headers: b"", sep: sep });
}

// The value at a match strings.find_field already found: from just past
// its colon to the line's end, OWS-trimmed, one allocation. Shared by
// header() and header_or() below, which differ only in what a miss does.
fn value_at(raw: bytes, at: int) -> str {
    let eol = find_crlf(raw, at);
    if eol < 0 {
        eol = len(raw);
    }
    let vlo = at;
    let vhi = eol;
    while vlo < vhi && is_ows(raw[vlo]) {
        vlo = vlo + 1;
    }
    while vhi > vlo && is_ows(raw[vhi - 1]) {
        vhi = vhi - 1;
    }
    return strings.from_bytes(raw, vlo, vhi);
}

pub fn header(r: Request, name: str) -> opt[str] {
    let at = strings.find_field(r.raw_headers, name);
    if at < 0 {
        return none;
    }
    return some(value_at(r.raw_headers, at));
}

// header()'s two real call sites (Ctx.header in zokor, the WebSocket
// handshake) are both `header(...) ?? fallback` already -- this is that,
// without the opt allocation `??` unwraps.
pub fn header_or(r: Request, name: str, fallback: str) -> str {
    let at = strings.find_field(r.raw_headers, name);
    if at < 0 {
        return fallback;
    }
    return value_at(r.raw_headers, at);
}

// Every header a request carries, as a map -- built fresh on each call by
// scanning raw_headers once. Nothing in either repo iterates a request's
// headers today (confirmed by grep), which is what makes "built on
// demand" the right default over a cached field: a cache nothing reads
// is pure cost. Walks the same line shape scan_headers does, for a
// different reason (that one validates and extracts two offsets; this
// one assumes an already-valid block and extracts every name and value)
// -- kept as two functions rather than one parameterized by what to do
// with each line, which would obscure both to save repeating six lines.
pub fn headers(r: Request) -> map[str]str {
    let out: map[str]str = {};
    let raw = r.raw_headers;
    let n = len(raw);
    let i = 0;
    while i < n {
        let eol = find_crlf(raw, i);
        if eol < 0 || eol == i {
            return out;
        }
        let colon = byteutil.find(raw, i, 58);
        if colon < 0 || colon >= eol {
            return out;
        }
        let name = header_name(raw, i, colon);
        out[name] = value_at(raw, colon + 1);
        i = eol + 2;
    }
    return out;
}

fn header_part_ok(s: str) -> bool {
    let b = to_bytes(s);
    let i = 0;
    while i < len(b) {
        if b[i] == 13 || b[i] == 10 {
            return false;
        }
        i = i + 1;
    }
    return true;
}

// Builds a Request from a map the way the eager parser builds one off the
// wire: a header name or value may not contain CR or LF (an application-
// or test-constructed header gets no such check for free the way one
// read off the wire does -- this is where that rule lives for this
// path), and a name may not contain the colon that separates it from its
// value on the wire. Both are a real hazard, not a theoretical one, now
// that raw_headers is what a request's headers actually are: a value
// containing "\r\n" would be concatenated straight into the block below
// as a SECOND header line -- injection -- if it weren't rejected first.
pub fn request(method: str, path: str, version: str,
               headers: map[str]str, body: bytes) -> result[Request, str] {
    let sb = builder.new_bytes();
    for k, v in headers {
        if byteutil.find(to_bytes(k), 0, 58) >= 0 {
            return err("header name contains ':': '" + k + "'");
        }
        if !header_part_ok(k) {
            return err("header name contains CR or LF: '" + k + "'");
        }
        if !header_part_ok(v) {
            return err("header value contains CR or LF (header '" + k + "')");
        }
        sb.write_str(k);
        sb.write_str(": ");
        sb.write_str(v);
        sb.write_str("\r\n");
    }
    return ok(Request { method: method, path: path, version: version,
                        raw_headers: sb.finish(), body: body });
}

pub fn parse(raw: bytes) -> result[Request, str] {
    if len(raw) == 0 {
        return err("empty request");
    }
    let sep = find_blank_line(raw);
    if sep < 0 {
        return err("missing header terminator");
    }
    let hr = parse_head(raw, sep);
    guard let head = hr else let e = err_of(hr) {
        return err(e);
    }
    let fr = frame(raw, head.hs, sep, head.version);
    guard let f = fr else let e = err_of(fr) {
        return err("body: " + e);
    }
    if !f.complete {
        return err("truncated body");
    }
    return ok(Request {
        method: head.method,
        path: head.path,
        version: head.version,
        raw_headers: head.hs.raw_headers,
        body: f.body
    });
}

// Assembled through a builder, not by `+`.
//
// Every `+` on bytes allocates a new buffer and copies everything written
// so far into it, so building a response header by header re-copied the
// whole response once per header -- on every response the server sends.
// This is the same quadratic assembly `builder` was added to fix
// elsewhere; the stdlib's own HTTP path still had it.
//
// A builder rather than a `[bytes]` and one `strings.join_bytes`: the
// list form was tried and measured slower, because a piece per header is
// an allocation per header before anything is joined.
//
// This is the standalone/TLS path (`demo/main.sl` calls it directly) and
// `write`'s fallback for a response too large for its caller's arena.
// `write` itself does not call this when the response fits -- see `emit`
// below, which skips these allocations entirely.
pub fn serialize(r: Response) -> bytes {
    let sb = builder.new_bytes();
    sb.write_str("HTTP/1.1 ");
    sb.write_str(to_str(r.status));
    sb.write_str(" ");
    sb.write_str(r.status_text);
    sb.write_str("\r\n");
    for k, v in r.headers {
        if k != "content-length" && k != "connection" {
            sb.write_str(k);
            sb.write_str(": ");
            sb.write_str(v);
            sb.write_str("\r\n");
        }
    }
    let conn = "keep-alive";
    if has(r.headers, "connection") {
        conn = r.headers["connection"];
    }
    sb.write_str("Content-Length: ");
    sb.write_str(to_str(len(r.body)));
    sb.write_str("\r\nConnection: ");
    sb.write_str(conn);
    sb.write_str("\r\n\r\n");
    sb.write(r.body);
    return sb.finish();
}



fn compact_wire(buf: wire, used: int, filled: int) -> int {
    if used <= 0 {
        return filled;
    }
    let n = filled - used;
    let i = 0;
    while i < n {
        buf[i] = buf[used + i];
        i = i + 1;
    }
    return n;
}

pub fn wants_close(r: Request) -> bool {
    let c = header(r, "connection");
    if r.version == "HTTP/1.0" {
        guard let v = c else {
            return true;
        }
        return lower_ascii(v) != "keep-alive";
    }
    guard let v = c else {
        return false;
    }
    return lower_ascii(v) == "close";
}

// `read` knows this request's `Content-Length` value as an integer
// without allocating a `str` for the digits; mirrors `parse_digits`
// but returns -1 instead of an error since `read` treats a malformed
// value as no body.
fn content_length_wire(raw: wire, lo: int, hi: int) -> int {
    if hi <= lo {
        return -1;
    }
    let v = 0;
    let i = lo;
    while i < hi {
        let d = raw[i] - 48;
        if d < 0 || d > 9 {
            return -1;
        }
        v = v * 10 + d;
        i = i + 1;
    }
    return v;
}

// `read` frames the body directly on the socket buffer: same rules as
// `frame` (chunked-only-TE, no TE+CL, no TE-on-1.0, CL length, empty),
// but the offsets are into `buf[0..n]` and the body is one copy out,
// never via an intermediate head-bytes.
fn frame_body_wire(buf: wire, n: int, version: str, hs: HeaderScan,
                   sep: int) -> result[Framing, str] {
    let cap = len(buf);
    if n > cap {
        n = cap;
    }
    let body_start = sep + 4;
    if body_start > n {
        return ok(need_more(body_start));
    }
    if hs.has_transfer_encoding {
        if !hs.te_is_chunked {
            return err("unsupported transfer coding");
        }
        if hs.has_content_length {
            return err("Transfer-Encoding and Content-Length together");
        }
        if version == "HTTP/1.0" {
            return err("transfer-encoding on HTTP/1.0");
        }
        let cr = scan_chunked_wire(buf, n, body_start);
        guard let fr = cr else {
            return err(err_of(cr));
        }
        if !fr.complete {
            if fr.need > 0 {
                if fr.need > len(buf) {
                    return err("request too large for buffer");
                }
                return ok(need_more(fr.need));
            }
            // Incomplete, size unknown: read more unless the buffer is
            // already full, in which case this request cannot fit.
            // scan_chunked_wire refuses an oversized size line or
            // trailers itself once they exceed the buffer, so reaching
            // here with a full buffer means the body genuinely needs
            // more room than exists.
            if n >= len(buf) {
                return err("request too large for buffer");
            }
            return ok(incomplete(-1));
        }
        // Chunked bodies arrive discontiguous (size lines, CRLFs between
        // chunks), so unlike the CL path there is no single range to copy:
        // reassemble from the framed ranges. One copy per chunk, same as
        // the bytes path's concat_parts, but straight out of the wire.
        let parts: [bytes] = [];
        let ci = body_start;
        while ci < fr.end {
            let eol = find_crlf_wire(buf, ci);
            if eol < 0 || eol >= fr.end {
                break;
            }
            let size = 0;
            let digits = 0;
            let j = ci;
            while j < eol && hex_val(buf[j]) >= 0 {
                size = size * 16 + hex_val(buf[j]);
                digits = digits + 1;
                j = j + 1;
            }
            if digits == 0 {
                break;
            }
            ci = eol + 2;
            if size == 0 {
                break;
            }
            push(parts, to_bytes(buf[ci..ci + size]));
            ci = ci + size + 2;
        }
        return ok(Framing { complete: true, end: fr.end, need: fr.end,
                            body: concat_parts(parts),
                            body_lo: body_start });
    }
    if hs.has_content_length {
        let cl = content_length_wire(buf, hs.cl_lo, hs.cl_hi);
        if cl < 0 {
            return err("bad Content-Length");
        }
        // A declared body larger than the buffer is refused, not waited
        // on: read() would otherwise recv forever into a wire that cannot
        // hold it. Same rule the old path enforced via read_more.
        if body_start + cl > len(buf) {
            return err("request too large for buffer");
        }
        let end = body_start + cl;
        if n < end {
            return ok(need_more(end));
        }
        return ok(Framing { complete: true, end: end, need: end,
                            body: to_bytes(buf[body_start..end]),
                            body_lo: body_start });
    }
    return ok(Framing { complete: true, end: body_start, need: body_start,
                        body: b"", body_lo: body_start });
}

// `read`'s loop re-tests the head result after the guard above: the
// guard returns every real error and falls through only on
// "need more", so reaching here with an error means need-more and
// reaching here with a value means framed. A helper rather than
// inlining because slang has no `is_ok()` method on results.
fn hr_ok(r: result[Head, str]) -> bool {
    guard let _v = r else {
        return false;
    }
    return true;
}

pub fn read(c: &mut link, buf: wire, filled: int, deadline: until) -> result[Incoming, str] {
    let n = filled;
    while true {
        if n > 0 {
            // Hot path: frame head + body directly on the socket buffer.
            // No head-bytes copy, no per-field slices: method/path/version
            // materialize straight out of the wire (one alloc each), the
            // header block is the single block copy `header()` searches,
            // and the body is one copy out. `parse` keeps the bytes path;
            // this is the socket path.
            let hr = frame_head_wire(buf, n);
            guard let hd = hr else let he = err_of(hr) {
                if he != "need more" {
                    return err(he);
                }
                // else: head not fully arrived yet -- read more below.
            }
            if hr_ok(hr) {
                guard let hd2 = hr else {
                    return err("unreachable");
                }
                let fr = frame_body_wire(buf, n, hd2.version, hd2.hs, hd2.sep);
                guard let fm = fr else let fe = err_of(fr) {
                    return err(fe);
                }
                if !fm.complete {
                    if fm.need > 0 && fm.need > len(buf) {
                        return err("request too large for buffer");
                    }
                    // else: body not fully arrived yet -- read more below.
                } else {
                    let req = Request {
                        method: hd2.method,
                        path: hd2.path,
                        version: hd2.version,
                        raw_headers: hd2.headers,
                        body: fm.body
                    };
                    let rest = compact_wire(buf, fm.end, n);
                    return ok(Incoming { req: req, filled: rest });
                }
            }
        }
        if n >= len(buf) {
            return err("request too large for buffer");
        }
        let tail = buf[n..];
        let rr = c.recv(tail, deadline);
        guard let m = rr else let e = err_of(rr) {
            return err("recv: " + to_str(e));
        }
        if m == 0 {
            if n == 0 {
                return err("connection closed");
            }
            return err("truncated request");
        }
        n = n + m;
    }
}

// Writes into `w` starting at `off` and returns the offset just past what
// was written -- the TRUE length of the piece, whether or not `w` had
// room for all of it. That's what makes `emit` below one implementation
// for two passes: called with a zero-length probe wire, every put_*
// silently writes nothing (there is no room) but `off` still advances by
// each piece's real length, so the function returns the response's exact
// total size without writing a byte of it. Called again with a wire that
// size, the same calls this time have all the room they need and every
// byte lands.
fn put_str(w: wire, off: int, s: str) -> int {
    wire_put(w, off, s);
    return off + len(s);
}
fn put_bytes(w: wire, off: int, b: bytes) -> int {
    wire_put_bytes(w, off, b);
    return off + len(b);
}

// The integer twin: serializes `v` as ASCII digits straight into the
// wire, no `to_str` allocation. Same probe/fill contract: `off`
// advances by the true digit count either way. Single ASCII bytes go
// through one-byte wires: `wire_put(w, at, "5")` is one call, not one
// allocation (string literals are constants, not GC values).
fn put_byte(w: wire, off: int, b: int) -> int {
    if b == 48 {
        wire_put(w, off, "0");
    } else if b == 49 {
        wire_put(w, off, "1");
    } else if b == 50 {
        wire_put(w, off, "2");
    } else if b == 51 {
        wire_put(w, off, "3");
    } else if b == 52 {
        wire_put(w, off, "4");
    } else if b == 53 {
        wire_put(w, off, "5");
    } else if b == 54 {
        wire_put(w, off, "6");
    } else if b == 55 {
        wire_put(w, off, "7");
    } else if b == 56 {
        wire_put(w, off, "8");
    } else {
        wire_put(w, off, "9");
    }
    return off + 1;
}

fn put_int(w: wire, off: int, v: int) -> int {
    if v == 0 {
        return put_byte(w, off, 48);
    }
    let neg = false;
    let u = v;
    if v < 0 {
        neg = true;
        u = -v;
    }
    let digits = 0;
    let t = u;
    while t > 0 {
        digits = digits + 1;
        t = t / 10;
    }
    let total = digits;
    let at = off;
    if neg {
        wire_put(w, off, "-");
        at = off + 1;
        total = total + 1;
    }
    let i = 0;
    while i < digits {
        let p = 1;
        let k = 0;
        while k < digits - 1 - i {
            p = p * 10;
            k = k + 1;
        }
        let d = (u / p) % 10 + 48;
        put_byte(w, at + i, d);
        i = i + 1;
    }
    return off + total;
}

// SHAPE-CHECK (fast response path -- the only definition): true when
// `r` has exactly the shape `text_response` builds -- one
// content-type header and nothing else the fast path would drop. The
// connection header is read, not matched: any value (or none) rides
// along through `conn`, so it never changes the shape decision.
fn is_fast_response(r: Response) -> bool {
    if len(r.headers) != 1 {
        return false;
    }
    return has(r.headers, "content-type");
}

fn fast_content_type(r: Response) -> str {
    return r.headers["content-type"];
}

fn fast_conn(r: Response) -> str {
    if has(r.headers, "connection") {
        return r.headers["connection"];
    }
    return "keep-alive";
}

// EMIT (general response path): `emit` and `serialize` are two
// implementations of the same byte layout that must never disagree --
// see tests/http_write_arena, which sends every response shape through
// both and compares. `emit_into` above is the third: the fixed
// fast-path layout (status line, one content-type, content-length,
// connection, blank line, body) written straight into the caller's
// arena with no map, no integer str, and no intermediate bytes.
// `write` uses it when the response has exactly the shape
// `text_response` builds; anything else falls back to
// `emit`/`serialize` unchanged.
//
// EMIT-GENERAL-CONTRACT: one implementation serving both the size
// pass and the fill pass keeps them from drifting apart under
// maintenance -- a future field added to one and not the other is
// exactly the bug two implementations would eventually grow. Must
// stay byte-identical to serialize(): same order, same
// "Connection"-capitalised quirk in the skip filter below (kept
// deliberately -- see serialize()'s own history).
//
// EMIT-INTO-CONTRACT (fixed fast-path layout): status line, one
// content-type, content-length, connection, blank line, body --
// written straight into the caller's wire with no map lookup, no
// integer str, and no intermediate bytes. Same probe/fill contract as
// `emit` (off advances by true lengths), same byte layout as
// `serialize` for this shape.
// EMIT-INTO (fixed fast-path layout): status line, one content-type,
// content-length, connection, blank line, body -- written straight
// into the caller's wire with no map lookup, no integer str, and no
// intermediate bytes. Same probe/fill contract as `emit` (off advances
// by true lengths), same byte layout as `serialize` for this shape.
//
// SHAPE-CHECK: `is_fast_response` is true when `r` has exactly the
// shape `text_response` builds -- one content-type header and nothing
// else the fast path would drop. The connection header is read, not
// matched: any value (or none) rides along through `conn`, so it
// never changes the shape decision.
fn emit_into(w: wire, status: i32, status_text: str, content_type: str,
             body: bytes, conn: str) -> int {
    let off = 0;
    off = put_str(w, off, "HTTP/1.1 ");
    off = put_int(w, off, status);
    off = put_str(w, off, " ");
    off = put_str(w, off, status_text);
    off = put_str(w, off, "\r\ncontent-type: ");
    off = put_str(w, off, content_type);
    off = put_str(w, off, "\r\nContent-Length: ");
    off = put_int(w, off, len(body));
    off = put_str(w, off, "\r\nConnection: ");
    off = put_str(w, off, conn);
    off = put_str(w, off, "\r\n\r\n");
    off = put_bytes(w, off, body);
    return off;
}

fn emit(r: Response, w: wire) -> int {
    let off = 0;
    off = put_str(w, off, "HTTP/1.1 ");
    off = put_str(w, off, to_str(r.status));
    off = put_str(w, off, " ");
    off = put_str(w, off, r.status_text);
    off = put_str(w, off, "\r\n");
    for k, v in r.headers {
        if k != "content-length" && k != "connection" {
            off = put_str(w, off, k);
            off = put_str(w, off, ": ");
            off = put_str(w, off, v);
            off = put_str(w, off, "\r\n");
        }
    }
    let conn = "keep-alive";
    if has(r.headers, "connection") {
        conn = r.headers["connection"];
    }
    off = put_str(w, off, "Content-Length: ");
    off = put_str(w, off, to_str(len(r.body)));
    off = put_str(w, off, "\r\nConnection: ");
    off = put_str(w, off, conn);
    off = put_str(w, off, "\r\n\r\n");
    off = put_bytes(w, off, r.body);
    return off;
}

// serialize()'s GC allocations (~40 of them for a typical response, see
// serialize()'s own comment) replaced with two passes over the caller's
// own arena: size, then fill. If the response is larger than what's left
// of the arena, falls back to serialize() + send_bytes rather than
// letting a.wire(need) past capacity kill the task -- a slow response
// stays a slow response instead of becoming a dropped connection.
//
// Responses with exactly the `text_response` shape (one content-type,
// nothing else) take the fixed fast path above: no map iteration, no
// integer str, no intermediate bytes. Anything else uses the general
// `emit` below, unchanged.
pub fn write(c: &mut link, r: Response, a: &mut arena, deadline: until) -> result[int, fault] {
    if is_fast_response(r) {
        let ct = fast_content_type(r);
        let conn = fast_conn(r);
        let probe = a.wire(0);
        let need = emit_into(probe, r.status, r.status_text, ct, r.body, conn);
        if need > a.left() {
            let raw = serialize(r);
            return c.send_bytes(raw, deadline);
        }
        let w = a.wire(need);
        emit_into(w, r.status, r.status_text, ct, r.body, conn);
        return c.send(w, deadline);
    }
    let probe = a.wire(0);
    let need = emit(r, probe);
    if need > a.left() {
        let raw = serialize(r);
        return c.send_bytes(raw, deadline);
    }
    let w = a.wire(need);
    emit(r, w);
    return c.send(w, deadline);
}

pub fn text_response(status: i32, status_text: str, content_type: str,
                     body: str) -> Response {
    let headers: map[str]str = {};
    headers["content-type"] = content_type;
    return Response {
        status: status,
        status_text: status_text,
        headers: headers,
        body: to_bytes(body)
    };
}

pub fn ok_html(body: str) -> Response {
    return text_response(200, "OK", "text/html; charset=utf-8", body);
}

pub fn ok_css(body: str) -> Response {
    return text_response(200, "OK", "text/css; charset=utf-8", body);
}

pub fn ok_js(body: str) -> Response {
    return text_response(200, "OK", "application/javascript; charset=utf-8",
                         body);
}

pub fn ok_json(body: str) -> Response {
    return text_response(200, "OK", "application/json; charset=utf-8", body);
}

pub fn ok_text(body: str) -> Response {
    return text_response(200, "OK", "text/plain; charset=utf-8", body);
}

pub fn created_json(body: str) -> Response {
    return text_response(201, "Created", "application/json; charset=utf-8",
                         body);
}

pub fn bad_request(msg: str) -> Response {
    return text_response(400, "Bad Request", "application/json; charset=utf-8",
                         "{\"error\":\"" + msg + "\"}");
}

pub fn not_found() -> Response {
    return text_response(404, "Not Found", "text/plain; charset=utf-8",
                         "not found");
}

pub fn method_not_allowed() -> Response {
    return text_response(405, "Method Not Allowed",
                         "text/plain; charset=utf-8", "method not allowed");
}
