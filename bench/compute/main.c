#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int getenv_int(const char *name, int def) {
    const char *s = getenv(name);
    if (!s || !s[0])
        return def;
    return atoi(s);
}

static int count_primes_range(int lo, int hi) {
    int count = 0;
    for (int i = lo; i < hi; i++) {
        int is_prime = 1;
        if (i < 2)
            is_prime = 0;
        for (int d = 2; d * d <= i; d++) {
            if (i % d == 0)
                is_prime = 0;
        }
        if (is_prime)
            count++;
    }
    return count;
}

static int alloc_and_sum(int n) {
    int *xs = (int *)malloc((size_t)n * sizeof(int));
    if (!xs)
        exit(1);
    for (int i = 0; i < n; i++)
        xs[i] = i;
    int sum = 0;
    for (int i = 0; i < n; i++)
        sum += xs[i];
    for (int i = 0; i < n; i++) {
        char buf[32];
        snprintf(buf, sizeof(buf), "%d", i);
        sum += i + (int)strlen(buf);
    }
    free(xs);
    return sum;
}

typedef struct {
    int work_n;
    int alloc_n;
    int primes;
    int alloc_sum;
} TaskArg;

static void *worker(void *p) {
    TaskArg *a = (TaskArg *)p;
    a->primes = count_primes_range(0, a->work_n);
    a->alloc_sum = alloc_and_sum(a->alloc_n);
    return NULL;
}

int main(void) {
    int tasks = getenv_int("CC_TASKS", 1000);
    int work_n = getenv_int("CC_WORK", 20000);
    int alloc_n = getenv_int("CC_ALLOC", 200);
    printf("concurrent_compute: tasks=%d work_n=%d alloc_n=%d\n",
           tasks, work_n, alloc_n);

    TaskArg *args = (TaskArg *)calloc((size_t)tasks, sizeof(TaskArg));
    pthread_t *ths = (pthread_t *)malloc((size_t)tasks * sizeof(pthread_t));
    if (!args || !ths)
        return 1;

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < tasks; i++) {
        args[i].work_n = work_n;
        args[i].alloc_n = alloc_n;
        if (pthread_create(&ths[i], NULL, worker, &args[i]) != 0)
            exit(1);
    }
    int total_primes = 0, total_alloc = 0;
    for (int i = 0; i < tasks; i++) {
        pthread_join(ths[i], NULL);
        total_primes += args[i].primes;
        total_alloc += args[i].alloc_sum;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    long elapsed_ms = (t1.tv_sec - t0.tv_sec) * 1000 +
                      (t1.tv_nsec - t0.tv_nsec) / 1000000;
    long tps = elapsed_ms > 0 ? (tasks * 1000L) / elapsed_ms : 0;
    printf("RESULT tasks=%d work_n=%d alloc_n=%d wall_ms=%ld total_primes=%d "
           "total_alloc_sum=%d tasks_per_sec=%ld\n",
           tasks, work_n, alloc_n, elapsed_ms, total_primes, total_alloc, tps);
    free(args);
    free(ths);
    return 0;
}
