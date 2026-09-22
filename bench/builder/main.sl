// Why the builder package exists.
//
// `a + b` copies both sides, so assembling a result one piece at a time
// costs the sum of every intermediate length: quadratic. This prints
// both, so the difference is a number rather than a claim:
//
//     ./slangc bench/builder/main.sl --run
//
// Reference run (one Mac; treat as an order of magnitude):
//
//     naive bytes (b + one):        10000 ->    21 ms    80000 -> 1826 ms
//     builder.write_byte:         1000000 ->    32 ms  4000000 ->  136 ms
//
// Doubling the input roughly doubles the builder's time. The naive loop's
// grows by ten times between 20 KB and 40 KB, and by six between 40 KB
// and 80 KB, which is the collector joining in.
import "builder";
import "time";

fn naive_bytes(n: int) -> int {
    let out: bytes = b"";
    let one: bytes = b".";
    let i = 0;
    while i < n {
        one[0] = 97 + (i % 26);
        out = out + one;
        i = i + 1;
    }
    return len(out);
}

fn built_bytes(n: int) -> int {
    let b = builder.new_bytes();
    let i = 0;
    while i < n {
        b.write_byte(97 + (i % 26));
        i = i + 1;
    }
    return len(b.finish());
}

fn built_str(n: int) -> int {
    let b = builder.new_str();
    let i = 0;
    while i < n {
        b.write("ab");
        i = i + 1;
    }
    return len(b.finish());
}

fn built_slices(n: int) -> int {
    let b = builder.new_bytes();
    let piece = to_bytes("0123456789abcdef");
    let i = 0;
    while i < n {
        b.write(piece);
        i = i + 1;
    }
    return len(b.finish());
}

fn ms(t0: duration) -> int {
    return ((time.mono() - t0) / 1000000) as int;
}

println("naive bytes (b + one):");
for n in [10000, 20000, 40000, 80000] {
    let t0 = time.mono();
    let got = naive_bytes(n);
    println("  " + to_str(n) + " -> " + to_str(ms(t0)) + " ms");
}
println("builder.write_byte:");
for n in [10000, 100000, 1000000, 4000000] {
    let t0 = time.mono();
    let got = built_bytes(n);
    println("  " + to_str(n) + " -> " + to_str(ms(t0)) + " ms (" + to_str(got) + " bytes)");
}
println("builder.Str write (2 bytes each):");
for n in [10000, 100000, 1000000] {
    let t0 = time.mono();
    let got = built_str(n);
    println("  " + to_str(n) + " -> " + to_str(ms(t0)) + " ms (" + to_str(got) + " bytes)");
}
println("builder.Bytes write (16-byte pieces):");
for n in [10000, 100000, 1000000] {
    let t0 = time.mono();
    let got = built_slices(n);
    println("  " + to_str(n) + " -> " + to_str(ms(t0)) + " ms (" + to_str(got) + " bytes)");
}
