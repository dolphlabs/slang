// read_secret: echo off while the line is read, on again after.
import "io";

print("pw? ");
let r = io.read_secret();
guard let maybe = r else let e = err_of(r) { println("ERR " + e); exit(1); }
println("got:" + (maybe ?? "<eof>"));
println("after");
