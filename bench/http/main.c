#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAX_EVENTS 128
#define RECV_CAP 2048
#define ARENA_CAP (1 << 20)

static const char RESPONSE[] =
    "HTTP/1.0 200 OK\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 200\r\n"
    "Connection: close\r\n"
    "\r\n"
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    "01234567";

typedef struct {
    char *base;
    size_t cap;
    size_t used;
} Arena;

static void *bump(Arena *a, size_t n) {
    size_t pad = (8u - (a->used & 7u)) & 7u;
    if (a->used + pad + n > a->cap)
        return NULL;
    a->used += pad;
    void *p = a->base + a->used;
    a->used += n;
    return p;
}

static int listen_sock(int port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (fd < 0)
        return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 1024) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void serve_conn(int cfd, Arena *a) {
    a->used = 0;
    char *buf = (char *)bump(a, RECV_CAP);
    if (!buf) {
        close(cfd);
        return;
    }
    recv(cfd, buf, RECV_CAP, 0);
    send(cfd, RESPONSE, sizeof(RESPONSE) - 1, 0);
    close(cfd);
}

static void *worker(void *arg) {
    int port = *(int *)arg;
    int lfd = listen_sock(port);
    if (lfd < 0) {
        perror("listen");
        return NULL;
    }
    int ep = epoll_create1(0);
    if (ep < 0) {
        perror("epoll");
        return NULL;
    }
    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.fd = lfd;
    epoll_ctl(ep, EPOLL_CTL_ADD, lfd, &ev);

    Arena a;
    a.cap = ARENA_CAP;
    a.used = 0;
    a.base = (char *)malloc(a.cap);
    if (!a.base)
        return NULL;

    struct epoll_event evs[MAX_EVENTS];
    for (;;) {
        int n = epoll_wait(ep, evs, MAX_EVENTS, -1);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        for (int i = 0; i < n; i++) {
            int fd = evs[i].data.fd;
            if (fd == lfd) {
                for (;;) {
                    int cfd = accept4(lfd, NULL, NULL, SOCK_NONBLOCK);
                    if (cfd < 0)
                        break;
                    ev.events = EPOLLIN;
                    ev.data.fd = cfd;
                    if (epoll_ctl(ep, EPOLL_CTL_ADD, cfd, &ev) != 0)
                        close(cfd);
                }
            } else {
                epoll_ctl(ep, EPOLL_CTL_DEL, fd, NULL);
                serve_conn(fd, &a);
            }
        }
    }
    return NULL;
}

int main(void) {
    const char *ps = getenv("HTTP_PORT");
    int port = (ps && ps[0]) ? atoi(ps) : 18182;
    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    int n = ncpu > 0 ? (int)ncpu : 1;
    printf("LISTEN_PORT %d\n", port);
    fflush(stdout);
    pthread_t *ths = (pthread_t *)malloc((size_t)n * sizeof(pthread_t));
    if (!ths)
        return 1;
    for (int i = 0; i < n; i++) {
        if (pthread_create(&ths[i], NULL, worker, &port) != 0)
            return 1;
    }
    for (int i = 0; i < n; i++)
        pthread_join(ths[i], NULL);
    return 0;
}
