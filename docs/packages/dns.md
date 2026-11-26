# dns

> Package dns.

A DNS client over the wire: A, AAAA, CNAME, MX, TXT, SRV, NS and PTR
lookups, with `/etc/resolv.conf`, `/etc/hosts`, search domains, a TTL
cache and a deadline on every call.

```slang
import "dns";

let r = dns.system_resolver();                     // resolv.conf + hosts, read once
let ips = dns.lookup_ip(r, "api.example.com", deadline);   // IPv4 first, then IPv6
let mx = dns.lookup_mx(r, "example.com", deadline);        // by preference
let srv = dns.lookup_srv(r, "_imap._tcp.example.com", deadline);
guard let found = ips else |e| {
    if e == "no such host" { /* NXDOMAIN, after every search domain */ }
    return;
}
```

A lookup parks its task on the reactor and holds no thread, unlike
`net.dial`'s `getaddrinfo`, which runs on a resolver thread. A and AAAA
go out at once. Each try gets the configured per-try timeout or what is
left of the caller's deadline, whichever is sooner, so a silent server
costs one try and the next server answers.

- **Transport.** UDP with EDNS0 (1232-byte answers), and TCP when an answer
  comes back truncated.
- **Spoofing.** Each query has a random id and a fresh socket, so a random
  source port. A reply counts only if it comes from the server asked and
  carries the id and question that were sent; anything else is ignored.
- **Failures.** SERVFAIL, REFUSED and errors move on to the next server;
  `options rotate` spreads queries over them.
- **Cache.** Answers are kept for their TTL, at most `max_ttl` (an hour).
  NXDOMAIN and empty answers are kept for the zone's negative TTL (the
  SOA's, RFC 2308), and not at all without one. The cache holds at most
  `max_entries` (10,000).
- **Names.** Search domains and `ndots` work as in glibc. CNAME chains are
  followed, inside an answer or with a new query, up to 8 hops.
  `localhost` is the loopback addresses (RFC 6761), and an IP literal is
  itself.

`dns.exchange(server, name, type, deadline)` sends one query, and
`dns.encode` / `dns.decode` build and read messages, for a server or a
test's fake one. `parse_ip`, `format_ip` (RFC 5952) and `reverse_name`
handle addresses.

**Not done, deliberately:** no DNSSEC validation, no DNS over TLS or
HTTPS, no single-flight for identical lookups in flight, and `net.dial`
still resolves with `getaddrinfo`.

## API

### `let A = 1;`

Record types.

### `let NS = 2;`

### `let CNAME = 5;`

### `let SOA = 6;`

### `let PTR = 12;`

### `let MX = 15;`

### `let TXT = 16;`

### `let AAAA = 28;`

### `let SRV = 33;`

### `let NOERROR = 0;`

Response codes.

### `let FORMERR = 1;`

### `let SERVFAIL = 2;`

### `let NXDOMAIN = 3;`

### `let NOTIMP = 4;`

### `let REFUSED = 5;`

### `gc struct Record`

One resource record, decoded. `name` is lowercased with no final dot. `value` is the address (A, AAAA), the target name (CNAME, NS, PTR, MX, SRV, and SOA's primary server), or the text (TXT, its strings joined). `priority` is MX's preference or SRV's priority; `weight` and `port` are SRV's. A SOA's `ttl` is already its negative TTL: the lesser of the record's TTL and its MINIMUM field.

### `gc struct Question`

### `gc struct Message`

### `gc struct Server`

A name server: an IP literal and a port.

### `gc struct Config`

What /etc/resolv.conf says. timeout is per try, in nanoseconds; a lookup makes up to attempts passes over servers.

### `gc struct Hosts`

/etc/hosts: addresses by lowercased name, in file order.

### `gc struct Resolver`

### `fn parse_ip(s: str) -> result[bytes, str]`

An IP address in text: 4 bytes for IPv4, 16 for IPv6.

### `fn format_ip(b: bytes) -> str`

An address's canonical text: dotted IPv4, or RFC 5952 IPv6.

### `fn reverse_name(ip: str) -> result[str, str]`

The PTR name for an address: "4.3.2.1.in-addr.arpa" or the IPv6 nibbles under ip6.arpa.

### `fn encode_query(id: int, name: str, qtype: int) -> result[bytes, str]`

A query for `name`, recursion desired, with an EDNS0 OPT record asking for answers up to 1232 bytes over UDP.

### `fn encode(m: Message) -> result[bytes, str]`

A whole message, uncompressed: for a server, or a test's fake one.

### `fn decode(b: bytes) -> result[Message, str]`

A message from the wire. Records this package does not read (OPT, other classes, other types) are skipped.

### `fn exchange(s: Server, name: str, qtype: int, deadline: until) -> result[Message, str]`

One query to one server: over UDP, then over TCP when the answer came back truncated. Replies that are malformed, or answer some other query, are ignored and the wait goes on until `deadline`.

### `fn default_config() -> Config`

What a machine with no resolv.conf gets, as glibc and Go do: the local host on port 53, ndots 1, 5s per try, 2 attempts.

### `fn parse_resolv_conf(text: str) -> Config`

/etc/resolv.conf's text: nameserver, search, domain, and the options ndots, timeout, attempts and rotate (caps as glibc's: ndots 15, timeout 30s, attempts 5). A nameserver that is not an IP address is skipped; with none left, the local host is used.

### `fn system_config() -> Config`

/etc/resolv.conf, or default_config() when it cannot be read.

### `fn no_hosts() -> Hosts`

### `fn parse_hosts(text: str) -> Hosts`

A hosts file's text: an address, then its names. Lines whose address does not parse are skipped.

### `fn system_hosts() -> Hosts`

/etc/hosts, or no hosts when it cannot be read.

### `fn new_resolver(cfg: Config, hosts: Hosts) -> Resolver`

### `fn system_resolver() -> Resolver`

A resolver over /etc/resolv.conf and /etc/hosts, read once, now.

### `fn queries_sent(r: Resolver) -> int`

How many queries this resolver has sent: answers from the cache or hosts send none.

### `fn cache_len(r: Resolver) -> int`

### `fn cache_clear(r: Resolver)`

### `fn lookup(r: Resolver, name: str, qtype: int, deadline: until) -> result[[Record], str]`

The records of `qtype` for `name`, after search domains and CNAMEs. err("no such host") when no candidate name exists; ok([]) when one exists without records of this type.

### `fn lookup_ip(r: Resolver, host: str, deadline: until) -> result[[str], str]`

The addresses of `host`: IPv4 first, then IPv6. An IP literal is itself; then /etc/hosts; "localhost" and names under it are the loopback addresses (RFC 6761); anything else asks for A and AAAA at once. One family failing while the other answers is not an error.

### `fn lookup_cname(r: Resolver, name: str, deadline: until) -> result[str, str]`

The name `name` is an alias of, after every CNAME; `name` itself when it is not an alias.

### `fn lookup_mx(r: Resolver, name: str, deadline: until) -> result[[Record], str]`

Mail exchangers, by preference (lowest first). `value` is the host, `priority` its preference.

### `fn lookup_srv(r: Resolver, name: str, deadline: until) -> result[[Record], str]`

Service records for a full name such as "_imap._tcp.example.com", by priority (lowest first) and then weight (highest first). Choosing among one priority's records by weight, as RFC 2782 has a client do, is the caller's.

### `fn lookup_txt(r: Resolver, name: str, deadline: until) -> result[[str], str]`

Each TXT record's text, its strings joined.

### `fn lookup_ns(r: Resolver, name: str, deadline: until) -> result[[str], str]`

### `fn lookup_addr(r: Resolver, ip: str, deadline: until) -> result[[str], str]`

The names an address points back to (PTR records).

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
