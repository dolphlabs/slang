// Raw mode and key decoding on a real terminal: keys arrive unechoed, one
// at a time, and raw_off puts the terminal back.
import "io";

let r = io.raw_on();
guard let ok = r else let e = err_of(r) { println("ERR " + e); exit(1); }
println("raw");
while true {
    let k = io.read_key();
    guard let maybe = k else let e2 = err_of(k) { println("ERR " + e2); exit(1); }
    let key = maybe ?? "<eof>";
    println("key " + key);
    if key == "q" { break; }
}
io.raw_off();
println("done");
