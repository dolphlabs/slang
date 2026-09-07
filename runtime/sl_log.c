#include <stdio.h>
#include <time.h>

static void sl_log_line(const char *level, const char *msg) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
    localtime_r(&ts.tv_sec, &tm);
    char stamp[32];
    strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%S", &tm);
    fprintf(stderr, "%s.%09ld %s %s\n", stamp, (long)ts.tv_nsec, level, msg);
}

static void sl_log_debug(const char *msg) { sl_log_line("DEBUG", msg); }
static void sl_log_info(const char *msg) { sl_log_line("INFO", msg); }
static void sl_log_warn(const char *msg) { sl_log_line("WARN", msg); }
static void sl_log_error(const char *msg) { sl_log_line("ERROR", msg); }
