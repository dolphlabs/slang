// verify takes the chain as parsed certificates, not PEM text
import "x509";
let r = x509.verify("-----BEGIN CERTIFICATE-----", x509.Verify { roots_pem: "", host: "", at: 0, purpose: "" });
println(r ?? false);
