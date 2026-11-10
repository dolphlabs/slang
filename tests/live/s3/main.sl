// The s3 client against a REAL S3-compatible server. Not part of
// `make test`; CI runs it against a service container, and locally:
//
//   docker run -d -p 58000:8000 -e REMOTE_MANAGEMENT_DISABLE=1 \
//       -e SCALITY_ACCESS_KEY_ID=slangtest -e SCALITY_SECRET_ACCESS_KEY=slangtestsecret \
//       zenko/cloudserver
//   S3_ENDPOINT=http://127.0.0.1:58000 ./slangc tests/live/s3/main.sl --run
//
// The server checks every SigV4 signature, so each passing call is also a
// signature the server accepted.

import "httpc";
import "proc";
import "s3";
import "strings";
import "time";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon() -> until {
    return until_of(time.mono() + 30000000000);
}

fn must_str(r: result[str, str], what: str) -> str {
    guard let v = r else let e = err_of(r) { die(what + ": " + e); return ""; }
    return v;
}

fn must_bytes(r: result[bytes, str], what: str) -> bytes {
    guard let v = r else let e = err_of(r) { die(what + ": " + e); return b""; }
    return v;
}

let endpoint = proc.getenv("S3_ENDPOINT") ?? "http://127.0.0.1:58000";
let cr = s3.new_client(endpoint, proc.getenv("S3_REGION") ?? "us-east-1",
                       proc.getenv("S3_ACCESS_KEY") ?? "slangtest",
                       proc.getenv("S3_SECRET_KEY") ?? "slangtestsecret");
guard let c = cr else let e = err_of(cr) { die(e); panic("x"); }
let bucket = "slang-live-" + to_str((time.wall() / 1000) % 1000000000);
guard let _b = s3.create_bucket(c, bucket, soon()) else let e = err_of(s3.create_bucket(c, bucket, soon())) {
    die("create_bucket: " + e);
}

// ---- put, get, range, head ----------------------------------------------------
let etag = must_str(s3.put_object(c, bucket, "hello.txt", b"hello, object storage", "text/plain", soon()), "put");
if len(etag) != 32 {
    die("etag " + etag);
}
let body = must_bytes(s3.get_object(c, bucket, "hello.txt", soon()), "get");
if to_str(body) != "hello, object storage" {
    die("get body");
}
let part = must_bytes(s3.get_range(c, bucket, "hello.txt", 7, 12, soon()), "range");
if to_str(part) != "object" {
    die("range gave " + to_str(part));
}
let hr = s3.head_object(c, bucket, "hello.txt", soon());
guard let ho = hr else let e = err_of(hr) { die("head: " + e); panic("x"); }
guard let info = ho else { die("head: missing"); panic("x"); }
if info.size != 21 || info.etag != etag {
    die("head size/etag");
}
let missing = s3.head_object(c, bucket, "nope", soon());
if let m = missing ?? none { die("head of a missing key"); }
let gm = s3.get_object(c, bucket, "nope", soon());
if !strings.contains(err_of(gm), "NoSuchKey") {
    die("get of a missing key: " + err_of(gm));
}
println("ok put, get, range and head (missing: " + err_of(gm) + ")");

// ---- awkward keys ------------------------------------------------------------------
let odd = "dir one/naïve café+%&=?.txt";
must_str(s3.put_object(c, bucket, odd, b"odd", "", soon()), "put odd key");
if to_str(must_bytes(s3.get_object(c, bucket, odd, soon()), "get odd key")) != "odd" {
    die("odd key round trip");
}
println("ok keys with spaces, unicode and reserved characters");

// ---- listing ---------------------------------------------------------------------------
for i in 0..7 {
    must_str(s3.put_object(c, bucket, "list/" + to_str(i) + ".bin", b"x", "", soon()), "put list");
}
must_str(s3.put_object(c, bucket, "list/sub/deep.bin", b"x", "", soon()), "put deep");
let keys: [str] = [];
let next = "";
let pages = 0;
while true {
    let pr = s3.list_objects(c, bucket, "list/", "", next, 3, soon());
    guard let page = pr else let e = err_of(pr) { die("list: " + e); panic("x"); }
    for o in page.objects {
        push(keys, o.key);
    }
    pages += 1;
    if !page.truncated {
        break;
    }
    next = page.next;
}
if len(keys) != 8 || pages != 3 {
    die("listed " + to_str(len(keys)) + " keys in " + to_str(pages) + " pages");
}
let dr = s3.list_objects(c, bucket, "list/", "/", "", 1000, soon());
guard let dpage = dr else let e = err_of(dr) { die("list /: " + e); panic("x"); }
if len(dpage.objects) != 7 || len(dpage.prefixes) != 1 || dpage.prefixes[0] != "list/sub/" {
    die("delimiter listing");
}
let rr = s3.list_objects(c, bucket, "dir one/", "", "", 1000, soon());
guard let rpage = rr else let e = err_of(rr) { die("list odd: " + e); panic("x"); }
if len(rpage.objects) != 1 || rpage.objects[0].key != odd {
    die("listed odd key as " + rpage.objects[0].key);
}
println("ok listing: 3 pages, a delimiter, odd keys decoded");

// ---- multipart -------------------------------------------------------------------------
let big = strings.bytes_zero(12 * 1048576 + 123);
for i in 0..len(big) {
    if i % 4096 == 0 {
        big[i] = (i / 4096) & 255;
    }
}
let met = must_str(s3.put_large(c, bucket, "big.bin", big, "application/octet-stream",
                                5 * 1048576, soon()), "put_large");
let back = must_bytes(s3.get_object(c, bucket, "big.bin", soon()), "get big");
if back != big {
    die("multipart round trip (" + to_str(len(back)) + " bytes)");
}
if !strings.contains(met, "-3") {
    die("multipart etag " + met);
}
let up = must_str(s3.create_multipart(c, bucket, "aborted.bin", "", soon()), "create");
must_str(s3.upload_part(c, bucket, "aborted.bin", up, 1, b"part", soon()), "part");
guard let _a = s3.abort_multipart(c, bucket, "aborted.bin", up, soon()) else { die("abort"); }
println("ok multipart: 3 parts round trip, abort");

// ---- presigned URLs -------------------------------------------------------------------
let pg = must_str(s3.presign_get(c, bucket, "hello.txt", 60), "presign get");
let gr = httpc.get(pg, soon());
guard let gresp = gr else let e = err_of(gr) { die("presigned get: " + e); panic("x"); }
if gresp.status != 200 || to_str(gresp.body) != "hello, object storage" {
    die("presigned get status " + to_str(gresp.status));
}
let pp = must_str(s3.presign_put(c, bucket, "uploaded.txt", 60), "presign put");
let preq = httpc.new_request("PUT", pp);
preq.body = b"via a presigned url";
let pr2 = httpc.send(preq, soon());
guard let presp = pr2 else let e = err_of(pr2) { die("presigned put: " + e); panic("x"); }
if presp.status != 200 || to_str(must_bytes(s3.get_object(c, bucket, "uploaded.txt", soon()), "get uploaded")) != "via a presigned url" {
    die("presigned put status " + to_str(presp.status));
}
let tampered = strings.replace(pg, "hello.txt", "uploaded.txt");
let tr = httpc.get(tampered, soon());
guard let tresp = tr else { die("tampered get"); panic("x"); }
if tresp.status != 403 {
    die("a presigned URL for another key worked (" + to_str(tresp.status) + ")");
}
println("ok presigned GET and PUT (a URL edited to another key is refused)");

// ---- a wrong secret is refused -------------------------------------------------------------
let wr = s3.new_client(endpoint, "us-east-1", "slangtest", "not-the-secret");
guard let w = wr else { die("client"); panic("x"); }
let denied = s3.get_object(w, bucket, "hello.txt", soon());
if let _d = denied { die("a wrong secret was accepted"); }
println("ok wrong secret refused: " + err_of(denied));

// ---- clean up ------------------------------------------------------------------------------
let all = s3.list_objects(c, bucket, "", "", "", 1000, soon());
guard let ap = all else { die("final list"); panic("x"); }
for o in ap.objects {
    guard let _d = s3.delete_object(c, bucket, o.key, soon()) else { die("delete " + o.key); }
}
guard let _db = s3.delete_bucket(c, bucket, soon()) else let e = err_of(s3.delete_bucket(c, bucket, soon())) {
    die("delete_bucket: " + e);
}
println("ok delete objects and bucket");
