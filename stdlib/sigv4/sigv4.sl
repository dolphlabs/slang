// AWS Signature Version 4 for any service: S3, SQS, SNS, and the
// S3-compatible stores (R2, MinIO, GCS with HMAC keys).
//
//     import "sigv4";
//
//     let s = sigv4.new_signer(access_key, secret_key, "eu-west-1", "sqs");
//     let h: map[str]str = {};
//     h["content-type"] = "application/x-amz-json-1.0";
//     h["x-amz-target"] = "AmazonSQS.SendMessage";
//     let amzdate = sigv4.amz_date_now();
//     let auth = sigv4.sign(s, "POST", "sqs.eu-west-1.amazonaws.com", "/", {}, h,
//                           sigv4.payload_hash(body), amzdate);
//     // send: Authorization: auth, X-Amz-Date: amzdate, the headers in h,
//     // and X-Amz-Security-Token when s.session_token is set
//
// Pure computation over crypto's SHA-256 and HMAC: no clock unless asked
// (amz_date_now), no network.

import "crypto";
import "encoding";
import "strings";
import "time";
import "timez";

// The signing key for one day, held as one object so a request never
// pairs one day's date with another day's key while the day turns.
pub gc struct DayKey { date: str, key: bytes }

pub gc struct Signer {
    access_key: str,
    secret_key: str,
    // Temporary credentials (STS, instance roles): signed and sent as
    // x-amz-security-token. "" for long-term keys.
    session_token: str,
    region: str,
    service: str,
    cached: DayKey,
}

pub fn new_signer(access_key: str, secret_key: str, region: str, service: str) -> Signer {
    return Signer { access_key: access_key, secret_key: secret_key, session_token: "",
                    region: region, service: service, cached: DayKey { date: "", key: b"" } };
}

// "20130524T000000Z" for now, UTC.
pub fn amz_date_now() -> str {
    return timez.unix_nano(time.wall()).format("%Y%m%dT%H%M%SZ");
}

// The hex SHA-256 SigV4 signs as the payload hash.
pub fn payload_hash(body: bytes) -> str {
    return encoding.hex_encode(crypto.sha256(body));
}

// kSigning = HMAC(HMAC(HMAC(HMAC("AWS4" + secret, date), region), service),
// "aws4_request"). `date` is YYYYMMDD.
pub fn derive_key(secret_key: str, date: str, region: str, service: str) -> bytes {
    let k = crypto.hmac_sha256(to_bytes("AWS4" + secret_key), to_bytes(date));
    k = crypto.hmac_sha256(k, to_bytes(region));
    k = crypto.hmac_sha256(k, to_bytes(service));
    return crypto.hmac_sha256(k, b"aws4_request");
}

// The signer's key for `date`, derived once a day.
pub fn signing_key(s: Signer, date: str) -> bytes {
    let c = s.cached;
    if c.date == date {
        return c.key;
    }
    let k = derive_key(s.secret_key, date, s.region, s.service);
    s.cached = DayKey { date: date, key: k };
    return k;
}

pub fn scope(date: str, region: str, service: str) -> str {
    return date + "/" + region + "/" + service + "/aws4_request";
}

fn sort_strs(xs: [str]) -> [str] {
    let out = xs;
    // insertion sort: a request has a handful of headers or parameters
    for i in 1..len(out) {
        let v = out[i];
        let j = i;
        while j > 0 && out[j - 1] > v {
            out[j] = out[j - 1];
            j -= 1;
        }
        out[j] = v;
    }
    return out;
}

// RFC 3986 percent-encoding as SigV4 wants it: everything but A-Z a-z
// 0-9 - _ . ~ (and / in paths, when keep_slash).
pub fn uri_encode(s: str, keep_slash: bool) -> str {
    let b = to_bytes(s);
    let hex = to_bytes("0123456789ABCDEF");
    let out = strings.bytes_zero(len(b) * 3);
    let o = 0;
    for i in 0..len(b) {
        let c = b[i];
        if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) ||
           c == 45 || c == 95 || c == 46 || c == 126 || (keep_slash && c == 47) {
            out[o] = c;
            o += 1;
        } else {
            out[o] = 37;
            out[o + 1] = hex[c >> 4];
            out[o + 2] = hex[c & 15];
            o += 3;
        }
    }
    return strings.from_bytes(out, 0, o);
}

// Parameters encoded, then sorted by their encoded form: the order SigV4
// signs and the order a request should send.
pub fn canonical_query(q: map[str]str) -> str {
    let pairs: [str] = [];
    for k, v in q {
        push(pairs, uri_encode(k, false) + "=" + uri_encode(v, false));
    }
    return strings.join(sort_strs(pairs), "&");
}

// The signature over a canonical request whose headers are exactly
// `headers` (names any case, values trimmed), and the SignedHeaders list
// that goes with it, as "signedheaders\nsignature".
fn signature(key: bytes, amzdate: str, sc: str, method: str, path: str, query: str,
             headers: map[str]str, payload: str) -> str {
    let all: map[str]str = {};
    for k, v in headers {
        all[strings.to_lower(k)] = strings.trim(v);
    }
    let names: [str] = [];
    for k, _v in all {
        push(names, k);
    }
    let sorted = sort_strs(names);
    let ch = "";
    for k in sorted {
        ch = ch + k + ":" + all[k] + "\n";
    }
    let signed = strings.join(sorted, ";");
    let creq = method + "\n" + path + "\n" + query + "\n" + ch + "\n" + signed + "\n" + payload;
    let sts = "AWS4-HMAC-SHA256\n" + amzdate + "\n" + sc + "\n" +
              encoding.hex_encode(crypto.sha256(to_bytes(creq)));
    return signed + "\n" + encoding.hex_encode(crypto.hmac_sha256(key, to_bytes(sts)));
}

// The Authorization header for a request whose signed headers are
// exactly `headers` (which must hold host and x-amz-date, and
// x-amz-security-token with temporary credentials). For callers that
// keep their own key cache, as s3 does; most callers want `sign`.
pub fn authorization(access_key: str, key: bytes, region: str, service: str, method: str,
                     path: str, query: map[str]str, headers: map[str]str, payload: str,
                     amzdate: str) -> str {
    let sc = scope(strings.slice(amzdate, 0, 8), region, service);
    let sig = signature(key, amzdate, sc, method, path, canonical_query(query), headers, payload);
    let nl = strings.find(sig, "\n");
    return "AWS4-HMAC-SHA256 Credential=" + access_key + "/" + sc +
           ", SignedHeaders=" + strings.slice(sig, 0, nl) +
           ", Signature=" + strings.slice(sig, nl + 1, len(sig));
}

// The Authorization header for a request to `host`: signs `headers` plus
// host, x-amz-date and, with temporary credentials, x-amz-security-token.
// The caller sends X-Amz-Date (and the token) with the same values.
pub fn sign(s: Signer, method: str, host: str, path: str, query: map[str]str,
            headers: map[str]str, payload: str, amzdate: str) -> str {
    let all: map[str]str = {};
    for k, v in headers {
        all[strings.to_lower(k)] = v;
    }
    all["host"] = host;
    all["x-amz-date"] = amzdate;
    if s.session_token != "" {
        all["x-amz-security-token"] = s.session_token;
    }
    return authorization(s.access_key, signing_key(s, strings.slice(amzdate, 0, 8)), s.region,
                         s.service, method, path, query, all, payload, amzdate);
}

// The query string of a presigned URL (with X-Amz-Signature last), for a
// request that signs only the host header. `query` holds the request's
// own parameters; payload is usually "UNSIGNED-PAYLOAD". For callers
// with their own key cache; most callers want `presign`.
pub fn presign_query(access_key: str, key: bytes, region: str, service: str, session_token: str,
                     method: str, host: str, path: str, query: map[str]str,
                     expires_seconds: int, payload: str, amzdate: str) -> str {
    let sc = scope(strings.slice(amzdate, 0, 8), region, service);
    let q: map[str]str = {};
    for k, v in query {
        q[k] = v;
    }
    q["X-Amz-Algorithm"] = "AWS4-HMAC-SHA256";
    q["X-Amz-Credential"] = access_key + "/" + sc;
    q["X-Amz-Date"] = amzdate;
    q["X-Amz-Expires"] = to_str(expires_seconds);
    q["X-Amz-SignedHeaders"] = "host";
    if session_token != "" {
        q["X-Amz-Security-Token"] = session_token;
    }
    let cq = canonical_query(q);
    let h: map[str]str = {};
    h["host"] = host;
    let sig = signature(key, amzdate, sc, method, path, cq, h, payload);
    let nl = strings.find(sig, "\n");
    return cq + "&X-Amz-Signature=" + strings.slice(sig, nl + 1, len(sig));
}

pub fn presign(s: Signer, method: str, host: str, path: str, query: map[str]str,
               expires_seconds: int, amzdate: str) -> str {
    return presign_query(s.access_key, signing_key(s, strings.slice(amzdate, 0, 8)), s.region,
                         s.service, s.session_token, method, host, path, query,
                         expires_seconds, "UNSIGNED-PAYLOAD", amzdate);
}
