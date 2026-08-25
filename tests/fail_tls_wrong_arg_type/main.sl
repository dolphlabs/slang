// a TLS connection handle is a rawptr, not a raw socket fd
import "net";
net.tls_send(5, b"data");
