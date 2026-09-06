import "byteutil";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

if byteutil.find(b"hello", 0, 108) != 2 { die("find"); }
if byteutil.find(b"hello", 3, 108) != 3 { die("find from"); }
if byteutil.find(b"hello", 0, 122) != -1 { die("find miss"); }
println("find");

if !byteutil.has_prefix(b"hello", b"he") { die("prefix"); }
if byteutil.has_prefix(b"hello", b"hex") { die("prefix miss"); }
if !byteutil.has_prefix(b"hello", b"") { die("prefix empty"); }
if !byteutil.has_suffix(b"hello", b"lo") { die("suffix"); }
if byteutil.has_suffix(b"hello", b"el") { die("suffix miss"); }
println("affix");

if byteutil.trim(b"  hi\r\n") != b"hi" { die("trim"); }
if byteutil.trim(b"xy") != b"xy" { die("trim none"); }
if byteutil.trim(b" \t\n") != b"" { die("trim all"); }
println("trim");

let parts = byteutil.split(b"a,b,c", 44);
if len(parts) != 3 { die("split len"); }
if parts[0] != b"a" || parts[1] != b"b" || parts[2] != b"c" { die("split"); }
let empty = byteutil.split(b"", 44);
if len(empty) != 1 || empty[0] != b"" { die("split empty"); }
let edges = byteutil.split(b",x,", 44);
if len(edges) != 3 { die("split edges len"); }
if edges[0] != b"" || edges[1] != b"x" || edges[2] != b"" { die("split edges"); }
println("split");
println("byteutil ok");
