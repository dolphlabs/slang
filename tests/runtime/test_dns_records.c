#include "../../runtime/sl_dns.c"

#include <assert.h>
#include <stdio.h>

static void put16(unsigned char *p, unsigned value) {
    p[0] = (unsigned char)(value >> 8);
    p[1] = (unsigned char)value;
}

static size_t put_name(unsigned char *p, const char *name) {
    const char *label = name;
    size_t n = 0;
    while (*label) {
        const char *dot = strchr(label, '.');
        size_t len = dot ? (size_t)(dot - label) : strlen(label);
        assert(len > 0 && len <= 63);
        p[n++] = (unsigned char)len;
        memcpy(p + n, label, len);
        n += len;
        if (!dot) break;
        label = dot + 1;
    }
    p[n++] = 0;
    return n;
}

static size_t begin_packet(unsigned char *p, unsigned qtype) {
    memset(p, 0, 512);
    put16(p, 0x1234);
    put16(p + 2, 0x8180);
    put16(p + 4, 1);
    put16(p + 6, 1);
    size_t n = 12;
    n += put_name(p + n, "_mongodb._tcp.example.com");
    put16(p + n, qtype);
    put16(p + n + 2, ns_c_in);
    return n + 4;
}

static size_t begin_answer(unsigned char *p, size_t n, unsigned type,
                           size_t rdlen) {
    p[n++] = 0xc0;
    p[n++] = 0x0c;
    put16(p + n, type);
    put16(p + n + 2, ns_c_in);
    memset(p + n + 4, 0, 4); /* TTL */
    put16(p + n + 8, (unsigned)rdlen);
    return n + 10;
}

static size_t begin_answer_named(unsigned char *p, size_t n, unsigned type,
                                 size_t rdlen, const char *owner) {
    n += put_name(p + n, owner);
    put16(p + n, type);
    put16(p + n + 2, ns_c_in);
    memset(p + n + 4, 0, 4);
    put16(p + n + 8, (unsigned)rdlen);
    return n + 10;
}

static void test_srv(void) {
    unsigned char packet[512];
    size_t n = begin_packet(packet, ns_t_srv);
    const char *target = "cluster1.example.net";
    size_t target_wire = 1 + 8 + 1 + 7 + 1 + 3 + 1;
    size_t rdlen = 6 + target_wire;
    n = begin_answer(packet, n, ns_t_srv, rdlen);
    put16(packet + n, 10);      /* priority */
    put16(packet + n + 2, 5);   /* weight */
    put16(packet + n + 4, 27017);
    size_t written = put_name(packet + n + 6, target);
    assert(written == target_wire);
    n += rdlen;

    sl_dns_srv_record records[2];
    size_t count = 0;
    const char *error = NULL;
    assert(sl_dns_parse_srv_packet(packet, n, "_mongodb._tcp.example.com",
                                   records, 2, &count, &error));
    assert(count == 1);
    assert(strcmp(records[0].target, "cluster1.example.net") == 0);
    assert(records[0].priority == 10);
    assert(records[0].weight == 5);
    assert(records[0].port == 27017);

    n = begin_packet(packet, ns_t_srv);
    n = begin_answer(packet, n, ns_t_srv, 7);
    put16(packet + n, 0);
    put16(packet + n + 2, 0);
    put16(packet + n + 4, 0);
    packet[n + 6] = 0;
    n += 7;
    assert(sl_dns_parse_srv_packet(packet, n, "_mongodb._tcp.example.com",
                                   records, 2, &count, &error));
    assert(count == 1 && strcmp(records[0].target, ".") == 0);
}

static void test_txt_chunks(void) {
    unsigned char packet[512];
    size_t n = begin_packet(packet, ns_t_txt);
    static const char first[] = "authSource=";
    static const char second[] = "admin";
    size_t rdlen = 1 + sizeof(first) - 1 + 1 + sizeof(second) - 1;
    n = begin_answer(packet, n, ns_t_txt, rdlen);
    size_t at = n;
    packet[at++] = (unsigned char)(sizeof(first) - 1);
    memcpy(packet + at, first, sizeof(first) - 1);
    at += sizeof(first) - 1;
    packet[at++] = (unsigned char)(sizeof(second) - 1);
    memcpy(packet + at, second, sizeof(second) - 1);
    n += rdlen;

    sl_dns_txt_record records[2];
    char storage[128];
    size_t count = 0;
    const char *error = NULL;
    assert(sl_dns_parse_txt_packet(packet, n, "_mongodb._tcp.example.com",
                                   records, 2, storage,
                                   sizeof(storage), &count, &error));
    assert(count == 1);
    assert(records[0].len == 16);
    assert(strcmp(records[0].value, "authSource=admin") == 0);
}

static void test_rejects_bad_packets_and_names(void) {
    unsigned char packet[512];
    size_t n = begin_packet(packet, ns_t_srv);
    const char *error = NULL;
    sl_dns_srv_record srvs[1];
    sl_dns_txt_record txts[1];
    char storage[32];
    size_t count = 0;
    assert(!sl_dns_parse_srv_packet(packet, 8,
                                    "_mongodb._tcp.example.com",
                                    srvs, 1, &count, &error));
    assert(error && strcmp(error, "malformed DNS response") == 0);
    packet[2] |= 0x02; /* TC */
    put16(packet + 6, 0); /* no answers in this valid truncated response */
    assert(!sl_dns_parse_txt_packet(packet, n, "_mongodb._tcp.example.com",
                                    txts, 1, storage,
                                    sizeof(storage), &count, &error));
    assert(error && strcmp(error, "DNS response is truncated") == 0);
    assert(!sl_dns_name_valid("a..example.com", 1));
    assert(!sl_dns_name_valid("-bad.example.com", 0));
    assert(sl_dns_name_valid("_mongodb._tcp.example.com.", 1));
    assert(sl_dns_host_name_valid("node-1.example.com."));
    assert(!sl_dns_host_name_valid("node_1.example.com"));

    n = begin_packet(packet, ns_t_srv);
    static const char target[] = "node.example.com";
    size_t target_wire = 1 + 4 + 1 + 7 + 1 + 3 + 1;
    size_t rdlen = 6 + target_wire;
    n = begin_answer_named(packet, n, ns_t_srv, rdlen,
                           "other.example.com");
    put16(packet + n, 0);
    put16(packet + n + 2, 0);
    put16(packet + n + 4, 27017);
    assert(put_name(packet + n + 6, target) == target_wire);
    n += rdlen;
    assert(!sl_dns_parse_srv_packet(packet, n,
                                    "_mongodb._tcp.example.com",
                                    srvs, 1, &count, &error));
    assert(error && strcmp(error, "DNS SRV answer owner does not match the query") == 0);

    n = begin_packet(packet, ns_t_txt);
    put16(packet + 6, 0);
    packet[13] = 'x'; /* response question no longer matches the request */
    assert(!sl_dns_parse_txt_packet(packet, n,
                                    "_mongodb._tcp.example.com",
                                    txts, 1, storage, sizeof(storage),
                                    &count, &error));
    assert(error && strcmp(error, "DNS response question does not match the query") == 0);
}

int main(void) {
    test_srv();
    test_txt_chunks();
    test_rejects_bad_packets_and_names();
    puts("DNS SRV/TXT parser ok");
    return 0;
}
