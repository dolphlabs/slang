/* heavy/api in C: one epoll loop per core, each owning non-blocking libpq
 * connections; hand-written HTTP/1.1 and JSON. See bench/SPEC.md.
 *
 *   cc -O3 -march=native -flto -o api server.c -lpq -lpthread
 *
 * Per worker thread: a SO_REUSEPORT listener, an epoll set, and
 * DB_POOL_TOTAL/WORKERS database connections in libpq's non-blocking
 * mode. A request that needs the database waits in the worker's queue for
 * a free connection; its query is sent with PQsendQueryPrepared and the
 * connection's socket is watched in the same epoll set, so no thread ever
 * blocks on the database. One request is in flight per client connection;
 * pipelined requests wait in its input buffer. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <libpq-fe.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <strings.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

#define TS "to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"
static const char *SQL[] = {
    "SELECT id, email, name, country, " TS " FROM users WHERE id = $1",
    "SELECT id, sku, qty, price_cents, status, " TS " FROM orders WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2",
    "SELECT status, count(*), coalesce(sum(qty * price_cents), 0) FROM orders WHERE user_id = $1 GROUP BY status",
    "INSERT INTO orders (user_id, sku, qty, price_cents, status, created_at) VALUES ($1, $2, $3, $4, 'pending', now()) RETURNING id",
};
enum { Q_USER, Q_ORDERS, Q_SUMMARY, Q_INSERT };
static const int NPARAMS[] = {1, 2, 1, 4};

#define MAX_BODY (8 << 20)

/* ---- growable byte buffer ------------------------------------------ */

typedef struct {
    char *p;
    size_t len, cap;
} buf_t;

static void buf_reserve(buf_t *b, size_t extra) {
    if (b->len + extra <= b->cap) return;
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < b->len + extra) cap *= 2;
    b->p = realloc(b->p, cap);
    if (!b->p) abort();
    b->cap = cap;
}

static void buf_put(buf_t *b, const char *s, size_t n) {
    buf_reserve(b, n);
    memcpy(b->p + b->len, s, n);
    b->len += n;
}

static void buf_str(buf_t *b, const char *s) { buf_put(b, s, strlen(s)); }

static void buf_i64(buf_t *b, int64_t v) {
    char tmp[24];
    int n = 0;
    uint64_t u = v < 0 ? (uint64_t)(-(v + 1)) + 1 : (uint64_t)v;
    do tmp[n++] = (char)('0' + u % 10); while ((u /= 10));
    buf_reserve(b, (size_t)n + 1);
    if (v < 0) b->p[b->len++] = '-';
    while (n) b->p[b->len++] = tmp[--n];
}

/* JSON string with escaping */
static void buf_jstr(buf_t *b, const char *s, size_t n) {
    buf_reserve(b, n * 6 + 2);
    b->p[b->len++] = '"';
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') {
            b->p[b->len++] = '\\';
            b->p[b->len++] = (char)c;
        } else if (c < 0x20) {
            b->len += (size_t)sprintf(b->p + b->len, "\\u%04x", c);
        } else {
            b->p[b->len++] = (char)c;
        }
    }
    b->p[b->len++] = '"';
}

/* ---- a small JSON reader: enough for the two request bodies -------- */

typedef struct {
    const char *p, *end;
    int bad;
} jr_t;

static void jr_ws(jr_t *j) {
    while (j->p < j->end && (*j->p == ' ' || *j->p == '\n' || *j->p == '\r' || *j->p == '\t')) j->p++;
}

static int jr_eat(jr_t *j, char c) {
    jr_ws(j);
    if (j->p < j->end && *j->p == c) {
        j->p++;
        return 1;
    }
    return 0;
}

/* A string into out (unescaped, NUL-terminated, truncated to cap-1 but
 * the true length returned via *len). Returns 0 on malformed input. */
static int jr_string(jr_t *j, char *out, size_t cap, size_t *len) {
    jr_ws(j);
    if (j->p >= j->end || *j->p != '"') return 0;
    j->p++;
    size_t n = 0;
    while (j->p < j->end && *j->p != '"') {
        char c = *j->p++;
        if (c == '\\') {
            if (j->p >= j->end) return 0;
            char e = *j->p++;
            switch (e) {
            case 'n': c = '\n'; break;
            case 't': c = '\t'; break;
            case 'r': c = '\r'; break;
            case 'b': c = '\b'; break;
            case 'f': c = '\f'; break;
            case 'u':
                if (j->end - j->p < 4) return 0;
                j->p += 4; /* keys and skus here are ASCII; count it as one char */
                c = '?';
                break;
            default: c = e;
            }
        }
        if (out && n + 1 < cap) out[n] = c;
        n++;
    }
    if (j->p >= j->end) return 0;
    j->p++;
    if (out && cap) out[n < cap ? n : cap - 1] = 0;
    if (len) *len = n;
    return 1;
}

/* An integer; 0 when not an integer (a fraction, exponent or non-number). */
static int jr_int(jr_t *j, int64_t *v) {
    jr_ws(j);
    const char *s = j->p;
    int neg = 0;
    if (s < j->end && *s == '-') { neg = 1; s++; }
    if (s >= j->end || *s < '0' || *s > '9') return 0;
    int64_t n = 0;
    int digits = 0;
    while (s < j->end && *s >= '0' && *s <= '9') {
        if (++digits > 18) return 0;
        n = n * 10 + (*s++ - '0');
    }
    if (s < j->end && (*s == '.' || *s == 'e' || *s == 'E')) return 0;
    j->p = s;
    *v = neg ? -n : n;
    return 1;
}

static int jr_skip(jr_t *j, int depth);

static int jr_skip(jr_t *j, int depth) {
    if (depth > 64) return 0;
    jr_ws(j);
    if (j->p >= j->end) return 0;
    char c = *j->p;
    if (c == '"') return jr_string(j, NULL, 0, NULL);
    if (c == '{' || c == '[') {
        char close = c == '{' ? '}' : ']';
        j->p++;
        if (jr_eat(j, close)) return 1;
        for (;;) {
            if (c == '{') {
                if (!jr_string(j, NULL, 0, NULL) || !jr_eat(j, ':')) return 0;
            }
            if (!jr_skip(j, depth + 1)) return 0;
            if (jr_eat(j, ',')) continue;
            return jr_eat(j, close);
        }
    }
    const char *s = j->p;
    while (j->p < j->end && (*j->p == '-' || *j->p == '+' || *j->p == '.' ||
                             (*j->p >= '0' && *j->p <= '9') || *j->p == 'e' || *j->p == 'E' ||
                             (*j->p >= 'a' && *j->p <= 'z')))
        j->p++;
    return j->p > s;
}

/* ---- connections and requests --------------------------------------- */

typedef struct worker worker_t;

typedef struct client {
    int fd;
    worker_t *w;
    buf_t in, out;
    size_t out_off;
    int busy;          /* a request of ours is waiting for, or in, the database */
    int close_after;   /* Connection: close on the request being answered */
    int closing;       /* no more requests: free once idle and flushed */
    int detached;      /* gone from epoll while busy: its query frees it */
    /* the pending database request */
    int query;
    int64_t id, limit;
    char *params[4];
    char pbuf[4][40];
    char sku[64];
    struct client *next_wait;
} client_t;

typedef struct {
    PGconn *conn;
    int fd;
    client_t *owner;   /* whose result is still to be delivered */
    int inflight;      /* a query is running: free only after libpq's final NULL */
} dbconn_t;

struct worker {
    int ep, lfd;
    dbconn_t *db;
    int ndb;
    client_t *wait_head, *wait_tail;
};

static const char *DB_URL;
static int PORT = 8080, WORKERS = 1, POOL_TOTAL = 64;

/* epoll user data: tag the pointer's low bit to tell db from client */
#define TAG_DB 1

static void client_free(client_t *c) {
    close(c->fd);
    free(c->in.p);
    free(c->out.p);
    free(c);
}

static void set_nonblock(int fd) { fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); }

static void respond(client_t *c, int status, const char *body, size_t n) {
    const char *text = status == 200 ? "200 OK" : status == 201 ? "201 Created" :
                       status == 400 ? "400 Bad Request" : status == 404 ? "404 Not Found" :
                       "500 Internal Server Error";
    buf_str(&c->out, "HTTP/1.1 ");
    buf_str(&c->out, text);
    buf_str(&c->out, "\r\nContent-Type: application/json\r\nContent-Length: ");
    buf_i64(&c->out, (int64_t)n);
    buf_str(&c->out, c->close_after ? "\r\nConnection: close\r\n\r\n" : "\r\n\r\n");
    buf_put(&c->out, body, n);
}

#define BAD "{\"error\":\"bad request\"}"
#define NOT_FOUND "{\"error\":\"not found\"}"
#define LIT(s) s, sizeof(s) - 1

static void flush(client_t *c);
static void process(client_t *c);
static void settle(client_t *c);

static void db_send(dbconn_t *d, client_t *c) {
    d->owner = c;
    d->inflight = 1;
    c->busy = 1;
    const char *name[] = {"q0", "q1", "q2", "q3"};
    int ok = PQsendQueryPrepared(d->conn, name[c->query], NPARAMS[c->query],
                                 (const char *const *)c->params, NULL, NULL, 0);
    if (!ok) {
        /* the caller settles the client: from inside process() it must
           not, or the request being handled would be parsed again */
        d->owner = NULL;
        d->inflight = 0;
        c->busy = 0;
        respond(c, 500, LIT("{\"error\":\"internal\"}"));
        flush(c);
        return;
    }
    PQflush(d->conn);
    struct epoll_event ev = {.events = EPOLLIN, .data.ptr = (void *)((uintptr_t)d | TAG_DB)};
    epoll_ctl(c->w->ep, EPOLL_CTL_MOD, d->fd, &ev);
}

static void enqueue_db(client_t *c) {
    worker_t *w = c->w;
    for (int i = 0; i < w->ndb; i++) {
        if (!w->db[i].inflight) {
            db_send(&w->db[i], c);
            return;
        }
    }
    c->busy = 1;
    c->next_wait = NULL;
    if (w->wait_tail) w->wait_tail->next_wait = c;
    else w->wait_head = c;
    w->wait_tail = c;
}

static void finish_query(dbconn_t *d, PGresult *res) {
    client_t *c = d->owner;
    d->owner = NULL;
    c->busy = 0;
    if (c->detached) {
        client_free(c);
        return;
    } else if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        respond(c, 500, LIT("{\"error\":\"internal\"}"));
        flush(c);
    } else {
        buf_t b = {0};
        int rows = PQntuples(res);
        switch (c->query) {
        case Q_USER:
            if (rows == 0) {
                respond(c, 404, LIT(NOT_FOUND));
                break;
            }
            buf_str(&b, "{\"id\":");
            buf_str(&b, PQgetvalue(res, 0, 0));
            buf_str(&b, ",\"email\":");
            buf_jstr(&b, PQgetvalue(res, 0, 1), (size_t)PQgetlength(res, 0, 1));
            buf_str(&b, ",\"name\":");
            buf_jstr(&b, PQgetvalue(res, 0, 2), (size_t)PQgetlength(res, 0, 2));
            buf_str(&b, ",\"country\":");
            buf_jstr(&b, PQgetvalue(res, 0, 3), (size_t)PQgetlength(res, 0, 3));
            buf_str(&b, ",\"created_at\":");
            buf_jstr(&b, PQgetvalue(res, 0, 4), (size_t)PQgetlength(res, 0, 4));
            buf_str(&b, "}");
            respond(c, 200, b.p, b.len);
            break;
        case Q_ORDERS:
            buf_str(&b, "{\"user_id\":");
            buf_i64(&b, c->id);
            buf_str(&b, ",\"orders\":[");
            for (int i = 0; i < rows; i++) {
                buf_str(&b, i ? ",{\"id\":" : "{\"id\":");
                buf_str(&b, PQgetvalue(res, i, 0));
                buf_str(&b, ",\"sku\":");
                buf_jstr(&b, PQgetvalue(res, i, 1), (size_t)PQgetlength(res, i, 1));
                buf_str(&b, ",\"qty\":");
                buf_str(&b, PQgetvalue(res, i, 2));
                buf_str(&b, ",\"price_cents\":");
                buf_str(&b, PQgetvalue(res, i, 3));
                buf_str(&b, ",\"status\":");
                buf_jstr(&b, PQgetvalue(res, i, 4), (size_t)PQgetlength(res, i, 4));
                buf_str(&b, ",\"created_at\":");
                buf_jstr(&b, PQgetvalue(res, i, 5), (size_t)PQgetlength(res, i, 5));
                buf_str(&b, "}");
            }
            buf_str(&b, "]}");
            respond(c, 200, b.p, b.len);
            break;
        case Q_SUMMARY: {
            static const char *names[] = {"cancelled", "delivered", "paid", "pending", "shipped"};
            int64_t by[5] = {0}, count = 0, total = 0;
            for (int i = 0; i < rows; i++) {
                const char *st = PQgetvalue(res, i, 0);
                int64_t n = strtoll(PQgetvalue(res, i, 1), NULL, 10);
                for (int k = 0; k < 5; k++)
                    if (!strcmp(st, names[k])) by[k] = n;
                count += n;
                total += strtoll(PQgetvalue(res, i, 2), NULL, 10);
            }
            buf_str(&b, "{\"user_id\":");
            buf_i64(&b, c->id);
            buf_str(&b, ",\"order_count\":");
            buf_i64(&b, count);
            buf_str(&b, ",\"total_cents\":");
            buf_i64(&b, total);
            buf_str(&b, ",\"by_status\":{");
            for (int k = 0; k < 5; k++) {
                buf_str(&b, k ? ",\"" : "\"");
                buf_str(&b, names[k]);
                buf_str(&b, "\":");
                buf_i64(&b, by[k]);
            }
            buf_str(&b, "}}");
            respond(c, 200, b.p, b.len);
            break;
        }
        case Q_INSERT:
            buf_str(&b, "{\"id\":");
            buf_str(&b, PQgetvalue(res, 0, 0));
            buf_str(&b, ",\"status\":\"pending\"}");
            respond(c, 201, b.p, b.len);
            break;
        }
        free(b.p);
        flush(c);
    }
    settle(c);
}

static void db_readable(worker_t *w, dbconn_t *d) {
    if (!PQconsumeInput(d->conn)) {
        fprintf(stderr, "database: %s", PQerrorMessage(d->conn));
        exit(1);
    }
    int done = 0;
    while (!PQisBusy(d->conn)) {
        PGresult *res = PQgetResult(d->conn);
        if (!res) {
            done = 1;
            break;
        }
        if (d->owner) finish_query(d, res);
        PQclear(res);
    }
    if (!done)
        return;
    /* the exchange is over: the connection can take the next query */
    d->inflight = 0;
    struct epoll_event ev = {.events = 0, .data.ptr = (void *)((uintptr_t)d | TAG_DB)};
    epoll_ctl(w->ep, EPOLL_CTL_MOD, d->fd, &ev);
    while (w->wait_head) {
        client_t *next = w->wait_head;
        w->wait_head = next->next_wait;
        if (!w->wait_head) w->wait_tail = NULL;
        if (next->detached) {
            client_free(next);
            continue;
        }
        db_send(d, next);
        if (next->busy)
            break;
        settle(next); /* the send failed and it was answered with a 500 */
    }
}

static int64_t parse_id(const char *s, size_t n) {
    if (n == 0 || n > 18) return -1;
    int64_t v = 0;
    for (size_t i = 0; i < n; i++) {
        if (s[i] < '0' || s[i] > '9') return -1;
        v = v * 10 + (s[i] - '0');
    }
    return v > 0 ? v : -1;
}

static int64_t rate_for(const char *r) {
    static const struct { const char *code; int64_t bp; } T[] = {
        {"US", 725}, {"CA", 1300}, {"UK", 2000}, {"EU", 2000}, {"DE", 1900}, {"FR", 2000},
        {"JP", 1000}, {"IN", 1800}, {"BR", 1700}, {"NG", 750}, {"AU", 1000}};
    for (size_t i = 0; i < sizeof T / sizeof T[0]; i++)
        if (!strcmp(r, T[i].code)) return T[i].bp;
    return -1;
}

typedef struct {
    int64_t net;
    size_t pos;
    char sku[64];
} ranked_t;

static int ahead(const ranked_t *a, const ranked_t *b) {
    if (a->net != b->net) return a->net > b->net;
    int c = strcmp(a->sku, b->sku);
    if (c) return c < 0;
    return a->pos < b->pos;
}

static void quote(client_t *c, const char *body, size_t n) {
    jr_t j = {body, body + n, 0};
    char region[8] = "";
    size_t region_len = 0;
    int have_items = 0;
    int64_t sub = 0, disc = 0, tax = 0, rate = -1;
    size_t lines = 0;
    ranked_t top[5];
    int ntop = 0;
    if (!jr_eat(&j, '{')) goto bad;
    /* region must be known before items are priced; parse items only after */
    const char *items_at = NULL;
    if (!jr_eat(&j, '}')) {
        for (;;) {
            char key[32];
            size_t klen;
            if (!jr_string(&j, key, sizeof key, &klen) || !jr_eat(&j, ':')) goto bad;
            if (!strcmp(key, "region")) {
                if (!jr_string(&j, region, sizeof region, &region_len)) goto bad;
            } else if (!strcmp(key, "items")) {
                jr_ws(&j);
                items_at = j.p;
                if (!jr_skip(&j, 0)) goto bad;
            } else if (!jr_skip(&j, 0)) {
                goto bad;
            }
            if (jr_eat(&j, ',')) continue;
            if (!jr_eat(&j, '}')) goto bad;
            break;
        }
    }
    if (region_len > 4 || (rate = rate_for(region)) < 0 || !items_at) goto bad;
    j.p = items_at;
    if (!jr_eat(&j, '[')) goto bad;
    if (!jr_eat(&j, ']')) {
        have_items = 1;
        for (;;) {
            ranked_t r = {0};
            int64_t qty = 0, price = 0;
            int got_qty = 0, got_price = 0, got_sku = 0;
            if (!jr_eat(&j, '{')) goto bad;
            if (!jr_eat(&j, '}')) {
                for (;;) {
                    char key[32];
                    size_t klen;
                    if (!jr_string(&j, key, sizeof key, &klen) || !jr_eat(&j, ':')) goto bad;
                    if (!strcmp(key, "sku")) {
                        size_t sl;
                        if (!jr_string(&j, r.sku, sizeof r.sku, &sl)) goto bad;
                        got_sku = 1;
                    } else if (!strcmp(key, "qty")) {
                        if (!jr_int(&j, &qty)) goto bad;
                        got_qty = 1;
                    } else if (!strcmp(key, "price_cents")) {
                        if (!jr_int(&j, &price)) goto bad;
                        got_price = 1;
                    } else if (!jr_skip(&j, 0)) {
                        goto bad;
                    }
                    if (jr_eat(&j, ',')) continue;
                    if (!jr_eat(&j, '}')) goto bad;
                    break;
                }
            }
            if (!got_sku || !got_qty || !got_price || qty < 1 || price < 0) goto bad;
            int64_t gross = qty * price;
            int64_t d = qty >= 10 ? gross * 500 / 10000 : 0;
            r.net = gross - d;
            r.pos = lines++;
            sub += gross;
            disc += d;
            tax += r.net * rate / 10000;
            if (ntop < 5 || ahead(&r, &top[ntop - 1])) {
                int at = ntop < 5 ? ntop++ : 4;
                while (at > 0 && ahead(&r, &top[at - 1])) {
                    top[at] = top[at - 1];
                    at--;
                }
                top[at] = r;
            }
            if (jr_eat(&j, ',')) continue;
            if (!jr_eat(&j, ']')) goto bad;
            break;
        }
    }
    if (!have_items) goto bad;
    {
        buf_t b = {0};
        buf_str(&b, "{\"region\":");
        buf_jstr(&b, region, region_len);
        buf_str(&b, ",\"lines\":");
        buf_i64(&b, (int64_t)lines);
        buf_str(&b, ",\"subtotal_cents\":");
        buf_i64(&b, sub);
        buf_str(&b, ",\"discount_cents\":");
        buf_i64(&b, disc);
        buf_str(&b, ",\"tax_cents\":");
        buf_i64(&b, tax);
        buf_str(&b, ",\"total_cents\":");
        buf_i64(&b, sub - disc + tax);
        buf_str(&b, ",\"top_skus\":[");
        for (int i = 0; i < ntop; i++) {
            if (i) buf_str(&b, ",");
            buf_jstr(&b, top[i].sku, strlen(top[i].sku));
        }
        buf_str(&b, "]}");
        respond(c, 200, b.p, b.len);
        free(b.p);
    }
    return;
bad:
    respond(c, 400, LIT(BAD));
}

static void create_order(client_t *c, const char *body, size_t n) {
    jr_t j = {body, body + n, 0};
    int64_t uid = 0, qty = 0, price = 0;
    size_t sku_len = 0;
    int got = 0;
    if (!jr_eat(&j, '{')) goto bad;
    if (!jr_eat(&j, '}')) {
        for (;;) {
            char key[32];
            size_t klen;
            if (!jr_string(&j, key, sizeof key, &klen) || !jr_eat(&j, ':')) goto bad;
            if (!strcmp(key, "user_id")) {
                if (!jr_int(&j, &uid)) goto bad;
                got |= 1;
            } else if (!strcmp(key, "sku")) {
                if (!jr_string(&j, c->sku, sizeof c->sku, &sku_len)) goto bad;
                got |= 2;
            } else if (!strcmp(key, "qty")) {
                if (!jr_int(&j, &qty)) goto bad;
                got |= 4;
            } else if (!strcmp(key, "price_cents")) {
                if (!jr_int(&j, &price)) goto bad;
                got |= 8;
            } else if (!jr_skip(&j, 0)) {
                goto bad;
            }
            if (jr_eat(&j, ',')) continue;
            if (!jr_eat(&j, '}')) goto bad;
            break;
        }
    }
    jr_ws(&j);
    if (j.p != j.end || got != 15 || uid < 1 || qty < 1 || qty > 1000 || price < 1 ||
        price > 1000000000 || sku_len < 1 || sku_len > 32)
        goto bad;
    c->query = Q_INSERT;
    snprintf(c->pbuf[0], sizeof c->pbuf[0], "%lld", (long long)uid);
    snprintf(c->pbuf[2], sizeof c->pbuf[2], "%lld", (long long)qty);
    snprintf(c->pbuf[3], sizeof c->pbuf[3], "%lld", (long long)price);
    c->params[0] = c->pbuf[0];
    c->params[1] = c->sku;
    c->params[2] = c->pbuf[2];
    c->params[3] = c->pbuf[3];
    enqueue_db(c);
    return;
bad:
    respond(c, 400, LIT(BAD));
}

static int header_is(const char *line, size_t n, const char *name) {
    size_t k = strlen(name);
    return n > k && line[k] == ':' && !strncasecmp(line, name, k);
}

/* Handle every complete request buffered, one at a time. */
static void process(client_t *c) {
    while (!c->busy && !c->closing) {
        char *hdr_end = memmem(c->in.p, c->in.len, "\r\n\r\n", 4);
        if (!hdr_end) {
            if (c->in.len > 65536) c->closing = 1;
            return;
        }
        size_t head_len = (size_t)(hdr_end - c->in.p) + 4;
        char *line_end = memchr(c->in.p, '\r', head_len);
        char *sp1 = memchr(c->in.p, ' ', (size_t)(line_end - c->in.p));
        char *sp2 = sp1 ? memchr(sp1 + 1, ' ', (size_t)(line_end - sp1 - 1)) : NULL;
        if (!sp1 || !sp2) {
            c->closing = 1;
            return;
        }
        size_t body_len = 0;
        int is11 = !memcmp(sp2 + 1, "HTTP/1.1", 8);
        c->close_after = !is11;
        for (char *h = line_end + 2; h < hdr_end;) {
            char *e = memmem(h, (size_t)(hdr_end + 2 - h), "\r\n", 2);
            size_t hl = (size_t)(e - h);
            if (header_is(h, hl, "content-length")) {
                body_len = (size_t)strtoull(h + 15, NULL, 10);
            } else if (header_is(h, hl, "connection")) {
                const char *v = h + 11;
                while (*v == ' ') v++;
                if (!strncasecmp(v, "close", 5)) c->close_after = 1;
                if (!strncasecmp(v, "keep-alive", 10)) c->close_after = 0;
            }
            h = e + 2;
        }
        if (body_len > MAX_BODY) {
            c->closing = 1;
            return;
        }
        if (c->in.len < head_len + body_len) return;

        const char *method = c->in.p;
        size_t mlen = (size_t)(sp1 - c->in.p);
        const char *target = sp1 + 1;
        size_t tlen = (size_t)(sp2 - target);
        const char *q = memchr(target, '?', tlen);
        size_t plen = q ? (size_t)(q - target) : tlen;
        const char *body = c->in.p + head_len;
        int get = mlen == 3 && !memcmp(method, "GET", 3);
        int post = mlen == 4 && !memcmp(method, "POST", 4);

        #define PATH_IS(s) (plen == sizeof(s) - 1 && !memcmp(target, s, plen))
        if (PATH_IS("/health")) {
            respond(c, 200, LIT("{\"ok\":true}"));
        } else if (post && PATH_IS("/api/quote")) {
            quote(c, body, body_len);
        } else if (post && PATH_IS("/api/orders")) {
            create_order(c, body, body_len);
        } else if (get && plen > 11 && !memcmp(target, "/api/users/", 11)) {
            const char *rest = target + 11;
            size_t rlen = plen - 11;
            const char *slash = memchr(rest, '/', rlen);
            size_t idlen = slash ? (size_t)(slash - rest) : rlen;
            const char *tail = slash ? slash : rest + rlen;
            size_t tail_len = rlen - idlen;
            int64_t id = parse_id(rest, idlen);
            int kind = tail_len == 0 ? Q_USER :
                       (tail_len == 7 && !memcmp(tail, "/orders", 7)) ? Q_ORDERS :
                       (tail_len == 8 && !memcmp(tail, "/summary", 8)) ? Q_SUMMARY : -1;
            int64_t limit = 20;
            if (kind == Q_ORDERS && q) {
                const char *qs = q + 1, *qe = target + tlen;
                while (qs < qe) {
                    const char *amp = memchr(qs, '&', (size_t)(qe - qs));
                    const char *pe = amp ? amp : qe;
                    if (pe - qs >= 6 && !memcmp(qs, "limit=", 6)) {
                        limit = parse_id(qs + 6, (size_t)(pe - qs - 6));
                        if (limit > 100) limit = -1;
                    }
                    qs = pe + 1;
                }
            }
            if (kind < 0) {
                respond(c, 404, LIT(NOT_FOUND));
            } else if (id < 0 || limit < 0) {
                respond(c, 400, LIT(BAD));
            } else {
                c->query = kind;
                c->id = id;
                c->limit = limit;
                snprintf(c->pbuf[0], sizeof c->pbuf[0], "%lld", (long long)id);
                snprintf(c->pbuf[1], sizeof c->pbuf[1], "%lld", (long long)limit);
                c->params[0] = c->pbuf[0];
                c->params[1] = c->pbuf[1];
                enqueue_db(c);
            }
        } else {
            respond(c, 404, LIT(NOT_FOUND));
        }
        #undef PATH_IS

        /* consume the request */
        size_t used = head_len + body_len;
        memmove(c->in.p, c->in.p + used, c->in.len - used);
        c->in.len -= used;
        if (!c->busy) flush(c);
    }
}

static void flush(client_t *c) {
    while (c->out_off < c->out.len) {
        ssize_t n = write(c->fd, c->out.p + c->out_off, c->out.len - c->out_off);
        if (n > 0) {
            c->out_off += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EAGAIN) {
            struct epoll_event ev = {.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP, .data.ptr = c};
            epoll_ctl(c->w->ep, EPOLL_CTL_MOD, c->fd, &ev);
            return;
        }
        c->closing = 1;
        return;
    }
    c->out.len = c->out_off = 0;
    if (c->close_after) c->closing = 1;
    if (c->closing) return;
    struct epoll_event ev = {.events = EPOLLIN | EPOLLRDHUP, .data.ptr = c};
    epoll_ctl(c->w->ep, EPOLL_CTL_MOD, c->fd, &ev);
}

/* After any change to a client: answer what is buffered, or let it go. */
static void settle(client_t *c) {
    if (c->detached)
        return;
    if (!c->closing && !c->busy)
        process(c);
    if (c->closing && !c->busy && c->out_off >= c->out.len) {
        epoll_ctl(c->w->ep, EPOLL_CTL_DEL, c->fd, NULL);
        client_free(c);
    }
}

static void *worker_main(void *arg) {
    worker_t *w = arg;
    w->ep = epoll_create1(0);
    w->lfd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(w->lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(w->lfd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons((uint16_t)PORT)};
    if (bind(w->lfd, (struct sockaddr *)&addr, sizeof addr) || listen(w->lfd, 4096)) {
        perror("listen");
        exit(1);
    }
    set_nonblock(w->lfd);
    struct epoll_event lev = {.events = EPOLLIN, .data.ptr = NULL};
    epoll_ctl(w->ep, EPOLL_CTL_ADD, w->lfd, &lev);

    for (int i = 0; i < w->ndb; i++) {
        dbconn_t *d = &w->db[i];
        d->conn = PQconnectdb(DB_URL);
        if (PQstatus(d->conn) != CONNECTION_OK) {
            fprintf(stderr, "database: %s", PQerrorMessage(d->conn));
            exit(1);
        }
        for (int q = 0; q < 4; q++) {
            char name[4] = {'q', (char)('0' + q), 0};
            PGresult *r = PQprepare(d->conn, name, SQL[q], NPARAMS[q], NULL);
            if (PQresultStatus(r) != PGRES_COMMAND_OK) {
                fprintf(stderr, "prepare: %s", PQerrorMessage(d->conn));
                exit(1);
            }
            PQclear(r);
        }
        PQsetnonblocking(d->conn, 1);
        d->fd = PQsocket(d->conn);
        struct epoll_event ev = {.events = 0, .data.ptr = (void *)((uintptr_t)d | TAG_DB)};
        epoll_ctl(w->ep, EPOLL_CTL_ADD, d->fd, &ev);
    }

    struct epoll_event events[512];
    for (;;) {
        int n = epoll_wait(w->ep, events, 512, -1);
        for (int i = 0; i < n; i++) {
            void *ptr = events[i].data.ptr;
            if (!ptr) {
                for (;;) {
                    int fd = accept4(w->lfd, NULL, NULL, SOCK_NONBLOCK);
                    if (fd < 0) break;
                    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
                    client_t *c = calloc(1, sizeof *c);
                    c->fd = fd;
                    c->w = w;
                    struct epoll_event ev = {.events = EPOLLIN | EPOLLRDHUP, .data.ptr = c};
                    epoll_ctl(w->ep, EPOLL_CTL_ADD, fd, &ev);
                }
                continue;
            }
            if ((uintptr_t)ptr & TAG_DB) {
                db_readable(w, (dbconn_t *)((uintptr_t)ptr & ~(uintptr_t)TAG_DB));
                continue;
            }
            client_t *c = ptr;
            if (events[i].events & EPOLLOUT)
                flush(c);
            int gone = 0;
            if (events[i].events & EPOLLIN) {
                for (;;) {
                    buf_reserve(&c->in, 65536);
                    ssize_t r = read(c->fd, c->in.p + c->in.len, c->in.cap - c->in.len);
                    if (r > 0) {
                        c->in.len += (size_t)r;
                        continue;
                    }
                    if (r == 0 || errno != EAGAIN) gone = 1;
                    break;
                }
            }
            if (events[i].events & (EPOLLHUP | EPOLLERR))
                gone = 1;
            if (gone) {
                c->closing = 1;
                if (c->busy) {
                    /* its query is still out: stop watching, free on return */
                    epoll_ctl(w->ep, EPOLL_CTL_DEL, c->fd, NULL);
                    c->detached = 1;
                    continue;
                }
                c->out.len = c->out_off = 0;
            }
            settle(c);
        }
    }
    return NULL;
}

static int env_int(const char *name, int def) {
    const char *v = getenv(name);
    int n = v ? atoi(v) : 0;
    return n > 0 ? n : def;
}

int main(void) {
    DB_URL = getenv("DATABASE_URL");
    if (!DB_URL) {
        fprintf(stderr, "DATABASE_URL is not set\n");
        return 1;
    }
    cpu_set_t set;
    CPU_ZERO(&set);
    int cpus = sched_getaffinity(0, sizeof set, &set) == 0 ? CPU_COUNT(&set) : 1;
    WORKERS = env_int("WORKERS", cpus);
    PORT = env_int("PORT", 8080);
    POOL_TOTAL = env_int("DB_POOL_TOTAL", 64);
    signal(SIGPIPE, SIG_IGN);
    pthread_t *threads = calloc((size_t)WORKERS, sizeof *threads);
    for (int i = 0; i < WORKERS; i++) {
        worker_t *w = calloc(1, sizeof *w);
        w->ndb = (POOL_TOTAL + WORKERS - 1) / WORKERS;
        w->db = calloc((size_t)w->ndb, sizeof *w->db);
        pthread_create(&threads[i], NULL, worker_main, w);
    }
    printf("listening on %d\n", PORT);
    fflush(stdout);
    for (int i = 0; i < WORKERS; i++) pthread_join(threads[i], NULL);
    return 0;
}
