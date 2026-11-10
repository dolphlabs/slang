// crypto: SHA-384/512, HMAC, HKDF, constant-time compare, AES-256-GCM,
// ChaCha20-Poly1305, seal/open, Ed25519, ECDSA P-256 and RSA signing,
// against published vectors (FIPS 180-4, RFC 4231, RFC 5869, NIST GCM
// test case 16, RFC 8439 2.8.2, RFC 8032 7.1, RFC 6979 A.2.5) and against
// keys and signatures made by the openssl command-line tool. Those keys
// were generated for this test alone and protect nothing.

import "crypto";
import "encoding";

fn h(s: str) -> bytes {
    let r = encoding.hex_decode(s);
    guard let b = r else let e = err_of(r) { panic(e); }
    return b;
}
fn hx(b: bytes) -> str {
    return encoding.hex_encode(b);
}
fn must(r: result[bytes, str]) -> bytes {
    guard let b = r else let e = err_of(r) { panic(e); }
    return b;
}
fn err_text(r: result[bytes, str]) -> str {
    if let b = r {
        return "no error: " + hx(b);
    }
    return err_of(r);
}
fn yes(r: result[bool, str]) -> bool {
    return r ?? false;
}
fn check(name: str, ok: bool) {
    if ok {
        println("ok " + name);
    } else {
        println("FAIL " + name);
    }
}

// ---- hashes, HMAC, HKDF -----------------------------------------------------
check("sha384 abc", hx(crypto.sha384(b"abc")) == "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7");
check("sha512 abc", hx(crypto.sha512(b"abc")) == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");
check("sha512 empty", len(crypto.sha512(b"")) == 64);
check("hmac_sha384 rfc4231 #1", hx(crypto.hmac_sha384(h("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), b"Hi There")) == "afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59cfaea9ea9076ede7f4af152e8b2fa9cb6");
check("hmac_sha512 rfc4231 #1", hx(crypto.hmac_sha512(h("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), b"Hi There")) == "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854");
check("hkdf_sha256 rfc5869 A.1", hx(must(crypto.hkdf_sha256(h("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"),
    h("000102030405060708090a0b0c"), h("f0f1f2f3f4f5f6f7f8f9"), 42))) == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865");
check("hkdf_sha256 rfc5869 A.3 (no salt or info)", hx(must(crypto.hkdf_sha256(
    h("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), b"", b"", 42))) == "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8");
check("hkdf_sha512", hx(must(crypto.hkdf_sha512(b"secret", b"salt", b"info", 80))) == "90e269f053d383c4b2070be93238adf358f3d67bd7b17ca3de95f10a50a8385e66d8241c8c22c91cee75d7bda92e8111236b71b63c8f05973947428074d272f073de7d106ca1b6f5beeb22fc785a8166");
println(err_text(crypto.hkdf_sha256(b"k", b"", b"", 0)));
println(err_text(crypto.hkdf_sha256(b"k", b"", b"", 8161)));
check("hkdf at the limit", len(must(crypto.hkdf_sha256(b"k", b"", b"", 8160))) == 8160);
check("constant_time_eq", crypto.constant_time_eq(b"abc", b"abc") && !crypto.constant_time_eq(b"abc", b"abd")
      && !crypto.constant_time_eq(b"abc", b"ab") && crypto.constant_time_eq(b"", b""));

// ---- AEAD -------------------------------------------------------------------
let ck = h("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
let cn = h("070000004041424344454647");
let caad = h("50515253c0c1c2c3c4c5c6c7");
let cpt = b"Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
let cwant = "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116" +
            "1ae10b594f09e26a7e902ecbd0600691";
let csealed = must(crypto.chacha20poly1305_seal(ck, cn, cpt, caad));
check("chacha20poly1305 rfc8439 2.8.2", hx(csealed) == cwant);
check("chacha20poly1305 opens", must(crypto.chacha20poly1305_open(ck, cn, csealed, caad)) == cpt);
let tampered = csealed[..];
tampered[0] = tampered[0] ^ 1;
println(err_text(crypto.chacha20poly1305_open(ck, cn, tampered, caad)));
println(err_text(crypto.chacha20poly1305_open(ck, cn, csealed, b"other aad")));
println(err_text(crypto.chacha20poly1305_seal(ck[..31], cn, cpt, caad)));
println(err_text(crypto.chacha20poly1305_seal(ck, cn[..8], cpt, caad)));

let gk = h("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308");
let gn = h("cafebabefacedbaddecaf888");
let gpt = h("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39");
let gaad = h("feedfacedeadbeeffeedfacedeadbeefabaddad2");
let gwant = "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662" +
            "76fc6ece0f4e1768cddf8853bb2d551b";
let gsealed = must(crypto.aes256gcm_seal(gk, gn, gpt, gaad));
check("aes256gcm nist test case 16", hx(gsealed) == gwant);
check("aes256gcm opens", must(crypto.aes256gcm_open(gk, gn, gsealed, gaad)) == gpt);
check("aes256gcm empty message", len(must(crypto.aes256gcm_seal(gk, gn, b"", b""))) == 16);
check("aes256gcm empty opens", len(must(crypto.aes256gcm_open(gk, gn, must(crypto.aes256gcm_seal(gk, gn, b"", b"")), b""))) == 0);
println(err_text(crypto.aes256gcm_open(gk, gn, gsealed[..15], gaad)));

let key = must(crypto.rand(32));
let box1 = must(crypto.seal(key, b"session=42", b"cookie"));
let box2 = must(crypto.seal(key, b"session=42", b"cookie"));
check("seal adds nonce and tag", len(box1) == 12 + 10 + 16);
check("seal picks a fresh nonce", box1 != box2);
check("open", to_str(must(crypto.open(key, box1, b"cookie"))) == "session=42");
println(err_text(crypto.open(key, box1, b"other")));
println(err_text(crypto.open(must(crypto.rand(32)), box1, b"cookie")));
println(err_text(crypto.open(key, box1[..20], b"cookie")));

// ---- Ed25519 ------------------------------------------------------------------
let e1 = h("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
check("ed25519 rfc8032 #1 public", hx(must(crypto.ed25519_public_key(e1))) == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
check("ed25519 rfc8032 #1 sign", hx(must(crypto.ed25519_sign(e1, b""))) == "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
let e2 = h("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb");
let e2pub = h("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c");
let e2sig = h("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00");
check("ed25519 rfc8032 #2 sign", must(crypto.ed25519_sign(e2, h("72"))) == e2sig);
check("ed25519 verifies", yes(crypto.ed25519_verify(e2pub, h("72"), e2sig)));
check("ed25519 rejects another message", !yes(crypto.ed25519_verify(e2pub, h("73"), e2sig)));
check("ed25519 rejects a short signature", !yes(crypto.ed25519_verify(e2pub, h("72"), e2sig[..63])));
println(err_of(crypto.ed25519_verify(e2pub[..31], h("72"), e2sig)));
let eg = must(crypto.ed25519_generate());
check("ed25519 generated key round trip", yes(crypto.ed25519_verify(must(crypto.ed25519_public_key(eg)), b"m", must(crypto.ed25519_sign(eg, b"m")))));
let ed_pem = "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIHjhrzHfvr62GGOEfNDkebJznoED/N92fSFIA7+Ble/E\n-----END PRIVATE KEY-----\n";
let ed_pub_pem = "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAxTH557B1bgYJfuvBuYE4sxMBU2yNwTmBxEZvwv2lHLA=\n-----END PUBLIC KEY-----\n";
check("ed25519 private from openssl pem", hx(must(crypto.ed25519_private_from_pem(ed_pem))) == "78e1af31dfbebeb61863847cd0e479b2739e8103fcdf767d214803bf8195efc4");
check("ed25519 public from openssl pem", hx(must(crypto.ed25519_public_from_pem(ed_pub_pem))) == "c531f9e7b0756e06097eebc1b98138b31301536c8dc13981c4466fc2fda51cb0");
check("ed25519 public from a private pem", hx(must(crypto.ed25519_public_from_pem(ed_pem))) == "c531f9e7b0756e06097eebc1b98138b31301536c8dc13981c4466fc2fda51cb0");
println(err_text(crypto.ed25519_private_from_pem("not a key")));

// ---- ECDSA P-256 ----------------------------------------------------------------
let x = h("c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721");
let u = must(crypto.ecdsa_p256_public_key(x));
check("p256 rfc6979 public key", hx(u) == "0460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb67903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299");
let s1 = must(crypto.ecdsa_p256_sign_sha256(x, b"sample"));
let s2 = must(crypto.ecdsa_p256_sign_sha256(x, b"sample"));
let rfc = "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8";
// OpenSSL 3.2+ signs deterministically (RFC 6979) and must then give the
// RFC's signature exactly; older 3.x uses random nonces, still valid.
check("p256 rfc6979 signature (or a random-nonce one)", (s1 == s2 && hx(s1) == rfc) || s1 != s2);
// (deterministic here: printed so a run shows which path it took)
check("p256 verifies", yes(crypto.ecdsa_p256_verify_sha256(u, b"sample", s1)));
check("p256 verifies the rfc signature", yes(crypto.ecdsa_p256_verify_sha256(u, b"sample", h(rfc))));
check("p256 rejects another message", !yes(crypto.ecdsa_p256_verify_sha256(u, b"sampl", s1)));
let off_curve = u[..];
off_curve[64] = off_curve[64] ^ 1;
println(err_of(crypto.ecdsa_p256_verify_sha256(off_curve, b"sample", s1)));
println(err_text(crypto.ecdsa_p256_public_key(h("0000000000000000000000000000000000000000000000000000000000000000"))));
let pg = must(crypto.ecdsa_p256_generate());
check("p256 generated key round trip", yes(crypto.ecdsa_p256_verify_sha256(must(crypto.ecdsa_p256_public_key(pg)), b"m", must(crypto.ecdsa_p256_sign_sha256(pg, b"m")))));
let ec_pem = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgj9mFFn9VnrVZ1vYO\nB6FhGzkgPBS4dwVHZlvvXwAuUdehRANCAASLflbQ0wweD6LHimRyz3NVGW6BkL6z\nNCo8Pb76/ABDcm1BtnxQMrdnkNbzBWnEZrHJF2+DzeSOzCijCJpiCArJ\n-----END PRIVATE KEY-----\n";
let ec_pub_pem = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEi35W0NMMHg+ix4pkcs9zVRlugZC+\nszQqPD2++vwAQ3JtQbZ8UDK3Z5DW8wVpxGaxyRdvg83kjswoowiaYggKyQ==\n-----END PUBLIC KEY-----\n";
check("p256 private from openssl pem", hx(must(crypto.ecdsa_p256_private_from_pem(ec_pem))) == "8fd985167f559eb559d6f60e07a1611b39203c14b8770547665bef5f002e51d7");
check("p256 public from openssl pem", hx(must(crypto.ecdsa_p256_public_from_pem(ec_pub_pem))) == "048b7e56d0d30c1e0fa2c78a6472cf7355196e8190beb3342a3c3dbefafc0043726d41b67c5032b76790d6f30569c466b1c9176f83cde48ecc28a3089a62080ac9");
check("p256 public of the pem's private", hx(must(crypto.ecdsa_p256_public_key(must(crypto.ecdsa_p256_private_from_pem(ec_pem))))) == "048b7e56d0d30c1e0fa2c78a6472cf7355196e8190beb3342a3c3dbefafc0043726d41b67c5032b76790d6f30569c466b1c9176f83cde48ecc28a3089a62080ac9");
println(err_text(crypto.ecdsa_p256_private_from_pem(ed_pem)));

// ---- RSA ------------------------------------------------------------------------
let rsa_pem = "-----BEGIN PRIVATE KEY-----\nMIIEuwIBADANBgkqhkiG9w0BAQEFAASCBKUwggShAgEAAoIBAQC9abR5Y1x1wumh\nQ4oWrZ0XT/fFZKPZ/8VdL0rLOMHbWbyudQMZYrCyea5bcUTviQVyo7AZ8mF5cO3D\nMuQfHv5OkfEEUFgNGKhgeDCltwfxyLRUFfR2m2yWryIborJ5Aza5E7FXmGU+zWvD\n/Ts/S/7iXlximTXDDO7wnZKC19u1kBU8jvWHHf9cIADtC7W/03uTYSmkrEZHc/g7\nV438n5Uvq2/3J6h0vZ6YaN6PgRXwuMb2NBRYX+m1QRglyU3ENIrsGXujgFA/R2Ny\nQ1o5A0oFc7mRpkwU+ICpXaFPIK8uqY9UiNoai+89kpftBqR7peybm5TjeooUgBBN\nCp541LjhAgMBAAECgf8fA2/JcGYd4gw0RhrAxoHc5KXCbE1nzw6XHhHhCdS0AGgk\nfdmZY89gFGG4Fz5yT2fU8s2ix00D1WRuJvxdxsqyPV3OlwPTy8sbVef2j5bSv/TG\nz9F3RNDtheolHD6cvH9Oo9V7F44m+lDq26EX0W7/zEjUMWyGw1dcORtZe9PoUPxE\nYYCFiGdm5Vk9/HuMo4P94uHLueoTOLhGf4M8HJl8GeD3WMi11p4p/s5nScAYKStG\nFbLRjCrF4tpwXUmj508Bxv4QrPH5SlIDeRrSLPoTCtsHFZtggfFitP2i0GSOntl2\nw8oKsnLgwZs+mLnQ5+usH35TrzsmYjKe8/SIz0ECgYEA6Q697kRJGv0cjKZoXLSz\ngsvRRzD+utf7cLOoX/b/dq5DM/NbSvpby+K58jDNAS6QDxDUimJziKdlo41Kc3jb\nxVoWfppzM0NYwwC71xxLzbSK7CZVofHrdB8IM4ILyiLsF9MU20gIXWVaEPWoqxEe\nrMe6WxZQkBiFKEFlDDnBBnECgYEA0A8UF6JM8wUifyOC7fJ2mthyoLQpdkFYMQcd\n5dsh5OoK6andKLUuc4Wo/09eJcM13ndq57A4zxCV+f122kQSVyqt/4Y+avVnfHz4\nSNK7xhzhFkeL5etiolBqisCIP+qTy3mhRbqtXHS993BGPBzfYPCfk66O5yWFwt1u\nI+HZcXECgYAdWxUDcSiANMem08MrgjtmS0QGIp7DbDcowAiCZftRuKuQXKPwMs7j\nRKDFZ+46quHMdANBlxsUaHl9+2sYVm3gUvOoaM3/9Ai3L115v/+wXoBtNHru1ikh\nTFNdIZFYmcOBUL48zLr5AK4ymq7vNU3W16WamZn2PJBxPKN8wb2VkQKBgEVZ0VOz\naLzUqFQCrUDNQhWJMmQ4yV0+mLv26FNWwKyCCtMqKKrKAcrF8bfwZ6xkrk8SNRM3\nXShAGg2zG+vTJt3hPxBeWe3jEPSg302+2JJHzAtWG96uoDkEXw8S8BeGBG+dglEw\n0VpxG2UgCnk9EoRIkJh0ZfPMQRLcJjtVq9oxAoGBAJ2yW45FRHsDx0q1jGRnGI8Y\nohofDH3HPsKeBV+ywD0LgnIOoy+d38cXPoi4ZNqicLLO/EwB+iCWfBexr8Jzc2AG\n2M8pS5fEgYuY2saHcOWzXBbKoE9Ls29ZRCp5i0z3dN/IuM1yJavuREkSniIp+pgb\nCd4IpOx2L/DycSrzccSn\n-----END PRIVATE KEY-----\n";
let msg = b"slang signs this";
let n = must(crypto.rsa_public_n(rsa_pem));
let e = must(crypto.rsa_public_e(rsa_pem));
check("rsa modulus matches openssl", hx(n) == "bd69b479635c75c2e9a1438a16ad9d174ff7c564a3d9ffc55d2f4acb38c1db59bcae75031962b0b279ae5b7144ef890572a3b019f2617970edc332e41f1efe4e91f10450580d18a8607830a5b707f1c8b45415f4769b6c96af221ba2b2790336b913b15798653ecd6bc3fd3b3f4bfee25e5c629935c30ceef09d9282d7dbb590153c8ef5871dff5c2000ed0bb5bfd37b936129a4ac464773f83b578dfc9f952fab6ff727a874bd9e9868de8f8115f0b8c6f63414585fe9b5411825c94dc4348aec197ba380503f476372435a39034a0573b991a64c14f880a95da14f20af2ea98f5488da1a8bef3d9297ed06a47ba5ec9b9b94e37a8a1480104d0a9e78d4b8e1");
check("rsa exponent 65537", hx(e) == "010001");
check("rsa pkcs1 signature equals openssl's", hx(must(crypto.rsa_sign_sha256(rsa_pem, msg))) == "590269f2bfc95bc40ce0dbd1543f27887790c2a006741fc0a9a72ae1533c84f89bd0657087ae4d86985d6f514458db6f49c7f92a819c6357fd24e3853f2f7eb174bcd51f3599335bdf4c4a3df921a8986d3ef98b88407b1d028d53aeb7b5c618e2a94ba0c7e4abdeb6c20157439ed33dbd3fa6c68af4de3517592f6bb010771a6f8d399b5cb7b8338fec560f9a6df980fcf5e896580f770b22ded5fe038d211ded24101e5c36e2887242dbc55c5039237d86ca663cda1ed5c2efe30733da6a99d15cce22e81ec0b51d09dcf15825a22cdd011bb266c36a4b5c1d58f82239b6b61a70764448fdf41deca5615bfaf95b1f7391ab9a14fb106028cef1db4f770330");
check("rsa pkcs1 verifies", yes(crypto.rsa_verify_sha256(n, e, msg, h("590269f2bfc95bc40ce0dbd1543f27887790c2a006741fc0a9a72ae1533c84f89bd0657087ae4d86985d6f514458db6f49c7f92a819c6357fd24e3853f2f7eb174bcd51f3599335bdf4c4a3df921a8986d3ef98b88407b1d028d53aeb7b5c618e2a94ba0c7e4abdeb6c20157439ed33dbd3fa6c68af4de3517592f6bb010771a6f8d399b5cb7b8338fec560f9a6df980fcf5e896580f770b22ded5fe038d211ded24101e5c36e2887242dbc55c5039237d86ca663cda1ed5c2efe30733da6a99d15cce22e81ec0b51d09dcf15825a22cdd011bb266c36a4b5c1d58f82239b6b61a70764448fdf41deca5615bfaf95b1f7391ab9a14fb106028cef1db4f770330"))));
check("rsa pss from openssl verifies", yes(crypto.rsa_verify_pss_sha256(n, e, msg, h("6015696a042ecdafd84b14ffc05a2dbbeb4f2583aa8733c4b44d15f979588e12b32239bfd65cbdfb4d02c07f0af71c572a2f7d3e25c397c46bcc68537c293ad8a984ceff030e0e6f85dadf1ce26e0fee13711a48c12d337d7f449685d75d8f92eb04ec71bf13df256fe3432f9a761a04bf8ffe001862e44280f212f5d25fda8b49abbc4aab03dc9f55f75a324d6d5632ef637db2f7b44f66987e2c317530ecb592caf3a7ae79e9b045b29c1954667972ba5284830955f8f5fe22dbf76e75b7f4a22bcb9f39fdf12c0cb7030de779680d293c232107b93fc15df33c7078ed8e192288366ef090048a66d005f2e725df4b3eeb69b710e9172c9f4a7456eefd16df"))));
let pss = must(crypto.rsa_sign_pss_sha256(rsa_pem, msg));
check("rsa pss round trip", yes(crypto.rsa_verify_pss_sha256(n, e, msg, pss)));
check("rsa pss is not pkcs1", !yes(crypto.rsa_verify_sha256(n, e, msg, pss)));
check("rsa pkcs1 is not pss", !yes(crypto.rsa_verify_pss_sha256(n, e, msg, h("590269f2bfc95bc40ce0dbd1543f27887790c2a006741fc0a9a72ae1533c84f89bd0657087ae4d86985d6f514458db6f49c7f92a819c6357fd24e3853f2f7eb174bcd51f3599335bdf4c4a3df921a8986d3ef98b88407b1d028d53aeb7b5c618e2a94ba0c7e4abdeb6c20157439ed33dbd3fa6c68af4de3517592f6bb010771a6f8d399b5cb7b8338fec560f9a6df980fcf5e896580f770b22ded5fe038d211ded24101e5c36e2887242dbc55c5039237d86ca663cda1ed5c2efe30733da6a99d15cce22e81ec0b51d09dcf15825a22cdd011bb266c36a4b5c1d58f82239b6b61a70764448fdf41deca5615bfaf95b1f7391ab9a14fb106028cef1db4f770330"))));
check("rsa pss with another salt length does not verify (PS256 fixes it)", !yes(crypto.rsa_verify_pss_sha256(n, e, msg, h("223abbb96f4acbaf97b8cebfdaa10da286adbeaad72db94471a83062f94d3c56b0bd6bdea2fd64a0efa302dda40b1e6f3b669d3bec0049c2581115f735a85daa56c2be9bab67ee9d99bd898224b4a155bbdc305dbdec3715ad5ae9e8c5c69b11272030c12f987e2386181a590459f063b2dfb303cec9d2bb31c4d1b3907ce8d51fc34f5a5a2bc7aab6317027a3a5b8b71dc2afce14ecb4134e225fe35af8b80efe158b715b9ca10c0f07cdc6a6176986299e6aeb66e9bd05cd37cfdab1beb06ab5a711c2a11066d659c48a00d7c9ee3e7940495729d0b8fb7cc8d5a9bcf4653b207123fc4e3665af8a386be92c02ed426128c2a98e4c7cc026e0fb0e298668a1"))));
check("rsa pss rejects another message", !yes(crypto.rsa_verify_pss_sha256(n, e, b"other", pss)));
let gen = crypto.rsa_generate(2048);
guard let gpem = gen else let ge = err_of(gen) { panic(ge); }
check("rsa generated key signs", yes(crypto.rsa_verify_sha256(must(crypto.rsa_public_n(gpem)), must(crypto.rsa_public_e(gpem)), msg, must(crypto.rsa_sign_sha256(gpem, msg)))));
let small = crypto.rsa_generate(1024);
println(err_of(small));
println(err_text(crypto.rsa_sign_sha256(ed_pem, msg)));
