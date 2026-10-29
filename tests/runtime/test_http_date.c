/* The HTTP Date formatter (runtime/sl_time.c, sl_hd_format) against
 * Python's datetime: the epoch and the second before it, leap days in a
 * year divisible by 400 (2000) and not by 100 rules (2100 is no leap
 * year), 2024's leap day, the 32-bit rollover, year 1 and 9999. The
 * per-second cache is exercised end to end by tests/http_date. */

static int sl_runtime_test_main(void);

#define main sl_runtime_unused_main
#include "sl_core.c"
#include "sl_gc.c"
#include "sl_ryu_tables.c"
#include "sl_ryu.c"
#include "sl_containers.c"
#include "sl_sched.c"
#include "sl_pool.c"
#include "sl_time.c"
#undef main

static const struct { long long sec; const char *want; } sl_hd_vectors[] = {
    {0LL, "Thu, 01 Jan 1970 00:00:00 GMT"},
    {-1LL, "Wed, 31 Dec 1969 23:59:59 GMT"},
    {86399LL, "Thu, 01 Jan 1970 23:59:59 GMT"},
    {86400LL, "Fri, 02 Jan 1970 00:00:00 GMT"},
    {951782400LL, "Tue, 29 Feb 2000 00:00:00 GMT"},
    {951868799LL, "Tue, 29 Feb 2000 23:59:59 GMT"},
    {951868800LL, "Wed, 01 Mar 2000 00:00:00 GMT"},
    {4107542399LL, "Sun, 28 Feb 2100 23:59:59 GMT"},
    {4107542400LL, "Mon, 01 Mar 2100 00:00:00 GMT"},
    {1709164800LL, "Thu, 29 Feb 2024 00:00:00 GMT"},
    {1709251199LL, "Thu, 29 Feb 2024 23:59:59 GMT"},
    {253402300799LL, "Fri, 31 Dec 9999 23:59:59 GMT"},
    {1792000000LL, "Wed, 14 Oct 2026 17:46:40 GMT"},
    {-62135596800LL, "Mon, 01 Jan 0001 00:00:00 GMT"},
    {1234567890LL, "Fri, 13 Feb 2009 23:31:30 GMT"},
    {2147483647LL, "Tue, 19 Jan 2038 03:14:07 GMT"},
    {2147483648LL, "Tue, 19 Jan 2038 03:14:08 GMT"},
    {946684800LL, "Sat, 01 Jan 2000 00:00:00 GMT"},
    {978307199LL, "Sun, 31 Dec 2000 23:59:59 GMT"},
};

static int sl_runtime_test_main(void) {
    int bad = 0;
    for (size_t i = 0; i < sizeof(sl_hd_vectors) / sizeof(sl_hd_vectors[0]); i++) {
        char got[32];
        sl_hd_format(sl_hd_vectors[i].sec, got);
        if (strlen(got) != 29 || strcmp(got, sl_hd_vectors[i].want) != 0) {
            fprintf(stderr, "test_http_date: %lld: got \"%s\", want \"%s\"\n",
                    sl_hd_vectors[i].sec, got, sl_hd_vectors[i].want);
            bad = 1;
        }
    }
    char a[32], b[32];
    sl_hd_current(a);
    sl_hd_current(b);
    if (strlen(a) != 29 || memcmp(a + 25, " GMT", 4) != 0) {
        fprintf(stderr, "test_http_date: current date malformed: %s\n", a);
        bad = 1;
    }
    return bad;
}

int main(void) {
    return sl_runtime_test_main();
}
