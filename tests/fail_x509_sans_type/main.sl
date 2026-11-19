// x509_csr takes its names as a [str] of "DNS:" and "IP:" entries
import "crypto";
println(crypto.x509_csr("key", "cn", "DNS:a.test") ?? "");
