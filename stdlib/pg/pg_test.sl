// Unit tests: `slangc test stdlib/pg`. The protocol against a server is
// tested in tests/postgres (a scripted fake server) and tests/live/postgres (a real
// one).

fn cfg_of(url: str) -> Config {
    let r = parse_url(url);
    guard let c = r else let e = err_of(r) {
        panic("parse_url(" + url + "): " + e);
    }
    return c;
}

fn url_error(url: str) -> str {
    let r = parse_url(url);
    guard let c = r else let e = err_of(r) {
        return e;
    }
    panic("parse_url(" + url + ") should have failed");
}

// RFC 7677 section 3, the published SCRAM-SHA-256 exchange.
fn test_scram_rfc7677_vector() {
    let r = scram_client_final("pencil", "n=user,r=rOprNGfwEbeRWgbNEkqO",
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        "rOprNGfwEbeRWgbNEkqO");
    guard let x = r else let e = err_of(r) {
        panic(e);
    }
    assert(x.client_final == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
           "client final: " + x.client_final);
    assert(x.server_signature == "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=",
           "server signature: " + x.server_signature);
}

fn scram_error(server_first: str) -> str {
    let r = scram_client_final("pencil", "n=,r=abc", server_first, "abc");
    guard let x = r else let e = err_of(r) {
        return e;
    }
    panic("scram should have failed for " + server_first);
}

fn test_scram_refuses_bad_server_first() {
    // a nonce that does not extend ours is some other exchange's
    assert(strings.contains(scram_error("r=xyzdef,s=QUJD,i=4096"), "does not extend"));
    // the same nonce, not extended
    assert(strings.contains(scram_error("r=abc,s=QUJD,i=4096"), "does not extend"));
    assert(strings.contains(scram_error("r=abcdef,s=QUJD,i=0"), "iterations"));
    // a server may not pin a worker for as long as it likes
    assert(strings.contains(scram_error("r=abcdef,s=QUJD,i=1000001"), "limit"));
    assert(strings.contains(scram_error("r=abcdef,s=QUJD,i=x"), "iteration count"));
    assert(strings.contains(scram_error("r=abcdef,s=!!,i=4096"), "salt"));
    assert(strings.contains(scram_error("m=ext,r=abcdef,s=QUJD,i=4096"), "extension"));
}

fn test_parse_url_full() {
    let c = cfg_of("postgres://al%40ice:p%3Aw%40d@db.example.com:6543/app%20db?sslmode=require&application_name=api");
    assert(c.user == "al@ice", c.user);
    assert(c.password == "p:w@d", c.password);
    assert(c.host == "db.example.com", c.host);
    assert(c.port == 6543);
    assert(c.database == "app db", c.database);
    assert(c.sslmode == "require");
    assert(c.application_name == "api");
}

fn test_parse_url_defaults() {
    let c = cfg_of("postgresql://bob@db.internal");
    assert(c.port == 5432);
    assert(c.database == "bob", "database defaults to the user");
    assert(c.password == "");
    // off the machine, TLS unless asked otherwise
    assert(c.sslmode == "require", c.sslmode);
    assert(cfg_of("postgres://bob@localhost/x").sslmode == "disable");
    assert(cfg_of("postgres://bob@127.0.0.1/x").sslmode == "disable");
    assert(cfg_of("postgres://bob@[::1]:5433/x").sslmode == "disable");
    assert(cfg_of("postgres://bob@[::1]:5433/x").port == 5433);
    assert(cfg_of("postgres://bob@localhost/x?sslmode=verify-full").sslmode == "require");
    assert(cfg_of("postgres://bob@db/x?sslmode=disable").sslmode == "disable");
    assert(cfg_of("postgres://bob@db/x?sslrootcert=/etc/ca.pem").ca_path == "/etc/ca.pem");
}

fn test_parse_url_refusals() {
    assert(strings.contains(url_error("mysql://bob@db/x"), "must begin"));
    assert(strings.contains(url_error("postgres://db/x"), "no user"));
    assert(strings.contains(url_error("postgres://bob@/x"), "no host"));
    assert(strings.contains(url_error("postgres://bob@db:0/x"), "port"));
    assert(strings.contains(url_error("postgres://bob@db:99999/x"), "port"));
    assert(strings.contains(url_error("postgres://bob@db:abc/x"), "port"));
    assert(strings.contains(url_error("postgres://bob@a,b/x"), "multiple hosts"));
    // silently cleartext is never the answer to a typo or a fallback
    assert(strings.contains(url_error("postgres://bob@db/x?sslmdoe=require"), "unsupported url parameter: sslmdoe"));
    assert(strings.contains(url_error("postgres://bob@db/x?sslmode=prefer"), "cleartext"));
    assert(strings.contains(url_error("postgres://bob@db/x?sslmode=allow"), "cleartext"));
    assert(strings.contains(url_error("postgres://bob@db/x?sslmode=verify-ca"), "hostname"));
    assert(strings.contains(url_error("postgres://bob@db/x?sslmode=on"), "unknown sslmode"));
}

fn test_sqlstate() {
    assert(sqlstate("ERROR: duplicate key value violates unique constraint \"t_pkey\" (SQLSTATE 23505)") == "23505");
    // the server's message may itself mention a SQLSTATE; ours is last
    assert(sqlstate("ERROR: saw (SQLSTATE 00000) in a log (SQLSTATE 42P01)") == "42P01");
    assert(sqlstate("timeout") == "");
    assert(sqlstate("dial db: Connection refused") == "");
}

fn test_tag_count() {
    assert(tag_count("INSERT 0 3") == 3);
    assert(tag_count("UPDATE 12") == 12);
    assert(tag_count("SELECT 0") == 0);
    assert(tag_count("CREATE TABLE") == 0);
    assert(tag_count("BEGIN") == 0);
}

fn test_args_encode() {
    assert(to_str(arg_int(-9223372036854775807).data) == "-9223372036854775807");
    assert(to_str(arg_float(0.1 + 0.2).data) == "0.30000000000000004");
    assert(to_str(arg_bool(true).data) == "true");
    assert(arg_bytes(b"\x00\x01").binary);
    assert(arg_null().is_null);
}

fn test_startup_message() {
    let c = cfg_of("postgres://u@localhost/d?application_name=a");
    let m = startup_message(c);
    assert(rd32(m, 0) == len(m), "length counts the whole message");
    assert(rd32(m, 4) == 196608, "protocol 3.0");
    assert(m[len(m) - 1] == 0 && m[len(m) - 2] == 0, "double NUL terminator");
}
