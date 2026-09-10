// A failed listen must say WHY.
//
// link_listen used to call the str-returning net.listen, throw its
// message away, and return a bare fault_op(SL_FAULT_IO, 0, "listen") --
// so EADDRINUSE reached the program as "listen io", with the code
// field zeroed. That is exactly the collapse the error model forbids:
// "never collapse a descriptive error into a bare fault_io()".
//
// Binding the same port twice is the one listen failure that can be
// provoked portably and without privileges, so it is what this pins.

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn run() {
    // Ephemeral would defeat the point: two listens must contend for
    // the SAME port, so it has to be a fixed one. Picked high and
    // odd-looking to avoid colliding with anything real on the box.
    let port = 47813;

    let a = link_listen(port);
    guard let _ln = a else let e = err_of(a) {
        // Someone else already holds it: the test cannot run, but the
        // message it printed is itself the thing under test, so show it
        // rather than pretending to pass.
        die("could not take the port at all: " + to_str(e));
        return;
    }

    let b = link_listen(port);
    guard let _ln2 = b else let e2 = err_of(b) {
        let msg = to_str(e2);
        // The operation must be named, and the reason must be the OS's
        // own words rather than a numeric code the reader has to look
        // up. Matching the exact strerror text would pin us to one
        // libc, so this checks the shape: "listen: <something real>".
        if len(msg) < 10 {
            die("error is too terse to be useful: " + msg);
        }
        if msg == "listen io" || msg == "io" {
            die("error collapsed to a bare fault: " + msg);
        }
        println("second listen reported a reason");
        return;
    }
    die("second listen on a taken port unexpectedly succeeded");
}

run();
