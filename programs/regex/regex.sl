import "regex";
import "log";

let cr = regex.compile("(\\d{4})-(\\d{2})-(\\d{2})");
guard let re = cr else let e = err_of(cr) {
    log.error("bad pattern: " + e);
    exit(1);
}
let m = regex.find(re, "due 2026-09-09");
println(to_str(m[0]) + ".." + to_str(m[1]));   // whole match
println(to_str(m[2]) + ".." + to_str(m[3]));   // year
regex.free(re);
