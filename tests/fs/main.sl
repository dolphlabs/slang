import "fs";

extern fn getpid() -> i32;
extern fn unlink(s: str) -> i32;
extern fn rmdir(s: str) -> i32;

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

let base = "/tmp/sl_fs_" + to_str(getpid());
let path = base + ".bin";
let dir = base + "_dir";

let missing = fs.open(path + ".nope");
guard let _m = missing else {
    println("open missing");
}

let cr = fs.create(path);
guard let wfd = cr else { die("create"); }
let payload = b"a\0b!";
let wr = fs.write(wfd, payload);
guard let wn = wr else { die("write"); }
if wn != 4 { die("write len"); }
let clr = fs.close(wfd);
guard let _c1 = clr else { die("close write"); }

let or = fs.open(path);
guard let rfd = or else { die("open"); }
let rr = fs.read(rfd, 16);
guard let data = rr else { die("read"); }
if data != payload { die("roundtrip"); }
let zr = fs.read(rfd, 8);
guard let z = zr else { die("eof"); }
if len(z) != 0 { die("eof len"); }
let cr2 = fs.close(rfd);
guard let _c2 = cr2 else { die("close read"); }
println("roundtrip");

let mr = fs.mkdir(dir);
guard let _d = mr else { die("mkdir"); }
let again = fs.mkdir(dir);
guard let _d2 = again else {
    println("mkdir exists");
}

unlink(path);
rmdir(dir);
println("fs ok");
