/* DNS record parsing shared by net's optional SRV/TXT resolver and its
 * deterministic runtime tests. Resolver I/O stays on sl_net.c's resolver
 * thread; these routines only validate bounded response packets. */

#include <arpa/nameser.h>
#include <resolv.h>
#include <strings.h>

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define SL_DNS_MAX_PACKET 65535
#define SL_DNS_MAX_NAME 253
#define SL_DNS_MAX_SRV_RECORDS 256
#define SL_DNS_MAX_TXT_RECORDS 16
#define SL_DNS_MAX_TXT_RECORD_BYTES 8192
#define SL_DNS_MAX_TXT_BYTES 32768

typedef struct {
    char target[SL_DNS_MAX_NAME + 2];
    uint16_t priority;
    uint16_t weight;
    uint16_t port;
} sl_dns_srv_record;

typedef struct {
    const char *value;
    size_t len;
} sl_dns_txt_record;

/* Service query names may include the leading underscores in
 * _mongodb._tcp. Hostnames returned in SRV answers must not. A final dot is
 * accepted because DNS names are absolute on the wire. */
static int sl_dns_name_valid(const char *name, int allow_underscore) {
    if (!name) return 0;
    size_t n = 0;
    while (n < SL_DNS_MAX_NAME + 2 && name[n] != '\0') n++;
    if (n == SL_DNS_MAX_NAME + 2) return 0;
    if (n == 0) return 0;
    size_t end = name[n - 1] == '.' ? n - 1 : n;
    if (end == 0 || end > SL_DNS_MAX_NAME) return 0;
    size_t label = 0;
    unsigned char first = 0, last = 0;
    for (size_t i = 0; i < end; i++) {
        unsigned char c = (unsigned char)name[i];
        if (c == '.') {
            if (label == 0 || label > 63 || first == '-' || last == '-')
                return 0;
            label = 0;
            first = last = 0;
            continue;
        }
        int ascii_alnum = (c >= 'A' && c <= 'Z') ||
                          (c >= 'a' && c <= 'z') ||
                          (c >= '0' && c <= '9');
        if (!ascii_alnum && c != '-' && !(allow_underscore && c == '_'))
            return 0;
        if (label == 0) first = c;
        last = c;
        label++;
        if (label > 63) return 0;
    }
    return label != 0 && first != '-' && last != '-';
}

static int sl_dns_name_equal(const char *left, const char *right) {
    if (!left || !right) return 0;
    size_t left_len = strlen(left);
    size_t right_len = strlen(right);
    if (left_len && left[left_len - 1] == '.') left_len--;
    if (right_len && right[right_len - 1] == '.') right_len--;
    return left_len == right_len && strncasecmp(left, right, left_len) == 0;
}

static int sl_dns_response_init(const unsigned char *packet, size_t len,
                                const char *expected_name, int expected_type,
                                ns_msg *msg, const char **error) {
    if (!packet || len < 12 || len > SL_DNS_MAX_PACKET ||
        len > (size_t)INT32_MAX ||
        ns_initparse(packet, (int)len, msg) < 0) {
        *error = "malformed DNS response";
        return 0;
    }
    if (!ns_msg_getflag(*msg, ns_f_qr)) {
        *error = "DNS response has no response flag";
        return 0;
    }
    if (ns_msg_getflag(*msg, ns_f_tc)) {
        *error = "DNS response is truncated";
        return 0;
    }
    if (ns_msg_getflag(*msg, ns_f_rcode) != ns_r_noerror) {
        *error = "DNS server returned an error response";
        return 0;
    }
    if (ns_msg_count(*msg, ns_s_qd) != 1) {
        *error = "DNS response has an invalid question section";
        return 0;
    }
    ns_rr question;
    if (ns_parserr(msg, ns_s_qd, 0, &question) < 0 ||
        ns_rr_class(question) != ns_c_in ||
        ns_rr_type(question) != expected_type ||
        !sl_dns_name_equal(ns_rr_name(question), expected_name)) {
        *error = "DNS response question does not match the query";
        return 0;
    }
    return 1;
}

static int sl_dns_host_name_valid(const char *name) {
    if (!name || strcmp(name, ".") == 0) return 0;
    size_t n = strlen(name);
    size_t end = n && name[n - 1] == '.' ? n - 1 : n;
    if (end == 0 || end > SL_DNS_MAX_NAME) return 0;
    size_t label = 0;
    unsigned char first = 0, last = 0;
    for (size_t i = 0; i < end; i++) {
        unsigned char c = (unsigned char)name[i];
        if (c == '.') {
            if (label == 0 || label > 63 || first == '-' || last == '-')
                return 0;
            label = 0;
            first = last = 0;
            continue;
        }
        int ascii_alnum = (c >= 'A' && c <= 'Z') ||
                          (c >= 'a' && c <= 'z') ||
                          (c >= '0' && c <= '9');
        if (!ascii_alnum && c != '-') return 0;
        if (label == 0) first = c;
        last = c;
        label++;
        if (label > 63) return 0;
    }
    return label != 0 && first != '-' && last != '-';
}

static int sl_dns_parse_srv_packet(const unsigned char *packet, size_t len,
                                   const char *expected_name,
                                   sl_dns_srv_record *records,
                                   size_t capacity, size_t *count,
                                   const char **error) {
    *count = 0;
    *error = NULL;
    ns_msg msg;
    if (!sl_dns_response_init(packet, len, expected_name, ns_t_srv,
                              &msg, error)) return 0;
    int answers = ns_msg_count(msg, ns_s_an);
    for (int i = 0; i < answers; i++) {
        ns_rr rr;
        if (ns_parserr(&msg, ns_s_an, i, &rr) < 0) {
            *error = "malformed DNS answer section";
            return 0;
        }
        if (ns_rr_class(rr) != ns_c_in || ns_rr_type(rr) != ns_t_srv)
            continue;
        if (!sl_dns_name_equal(ns_rr_name(rr), expected_name)) {
            *error = "DNS SRV answer owner does not match the query";
            return 0;
        }
        if (*count >= capacity) {
            *error = "DNS SRV answer exceeds the record limit";
            return 0;
        }
        const unsigned char *rdata = ns_rr_rdata(rr);
        size_t rdlen = ns_rr_rdlen(rr);
        if (!rdata || rdlen < 7) {
            *error = "malformed DNS SRV record";
            return 0;
        }
        uint16_t priority = (uint16_t)(((uint16_t)rdata[0] << 8) | rdata[1]);
        uint16_t weight = (uint16_t)(((uint16_t)rdata[2] << 8) | rdata[3]);
        uint16_t port = (uint16_t)(((uint16_t)rdata[4] << 8) | rdata[5]);
        char target[SL_DNS_MAX_NAME + 2];
        int consumed = dn_expand(packet, packet + len, rdata + 6,
                                 target, (int)sizeof(target));
        if (consumed < 0 || (size_t)consumed != rdlen - 6) {
            *error = "DNS SRV record has an invalid target";
            return 0;
        }
        if (!target[0]) strcpy(target, "."); /* dn_expand prints root empty */
        if (strcmp(target, ".") != 0 && !sl_dns_host_name_valid(target)) {
            *error = "DNS SRV record has an invalid target";
            return 0;
        }
        if (port == 0 && strcmp(target, ".") != 0) {
            *error = "DNS SRV record has an invalid port";
            return 0;
        }
        size_t target_len = strlen(target);
        memcpy(records[*count].target, target, target_len + 1);
        records[*count].priority = priority;
        records[*count].weight = weight;
        records[*count].port = port;
        (*count)++;
    }
    return 1;
}

static int sl_dns_parse_txt_packet(const unsigned char *packet, size_t len,
                                   const char *expected_name,
                                   sl_dns_txt_record *records,
                                   size_t capacity, char *storage,
                                   size_t storage_cap, size_t *count,
                                   const char **error) {
    *count = 0;
    *error = NULL;
    ns_msg msg;
    if (!sl_dns_response_init(packet, len, expected_name, ns_t_txt,
                              &msg, error)) return 0;
    size_t used = 0;
    int answers = ns_msg_count(msg, ns_s_an);
    for (int i = 0; i < answers; i++) {
        ns_rr rr;
        if (ns_parserr(&msg, ns_s_an, i, &rr) < 0) {
            *error = "malformed DNS answer section";
            return 0;
        }
        if (ns_rr_class(rr) != ns_c_in || ns_rr_type(rr) != ns_t_txt)
            continue;
        if (!sl_dns_name_equal(ns_rr_name(rr), expected_name)) {
            *error = "DNS TXT answer owner does not match the query";
            return 0;
        }
        if (*count >= capacity) {
            *error = "DNS TXT answer exceeds the record limit";
            return 0;
        }
        const unsigned char *rdata = ns_rr_rdata(rr);
        size_t rdlen = ns_rr_rdlen(rr);
        if (!rdata && rdlen != 0) {
            *error = "malformed DNS TXT record";
            return 0;
        }
        size_t start = used;
        size_t pos = 0;
        while (pos < rdlen) {
            size_t chunk = rdata[pos++];
            if (chunk > rdlen - pos || chunk > SL_DNS_MAX_TXT_RECORD_BYTES ||
                used > storage_cap || chunk > storage_cap - used) {
                *error = "DNS TXT record exceeds the size limit";
                return 0;
            }
            for (size_t j = 0; j < chunk; j++) {
                unsigned char c = rdata[pos + j];
                if (c < 0x20 || c > 0x7e) {
                    *error = "DNS TXT record is not printable ASCII";
                    return 0;
                }
            }
            memcpy(storage + used, rdata + pos, chunk);
            used += chunk;
            pos += chunk;
        }
        if (used - start > SL_DNS_MAX_TXT_RECORD_BYTES ||
            used >= storage_cap) {
            *error = "DNS TXT record exceeds the size limit";
            return 0;
        }
        storage[used++] = '\0';
        records[*count].value = storage + start;
        records[*count].len = used - start - 1;
        (*count)++;
        if (used > SL_DNS_MAX_TXT_BYTES) {
            *error = "DNS TXT answer exceeds the total size limit";
            return 0;
        }
    }
    return 1;
}
