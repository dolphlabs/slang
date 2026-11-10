// Unit tests: `slangc test stdlib/s3`. The client against a real
// S3-compatible server is tests/live/s3.

fn example_client() -> Client {
    // the example credentials of AWS's Signature Version 4 documentation
    let r = new_client("https://s3.amazonaws.com", "us-east-1", "AKIAIOSFODNN7EXAMPLE",
                       "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");
    guard let c = r else let e = err_of(r) { panic(e); }
    c.path_style = false;
    return c;
}

// AWS docs, "Authenticating Requests: Using Query Parameters", the
// presigned GET of examplebucket/test.txt for 86400 s.
fn test_should_presign_like_the_aws_example() {
    let url = presign_at(example_client(), "GET", "examplebucket", "test.txt", 86400,
                         "20130524T000000Z") ?? "";
    assert(strings.has_suffix(url, "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"), url);
    assert(strings.has_prefix(url, "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"), url);
}

// AWS docs, "Authenticating Requests: Using the Authorization Header",
// the GET Object example with a Range header.
fn test_should_sign_headers_like_the_aws_example() {
    let h: map[str]str = {};
    h["range"] = "bytes=0-9";
    let auth = sign_request(example_client(), "GET", "examplebucket.s3.amazonaws.com",
                            "/test.txt", {}, h,
                            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                            "20130524T000000Z");
    assert(auth == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " +
           "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " +
           "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", auth);
}

fn test_should_cache_the_signing_key_per_day() {
    let c = example_client();
    let k1 = signing_key(c, "20130524");
    assert(c.key_date == "20130524" && signing_key(c, "20130524") == k1, "cached");
    let k2 = signing_key(c, "20130525");
    assert(k2 != k1 && c.key_date == "20130525", "a new day, a new key");
}

fn test_should_uri_encode_as_sigv4_wants() {
    assert(uri_encode("a b+c/d~e_f.g-h", false) == "a%20b%2Bc%2Fd~e_f.g-h", uri_encode("a b+c/d~e_f.g-h", false));
    assert(uri_encode("dir one/x", true) == "dir%20one/x", "keep slashes in paths");
    assert(uri_encode("café", true) == "caf%C3%A9", "UTF-8 bytes");
    assert(uri_encode("", false) == "", "empty");
}

fn test_should_sort_and_encode_the_canonical_query() {
    let q: map[str]str = {};
    q["uploadId"] = "a/b";
    q["partNumber"] = "2";
    q["list-type"] = "2";
    assert(canonical_query(q) == "list-type=2&partNumber=2&uploadId=a%2Fb", canonical_query(q));
    let e: map[str]str = {};
    e["uploads"] = "";
    assert(canonical_query(e) == "uploads=", "an empty value keeps its =");
}

fn test_should_validate_buckets_and_endpoints() {
    assert(is_ok_bool(check_bucket("my-bucket.v2")), "ok bucket");
    assert(!is_ok_bool(check_bucket("ab")), "too short");
    assert(!is_ok_bool(check_bucket("Upper")), "upper case");
    assert(!is_ok_bool(check_bucket("a/b/c")), "slash");
    assert(!is_ok_client(new_client("s3.amazonaws.com", "us-east-1", "k", "s")), "no scheme");
    assert(!is_ok_client(new_client("https://host/path", "us-east-1", "k", "s")), "a path");
    assert(!is_ok_client(new_client("https://host", "", "k", "s")), "no region");
    assert(!is_ok_client(new_client("https://host", "r", "", "s")), "no key");
    let c = new_client("https://host:443/", "auto", "k", "s") ?? example_client();
    assert(c.host == "host" && c.endpoint == "https://host", "default port and slash dropped");
    let d = new_client("http://127.0.0.1:9000", "us-east-1", "k", "s") ?? example_client();
    assert(d.host == "127.0.0.1:9000" && d.path_style, "port kept, path style by default");
}

fn test_should_build_paths_in_both_styles() {
    let c = new_client("http://127.0.0.1:9000", "us-east-1", "k", "s") ?? example_client();
    assert(target_path(c, "b1", "a b/c.txt") == "/b1/a%20b/c.txt", target_path(c, "b1", "a b/c.txt"));
    assert(target_path(c, "b1", "") == "/b1", "bucket root");
    assert(target_host(c, "b1") == "127.0.0.1:9000", "path-style host");
    c.path_style = false;
    assert(target_path(c, "b1", "k") == "/k" && target_host(c, "b1") == "b1.127.0.0.1:9000", "virtual host");
}

fn test_should_read_s3_xml() {
    let x = "<ListBucketResult><IsTruncated>true</IsTruncated><Contents><Key>a%20b</Key><Size>3</Size>" +
            "<ETag>&quot;abc&quot;</ETag></Contents><Contents><Key>c</Key><Size>10</Size><ETag>\"def\"</ETag>" +
            "</Contents><NextContinuationToken>t&amp;1</NextContinuationToken></ListBucketResult>";
    assert(xml_text(x, "IsTruncated") == "true", "text");
    assert(xml_text(x, "NextContinuationToken") == "t&1", "unescaped");
    assert(xml_text(x, "Missing") == "", "absent");
    let blocks = xml_blocks(x, "Contents");
    assert(len(blocks) == 2 && xml_text(blocks[1], "Key") == "c", "blocks");
    assert(unquote(xml_text(blocks[0], "ETag")) == "abc" && unquote(xml_text(blocks[1], "ETag")) == "def", "etags");
    assert(url_unescape("a%20b") == "a b", "url-decoded keys");
    assert(xml_escape("a&b<c>") == "a&amp;b&lt;c&gt;", "escape");
}

fn test_should_refuse_bad_presign_and_part_arguments() {
    let c = example_client();
    assert(!is_ok_str(presign_at(c, "GET", "examplebucket", "k", 0, "20130524T000000Z")), "zero expiry");
    assert(!is_ok_str(presign_at(c, "GET", "examplebucket", "k", 604801, "20130524T000000Z")), "past 7 days");
    assert(!is_ok_str(put_large(c, "examplebucket", "k", b"x", "", 1048576, until_never())), "parts under 5 MiB");
}

fn is_ok_bool(r: result[bool, str]) -> bool {
    if let _v = r { return true; }
    return false;
}
fn is_ok_str(r: result[str, str]) -> bool {
    if let _v = r { return true; }
    return false;
}
fn is_ok_client(r: result[Client, str]) -> bool {
    if let _v = r { return true; }
    return false;
}
