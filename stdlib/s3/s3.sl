// S3-compatible object storage: put, get (whole or a byte range), head,
// delete and list objects, multipart uploads, presigned URLs, and bucket
// create and delete, signed with AWS Signature Version 4. Works against
// AWS S3, Cloudflare R2, MinIO and other S3-compatible stores.
//
//     import "s3";
//
//     let r = s3.new_client("https://s3.eu-west-1.amazonaws.com", "eu-west-1",
//                           access_key, secret_key);
//     guard let c = r else let e = err_of(r) { panic(e); }
//     s3.put_object(c, "uploads", "avatars/42.png", png, "image/png", deadline);
//     let body = s3.get_object(c, "uploads", "avatars/42.png", deadline);
//     let url = s3.presign_get(c, "uploads", "avatars/42.png", 900);
//
// Requests are signed in slang over crypto's SHA-256 and HMAC; the
// payload is hashed and signed too (x-amz-content-sha256), so a body
// altered in transit is refused by the server. Errors carry S3's own
// code and message ("s3: NoSuchKey: The specified key does not exist.").

import "crypto";
import "encoding";
import "httpc";
import "strings";
import "time";
import "timez";

pub gc struct Client {
    // scheme://host[:port], no path
    endpoint: str,
    scheme: str,
    host: str,
    region: str,
    access_key: str,
    secret_key: str,
    session_token: str,
    // path style (endpoint/bucket/key) rather than virtual hosts
    // (bucket.endpoint/key): MinIO, R2 and most S3-compatible stores want
    // path style, which is the default; AWS accepts both.
    path_style: bool,
    http: httpc.Client,
    // signing keys cached per day: one HMAC chain a day, not four per request
    key_date: str,
    key: bytes,
}

pub gc struct Object {
    key: str,
    size: int,
    etag: str,
    last_modified: str,
    content_type: str,
}

pub gc struct Page {
    objects: [Object],
    // common prefixes when listing with a delimiter ("folders")
    prefixes: [str],
    truncated: bool,
    // pass to list_objects to fetch the next page; "" at the end
    next: str,
}

// A client for endpoint ("https://s3.us-east-1.amazonaws.com",
// "https://<account>.r2.cloudflarestorage.com", "http://127.0.0.1:9000").
pub fn new_client(endpoint: str, region: str, access_key: str, secret_key: str)
                  -> result[Client, str] {
    let u = strings.trim(endpoint);
    while strings.has_suffix(u, "/") {
        u = strings.slice(u, 0, len(u) - 1);
    }
    let scheme = "";
    let rest = "";
    if strings.has_prefix(u, "https://") {
        scheme = "https";
        rest = strings.slice(u, 8, len(u));
    } else if strings.has_prefix(u, "http://") {
        scheme = "http";
        rest = strings.slice(u, 7, len(u));
    } else {
        return err("s3: endpoint must start with https:// or http://");
    }
    if rest == "" || strings.contains(rest, "/") || strings.contains(rest, "?") {
        return err("s3: endpoint is scheme://host[:port] with no path");
    }
    if region == "" {
        return err("s3: region is required (us-east-1, auto for R2, ...)");
    }
    if access_key == "" || secret_key == "" {
        return err("s3: access key and secret key are required");
    }
    // the Host httpc will send: the default port is left out
    let host = rest;
    if scheme == "https" && strings.has_suffix(host, ":443") {
        host = strings.slice(host, 0, len(host) - 4);
    } else if scheme == "http" && strings.has_suffix(host, ":80") {
        host = strings.slice(host, 0, len(host) - 3);
    }
    return ok(Client { endpoint: scheme + "://" + host, scheme: scheme, host: host,
                       region: region, access_key: access_key, secret_key: secret_key,
                       session_token: "", path_style: true, http: httpc.new_client(),
                       key_date: "", key: b"" });
}

// A client from AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
// (optional), AWS_REGION (or AWS_DEFAULT_REGION) and S3_ENDPOINT (default:
// the region's AWS endpoint).
pub fn from_env(getenv: fn(str) -> opt[str]) -> result[Client, str] {
    let region = getenv("AWS_REGION") ?? (getenv("AWS_DEFAULT_REGION") ?? "");
    if region == "" {
        return err("s3: AWS_REGION is not set");
    }
    let endpoint = getenv("S3_ENDPOINT") ?? ("https://s3." + region + ".amazonaws.com");
    let r = new_client(endpoint, region, getenv("AWS_ACCESS_KEY_ID") ?? "",
                       getenv("AWS_SECRET_ACCESS_KEY") ?? "");
    guard let c = r else let e = err_of(r) { return err(e); }
    c.session_token = getenv("AWS_SESSION_TOKEN") ?? "";
    return ok(c);
}

// ---- objects --------------------------------------------------------------------

// Store data at bucket/key; the object's ETag.
pub fn put_object(c: Client, bucket: str, key: str, data: bytes, content_type: str,
                  deadline: until) -> result[str, str] {
    let h: map[str]str = {};
    if content_type != "" {
        h["content-type"] = content_type;
    }
    let r = send(c, "PUT", bucket, key, {}, h, data, deadline);
    guard let resp = r else let e = err_of(r) { return err(e); }
    return ok(unquote(httpc.header(resp, "etag") ?? ""));
}

pub fn get_object(c: Client, bucket: str, key: str, deadline: until) -> result[bytes, str] {
    let r = send(c, "GET", bucket, key, {}, {}, b"", deadline);
    guard let resp = r else let e = err_of(r) { return err(e); }
    return ok(resp.body);
}

// Bytes first..last of the object, both included (an HTTP Range).
pub fn get_range(c: Client, bucket: str, key: str, first: int, last: int,
                 deadline: until) -> result[bytes, str] {
    if first < 0 || last < first {
        return err("s3: range must be 0 <= first <= last");
    }
    let h: map[str]str = {};
    h["range"] = "bytes=" + to_str(first) + "-" + to_str(last);
    let r = send(c, "GET", bucket, key, {}, h, b"", deadline);
    guard let resp = r else let e = err_of(r) { return err(e); }
    return ok(resp.body);
}

// Size, ETag, type and modification time, without the body. none when
// the object does not exist.
pub fn head_object(c: Client, bucket: str, key: str, deadline: until)
                   -> result[opt[Object], str] {
    let r = send_raw(c, "HEAD", bucket, key, {}, {}, b"", deadline);
    guard let resp = r else let e = err_of(r) { return err(e); }
    if resp.status == 404 {
        return ok(none);
    }
    if resp.status != 200 {
        return err("s3: HEAD " + key + ": HTTP " + to_str(resp.status));
    }
    return ok(some(Object {
        key: key,
        size: to_int(httpc.header(resp, "content-length") ?? "0") ?? 0,
        etag: unquote(httpc.header(resp, "etag") ?? ""),
        last_modified: httpc.header(resp, "last-modified") ?? "",
        content_type: httpc.header(resp, "content-type") ?? ""
    }));
}

// Delete bucket/key. S3 answers success for a key that was not there.
pub fn delete_object(c: Client, bucket: str, key: str, deadline: until) -> result[bool, str] {
    let r = send(c, "DELETE", bucket, key, {}, {}, b"", deadline);
    guard let _resp = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

// One page (up to max_keys, at most 1000) of the keys under prefix, in
// key order, from where `next` (a Page's next, or "" to start) says.
// With delimiter "/", keys below the next "/" fold into page.prefixes.
pub fn list_objects(c: Client, bucket: str, prefix: str, delimiter: str, next: str,
                    max_keys: int, deadline: until) -> result[Page, str] {
    if max_keys < 1 || max_keys > 1000 {
        return err("s3: max_keys must be 1 to 1000");
    }
    let q: map[str]str = {};
    q["list-type"] = "2";
    q["encoding-type"] = "url";
    q["max-keys"] = to_str(max_keys);
    if prefix != "" {
        q["prefix"] = prefix;
    }
    if delimiter != "" {
        q["delimiter"] = delimiter;
    }
    if next != "" {
        q["continuation-token"] = next;
    }
    let r = send(c, "GET", bucket, "", q, {}, b"", deadline);
    guard let resp = r else let e = err_of(r) { return err(e); }
    let x = to_str(resp.body);
    let page = Page { objects: [], prefixes: [], truncated: xml_text(x, "IsTruncated") == "true",
                      next: xml_text(x, "NextContinuationToken") };
    for block in xml_blocks(x, "Contents") {
        push(page.objects, Object {
            key: url_unescape(xml_text(block, "Key")),
            size: to_int(xml_text(block, "Size")) ?? 0,
            etag: unquote(xml_text(block, "ETag")),
            last_modified: xml_text(block, "LastModified"),
            content_type: ""
        });
    }
    for block in xml_blocks(x, "CommonPrefixes") {
        push(page.prefixes, url_unescape(xml_text(block, "Prefix")));
    }
    return ok(page);
}

// ---- multipart uploads ----------------------------------------------------------------

// Start a multipart upload; its upload id.
pub fn create_multipart(c: Client, bucket: str, key: str, content_type: str,
                        deadline: until) -> result[str, str] {
    let q: map[str]str = {};
    q["uploads"] = "";
    let h: map[str]str = {};
    if content_type != "" {
        h["content-type"] = content_type;
    }
    let r = send(c, "POST", bucket, key, q, h, b"", deadline);
    guard let resp = r else let e = err_of(r) { return err(e); }
    let id = xml_text(to_str(resp.body), "UploadId");
    if id == "" {
        return err("s3: CreateMultipartUpload returned no UploadId");
    }
    return ok(id);
}

// Upload part number n (1 to 10000) of an upload; its ETag, for
// complete_multipart. Every part but the last must be at least 5 MiB.
pub fn upload_part(c: Client, bucket: str, key: str, upload_id: str, n: int, data: bytes,
                   deadline: until) -> result[str, str] {
    if n < 1 || n > 10000 {
        return err("s3: part numbers run from 1 to 10000");
    }
    let q: map[str]str = {};
    q["partNumber"] = to_str(n);
    q["uploadId"] = upload_id;
    let r = send(c, "PUT", bucket, key, q, {}, data, deadline);
    guard let resp = r else let e = err_of(r) { return err(e); }
    let etag = httpc.header(resp, "etag") ?? "";
    if etag == "" {
        return err("s3: UploadPart returned no ETag");
    }
    return ok(unquote(etag));
}

// Finish an upload from its parts' ETags, in part order; the object's ETag.
pub fn complete_multipart(c: Client, bucket: str, key: str, upload_id: str, etags: [str],
                          deadline: until) -> result[str, str] {
    if len(etags) == 0 {
        return err("s3: a multipart upload needs at least one part");
    }
    let body = "<CompleteMultipartUpload>";
    for i in 0..len(etags) {
        body = body + "<Part><PartNumber>" + to_str(i + 1) + "</PartNumber><ETag>\"" +
               xml_escape(etags[i]) + "\"</ETag></Part>";
    }
    body = body + "</CompleteMultipartUpload>";
    let q: map[str]str = {};
    q["uploadId"] = upload_id;
    let h: map[str]str = {};
    h["content-type"] = "application/xml";
    let r = send(c, "POST", bucket, key, q, h, to_bytes(body), deadline);
    guard let resp = r else let e = err_of(r) { return err(e); }
    // S3 can answer 200 with an error document for a failed completion
    let x = to_str(resp.body);
    if strings.contains(x, "<Error>") {
        return err("s3: " + xml_text(x, "Code") + ": " + xml_text(x, "Message"));
    }
    return ok(unquote(xml_text(x, "ETag")));
}

pub fn abort_multipart(c: Client, bucket: str, key: str, upload_id: str,
                       deadline: until) -> result[bool, str] {
    let q: map[str]str = {};
    q["uploadId"] = upload_id;
    let r = send(c, "DELETE", bucket, key, q, {}, b"", deadline);
    guard let _resp = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

// Upload data in parts of part_size bytes (at least 5 MiB), aborting the
// upload if any part fails, so no orphaned parts are left to be billed.
pub fn put_large(c: Client, bucket: str, key: str, data: bytes, content_type: str,
                 part_size: int, deadline: until) -> result[str, str] {
    if part_size < 5 * 1048576 {
        return err("s3: part_size must be at least 5 MiB");
    }
    if len(data) <= part_size {
        return put_object(c, bucket, key, data, content_type, deadline);
    }
    let cr = create_multipart(c, bucket, key, content_type, deadline);
    guard let id = cr else let e = err_of(cr) { return err(e); }
    let etags: [str] = [];
    let off = 0;
    let n = 1;
    while off < len(data) {
        let end = off + part_size;
        if end > len(data) {
            end = len(data);
        }
        let pr = upload_part(c, bucket, key, id, n, data[off..end], deadline);
        guard let etag = pr else let e = err_of(pr) {
            abort_multipart(c, bucket, key, id, deadline);
            return err(e);
        }
        push(etags, etag);
        off = end;
        n += 1;
    }
    let done = complete_multipart(c, bucket, key, id, etags, deadline);
    if let _e = done {
        return done;
    }
    abort_multipart(c, bucket, key, id, deadline);
    return done;
}

// ---- buckets ------------------------------------------------------------------------

pub fn create_bucket(c: Client, bucket: str, deadline: until) -> result[bool, str] {
    let body = b"";
    let h: map[str]str = {};
    if c.region != "us-east-1" && c.region != "auto" {
        body = to_bytes("<CreateBucketConfiguration><LocationConstraint>" + xml_escape(c.region) +
                        "</LocationConstraint></CreateBucketConfiguration>");
        h["content-type"] = "application/xml";
    }
    let r = send(c, "PUT", bucket, "", {}, h, body, deadline);
    guard let _resp = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

pub fn delete_bucket(c: Client, bucket: str, deadline: until) -> result[bool, str] {
    let r = send(c, "DELETE", bucket, "", {}, {}, b"", deadline);
    guard let _resp = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

// ---- presigned URLs ------------------------------------------------------------------

// A URL anyone can GET (or PUT, below) for expires_seconds (1 second to 7
// days), signed now: for downloads and browser uploads that never see
// your keys.
pub fn presign_get(c: Client, bucket: str, key: str, expires_seconds: int) -> result[str, str] {
    return presign_at(c, "GET", bucket, key, expires_seconds, amz_now());
}

pub fn presign_put(c: Client, bucket: str, key: str, expires_seconds: int) -> result[str, str] {
    return presign_at(c, "PUT", bucket, key, expires_seconds, amz_now());
}

// presign at a given time ("20130524T000000Z"), for tests and for URLs
// that must agree across servers.
pub fn presign_at(c: Client, method: str, bucket: str, key: str, expires_seconds: int,
                  amzdate: str) -> result[str, str] {
    if expires_seconds < 1 || expires_seconds > 604800 {
        return err("s3: a presigned URL lasts 1 second to 7 days");
    }
    let br = check_bucket(bucket);
    guard let _b = br else let e = err_of(br) { return err(e); }
    let date = strings.slice(amzdate, 0, 8);
    let scope = date + "/" + c.region + "/s3/aws4_request";
    let host = target_host(c, bucket);
    let path = target_path(c, bucket, key);
    let q: map[str]str = {};
    q["X-Amz-Algorithm"] = "AWS4-HMAC-SHA256";
    q["X-Amz-Credential"] = c.access_key + "/" + scope;
    q["X-Amz-Date"] = amzdate;
    q["X-Amz-Expires"] = to_str(expires_seconds);
    q["X-Amz-SignedHeaders"] = "host";
    if c.session_token != "" {
        q["X-Amz-Security-Token"] = c.session_token;
    }
    let cq = canonical_query(q);
    let creq = method + "\n" + path + "\n" + cq + "\nhost:" + host + "\n\nhost\nUNSIGNED-PAYLOAD";
    let sts = "AWS4-HMAC-SHA256\n" + amzdate + "\n" + scope + "\n" +
              encoding.hex_encode(crypto.sha256(to_bytes(creq)));
    let sig = encoding.hex_encode(crypto.hmac_sha256(signing_key(c, date), to_bytes(sts)));
    return ok(c.scheme + "://" + host + path + "?" + cq + "&X-Amz-Signature=" + sig);
}

// ---- signing -----------------------------------------------------------------------

fn amz_now() -> str {
    return timez.unix_nano(time.wall()).format("%Y%m%dT%H%M%SZ");
}

// kSigning = HMAC(HMAC(HMAC(HMAC("AWS4" + secret, date), region), "s3"),
// "aws4_request"), kept for the day it is for.
fn signing_key(c: Client, date: str) -> bytes {
    if c.key_date == date {
        return c.key;
    }
    let k = crypto.hmac_sha256(to_bytes("AWS4" + c.secret_key), to_bytes(date));
    k = crypto.hmac_sha256(k, to_bytes(c.region));
    k = crypto.hmac_sha256(k, b"s3");
    k = crypto.hmac_sha256(k, b"aws4_request");
    c.key_date = date;
    c.key = k;
    return k;
}

// The Authorization header for a request (SigV4, signed headers are host,
// x-amz-content-sha256, x-amz-date, any x-amz-security-token and the
// caller's headers). headers holds lowercase names.
pub fn sign_request(c: Client, method: str, host: str, path: str, query: map[str]str,
                    headers: map[str]str, payload_hash: str, amzdate: str) -> str {
    let date = strings.slice(amzdate, 0, 8);
    let scope = date + "/" + c.region + "/s3/aws4_request";
    let all: map[str]str = {};
    for k, v in headers {
        all[strings.to_lower(k)] = strings.trim(v);
    }
    all["host"] = host;
    all["x-amz-content-sha256"] = payload_hash;
    all["x-amz-date"] = amzdate;
    if c.session_token != "" {
        all["x-amz-security-token"] = c.session_token;
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
    let creq = method + "\n" + path + "\n" + canonical_query(query) + "\n" + ch + "\n" +
               signed + "\n" + payload_hash;
    let sts = "AWS4-HMAC-SHA256\n" + amzdate + "\n" + scope + "\n" +
              encoding.hex_encode(crypto.sha256(to_bytes(creq)));
    let sig = encoding.hex_encode(crypto.hmac_sha256(signing_key(c, date), to_bytes(sts)));
    return "AWS4-HMAC-SHA256 Credential=" + c.access_key + "/" + scope +
           ", SignedHeaders=" + signed + ", Signature=" + sig;
}

fn sort_strs(xs: [str]) -> [str] {
    let out = xs;
    // insertion sort: a request has a handful of headers
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

fn canonical_query(q: map[str]str) -> str {
    let pairs: [str] = [];
    for k, v in q {
        push(pairs, uri_encode(k, false) + "=" + uri_encode(v, false));
    }
    return strings.join(sort_strs(pairs), "&");
}

// Bucket names: 3 to 63 lowercase letters, digits, dots and hyphens.
fn check_bucket(b: str) -> result[bool, str] {
    if len(b) < 3 || len(b) > 63 {
        return err("s3: bucket names are 3 to 63 characters");
    }
    let x = to_bytes(b);
    for i in 0..len(x) {
        let c = x[i];
        if !((c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 46 || c == 45) {
            return err("s3: bucket names use lowercase letters, digits, dots and hyphens");
        }
    }
    return ok(true);
}

fn target_host(c: Client, bucket: str) -> str {
    if c.path_style || bucket == "" {
        return c.host;
    }
    return bucket + "." + c.host;
}

fn target_path(c: Client, bucket: str, key: str) -> str {
    let p = "/";
    if c.path_style && bucket != "" {
        p = p + bucket;
        if key != "" {
            p = p + "/";
        }
    }
    return p + uri_encode(key, true);
}

// Sign and send; a non-2xx answer is an error with S3's code and message.
fn send(c: Client, method: str, bucket: str, key: str, query: map[str]str,
        headers: map[str]str, body: bytes, deadline: until) -> result[httpc.Response, str] {
    let r = send_raw(c, method, bucket, key, query, headers, body, deadline);
    guard let resp = r else let e = err_of(r) { return err(e); }
    if resp.status < 200 || resp.status > 299 {
        let x = to_str(resp.body);
        let code = xml_text(x, "Code");
        if code == "" {
            return err("s3: " + method + " " + key + ": HTTP " + to_str(resp.status));
        }
        return err("s3: " + code + ": " + xml_text(x, "Message"));
    }
    return ok(resp);
}

fn send_raw(c: Client, method: str, bucket: str, key: str, query: map[str]str,
            headers: map[str]str, body: bytes, deadline: until) -> result[httpc.Response, str] {
    if bucket != "" {
        let br = check_bucket(bucket);
        guard let _b = br else let e = err_of(br) { return err(e); }
    }
    if len(key) > 1024 {
        return err("s3: object keys are at most 1024 bytes");
    }
    let host = target_host(c, bucket);
    let path = target_path(c, bucket, key);
    let amzdate = amz_now();
    let payload_hash = encoding.hex_encode(crypto.sha256(body));
    let auth = sign_request(c, method, host, path, query, headers, payload_hash, amzdate);
    let url = c.scheme + "://" + host + path;
    let cq = canonical_query(query);
    if cq != "" {
        url = url + "?" + cq;
    }
    let req = httpc.new_request(method, url);
    for k, v in headers {
        req.headers[k] = v;
    }
    req.headers["x-amz-date"] = amzdate;
    req.headers["x-amz-content-sha256"] = payload_hash;
    if c.session_token != "" {
        req.headers["x-amz-security-token"] = c.session_token;
    }
    req.headers["Authorization"] = auth;
    req.body = body;
    // a redirect would change the host the signature covers
    req.max_redirects = 0;
    return httpc.client_send(c.http, req, deadline);
}

// ---- small XML reading ---------------------------------------------------------------
//
// S3's responses are flat, known documents; these read the few elements
// used without a general XML parser. Text is unescaped.

fn xml_text(x: str, tag: str) -> str {
    let open = "<" + tag + ">";
    let at = strings.find(x, open);
    if at < 0 {
        return "";
    }
    let rest = strings.slice(x, at + len(open), len(x));
    let end = strings.find(rest, "</" + tag + ">");
    if end < 0 {
        return "";
    }
    return xml_unescape(strings.slice(rest, 0, end));
}

fn xml_blocks(x: str, tag: str) -> [str] {
    let out: [str] = [];
    let open = "<" + tag + ">";
    let close = "</" + tag + ">";
    let rest = x;
    while true {
        let at = strings.find(rest, open);
        if at < 0 {
            break;
        }
        rest = strings.slice(rest, at + len(open), len(rest));
        let end = strings.find(rest, close);
        if end < 0 {
            break;
        }
        push(out, strings.slice(rest, 0, end));
        rest = strings.slice(rest, end + len(close), len(rest));
    }
    return out;
}

fn xml_unescape(s: str) -> str {
    if !strings.contains(s, "&") {
        return s;
    }
    return strings.replace(strings.replace(strings.replace(strings.replace(strings.replace(s,
        "&lt;", "<"), "&gt;", ">"), "&quot;", "\""), "&apos;", "'"), "&amp;", "&");
}

fn xml_escape(s: str) -> str {
    return strings.replace(strings.replace(strings.replace(s, "&", "&amp;"), "<", "&lt;"), ">", "&gt;");
}

fn url_unescape(s: str) -> str {
    let r = encoding.url_decode(s);
    return r ?? s;
}

fn unquote(s: str) -> str {
    if len(s) >= 2 && strings.has_prefix(s, "\"") && strings.has_suffix(s, "\"") {
        return strings.slice(s, 1, len(s) - 1);
    }
    if strings.has_prefix(s, "&quot;") && strings.has_suffix(s, "&quot;") && len(s) >= 12 {
        return strings.slice(s, 6, len(s) - 6);
    }
    return s;
}
