/* Deterministic input for heavy/batch (bench/SPEC.md).
 *
 *   cc -O2 -o gen_batch gen_batch.c
 *   ./gen_batch <out.csv> <rows> <users> [seed]
 *
 * One splitmix64 stream, six draws per row in a fixed order, so the same
 * arguments produce the same bytes on every host. No header line. */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t state;

static uint64_t next(void) {
    uint64_t z = (state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

static const char *REGIONS[20] = {
    "AR", "AU", "BR", "CA", "DE", "EG", "ES", "FR", "IN", "IT",
    "JP", "KR", "MX", "NG", "NL", "PL", "SE", "UK", "US", "ZA",
};

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <out.csv> <rows> <users> [seed]\n", argv[0]);
        return 2;
    }
    uint64_t rows = strtoull(argv[2], NULL, 10);
    uint64_t users = strtoull(argv[3], NULL, 10);
    state = argc > 4 ? strtoull(argv[4], NULL, 10) : 20260917ULL;
    if (users == 0) {
        fprintf(stderr, "users must be positive\n");
        return 2;
    }
    FILE *f = fopen(argv[1], "wb");
    if (!f) {
        perror(argv[1]);
        return 1;
    }
    static char buf[1 << 20];
    size_t n = 0;
    for (uint64_t i = 0; i < rows; i++) {
        uint64_t ts = 1600000000ULL + next() % 100000000ULL;
        uint64_t user = 1 + next() % users;
        uint64_t sku = next() % 100000ULL;
        uint64_t qty = 1 + next() % 20;
        uint64_t price = 50 + next() % 50000ULL;
        const char *region = REGIONS[next() % 20];
        n += (size_t)snprintf(buf + n, sizeof buf - n,
                              "%" PRIu64 ",%" PRIu64 ",SKU-%05" PRIu64 ",%" PRIu64
                              ",%" PRIu64 ",%s\n",
                              ts, user, sku, qty, price, region);
        if (n > sizeof buf - 128) {
            if (fwrite(buf, 1, n, f) != n) {
                perror("write");
                return 1;
            }
            n = 0;
        }
    }
    if (n && fwrite(buf, 1, n, f) != n) {
        perror("write");
        return 1;
    }
    if (fclose(f) != 0) {
        perror("close");
        return 1;
    }
    return 0;
}
