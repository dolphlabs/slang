// bcrypt verification and scrypt, against outside references: scrypt's
// RFC 7914 vectors, and bcrypt hashes made by Apache's htpasswd (-B, $2y$)
// with one OpenBSD-style $2b$ and $2a$ each. A wrong password, a password
// past bcrypt's 72 bytes, and hashes with a bad prefix, cost or alphabet.
import "crypto";
import "encoding";

fn hex(r: result[bytes, str]) -> str {
    guard let b = r else let e = err_of(r) { return "err: " + e; }
    return encoding.hex_encode(b);
}

fn check(pw: str, h: str) -> str {
    let r = crypto.bcrypt_verify(to_bytes(pw), h);
    guard let ok_v = r else let e = err_of(r) { return "err: " + e; }
    if ok_v {
        return "match";
    }
    return "no match";
}

println("scrypt 1: " + hex(crypto.scrypt(b"", b"", 16, 1, 1, 64)));
println("scrypt 2: " + hex(crypto.scrypt(b"password", b"NaCl", 1024, 8, 16, 64)));
println("scrypt 3: " + hex(crypto.scrypt(b"pleaseletmein", b"SodiumChloride", 16384, 8, 1, 64)));
println("scrypt N=1000: " + hex(crypto.scrypt(b"a", b"b", 1000, 8, 1, 32)));
println("scrypt N=2^21: " + hex(crypto.scrypt(b"a", b"b", 2097152, 1, 1, 32)));
println("scrypt mem: " + hex(crypto.scrypt(b"a", b"b", 1048576, 8, 1, 32)));
println("scrypt len: " + hex(crypto.scrypt(b"a", b"b", 16, 1, 1, 65)));

let long_pw = "0123456789012345678901234567890123456789012345678901234567890123456789ab-tail";
let vectors = [
    ["password", "$2y$05$EFXZWjvKZJj71LQO4tWhXev6RnDZVCLo8ufH.qKnIhYqmISZ53I.."],
    ["correct horse battery staple", "$2y$05$tQrKsuMEjwqsd2WNVUSvp.DoMARg..x4ja3m81LFeRSf9Kfqz1Wxu"],
    ["", "$2y$05$Es9xaoZ967YmdD5m2n7G5uuMDKZKFu/cDGmnhm/ApDd9xJNF5l8R6"],
    ["pässwörd", "$2y$05$0ok3.2.xZ2NvdFQoWatoM.uaDoPRSTq5HrgyjQ5ik5Z2nWXjCjqSy"],
    [long_pw, "$2y$05$RyZw/g/DOV8XaeWXUMPI4emjb96sJu1zZih90DedU4FffkS8VKqi."],
    ["x", "$2y$04$wejJOts39TdRMkeM6FOvkeW4rsUI7U4vQNwXTMLUAl5CHZJImCbQy"]
];
for v in vectors {
    println("bcrypt " + v[1] + ": " + check(v[0], v[1]));
}
// The same hash under the $2b$ and $2a$ prefixes.
println("bcrypt 2b: " + check("password", "$2b$05$EFXZWjvKZJj71LQO4tWhXev6RnDZVCLo8ufH.qKnIhYqmISZ53I.."));
println("bcrypt 2a: " + check("password", "$2a$05$EFXZWjvKZJj71LQO4tWhXev6RnDZVCLo8ufH.qKnIhYqmISZ53I.."));
println("wrong password: " + check("Password", "$2y$05$EFXZWjvKZJj71LQO4tWhXev6RnDZVCLo8ufH.qKnIhYqmISZ53I.."));
println("empty vs one byte: " + check("a", "$2y$05$Es9xaoZ967YmdD5m2n7G5uuMDKZKFu/cDGmnhm/ApDd9xJNF5l8R6"));
// Only the first 72 bytes count.
println("72-byte prefix: " + check(strings_prefix(long_pw, 72), "$2y$05$RyZw/g/DOV8XaeWXUMPI4emjb96sJu1zZih90DedU4FffkS8VKqi."));
println("71-byte prefix: " + check(strings_prefix(long_pw, 71), "$2y$05$RyZw/g/DOV8XaeWXUMPI4emjb96sJu1zZih90DedU4FffkS8VKqi."));
println("2x: " + check("password", "$2x$05$EFXZWjvKZJj71LQO4tWhXev6RnDZVCLo8ufH.qKnIhYqmISZ53I.."));
println("cost 31: " + check("password", "$2y$31$EFXZWjvKZJj71LQO4tWhXev6RnDZVCLo8ufH.qKnIhYqmISZ53I.."));
println("cost 03: " + check("password", "$2y$03$EFXZWjvKZJj71LQO4tWhXev6RnDZVCLo8ufH.qKnIhYqmISZ53I.."));
println("alphabet: " + check("password", "$2y$05$EFXZWjvKZJj71LQO4tWhXev6RnDZVCLo8ufH.qKnIhYqmISZ53I.+"));
println("short: " + check("password", "$2y$05$EFXZWjvKZJj71LQO4tWhXev6RnDZVCLo8ufH"));
println("argon: " + check("password", "$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHQ$aGFzaGhhc2hoYXNo"));

fn strings_prefix(s: str, n: int) -> str {
    let b = to_bytes(s);
    return to_str(b[0..n]);
}
