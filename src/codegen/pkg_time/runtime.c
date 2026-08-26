/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "../internal.h"

/* ---- native 'time' package runtime (emitted on demand) ---- */

const char *TIME_RUNTIME[] = {
    "#include <time.h>",
    "#include <errno.h>",
    "",
    "/* ---- time: monotonic + wall clock; duration is nanoseconds ---- */",
    "",
    "static long long sl_time_mono(void) {",
    "    struct timespec ts;",
    "    clock_gettime(CLOCK_MONOTONIC, &ts);",
    "    return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;",
    "}",
    "",
    "static long long sl_time_wall(void) {",
    "    struct timespec ts;",
    "    clock_gettime(CLOCK_REALTIME, &ts);",
    "    return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;",
    "}",
    "",
    "static void sl_time_sleep(long long ns) {",
    "    struct timespec ts;",
    "    ts.tv_sec = (time_t)(ns / 1000000000LL);",
    "    ts.tv_nsec = (long)(ns % 1000000000LL);",
    "    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}",
    "}",
    "",
};

const int TIME_RUNTIME_LEN = sizeof(TIME_RUNTIME) / sizeof(TIME_RUNTIME[0]);
