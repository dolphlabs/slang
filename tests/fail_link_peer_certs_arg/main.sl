// link.peer_certs() reads the TLS peer's chain; it takes nothing
fn f(c: link) -> bytes {
    return c.peer_certs(1);
}
println("unreachable");
