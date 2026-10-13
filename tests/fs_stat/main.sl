// fs.realpath resolves "..", "." and symlinks to an absolute path (what a
// static file server compares with its root); fs.fstat reports an open
// file's kind, size and modification time. realpath needs more than a
// task's first 8 KB of stack, and grows it first: called from a spawned
// task here.
import "fs";
import "strings";

fn real(p: str) -> str {
    return fs.realpath(p) ?? "";
}

let here = real("tests/fs_stat/../fs_stat/./main.sl");
println(strings.has_prefix(here, "/") && strings.has_suffix(here, "/tests/fs_stat/main.sl"));
let h = spawn real("tests/../tests/fs_stat");
println(strings.has_suffix(join_wait(h) ?? "", "/tests/fs_stat"));
let missing = fs.realpath("tests/fs_stat/no-such-file");
if let _m = missing { println("missing resolved"); } else { println("missing is an error"); }

let fr = fs.open("tests/fs_stat/expected.txt");
guard let fd = fr else { println("open failed"); exit(1); }
let st = fs.fstat(fd);
let rr = fs.read(fd, 4096);
guard let body = rr else { println("read failed"); exit(1); }
println(len(st) == 4 && st[0] == 0 && st[1] == len(body) && st[2] > 1700000000 && st[3] >= 0);
fs.close(fd);
let dr = fs.open("tests/fs_stat");
guard let dfd = dr else { println("open dir failed"); exit(1); }
println(fs.fstat(dfd)[0] == 1);
fs.close(dfd);
println(len(fs.fstat(fd)) == 0);
