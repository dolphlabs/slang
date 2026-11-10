// Unit tests: `slangc test stdlib/mysql`. The client against MySQL 8.4 and
// MariaDB 11 is tests/live/mysqldb.

import "encoding";
import "strings";

fn cfg_of(url: str) -> Config {
    let r = parse_url(url);
    guard let c = r else let e = err_of(r) { panic(e); }
    return c;
}

fn test_should_parse_urls() {
    let c = cfg_of("mysql://app:p%40ss@db.example:3307/shop?sslrootcert=/ca.pem&statement_cache=8");
    assert(c.user == "app" && c.password == "p@ss" && c.host == "db.example" && c.port == 3307 && c.database == "shop",
           "fields");
    assert(c.sslmode == "require" && c.ca_path == "/ca.pem" && c.statement_cache == 8, "options");
    assert(cfg_of("mysql://u@127.0.0.1/db").sslmode == "disable", "loopback defaults to cleartext");
    assert(cfg_of("mysql://u@localhost/db").port == 3306, "default port");
    let unix = cfg_of("mysql://u@%2Fvar%2Frun%2Fmysqld%2Fmysqld.sock/db");
    assert(unix.host == "/var/run/mysqld/mysqld.sock" && unix.sslmode == "disable", "a Unix socket");
    assert(cfg_of("mariadb://u@[::1]:3310/db").host == "::1", "IPv6");
    assert(cfg_of("mysql://u@h/d?sslmode=VERIFY_IDENTITY").sslmode == "require", "mysql's spelling");
    assert(cfg_of("mysql://u@h/d?allow_public_key_retrieval=true").allow_public_key_retrieval, "pubkey");
    let bad = ["postgres://u@h/d", "mysql://h/d", "mysql://u@h/d?sslmdoe=require", "mysql://u@h/d?sslmode=prefer",
               "mysql://u@h:0/d", "mysql://u@h/d?time_zone=x'y", "mysql://u@%2Fs.sock/d?sslmode=require"];
    for u in bad {
        let r = parse_url(u);
        guard let _c = r else let e = err_of(r) {
            assert(strings.has_prefix(e, "mysql: "), e);
            continue;
        }
        panic("accepted " + u);
    }
}

fn nonce() -> bytes {
    let b = strings.bytes_zero(20);
    for k in 0..20 {
        b[k] = k + 1;
    }
    return b;
}

fn test_should_scramble_passwords_as_the_server_expects() {
    // reference values from Python's hashlib, following each plugin's definition
    assert(encoding.hex_encode(native_password_scramble("secret", nonce())) == "b32bb3a583e1340c0a1108d58b1be49781ad8c2f",
           "mysql_native_password");
    assert(encoding.hex_encode(sha2_password_scramble("secret", nonce())) ==
           "746ebe205d56a0707acb3e796e834e0dd7b1d61743b26bd5202c7a623230c7c9", "caching_sha2_password");
    assert(len(native_password_scramble("", nonce())) == 0 && len(sha2_password_scramble("", nonce())) == 0, "empty");
}

fn test_should_encode_length_encoded_integers() {
    assert(encoding.hex_encode(lenenc(0)) == "00" && encoding.hex_encode(lenenc(250)) == "fa", "one byte");
    assert(encoding.hex_encode(lenenc(251)) == "fcfb00" && encoding.hex_encode(lenenc(65535)) == "fcffff", "two");
    assert(encoding.hex_encode(lenenc(65536)) == "fd000001", "three");
    assert(encoding.hex_encode(lenenc(16777216)) == "fe0000000100000000", "eight");
    let b = cat([lenenc(300), lenenc(70000), b"\xfb", lenenc(16777216)]);
    let p = cur_of(b, 0, len(b));
    assert(get_lenenc(p) == 300 && get_lenenc(p) == 70000 && get_lenenc(p) == -1 && get_lenenc(p) == 16777216 && !p.bad,
           "round trip");
    let short = cur_of(b"\xfd\x01", 0, 2);
    get_lenenc(short);
    assert(short.bad, "a truncated integer is caught");
}

fn test_should_read_error_codes() {
    let e = "mysql: ERROR 1062 (23000): Duplicate entry '1' for key 'PRIMARY'";
    assert(sqlstate(e) == "23000" && error_code(e) == 1062, "both");
    assert(sqlstate("mysql: ERROR 2013: Lost connection") == "" && error_code("mysql: ERROR 2013: Lost connection") == 2013,
           "no state");
    assert(sqlstate("timeout") == "" && error_code("timeout") == 0, "not a server error");
}

fn test_should_map_column_types_for_rows_as() {
    assert(mysql_code(T_TINY, 0, 63, 1) == -16, "tinyint(1) is a bool");
    assert(mysql_code(T_TINY, 0, 63, 4) == 21, "tinyint");
    assert(mysql_code(T_LONG, FLAG_UNSIGNED, 63, 10) == 20, "unsigned int widens");
    assert(mysql_code(T_LONGLONG, 0, 63, 20) == 20 && mysql_code(T_NEWDECIMAL, 0, 63, 10) == 1700, "bigint, decimal");
    assert(mysql_code(T_BLOB, 0, 63, 65535) == -17 && mysql_code(T_BLOB, 0, 45, 65535) == 25, "blob vs text");
    assert(mysql_code(T_DATETIME, 0, 63, 26) == 1114 && mysql_code(T_JSON, 0, 63, 0) == 114, "datetime, json");
}

fn test_should_convert_binary_floats_and_fractions() {
    assert(float32_of(1069547520) == 1.5, "1.5");
    assert(float32_text(float32_of(1036831949)) == "0.1", float32_text(float32_of(1036831949)));
    assert(float32_text(float32_of(2945019999)) == "-2.5e-10", float32_text(float32_of(2945019999)));
    assert(float32_of(8388608) == 1.1754943508222875e-38, "smallest normal");
    assert(float32_text(float32_of(2139095039)) == "3.4028235e+38", float32_text(float32_of(2139095039)));
    assert(fraction(123456, 6) == ".123456" && fraction(500000, 3) == ".500" && fraction(0, 2) == ".00" &&
           fraction(7, 0) == "", "fsp");
}

fn test_should_build_execute_packets() {
    let st = Stmt { id: 7, params: 3, columns: [], types: [], raw_types: [], used: 0 };
    let p = execute_packet(st, [arg_int(1), arg_null(), arg_text("hé")]);
    // 17 | id 07000000 | flags 00 | iterations 01000000 | null bitmap 02 | bound 01 |
    // types 0800 0600 fd00 | 0100000000000000 | 03 68c3a9
    assert(encoding.hex_encode(p) == "1707000000000100000002010800" + "0600fd00" + "0100000000000000" + "0368c3a9",
           encoding.hex_encode(p));
}
