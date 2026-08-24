#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

/* ---- slang runtime ---- */

static char *sl_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    memcpy(p, s, n);
    return p;
}

static char *sl_str_concat(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    char *p = (char *)malloc(la + lb + 1);
    memcpy(p, a, la);
    memcpy(p + la, b, lb);
    p[la + lb] = 0;
    return p;
}

static char *sl_str_from_int(long long v) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", v);
    return sl_strdup(buf);
}

static char *sl_str_from_float(double v) {
    char buf[64];
    snprintf(buf, sizeof(buf), "%g", v);
    return sl_strdup(buf);
}

static char *sl_str_from_bool(bool v) {
    return sl_strdup(v ? "true" : "false");
}

/* ---- user program ---- */

static long long sl_examples_fib(long long n);
static long long sl_examples_add(long long a, long long b);
static const char * sl_examples_greet(const char * who);
static double sl_examples_area(double w, double h);
static bool sl_examples_is_even(long long n);

static long long sl_examples_fib(long long n) {
    if ((n < 2)) {
        return n;
    }
    return (sl_examples_fib((n - 1)) + sl_examples_fib((n - 2)));
}

static long long sl_examples_add(long long a, long long b) {
    return (a + b);
}

static const char * sl_examples_greet(const char * who) {
    return sl_str_concat(sl_str_concat("Hi, ", who), "!");
}

static double sl_examples_area(double w, double h) {
    return (w * h);
}

static bool sl_examples_is_even(long long n) {
    return ((n % 2) == 0);
}

int main(void) {
    long long i = 0;
    while ((i < 15)) {
        fputs("fib(", stdout);
        printf("%lld", i);
        fputs(") = ", stdout);
        printf("%lld\n", sl_examples_fib(i));
        i = (i + 1);
    }
    const char * name = "World";
    puts(sl_str_concat(sl_str_concat("Hello, ", name), "!"));
    long long x = 10;
    long long y = 3;
    printf("%lld\n", (x + y));
    printf("%lld\n", (x * y));
    printf("%lld\n", (x / y));
    printf("%g\n", ((double)(x) / 2.0));
    printf("%lld\n", (x % y));
    bool flag = true;
    fputs((flag) ? "true" : "false", stdout);
    fputs(" ", stdout);
    puts(((!flag)) ? "true" : "false");
    puts(((strcmp(name, "World") == 0)) ? "true" : "false");
    if ((x > y)) {
        puts("x is bigger");
    } else {
        puts("y is not bigger");
    }
    long long i = 0;
    while ((i < 5)) {
        printf("%lld", i);
        i = (i + 1);
    }
    puts("");
    printf("%lld\n", sl_examples_add(2, 40));
    puts(sl_examples_greet("slang"));
    printf("%g\n", sl_examples_area(2.5, 4.0));
    puts((sl_examples_is_even(10)) ? "true" : "false");
    return 0;
}
