// Names that are macros in C. Each broke the generated C on some
// platform: GCC predefines unix and linux as 1 (so this failed on Linux
// only), and errno/stdin/stdout/stderr/EOF/NULL expand to expressions.

struct Target { unix: bool, linux: int }

fn pick(unix: bool, errno: int) -> int {
    if unix {
        return errno;
    }
    return -errno;
}

let unix = true;
let linux = 2;
let i386 = 3;
let errno = 4;
let stdin = 5;
let stdout = 6;
let stderr = 7;
let EOF = 8;
let NULL = 9;
let t = Target { unix: unix, linux: linux };
println(pick(t.unix, errno) + t.linux + i386 + stdin + stdout + stderr + EOF + NULL);
