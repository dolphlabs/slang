// The HPACK static table (RFC 7541 Appendix A): 61 entries, 1-based.
//
// Built once into a pair of lists rather than written as package globals,
// because a package-level `let` must be a constant literal and cannot be
// a list. Callers go through static_name / static_value.

fn static_names() -> [str] {
    return [
        ":authority", ":method", ":method", ":path", ":path",
        ":scheme", ":scheme", ":status", ":status", ":status",
        ":status", ":status", ":status", ":status", "accept-charset",
        "accept-encoding", "accept-language", "accept-ranges", "accept",
        "access-control-allow-origin", "age", "allow", "authorization",
        "cache-control", "content-disposition", "content-encoding",
        "content-language", "content-length", "content-location",
        "content-range", "content-type", "cookie", "date", "etag",
        "expect", "expires", "from", "host", "if-match",
        "if-modified-since", "if-none-match", "if-range",
        "if-unmodified-since", "last-modified", "link", "location",
        "max-forwards", "proxy-authenticate", "proxy-authorization",
        "range", "referer", "refresh", "retry-after", "server",
        "set-cookie", "strict-transport-security", "transfer-encoding",
        "user-agent", "vary", "via", "www-authenticate"
    ];
}

fn static_values() -> [str] {
    return [
        "", "GET", "POST", "/", "/index.html",
        "http", "https", "200", "204", "206",
        "304", "400", "404", "500", "",
        "gzip, deflate", "", "", "",
        "", "", "", "",
        "", "", "",
        "", "", "",
        "", "", "", "", "",
        "", "", "", "", "",
        "", "", "",
        "", "", "", "",
        "", "", "",
        "", "", "", "", "",
        "", "", "",
        "", "", "", ""
    ];
}

pub let STATIC_LEN = 61;

pub fn static_name(idx: int) -> str {
    let n = static_names();
    if idx < 1 || idx > len(n) {
        return "";
    }
    return n[idx - 1];
}

pub fn static_value(idx: int) -> str {
    let v = static_values();
    if idx < 1 || idx > len(v) {
        return "";
    }
    return v[idx - 1];
}

// Index of an exact name+value match, or 0. Used by the encoder to send
// a one-byte indexed field for the common cases (:status 200, :method
// GET) instead of a literal.
pub fn static_find(name: str, value: str) -> int {
    let n = static_names();
    let v = static_values();
    for i in 0..len(n) {
        if n[i] == name && v[i] == value {
            return i + 1;
        }
    }
    return 0;
}

// Index of any entry with this name, or 0 -- lets the encoder reference
// a known name and send only the value as a literal.
pub fn static_find_name(name: str) -> int {
    let n = static_names();
    for i in 0..len(n) {
        if n[i] == name {
            return i + 1;
        }
    }
    return 0;
}
