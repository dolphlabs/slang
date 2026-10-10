import "net";
import "time";

let expired = net.lookup_srv_until(
    "_mongodb._tcp.example.com", until_of(time.mono()));
if let _records = expired {
    println("FAIL expired lookup unexpectedly succeeded");
    exit(1);
} else let e = err_of(expired) {
    if e != "timeout" { println("FAIL expired lookup: " + e); exit(1); }
}
println("expired deadline ok");

for i in 0..1024 {
    let invalid = net.lookup_txt_until(
        "example.com:27017", until_of(time.mono() + 1000000000));
    if let _values = invalid {
        println("FAIL invalid name accepted");
        exit(1);
    } else let e = err_of(invalid) {
        if e != "invalid DNS query name" {
            println("FAIL invalid query: " + e);
            exit(1);
        }
    }
}
println("invalid name rejected");
