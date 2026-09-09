/* ---- chan[T]: bounded, thread-safe queue for 'spawn'ed tasks ---- */

typedef struct {
    unsigned char *buf;
    size_t elemsz;
    int cap, head, count, closed;
    int elem_is_ptr;
    pthread_mutex_t mu;
    sl_task *send_waiters, *send_waiters_tail; /* Tier 11 fourth slice:
        tasks parked waiting for buffer space, oldest first -- replaces
        the old not_full condvar. A plain singly-linked list via
        sl_task.next (push-to-tail/pop-from-head): a task is never on
        a channel's wait list and the run queue at the same time, so
        reusing that field is safe. */
    sl_task *recv_waiters, *recv_waiters_tail; /* same, for tasks
        parked waiting for data -- replaces the old not_empty condvar */
} sl_chan;

static void sl_gc_trace_chan(void *p, void (*mark)(void *)) {
    sl_chan *c = (sl_chan *)p;
    if (!c->buf) return;
    mark(c->buf);
    if (!c->elem_is_ptr) return;
    for (int i = 0; i < c->cap; i++)
        mark(*(void **)(c->buf + (size_t)i * c->elemsz));
}

static sl_chan *sl_chan_new(size_t elemsz, int cap, int elem_is_ptr) {
    if (cap < 1) cap = 1;
    sl_chan *c = (sl_chan *)sl_gc_alloc(sizeof(sl_chan), sl_gc_trace_chan);
    c->buf = (unsigned char *)sl_gc_alloc(elemsz * (size_t)cap, NULL);
    c->elemsz = elemsz;
    c->cap = cap;
    c->head = 0;
    c->count = 0;
    c->closed = 0;
    c->elem_is_ptr = elem_is_ptr;
    pthread_mutex_init(&c->mu, NULL);
    return c;
}

static void sl_chan_wl_push(sl_task **head, sl_task **tail, sl_task *t) {
    t->next = NULL;
    if (*tail) (*tail)->next = t; else *head = t;
    *tail = t;
}
static sl_task *sl_chan_wl_pop(sl_task **head, sl_task **tail) {
    sl_task *t = *head;
    if (t) { *head = t->next; if (!*head) *tail = NULL; }
    return t;
}

/* Tier 11 fourth slice: chan_send/chan_recv now PARK a blocked task
 * (sl_task_park/sl_task_resume, runtime_pool.c) instead of blocking
 * the OS thread on a condvar -- the worker that was running the
 * blocked task goes back to servicing the run queue instead of
 * sitting idle. A woken waiter re-locks c->mu and re-checks the loop
 * condition itself, exactly like the old condvar-signal-then-
 * recheck did -- it is never handed a value directly, just told a
 * value (or a close) MIGHT now be available. No GC-checkin
 * bookkeeping is needed in this loop anymore either: a parked task
 * holds no OS thread hostage at all (unlike the old blocked-condvar
 * model), so it can never make the collector's quiescence wait wait
 * on it -- sl_task_park itself does not call sl_rt_gc_checkin(); the
 * very next checkin the now-freed OS thread reaches is
 * sl_worker_run_loop's own, immediately after re-entering its loop.
 * See the Tier 11 plan for the full design and the two critical bugs
 * (a lost-wakeup race, and main()'s own top-level task having no
 * dispatch loop to resume into) a dedicated review pass found before
 * any of this was implemented. */
static void sl_chan_send(sl_chan *c, const void *val) {
    /* Tier 11 eighth slice: bracketed entry-to-every-return -- NOT
     * just around sl_task_park's own internal body (already covered
     * there). sl_chan_wl_push below writes sl_rt_current_task->next to
     * link into c's OWN wait list, then sl_task_park is called to
     * actually suspend -- between those two steps the task is still
     * genuinely running, and an async signal landing in that window
     * would redirect it through the trampoline -> sl_preempt_yield ->
     * sl_task_yield_now -> sl_worker_after_switch, which pushes the
     * SAME task onto sl_global_runq by overwriting the very ->next
     * link this function just set for c's wait list -- corrupting
     * whichever list loses the race (the classic sl_task.next-is-
     * shared-across-exactly-one-list-at-a-time invariant every other
     * user of it, sl_task_park included, already depends on). Found by
     * tracing concurrent_compute's own chan_recv-in-a-loop collection
     * pattern -- see sl_chan_recv's identical bracket below, the far
     * more heavily-exercised half of this pair in that workload. */
    sl_rt_preempt_disable();
    pthread_mutex_lock(&c->mu);
    while (c->count == c->cap && !c->closed) {
        /* sl_rt_cur(), NOT a raw sl_rt_current_task read. The bracket
         * this function opened makes a raw read safe against ASYNC
         * preemption, which is what that exemption was written for --
         * but it says nothing about the migration sl_task_park performs
         * ITSELF. park is a context switch: the task resumes on
         * whichever worker dequeues it, so on the second and later trips
         * round this loop a compiler that cached the thread-affine
         * address of sl_rt_current_task before the park reads the OLD
         * worker's slot -- which by then names whatever task that worker
         * is now running. Confirmed at -O2, not theorised: comparing the
         * raw read against a value captured before the park trips
         * immediately. The consequence is that a completely unrelated,
         * currently-RUNNING task gets pushed onto this channel's wait
         * list, later popped and resumed while it is running, pushed
         * onto a run queue it is already off, and finally freed by
         * sl_worker_after_switch with that stray queue link still live --
         * the heap-use-after-free ASan reports at -O2. */
        sl_chan_wl_push(&c->send_waiters, &c->send_waiters_tail, sl_rt_cur());
        sl_task_park(&c->mu); /* leaves c->mu locked across the switch --
            see sl_task_park's own comment (runtime_pool.c) for why */
        pthread_mutex_lock(&c->mu); /* re-acquire before re-checking */
    }
    if (c->closed) {
        pthread_mutex_unlock(&c->mu);
        sl_rt_preempt_enable();
        sl_rt_error("send on closed channel", 0, 0);
        return;
    }
    int tail = (c->head + c->count) % c->cap;
    memcpy(c->buf + (size_t)tail * c->elemsz, val, c->elemsz);
    c->count++;
    if (c->recv_waiters) {
        sl_task *w = sl_chan_wl_pop(&c->recv_waiters, &c->recv_waiters_tail);
        sl_task_resume(w);
    }
    pthread_mutex_unlock(&c->mu);
    sl_rt_preempt_enable();
}

/* returns 1 with *out populated, or 0 if closed and drained empty */
static int sl_chan_recv(sl_chan *c, void *out) {
    /* Tier 11 eighth slice: same bracket, same reason, as
     * sl_chan_send's own comment above -- entry-to-every-return, not
     * just sl_task_park's own internal coverage. This is the far more
     * heavily-exercised half of the pair for a producer/consumer
     * workload like concurrent_compute's own results-collection loop
     * (one long-lived task calling chan_recv in a loop, parking and
     * resuming across many different, real pool-worker OS threads over
     * its lifetime -- each resume makes it a live async-preemption
     * target again, regardless of which thread first ran it) --
     * root-caused directly to a real crash (sl_gc_collect SEGV on a
     * tiny, garbage address, from the run queue's own ->next chain
     * having been corrupted by exactly this unbracketed window) before
     * this fix. */
    sl_rt_preempt_disable();
    pthread_mutex_lock(&c->mu);
    while (c->count == 0 && !c->closed) {
        /* sl_rt_cur(), not a raw read -- see sl_chan_send's own copy of
         * this loop for the full reasoning. Same hazard, same fix. */
        sl_chan_wl_push(&c->recv_waiters, &c->recv_waiters_tail, sl_rt_cur());
        sl_task_park(&c->mu);
        pthread_mutex_lock(&c->mu);
    }
    if (c->count == 0) {
        pthread_mutex_unlock(&c->mu);
        sl_rt_preempt_enable();
        return 0;
    }
    memcpy(out, c->buf + (size_t)c->head * c->elemsz, c->elemsz);
    c->head = (c->head + 1) % c->cap;
    c->count--;
    if (c->send_waiters) {
        sl_task *w = sl_chan_wl_pop(&c->send_waiters, &c->send_waiters_tail);
        sl_task_resume(w);
    }
    pthread_mutex_unlock(&c->mu);
    sl_rt_preempt_enable();
    return 1;
}

static void sl_chan_close(sl_chan *c) {
    pthread_mutex_lock(&c->mu);
    c->closed = 1;
    sl_task *w;
    while ((w = sl_chan_wl_pop(&c->recv_waiters, &c->recv_waiters_tail)))
        sl_task_resume(w);
    while ((w = sl_chan_wl_pop(&c->send_waiters, &c->send_waiters_tail)))
        sl_task_resume(w);
    pthread_mutex_unlock(&c->mu);
}

/* ---- bytes: length-prefixed, binary-safe sequences ---- */

typedef struct { long long len; unsigned char *ptr; } sl_bytes;

static void sl_gc_trace_bytes(void *p, void (*mark)(void *)) {
    mark(((sl_bytes *)p)->ptr);
}

static sl_bytes *sl_bytes_new(const unsigned char *p, long long n) {
    sl_bytes *b = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes), sl_gc_trace_bytes);
    b->len = n;
    b->ptr = (unsigned char *)sl_gc_alloc((size_t)(n > 0 ? n : 1), NULL);
    if (n > 0) memcpy(b->ptr, p, (size_t)n);
    return b;
}

static sl_bytes sl_bytes_static(const unsigned char *p, long long n) {
    sl_bytes b;
    b.len = n;
    b.ptr = (unsigned char *)p;
    return b;
}

static int sl_bytes_at(sl_bytes *b, long long i, const char *at) {
    if (i < 0 || i >= b->len)
        sl_rt_error_at("byte index out of bounds", i, b->len, at);
    return (int)b->ptr[i];
}

static void sl_bytes_set(sl_bytes *b, long long i, unsigned char v) {
    if (i < 0 || i >= b->len)
        sl_rt_error("byte index out of bounds", i, b->len);
    b->ptr[i] = v;
}

static sl_bytes *sl_bytes_concat(sl_bytes *a, sl_bytes *b) {
    sl_bytes *r = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes), sl_gc_trace_bytes);
    r->len = a->len + b->len;
    r->ptr = (unsigned char *)sl_gc_alloc((size_t)(r->len > 0 ? r->len : 1), NULL);
    if (a->len) memcpy(r->ptr, a->ptr, (size_t)a->len);
    if (b->len) memcpy(r->ptr + a->len, b->ptr, (size_t)b->len);
    return r;
}

static sl_bytes *sl_bytes_slice(sl_bytes *b, long long s, long long e) {
    if (s < 0) s = 0;
    if (e > b->len) e = b->len;
    if (e < s) e = s;
    sl_bytes *r = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes), sl_gc_trace_bytes);
    r->len = e - s;
    r->ptr = (unsigned char *)sl_gc_alloc((size_t)(r->len > 0 ? r->len : 1), NULL);
    if (r->len) memcpy(r->ptr, b->ptr + s, (size_t)r->len);
    return r;
}

static int sl_bytes_eq(sl_bytes *a, sl_bytes *b) {
    if (a->len != b->len) return 0;
    return a->len == 0 || memcmp(a->ptr, b->ptr, (size_t)a->len) == 0;
}

static char *sl_str_from_bytes(sl_bytes *b) {
    char *p = (char *)sl_gc_alloc((size_t)b->len + 1, NULL);
    if (b->len) memcpy(p, b->ptr, (size_t)b->len);
    p[b->len] = 0;
    return p;
}

static sl_bytes *sl_bytes_from_str(const char *s) {
    return sl_bytes_new((const unsigned char *)s, (long long)strlen(s));
}

static sl_bytes *sl_to_le(unsigned long long v) {
    unsigned char buf[8];
    for (int i = 0; i < 8; i++)
        buf[i] = (unsigned char)((v >> (8 * i)) & 0xff);
    return sl_bytes_new(buf, 8);
}

static sl_bytes *sl_to_be(unsigned long long v) {
    unsigned char buf[8];
    for (int i = 0; i < 8; i++)
        buf[7 - i] = (unsigned char)((v >> (8 * i)) & 0xff);
    return sl_bytes_new(buf, 8);
}

static unsigned long long sl_from_le(sl_bytes *b) {
    if (b->len != 8)
        sl_rt_error("from_le expects exactly 8 bytes", b->len, 8);
    unsigned long long v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | b->ptr[i];
    return v;
}

static unsigned long long sl_from_be(sl_bytes *b) {
    if (b->len != 8)
        sl_rt_error("from_be expects exactly 8 bytes", b->len, 8);
    unsigned long long v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | b->ptr[i];
    return v;
}

/* ---- growable arrays over GC memory ---- */

typedef struct {
    long long len, cap;
    unsigned char *data; /* elements stored inline */
    size_t esz;          /* element size in bytes */
    int elem_is_ptr;
} sl_arr;

static void sl_gc_trace_arr(void *p, void (*mark)(void *)) {
    sl_arr *a = (sl_arr *)p;
    if (!a->data) return;
    mark(a->data);
    if (!a->elem_is_ptr) return;
    for (long long i = 0; i < a->len; i++)
        mark(*(void **)(a->data + (size_t)i * a->esz));
}

static sl_arr *sl_arr_new(size_t esz, int elem_is_ptr) {
    sl_arr *a = (sl_arr *)sl_gc_alloc(sizeof(sl_arr), sl_gc_trace_arr);
    a->len = 0;
    a->cap = 0;
    a->data = NULL;
    a->esz = esz;
    a->elem_is_ptr = elem_is_ptr;
    return a;
}

static void sl_arr_reserve(sl_arr *a, long long need) {
    if (need <= a->cap) return;
    long long cap = a->cap ? a->cap : 8;
    while (cap < need) cap *= 2;
    a->data = (unsigned char *)sl_gc_realloc(a->data, (size_t)cap * a->esz);
    a->cap = cap;
}

static void *sl_arr_get(sl_arr *a, long long i, size_t esz, const char *at) {
    if (esz != a->esz)
        sl_rt_error("internal: element size mismatch", (long long)esz,
                    (long long)a->esz);
    if (i < 0 || i >= a->len)
        sl_rt_error_at("list index out of bounds", i, a->len, at);
    return a->data + (size_t)i * esz;
}

static void *sl_arr_at(sl_arr *a, long long i, size_t esz) {
    return a->data + (size_t)i * esz;
}

static void sl_arr_push(sl_arr *a, void *val, size_t esz) {
    if (esz != a->esz)
        sl_rt_error("internal: element size mismatch", (long long)esz,
                    (long long)a->esz);
    sl_arr_reserve(a, a->len + 1);
    memcpy(a->data + (size_t)a->len * esz, val, esz);
    a->len++;
}

static void *sl_arr_pop(sl_arr *a, size_t esz) {
    if (esz != a->esz)
        sl_rt_error("internal: element size mismatch", (long long)esz,
                    (long long)a->esz);
    if (a->len == 0) sl_rt_error("pop from empty list", 0, 0);
    a->len--;
    return a->data + (size_t)a->len * esz;
}

static sl_arr *sl_arr_from(void *buf, long long n, size_t esz, int elem_is_ptr) {
    sl_arr *a = sl_arr_new(esz, elem_is_ptr);
    sl_arr_reserve(a, n);
    if (n > 0) memcpy(a->data, buf, (size_t)n * esz);
    a->len = n;
    return a;
}

static sl_arr *sl_arr_slice(sl_arr *a, long long s, long long e) {
    if (s < 0) s = 0;
    if (e > a->len) e = a->len;
    if (e < s) e = s;
    sl_arr *r = sl_arr_new(a->esz, a->elem_is_ptr);
    sl_arr_reserve(r, e - s);
    if (e > s)
        memcpy(r->data, a->data + (size_t)s * a->esz,
               (size_t)(e - s) * a->esz);
    r->len = e - s;
    return r;
}

static sl_arr *sl_arr_concat(sl_arr *a, sl_arr *b) {
    if (a->esz != b->esz)
        sl_rt_error("cannot concatenate lists of different element types",
                    (long long)a->esz, (long long)b->esz);
    sl_arr *r = sl_arr_new(a->esz, a->elem_is_ptr);
    sl_arr_reserve(r, a->len + b->len);
    if (a->len) memcpy(r->data, a->data, (size_t)a->len * a->esz);
    if (b->len)
        memcpy(r->data + (size_t)a->len * a->esz, b->data,
               (size_t)b->len * b->esz);
    r->len = a->len + b->len;
    return r;
}

/* ---- maps: open-addressing hash tables over GC memory ---- */

typedef struct {
    long long count, cap;
    size_t ksz, vsz;
    int kstr;            /* keys are NUL-terminated strings */
    int key_is_ptr, val_is_ptr;
    unsigned char *keys; /* cap slots */
    unsigned char *vals; /* cap slots */
    unsigned char *state;/* 1 = occupied */
    long long *order;    /* occupied slot indices, insertion order */
} sl_map;

static void sl_gc_trace_map(void *p, void (*mark)(void *)) {
    sl_map *m = (sl_map *)p;
    if (m->keys) mark(m->keys);
    if (m->vals) mark(m->vals);
    if (m->state) mark(m->state);
    if (m->order) mark(m->order);
    if (!m->key_is_ptr && !m->val_is_ptr) return;
    for (long long i = 0; i < m->count; i++) {
        long long slot = m->order[i];
        if (m->key_is_ptr)
            mark(*(void **)(m->keys + (size_t)slot * m->ksz));
        if (m->val_is_ptr)
            mark(*(void **)(m->vals + (size_t)slot * m->vsz));
    }
}

static unsigned long long sl_hash_bytes(const unsigned char *p, size_t n) {
    unsigned long long h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

static unsigned long long sl_hash_str(const char *s) {
    unsigned long long h = 1469598103934665603ULL;
    for (; *s; s++) { h ^= (unsigned char)*s; h *= 1099511628211ULL; }
    return h;
}

static sl_map *sl_map_new(size_t ksz, size_t vsz, int kstr,
                           int key_is_ptr, int val_is_ptr) {
    sl_map *m = (sl_map *)sl_gc_alloc(sizeof(sl_map), sl_gc_trace_map);
    m->count = 0;
    m->cap = 8;
    m->ksz = ksz;
    m->vsz = vsz;
    m->kstr = kstr;
    m->key_is_ptr = key_is_ptr;
    m->val_is_ptr = val_is_ptr;
    m->keys = (unsigned char *)sl_gc_alloc(8 * ksz, NULL);
    m->vals = (unsigned char *)sl_gc_alloc(8 * vsz, NULL);
    m->state = (unsigned char *)sl_gc_alloc(8, NULL);
    m->order = (long long *)sl_gc_alloc(8 * sizeof(long long), NULL);
    return m;
}

/* Probe for a key: returns its slot if present, or -(slot)-1 for
 * the first empty slot where it could be inserted. */
static long long sl_map_probe(sl_map *m, const void *k,
                              unsigned long long h) {
    long long mask = m->cap - 1;
    long long i = (long long)(h & (unsigned long long)mask);
    for (;;) {
        if (!m->state[i])
            return -i - 1;
        void *kk = m->keys + (size_t)i * m->ksz;
        int eq = m->kstr
                    ? !strcmp(*(const char **)kk, *(const char *const *)k)
                    : memcmp(kk, k, m->ksz) == 0;
        if (eq)
            return i;
        i = (i + 1) & mask;
    }
}

static void sl_map_grow(sl_map *m) {
    /* Tier 11 eighth slice: bracketed entry-to-return -- ok/ov/oorder
     * below hold the OLD keys/vals/order buffers, which are STILL the
     * only live copies of every already-inserted key/value at the
     * moment they're captured, but become unreachable from m itself
     * the instant the very next line overwrites m->keys with a fresh
     * sl_gc_alloc'd buffer -- and there are three more such
     * reassignments right after it (m->vals/state/order), each
     * capable of setting sl_gc_collect_pending. Cooperative
     * preemption alone could never expose this (nothing in this
     * function or sl_gc_alloc calls sl_rt_gc_checkin, so a collection
     * could never actually land mid-sequence, only get pending), but
     * async preemption can suspend this task between any two of these
     * four allocs with no bracket to stop it -- and if a DIFFERENT
     * task then drives the actual collection through its own,
     * unrelated checkin while this one sits queued, ok/ov/oorder are
     * plain locals, not GC roots, and not necessarily rediscovered by
     * the conservative stack scan either (their true recorded values
     * only cover what this session directly verified, not every
     * variable in every hand-written runtime helper -- this bracket
     * closes the gap outright rather than depending on that). Root-
     * caused directly: concurrent_compute's own map[str]int-building
     * loop, caught live under lldb with a real, reproduced crash --
     * sl_hash_str(NULL) inside this function's own reinsertion loop,
     * meaning a PREVIOUSLY-inserted key had already been swept by the
     * time this grow tried to rehash it. */
    sl_rt_preempt_disable();
    long long old_cap = m->cap;
    unsigned char *ok = m->keys, *ov = m->vals;
    unsigned char *ost = m->state;
    long long ocount = m->count;
    long long *oorder = m->order;
    m->cap = old_cap * 2;
    m->count = 0;
    m->keys = (unsigned char *)sl_gc_alloc((size_t)m->cap * m->ksz, NULL);
    m->vals = (unsigned char *)sl_gc_alloc((size_t)m->cap * m->vsz, NULL);
    m->state = (unsigned char *)sl_gc_alloc((size_t)m->cap, NULL);
    m->order = (long long *)sl_gc_alloc((size_t)m->cap * sizeof(long long), NULL);
    (void)ost;
    /* reinsert in insertion order so iteration stays deterministic */
    for (long long i = 0; i < ocount; i++) {
        long long slot = oorder[i];
        void *k = ok + (size_t)slot * m->ksz;
        void *v = ov + (size_t)slot * m->vsz;
        unsigned long long h = m->kstr
                                  ? sl_hash_str(*(const char **)k)
                                  : sl_hash_bytes((const unsigned char *)k,
                                                  m->ksz);
        long long s = -sl_map_probe(m, k, h) - 1;
        memcpy(m->keys + (size_t)s * m->ksz, k, m->ksz);
        memcpy(m->vals + (size_t)s * m->vsz, v, m->vsz);
        m->state[s] = 1;
        m->order[m->count++] = s;
    }
    sl_rt_preempt_enable();
}

static void sl_map_put(sl_map *m, const void *k, const void *v) {
    /* Tier 11 eighth slice: bracketed entry-to-every-return -- not
     * just sl_map_grow's own internal bracket (which only covers
     * ITS OWN four-alloc sequence). This closes the whole family of
     * the same class of bug at once, rather than continuing to chase
     * individual sub-windows within it: between sl_map_probe finding
     * an empty slot and this function actually committing it
     * (m->state[s]=1, m->order[m->count++]=s), an async preemption
     * has nothing structurally wrong to exploit on its own (m isn't
     * shared across tasks), but this function is exactly the kind of
     * multi-step, GC-adjacent sequence this slice's own audit
     * (sl_map_grow) found a real bug in -- bracketing the whole
     * caller, not just the one nested call that already needed it,
     * is the same discipline sl_gc_alloc/sl_task_park/every other
     * fully-bracketed function in this codebase already follows. */
    sl_rt_preempt_disable();
    unsigned long long h = m->kstr
                              ? sl_hash_str(*(const char *const *)k)
                              : sl_hash_bytes((const unsigned char *)k,
                                              m->ksz);
    if ((m->count + 1) * 4 >= m->cap * 3)
        sl_map_grow(m);
    long long s = sl_map_probe(m, k, h);
    if (s >= 0) {
        memcpy(m->vals + (size_t)s * m->vsz, v, m->vsz);
        sl_rt_preempt_enable();
        return;
    }
    s = -s - 1;
    memcpy(m->keys + (size_t)s * m->ksz, k, m->ksz);
    memcpy(m->vals + (size_t)s * m->vsz, v, m->vsz);
    m->state[s] = 1;
    m->order[m->count++] = s;
    sl_rt_preempt_enable();
}

static void *sl_map_get(sl_map *m, const void *k) {
    unsigned long long h = m->kstr
                              ? sl_hash_str(*(const char *const *)k)
                              : sl_hash_bytes((const unsigned char *)k,
                                              m->ksz);
    long long s = sl_map_probe(m, k, h);
    if (s < 0)
        return NULL;
    return m->vals + (size_t)s * m->vsz;
}

static int sl_map_has(sl_map *m, const void *k) {
    return sl_map_get(m, k) != NULL;
}

static void sl_map_del(sl_map *m, const void *k) {
    /* Tier 11 eighth slice: bracketed entry-to-every-return -- same
     * reasoning as sl_map_put's own bracket just above. */
    sl_rt_preempt_disable();
    unsigned long long h = m->kstr
                              ? sl_hash_str(*(const char *const *)k)
                              : sl_hash_bytes((const unsigned char *)k,
                                              m->ksz);
    long long s = sl_map_probe(m, k, h);
    if (s < 0) {
        sl_rt_preempt_enable();
        return;
    }
    m->state[s] = 0;
    for (long long i = 0; i < m->count; i++) {
        if (m->order[i] == s) {
            memmove(m->order + i, m->order + i + 1,
                    (size_t)(m->count - i - 1) * sizeof(long long));
            break;
        }
    }
    m->count--;
    sl_rt_preempt_enable();
}

/* ---- strings ---- */

static char *sl_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = (char *)sl_gc_alloc(n, NULL);
    memcpy(p, s, n);
    return p;
}

static char *sl_str_concat(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    char *p = (char *)sl_gc_alloc(la + lb + 1, NULL);
    memcpy(p, a, la);
    memcpy(p + la, b, lb);
    p[la + lb] = 0;
    return p;
}

/* Tier 11 eighth slice: sl_str_from_int/_uint/_float's own snprintf
 * call (BEFORE sl_strdup, unlike sl_strdup's own internal calls,
 * which sl_gc_alloc's own bracket already covers) is bracketed
 * directly -- snprintf's libc implementation touches locale state
 * behind its own internal, thread-affine os_unfair_lock, exactly
 * the same vulnerability class as malloc/free (found the same way:
 * sl_str_from_int specifically crashed cc_real_preempt under real
 * load, os_unfair_lock's own 'recursive lock' abort surfacing on a
 * LATER, unrelated snprintf call on the same OS thread after an
 * earlier one was interrupted mid-call and abandoned by a task
 * migrating to a different worker). */
static char *sl_str_from_int(long long v) {
    sl_rt_preempt_disable();
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", v);
    sl_rt_preempt_enable();
    return sl_strdup(buf);
}

static char *sl_str_from_uint(unsigned long long v) {
    sl_rt_preempt_disable();
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", v);
    sl_rt_preempt_enable();
    return sl_strdup(buf);
}

static char *sl_str_from_float(double v) {
    sl_rt_preempt_disable();
    char buf[64];
    snprintf(buf, sizeof(buf), "%g", v);
    sl_rt_preempt_enable();
    return sl_strdup(buf);
}

static char *sl_str_from_bool(bool v) {
    return sl_strdup(v ? "true" : "false");
}

static char *sl_str_from_fault(sl_fault f) {
    const char *d = f.detail ? f.detail : "";
    const char *op = f.op ? f.op : "";
    if (!op[0] && f.code == 0)
        return sl_strdup(d);
    sl_rt_preempt_disable();
    char buf[160];
    if (op[0] && f.code != 0)
        snprintf(buf, sizeof(buf), "%s %s (code %d)", op, d, f.code);
    else if (op[0])
        snprintf(buf, sizeof(buf), "%s %s", op, d);
    else
        snprintf(buf, sizeof(buf), "%s (code %d)", d, f.code);
    sl_rt_preempt_enable();
    return sl_strdup(buf);
}

static void sl_fault_print(sl_fault f, int newline) {
    char *s = sl_str_from_fault(f);
    if (newline)
        puts(s);
    else
        fputs(s, stdout);
}

typedef struct {
    int done;
    int panicked;
    char *err;
    unsigned char *val;
    size_t valsz;
    int val_is_ptr;
    sl_task *waiter;
    pthread_mutex_t mu;
} sl_join;

static void sl_gc_trace_join(void *p, void (*mark)(void *)) {
    sl_join *j = (sl_join *)p;
    mark(j->err);
    mark(j->val);
    if (j->val_is_ptr && j->done && !j->panicked)
        mark(*(void **)j->val);
}

static sl_join *sl_join_new(size_t valsz, int val_is_ptr) {
    sl_join *j = (sl_join *)sl_gc_alloc(sizeof(sl_join), sl_gc_trace_join);
    j->valsz = valsz;
    j->val_is_ptr = val_is_ptr;
    j->val = (unsigned char *)sl_gc_alloc(valsz > 0 ? valsz : 1, NULL);
    pthread_mutex_init(&j->mu, NULL);
    return j;
}

static void sl_join_wake(sl_join *j) {
    if (j->waiter) {
        sl_task *w = j->waiter;
        j->waiter = NULL;
        sl_task_resume(w);
    }
}

static void sl_join_finish(sl_join *j, const void *val) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&j->mu);
    if (!j->done) {
        if (val && j->valsz)
            memcpy(j->val, val, j->valsz);
        j->done = 1;
        sl_join_wake(j);
    }
    pthread_mutex_unlock(&j->mu);
    sl_rt_preempt_enable();
}

static void sl_join_fail(void *jp, const char *msg) {
    sl_join *j = (sl_join *)jp;
    sl_rt_preempt_disable();
    pthread_mutex_lock(&j->mu);
    if (!j->done) {
        j->panicked = 1;
        j->err = sl_strdup(msg);
        j->done = 1;
        sl_join_wake(j);
    }
    pthread_mutex_unlock(&j->mu);
    sl_rt_preempt_enable();
}

static int sl_join_wait(sl_join *j, void *out) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&j->mu);
    while (!j->done) {
        j->waiter = sl_rt_cur();
        sl_task_park(&j->mu);
        pthread_mutex_lock(&j->mu);
    }
    int ok = !j->panicked;
    if (ok && out && j->valsz)
        memcpy(out, j->val, j->valsz);
    pthread_mutex_unlock(&j->mu);
    sl_rt_preempt_enable();
    return ok;
}

static char *sl_join_err(sl_join *j) {
    return j->err ? j->err : sl_strdup("task panicked");
}

/* ---- user program ---- */

