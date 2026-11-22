// http.parse_range and http.content_range (RFC 9110 14).
import "http";

fn show(h: str, size: int) {
    let r = http.parse_range(h, size);
    guard let rs = r else let e = err_of(r) { println(h + " -> 416 (" + e + ")"); return; }
    if len(rs) == 0 { println(h + " -> whole"); return; }
    let parts = "";
    for x in rs { parts = parts + " [" + http.content_range(x, size) + "]"; }
    println(h + " ->" + parts);
}

show("bytes=0-499", 1000);
show("bytes=500-", 1000);
show("bytes=-200", 1000);
show("bytes=-5000", 1000);
show("bytes=900-2000", 1000);
show("bytes=0-0, -1", 1000);
show("bytes=1000-", 1000);
show("bytes=1000-1200, 5000-", 1000);
show("bytes=-0", 1000);
show("bytes=0-", 0);
show("bytes=500-100", 1000);
show("bytes=abc", 1000);
show("items=0-10", 1000);
show("", 1000);
show("bytes=0-1,2-3,4-5,6-7,8-9,10-11,12-13,14-15,16-17,18-19,20-21,22-23,24-25,26-27,28-29,30-31,32-33", 1000);
