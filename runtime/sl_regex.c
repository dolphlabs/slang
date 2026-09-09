/* Runtime for the 'regex' native package: a Thompson NFA / Pike VM.
 *
 * No external dependency -- this is slang's own engine, deliberately,
 * so a program that matches text stays as dependency-free as a plain
 * TCP one. The tradeoff is the RE2/Go one: NO backreferences and NO
 * lookaround, ever. They are not missing features, they are the price
 * of the guarantee below.
 *
 * GUARANTEE: matching is O(len(subject) * len(program)) with a hard
 * ceiling on both, and no backtracking anywhere. A pattern like
 * (a+)+$ -- the classic ReDoS bomb that makes a backtracking engine
 * take exponential time -- runs in the same linear time here as any
 * other pattern. That matters because this is a server language and
 * patterns and subjects both arrive from the network.
 *
 * Shape follows sl_sql.c: compile returns an opaque rawptr handle in
 * a result[rawptr, str], every compile failure carries a descriptive
 * message ("missing )", "nothing to repeat at offset 3"), and the
 * handle is malloc'd, never GC-owned -- released by regex.free.
 * Subjects are always matched with an explicit length, so a `bytes`
 * containing NUL matches correctly rather than being cut short.
 *
 * STACK: split deliberately, because the two phases have very
 * different cost and very different frequency.
 *
 *   MATCHING (is_match/find -- the per-request hot path) needs NO
 *   stack growth and runs inside the default 8KB task stack. The VM's
 *   epsilon closure uses an explicit heap stack instead of C
 *   recursion precisely so this stays true no matter how big the
 *   program is. Keep it that way: it is what makes regex cheap to use
 *   from a spawned task per connection, and it is why matching costs
 *   no RSS beyond the compiled program.
 *
 *   COMPILING calls sl_rt_need_stack once. Parsing is four mutually
 *   recursive functions (alt/cat/repeat/atom) plus a recursive
 *   emitter, so nesting costs real C frames -- measured at ~160 bytes
 *   per level, which overflowed the 8KB stack somewhere between 40
 *   and 60 levels of "(?:" and aborted. SL_RX_MAX_DEPTH caps nesting
 *   at 100, so the ceiling is ~16KB of parse frames plus the
 *   emitter's own; SL_RX_COMPILE_STACK carries ~2x margin over that.
 *   Compile is normally once per pattern at startup, so this is paid
 *   once and never on the request path. */

#include <stdint.h>

/* ---- limits (all failures are descriptive, never a crash) -------- */
#define SL_RX_MAX_INSTS   4096   /* program ceiling; bounds match cost */
#define SL_RX_MAX_DEPTH    100   /* parser nesting; bounds parse recursion */
#define SL_RX_MAX_GROUPS    32
#define SL_RX_MAX_REPEAT  1000   /* {n,m} expansion bound */
/* Task stack the COMPILER (not the matcher) needs; see the STACK note
 * above for the measurement this is derived from. Applied via
 * sl_rt_need_stack, the same mechanism sl_tls.c and sl_sql.c use. */
#define SL_RX_COMPILE_STACK 65536
/* Concurrent matchers on ONE compiled regex that stay allocation-free.
 * Blocks are allocated on demand, so this is a ceiling, not a cost. */
#define SL_RX_SLOTS 8

/* ---- allocation ---------------------------------------------------
 * Every allocation in this file goes through these, and they exist
 * for one reason: malloc's own internal lock is owned by an OS
 * thread. A green task async-preempted inside malloc can resume on a
 * DIFFERENT pool worker, and the unlock then aborts the process with
 * _os_unfair_lock_unowned_abort -- no message, no slang-level
 * diagnostic, roughly 1 run in 100 under 16 concurrent matchers.
 *
 * This is the same class of bug as SQLite's thread-owner-tracked
 * mutexes (sl_sql.c) and the same fix the rest of the runtime already
 * uses: sl_gc_alloc_fin opens with sl_rt_preempt_disable around its
 * malloc, and sl_crypto.c brackets its own. Nested brackets are fine
 * -- preempt_disable_depth is a counter, not a flag. */
static void *sl_rx_malloc(size_t n) {
    sl_rt_preempt_disable();
    void *p = malloc(n);
    sl_rt_preempt_enable();
    return p;
}

static void *sl_rx_calloc(size_t n, size_t sz) {
    sl_rt_preempt_disable();
    void *p = calloc(n, sz);
    sl_rt_preempt_enable();
    return p;
}

static void *sl_rx_realloc(void *old, size_t n) {
    sl_rt_preempt_disable();
    void *p = realloc(old, n);
    sl_rt_preempt_enable();
    return p;
}

static void sl_rx_free(void *p) {
    if (!p) return;
    sl_rt_preempt_disable();
    free(p);
    sl_rt_preempt_enable();
}

/* ---- instructions ------------------------------------------------ */
enum {
    RX_BYTE,   /* match one literal byte arg */
    RX_CLASS,  /* match a byte in bitmap cls */
    RX_ANY,    /* match any byte except '\n' */
    RX_ANYNL,  /* match any byte at all */
    RX_SPLIT,  /* try x first, then y (priority = leftmost-first) */
    RX_JMP,
    RX_SAVE,   /* record current offset into capture slot arg */
    RX_ASSERT, /* zero-width: see RXA_* */
    RX_MATCH
};

enum { RXA_BOL, RXA_EOL, RXA_BOT, RXA_EOT, RXA_WORDB, RXA_NWORDB };

typedef struct {
    uint8_t op;
    uint8_t arg;    /* byte value / save slot / assert kind */
    int32_t cls;    /* index into class table, or -1 */
    int32_t x, y;   /* jump targets */
} sl_rx_inst;

typedef struct {
    unsigned char bits[32]; /* 256-bit membership bitmap */
} sl_rx_class;

typedef struct {
    sl_rx_inst *prog;
    int nprog;
    sl_rx_class *classes;
    int ncls;
    int ngroups;    /* capturing groups, excluding whole-match slot 0 */
    int nslots;     /* 2 * (ngroups + 1) */
    /* Reusable scratch blocks, each claimed with its own atomic flag.
     * A match needs O(nprog * nslots) working memory; allocating that
     * per call is correct but costs a malloc/free pair on every match,
     * which showed up directly as throughput (16 tasks sharing one
     * regex lost ~30%, since only one could ever win a single slot).
     *
     * Slots are allocated LAZILY, so a single-threaded user still only
     * ever holds one block and pays no RSS for concurrency it does not
     * use, while up to SL_RX_SLOTS concurrent matchers run allocation-
     * free in steady state. Past that it falls back to a private
     * malloc rather than blocking -- correctness never depends on
     * winning a slot. Only the flag holder touches its own slot. */
    void *scratch[SL_RX_SLOTS];
    _Atomic int scratch_busy[SL_RX_SLOTS];
    /* first-byte prefilter: when every match must start with one of
     * these bytes, find() can memchr past everything else. */
    int has_first;
    unsigned char first[32];
    int anchored_start; /* pattern begins with ^ / \A */
} sl_rx;

/* ---- byte-class helpers ------------------------------------------ */

static void sl_rx_cls_set(sl_rx_class *c, int b) {
    c->bits[(b & 0xff) >> 3] |= (unsigned char)(1u << (b & 7));
}
static int sl_rx_cls_has(const sl_rx_class *c, int b) {
    return (c->bits[(b & 0xff) >> 3] >> (b & 7)) & 1;
}
static void sl_rx_cls_negate(sl_rx_class *c) {
    for (int i = 0; i < 32; i++)
        c->bits[i] = (unsigned char)~c->bits[i];
}
static int sl_rx_is_word(int b) {
    return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') ||
           (b >= '0' && b <= '9') || b == '_';
}

/* ---- AST ---------------------------------------------------------
 * Parsed to a tree first, then emitted. A tree (rather than emitting
 * straight through) is what makes {n,m} expansion and correct
 * quantifier precedence straightforward. */

enum { N_EMPTY, N_BYTE, N_CLASS, N_ANY, N_ANYNL, N_CAT, N_ALT,
       N_STAR, N_PLUS, N_QUEST, N_REP, N_GROUP, N_ASSERT };

typedef struct sl_rx_node {
    int kind;
    int val;                 /* byte / assert kind / class index / group # */
    int greedy;
    int rmin, rmax;          /* N_REP; rmax < 0 means unbounded */
    struct sl_rx_node *a, *b;
} sl_rx_node;

typedef struct {
    const char *p;           /* pattern */
    size_t n, i;             /* length, cursor */
    int depth;
    int ngroups;
    sl_rx_class *cls;        /* growable class table */
    int ncls, clscap;
    sl_rx_node **pool;       /* every node, for one-shot free */
    int npool, poolcap;
    char err[160];
} sl_rx_parser;

static void sl_rx_fail(sl_rx_parser *ps, const char *msg) {
    if (!ps->err[0])
        snprintf(ps->err, sizeof(ps->err), "%s at offset %zu", msg, ps->i);
}

static sl_rx_node *sl_rx_node_new(sl_rx_parser *ps, int kind) {
    if (ps->npool == ps->poolcap) {
        int cap = ps->poolcap ? ps->poolcap * 2 : 32;
        sl_rx_node **np = (sl_rx_node **)sl_rx_realloc(ps->pool,
                                                 (size_t)cap * sizeof(*np));
        if (!np) { sl_rx_fail(ps, "out of memory"); return NULL; }
        ps->pool = np; ps->poolcap = cap;
    }
    sl_rx_node *nd = (sl_rx_node *)sl_rx_calloc(1, sizeof(*nd));
    if (!nd) { sl_rx_fail(ps, "out of memory"); return NULL; }
    nd->kind = kind; nd->greedy = 1; nd->val = -1; nd->rmax = -1;
    ps->pool[ps->npool++] = nd;
    return nd;
}

static int sl_rx_cls_add(sl_rx_parser *ps, const sl_rx_class *c) {
    if (ps->ncls == ps->clscap) {
        int cap = ps->clscap ? ps->clscap * 2 : 8;
        sl_rx_class *nc = (sl_rx_class *)sl_rx_realloc(ps->cls,
                                                 (size_t)cap * sizeof(*nc));
        if (!nc) { sl_rx_fail(ps, "out of memory"); return -1; }
        ps->cls = nc; ps->clscap = cap;
    }
    ps->cls[ps->ncls] = *c;
    return ps->ncls++;
}

static sl_rx_node *sl_rx_parse_alt(sl_rx_parser *ps);

/* \d \w \s and friends, plus \xHH and the punctuation escapes. Returns
 * a node, or NULL with ps->err set. */
static sl_rx_node *sl_rx_escape(sl_rx_parser *ps) {
    if (ps->i >= ps->n) { sl_rx_fail(ps, "trailing backslash"); return NULL; }
    char c = ps->p[ps->i++];
    sl_rx_class k;
    memset(&k, 0, sizeof(k));
    int negate = 0;
    switch (c) {
    case 'd': case 'D':
        for (int b = '0'; b <= '9'; b++) sl_rx_cls_set(&k, b);
        negate = (c == 'D'); goto klass;
    case 'w': case 'W':
        for (int b = 0; b < 256; b++) if (sl_rx_is_word(b)) sl_rx_cls_set(&k, b);
        negate = (c == 'W'); goto klass;
    case 's': case 'S':
        sl_rx_cls_set(&k,' '); sl_rx_cls_set(&k,'\t'); sl_rx_cls_set(&k,'\n');
        sl_rx_cls_set(&k,'\r'); sl_rx_cls_set(&k,'\f'); sl_rx_cls_set(&k,'\v');
        negate = (c == 'S'); goto klass;
    case 'b': case 'B': {
        sl_rx_node *nd = sl_rx_node_new(ps, N_ASSERT);
        if (nd) nd->val = (c == 'b') ? RXA_WORDB : RXA_NWORDB;
        return nd; }
    case 'A': case 'z': {
        sl_rx_node *nd = sl_rx_node_new(ps, N_ASSERT);
        if (nd) nd->val = (c == 'A') ? RXA_BOT : RXA_EOT;
        return nd; }
    default: break;
    }
    { /* single-byte escapes */
        int v;
        switch (c) {
        case 'n': v = '\n'; break;  case 'r': v = '\r'; break;
        case 't': v = '\t'; break;  case 'f': v = '\f'; break;
        case 'v': v = '\v'; break;  case '0': v = 0;    break;
        case 'x': {
            if (ps->i + 1 >= ps->n) { sl_rx_fail(ps, "truncated \\x escape"); return NULL; }
            int hi = ps->p[ps->i], lo = ps->p[ps->i + 1], h = 0;
            for (int k2 = 0; k2 < 2; k2++) {
                int d = k2 ? lo : hi;
                if (d >= '0' && d <= '9') d -= '0';
                else if (d >= 'a' && d <= 'f') d = d - 'a' + 10;
                else if (d >= 'A' && d <= 'F') d = d - 'A' + 10;
                else { sl_rx_fail(ps, "bad hex in \\x escape"); return NULL; }
                h = h * 16 + d;
            }
            ps->i += 2; v = h; break; }
        default:
            /* punctuation escapes are literal; letters are reserved so a
             * typo like \q is an error rather than a silent literal q */
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
                sl_rx_fail(ps, "unsupported escape"); return NULL;
            }
            v = (unsigned char)c;
        }
        sl_rx_node *nd = sl_rx_node_new(ps, N_BYTE);
        if (nd) nd->val = v & 0xff;
        return nd;
    }
klass: {
        /* Straight complement, NUL included: subjects carry an explicit
         * length, so \x00 is an ordinary byte here and \D must match it
         * the same way it matches any other non-digit. */
        if (negate)
            sl_rx_cls_negate(&k);
        int idx = sl_rx_cls_add(ps, &k);
        if (idx < 0) return NULL;
        sl_rx_node *nd = sl_rx_node_new(ps, N_CLASS);
        if (nd) nd->val = idx;
        return nd;
    }
}

/* [abc], [^a-z], [\d_], [[:digit:]] */
static sl_rx_node *sl_rx_bracket(sl_rx_parser *ps) {
    sl_rx_class k;
    memset(&k, 0, sizeof(k));
    int neg = 0;
    if (ps->i < ps->n && ps->p[ps->i] == '^') { neg = 1; ps->i++; }
    int first = 1, any = 0;
    while (ps->i < ps->n && (ps->p[ps->i] != ']' || first)) {
        first = 0;
        /* POSIX [:name:] */
        if (ps->p[ps->i] == '[' && ps->i + 1 < ps->n && ps->p[ps->i+1] == ':') {
            const char *e = strstr(ps->p + ps->i + 2, ":]");
            if (e) {
                size_t len = (size_t)(e - (ps->p + ps->i + 2));
                char nm[16];
                if (len < sizeof(nm)) {
                    memcpy(nm, ps->p + ps->i + 2, len); nm[len] = 0;
                    int ok = 1;
                    for (int b = 0; b < 256; b++) {
                        int in;
                        if (!strcmp(nm,"digit")) in = (b>='0'&&b<='9');
                        else if (!strcmp(nm,"alpha")) in = ((b>='a'&&b<='z')||(b>='A'&&b<='Z'));
                        else if (!strcmp(nm,"alnum")) in = ((b>='a'&&b<='z')||(b>='A'&&b<='Z')||(b>='0'&&b<='9'));
                        else if (!strcmp(nm,"space")) in = (b==' '||b=='\t'||b=='\n'||b=='\r'||b=='\f'||b=='\v');
                        else if (!strcmp(nm,"upper")) in = (b>='A'&&b<='Z');
                        else if (!strcmp(nm,"lower")) in = (b>='a'&&b<='z');
                        else if (!strcmp(nm,"punct")) in = (b>33&&b<127&&!((b>='a'&&b<='z')||(b>='A'&&b<='Z')||(b>='0'&&b<='9')));
                        else if (!strcmp(nm,"xdigit")) in = ((b>='0'&&b<='9')||(b>='a'&&b<='f')||(b>='A'&&b<='F'));
                        else { ok = 0; break; }
                        if (in) sl_rx_cls_set(&k, b);
                    }
                    if (!ok) { sl_rx_fail(ps, "unknown POSIX class"); return NULL; }
                    ps->i = (size_t)(e - ps->p) + 2; any = 1; continue;
                }
            }
        }
        int lo;
        if (ps->p[ps->i] == '\\') {
            ps->i++;
            if (ps->i >= ps->n) { sl_rx_fail(ps, "trailing backslash in class"); return NULL; }
            char c = ps->p[ps->i];
            if (c=='d'||c=='D'||c=='w'||c=='W'||c=='s'||c=='S') {
                sl_rx_class sub; memset(&sub, 0, sizeof(sub));
                int ng = (c=='D'||c=='W'||c=='S');
                char base = (char)(ng ? c + 32 : c);
                if (base=='d') { for (int b='0'; b<='9'; b++) sl_rx_cls_set(&sub,b); }
                else if (base=='w') { for (int b=0;b<256;b++) if (sl_rx_is_word(b)) sl_rx_cls_set(&sub,b); }
                else { sl_rx_cls_set(&sub,' '); sl_rx_cls_set(&sub,'\t'); sl_rx_cls_set(&sub,'\n');
                       sl_rx_cls_set(&sub,'\r'); sl_rx_cls_set(&sub,'\f'); sl_rx_cls_set(&sub,'\v'); }
                if (ng) sl_rx_cls_negate(&sub);
                for (int b = 0; b < 256; b++) if (sl_rx_cls_has(&sub,b)) sl_rx_cls_set(&k,b);
                ps->i++; any = 1; continue;
            }
            switch (c) {
            case 'n': lo='\n'; break; case 'r': lo='\r'; break;
            case 't': lo='\t'; break; case 'f': lo='\f'; break;
            case 'v': lo='\v'; break; case '0': lo=0;    break;
            case 'x': {
                if (ps->i + 2 >= ps->n) { sl_rx_fail(ps,"truncated \\x escape"); return NULL; }
                int h = 0;
                for (int k2 = 1; k2 <= 2; k2++) {
                    int d = ps->p[ps->i + k2];
                    if (d>='0'&&d<='9') d-='0';
                    else if (d>='a'&&d<='f') d=d-'a'+10;
                    else if (d>='A'&&d<='F') d=d-'A'+10;
                    else { sl_rx_fail(ps,"bad hex in \\x escape"); return NULL; }
                    h = h*16 + d;
                }
                ps->i += 2; lo = h; break; }
            default: lo = (unsigned char)c;
            }
            ps->i++;
        } else {
            lo = (unsigned char)ps->p[ps->i++];
        }
        /* range? */
        if (ps->i + 1 < ps->n && ps->p[ps->i] == '-' && ps->p[ps->i+1] != ']') {
            ps->i++;
            int hi;
            if (ps->p[ps->i] == '\\') {
                ps->i++;
                if (ps->i >= ps->n) { sl_rx_fail(ps,"trailing backslash in class"); return NULL; }
                hi = (unsigned char)ps->p[ps->i++];
            } else {
                hi = (unsigned char)ps->p[ps->i++];
            }
            if (hi < lo) { sl_rx_fail(ps, "reversed range in class"); return NULL; }
            for (int b = lo; b <= hi; b++) sl_rx_cls_set(&k, b);
        } else {
            sl_rx_cls_set(&k, lo);
        }
        any = 1;
    }
    if (ps->i >= ps->n || ps->p[ps->i] != ']') { sl_rx_fail(ps, "missing ]"); return NULL; }
    ps->i++;
    if (!any) { sl_rx_fail(ps, "empty character class"); return NULL; }
    if (neg) { sl_rx_cls_negate(&k); }
    int idx = sl_rx_cls_add(ps, &k);
    if (idx < 0) return NULL;
    sl_rx_node *nd = sl_rx_node_new(ps, N_CLASS);
    if (nd) nd->val = idx;
    return nd;
}

/* atom := '(' alt ')' | '[' class ']' | '.' | '^' | '$' | '\' esc | byte */
static sl_rx_node *sl_rx_parse_atom(sl_rx_parser *ps) {
    if (ps->i >= ps->n) return sl_rx_node_new(ps, N_EMPTY);
    char c = ps->p[ps->i];
    if (c == '(') {
        ps->i++;
        int capturing = 1, gnum = 0;
        if (ps->i + 1 < ps->n && ps->p[ps->i] == '?' && ps->p[ps->i+1] == ':') {
            capturing = 0; ps->i += 2;
        } else if (ps->i < ps->n && ps->p[ps->i] == '?') {
            sl_rx_fail(ps, "unsupported group syntax (only (?:...) is allowed; "
                           "lookaround is not supported by this engine)");
            return NULL;
        }
        if (capturing) {
            if (ps->ngroups >= SL_RX_MAX_GROUPS) {
                sl_rx_fail(ps, "too many capture groups"); return NULL; }
            gnum = ++ps->ngroups;
        }
        if (++ps->depth > SL_RX_MAX_DEPTH) {
            sl_rx_fail(ps, "pattern nested too deeply"); return NULL; }
        sl_rx_node *inner = sl_rx_parse_alt(ps);
        ps->depth--;
        if (!inner) return NULL;
        if (ps->i >= ps->n || ps->p[ps->i] != ')') {
            sl_rx_fail(ps, "missing )"); return NULL; }
        ps->i++;
        if (!capturing) return inner;
        sl_rx_node *g = sl_rx_node_new(ps, N_GROUP);
        if (!g) return NULL;
        g->val = gnum; g->a = inner;
        return g;
    }
    if (c == '[') { ps->i++; return sl_rx_bracket(ps); }
    if (c == '.') { ps->i++; return sl_rx_node_new(ps, N_ANY); }
    if (c == '^') { ps->i++;
        sl_rx_node *nd = sl_rx_node_new(ps, N_ASSERT);
        if (nd) nd->val = RXA_BOL; return nd; }
    if (c == '$') { ps->i++;
        sl_rx_node *nd = sl_rx_node_new(ps, N_ASSERT);
        if (nd) nd->val = RXA_EOL; return nd; }
    if (c == '\\') { ps->i++; return sl_rx_escape(ps); }
    if (c == ')' ) return sl_rx_node_new(ps, N_EMPTY);
    if (c == '*' || c == '+' || c == '?') {
        sl_rx_fail(ps, "nothing to repeat"); return NULL; }
    ps->i++;
    sl_rx_node *nd = sl_rx_node_new(ps, N_BYTE);
    if (nd) nd->val = (unsigned char)c;
    return nd;
}

/* repeat := atom ( '*' | '+' | '?' | '{n,m}' ) '?'?   */
static sl_rx_node *sl_rx_parse_repeat(sl_rx_parser *ps) {
    sl_rx_node *a = sl_rx_parse_atom(ps);
    if (!a) return NULL;
    for (;;) {
        if (ps->i >= ps->n) return a;
        char c = ps->p[ps->i];
        int kind;
        int rmin = 0, rmax = -1;
        if (c == '*') kind = N_STAR;
        else if (c == '+') kind = N_PLUS;
        else if (c == '?') kind = N_QUEST;
        else if (c == '{') {
            /* {n} {n,} {n,m} -- anything else is a literal '{' */
            size_t save = ps->i;
            size_t j = ps->i + 1;
            int lo = 0, hi = -1, sawlo = 0, sawcomma = 0, sawhi = 0;
            while (j < ps->n && ps->p[j] >= '0' && ps->p[j] <= '9') {
                lo = lo * 10 + (ps->p[j] - '0'); j++; sawlo = 1;
                if (lo > SL_RX_MAX_REPEAT) break;
            }
            if (j < ps->n && ps->p[j] == ',') { sawcomma = 1; j++;
                int h = 0;
                while (j < ps->n && ps->p[j] >= '0' && ps->p[j] <= '9') {
                    h = h * 10 + (ps->p[j] - '0'); j++; sawhi = 1;
                    if (h > SL_RX_MAX_REPEAT) break;
                }
                if (sawhi) hi = h;
            } else if (sawlo) { hi = lo; }
            if (!sawlo || j >= ps->n || ps->p[j] != '}') {
                ps->i = save; return a;   /* literal '{' handled by caller */
            }
            if (lo > SL_RX_MAX_REPEAT || (sawhi && hi > SL_RX_MAX_REPEAT)) {
                sl_rx_fail(ps, "repetition count too large"); return NULL; }
            if (sawcomma && sawhi && hi < lo) {
                sl_rx_fail(ps, "reversed repetition range"); return NULL; }
            ps->i = j + 1;
            kind = N_REP; rmin = lo; rmax = sawcomma ? (sawhi ? hi : -1) : lo;
            goto wrap;
        }
        else return a;
        ps->i++;
    wrap: {
            if (a->kind == N_ASSERT) {
                sl_rx_fail(ps, "cannot repeat a zero-width assertion");
                return NULL; }
            sl_rx_node *r = sl_rx_node_new(ps, kind);
            if (!r) return NULL;
            r->a = a; r->rmin = rmin; r->rmax = rmax;
            if (ps->i < ps->n && ps->p[ps->i] == '?') { r->greedy = 0; ps->i++; }
            a = r;
        }
    }
}

/* cat := repeat*
 *
 * Folded RIGHT-associatively, deliberately: a left-deep CAT chain
 * would make the emitter recurse once per atom, so a 2000-byte
 * pattern would want ~2000 C frames and overflow the 8KB task stack.
 * Right-deep lets sl_rx_emit walk the spine in a loop instead, so
 * concatenation costs O(1) stack no matter how long the pattern is.
 * Same reasoning for alternation below. */
static sl_rx_node *sl_rx_parse_cat(sl_rx_parser *ps) {
    sl_rx_node **items = NULL;
    int n = 0, cap = 0;
    while (ps->i < ps->n && ps->p[ps->i] != '|' && ps->p[ps->i] != ')') {
        sl_rx_node *r = sl_rx_parse_repeat(ps);
        if (!r) { sl_rx_free(items); return NULL; }
        if (n == cap) {
            int nc = cap ? cap * 2 : 16;
            sl_rx_node **ni = (sl_rx_node **)sl_rx_realloc(items,
                                                     (size_t)nc * sizeof(*ni));
            if (!ni) { sl_rx_free(items); sl_rx_fail(ps, "out of memory"); return NULL; }
            items = ni; cap = nc;
        }
        items[n++] = r;
    }
    if (n == 0) { sl_rx_free(items); return sl_rx_node_new(ps, N_EMPTY); }
    sl_rx_node *acc = items[n - 1];
    for (int k = n - 2; k >= 0; k--) {
        sl_rx_node *cat = sl_rx_node_new(ps, N_CAT);
        if (!cat) { sl_rx_free(items); return NULL; }
        cat->a = items[k]; cat->b = acc; acc = cat;
    }
    sl_rx_free(items);
    return acc;
}

/* alt := cat ('|' cat)*  -- right-folded, see sl_rx_parse_cat */
static sl_rx_node *sl_rx_parse_alt(sl_rx_parser *ps) {
    sl_rx_node **items = NULL;
    int n = 0, cap = 0;
    for (;;) {
        sl_rx_node *c = sl_rx_parse_cat(ps);
        if (!c) { sl_rx_free(items); return NULL; }
        if (n == cap) {
            int nc = cap ? cap * 2 : 8;
            sl_rx_node **ni = (sl_rx_node **)sl_rx_realloc(items,
                                                     (size_t)nc * sizeof(*ni));
            if (!ni) { sl_rx_free(items); sl_rx_fail(ps, "out of memory"); return NULL; }
            items = ni; cap = nc;
        }
        items[n++] = c;
        if (ps->i < ps->n && ps->p[ps->i] == '|') { ps->i++; continue; }
        break;
    }
    sl_rx_node *acc = items[n - 1];
    for (int k = n - 2; k >= 0; k--) {
        sl_rx_node *alt = sl_rx_node_new(ps, N_ALT);
        if (!alt) { sl_rx_free(items); return NULL; }
        alt->a = items[k]; alt->b = acc; acc = alt;
    }
    sl_rx_free(items);
    return acc;
}

/* ---- emitter: AST -> program -------------------------------------
 * Two passes: size the program, then fill it. Concatenation and
 * alternation walk their right-deep spines in a loop (see
 * sl_rx_parse_cat), so C recursion here follows only nesting depth,
 * which the parser already caps at SL_RX_MAX_DEPTH. */

typedef struct {
    sl_rx_inst *prog;
    int n, cap;
    int failed;
} sl_rx_emit_ctx;

static int sl_rx_emit1(sl_rx_emit_ctx *ec, int op, int arg, int cls) {
    if (ec->failed) return 0;
    if (ec->n >= ec->cap) { ec->failed = 1; return 0; }
    sl_rx_inst *in = &ec->prog[ec->n];
    in->op = (uint8_t)op; in->arg = (uint8_t)arg; in->cls = cls;
    in->x = in->y = -1;
    return ec->n++;
}

static void sl_rx_emit(sl_rx_emit_ctx *ec, sl_rx_node *nd);

/* one greedy/lazy star over the subtree at `body` */
static void sl_rx_emit_star(sl_rx_emit_ctx *ec, sl_rx_node *body, int greedy) {
    int sp = sl_rx_emit1(ec, RX_SPLIT, 0, -1);
    int start = ec->n;
    sl_rx_emit(ec, body);
    sl_rx_emit1(ec, RX_JMP, 0, -1);
    if (ec->failed) return;
    ec->prog[ec->n - 1].x = sp;
    if (greedy) { ec->prog[sp].x = start; ec->prog[sp].y = ec->n; }
    else        { ec->prog[sp].x = ec->n; ec->prog[sp].y = start; }
}

static void sl_rx_emit(sl_rx_emit_ctx *ec, sl_rx_node *nd) {
    while (nd && !ec->failed) {
        switch (nd->kind) {
        case N_EMPTY: return;
        case N_BYTE:  sl_rx_emit1(ec, RX_BYTE, nd->val, -1); return;
        case N_CLASS: sl_rx_emit1(ec, RX_CLASS, 0, nd->val); return;
        case N_ANY:   sl_rx_emit1(ec, RX_ANY, 0, -1); return;
        case N_ANYNL: sl_rx_emit1(ec, RX_ANYNL, 0, -1); return;
        case N_ASSERT: sl_rx_emit1(ec, RX_ASSERT, nd->val, -1); return;
        case N_GROUP:
            sl_rx_emit1(ec, RX_SAVE, 2 * nd->val, -1);
            sl_rx_emit(ec, nd->a);
            sl_rx_emit1(ec, RX_SAVE, 2 * nd->val + 1, -1);
            return;
        case N_CAT:
            /* iterate the right-deep spine: O(1) stack per element */
            sl_rx_emit(ec, nd->a);
            nd = nd->b;
            continue;
        case N_ALT: {
            /* Walk the right-deep alt spine in a loop, collecting the
             * jumps that all need patching to the common end. */
            int *ends = NULL; int nends = 0, ecap = 0;
            sl_rx_node *cur = nd;
            while (cur && cur->kind == N_ALT && !ec->failed) {
                int sp = sl_rx_emit1(ec, RX_SPLIT, 0, -1);
                if (ec->failed) break;
                ec->prog[sp].x = ec->n;
                sl_rx_emit(ec, cur->a);
                int j = sl_rx_emit1(ec, RX_JMP, 0, -1);
                if (ec->failed) break;
                ec->prog[sp].y = ec->n;
                if (nends == ecap) {
                    int nc = ecap ? ecap * 2 : 8;
                    int *ni = (int *)sl_rx_realloc(ends, (size_t)nc * sizeof(int));
                    if (!ni) { ec->failed = 1; break; }
                    ends = ni; ecap = nc;
                }
                ends[nends++] = j;
                cur = cur->b;
            }
            if (!ec->failed) sl_rx_emit(ec, cur);   /* last alternative */
            if (!ec->failed)
                for (int k = 0; k < nends; k++) ec->prog[ends[k]].x = ec->n;
            sl_rx_free(ends);
            return; }
        case N_QUEST: {
            int sp = sl_rx_emit1(ec, RX_SPLIT, 0, -1);
            int start = ec->n;
            sl_rx_emit(ec, nd->a);
            if (ec->failed) return;
            if (nd->greedy) { ec->prog[sp].x = start; ec->prog[sp].y = ec->n; }
            else            { ec->prog[sp].x = ec->n; ec->prog[sp].y = start; }
            return; }
        case N_STAR:
            sl_rx_emit_star(ec, nd->a, nd->greedy);
            return;
        case N_PLUS: {
            int start = ec->n;
            sl_rx_emit(ec, nd->a);
            int sp = sl_rx_emit1(ec, RX_SPLIT, 0, -1);
            if (ec->failed) return;
            if (nd->greedy) { ec->prog[sp].x = start; ec->prog[sp].y = ec->n; }
            else            { ec->prog[sp].x = ec->n; ec->prog[sp].y = start; }
            return; }
        case N_REP: {
            /* {n,m} by expansion: n copies, then (m-n) optional copies,
             * or a star when unbounded. The counts are capped at parse
             * time and the program ceiling catches the rest. */
            for (int k = 0; k < nd->rmin && !ec->failed; k++)
                sl_rx_emit(ec, nd->a);
            if (nd->rmax < 0) {
                /* {n,} == n copies followed by a star (n==0 included) */
                sl_rx_emit_star(ec, nd->a, nd->greedy);
            } else {
                int opt = nd->rmax - nd->rmin;
                int *sps = NULL;
                if (opt > 0) {
                    sps = (int *)sl_rx_malloc((size_t)opt * sizeof(int));
                    if (!sps) { ec->failed = 1; return; }
                }
                for (int k = 0; k < opt && !ec->failed; k++) {
                    int sp = sl_rx_emit1(ec, RX_SPLIT, 0, -1);
                    sps[k] = sp;
                    if (ec->failed) break;
                    ec->prog[sp].x = ec->n;
                    sl_rx_emit(ec, nd->a);
                }
                if (!ec->failed)
                    for (int k = 0; k < opt; k++) {
                        if (nd->greedy) ec->prog[sps[k]].y = ec->n;
                        else { ec->prog[sps[k]].y = ec->prog[sps[k]].x;
                               ec->prog[sps[k]].x = ec->n; }
                    }
                sl_rx_free(sps);
            }
            return; }
        default: return;
        }
    }
}

/* ---- Pike VM -----------------------------------------------------
 * Thompson simulation: one pass over the subject, carrying the set of
 * all NFA states alive at this position. No state is ever visited
 * twice per position (the sparse set enforces that), which is exactly
 * what makes the running time linear and ReDoS structurally
 * impossible -- there is no backtracking to blow up.
 *
 * Capture slots ride along per thread (this is the Pike VM refinement
 * of Thompson). Epsilon closure is an explicit-stack DFS with an undo
 * log rather than C recursion, so a 4096-instruction program costs a
 * bounded heap buffer instead of 4096 C frames -- see the STACK note
 * at the top of the file. */

enum { RXW_VISIT, RXW_RESTORE };

typedef struct { int kind; int pc; int slot; int old; } sl_rx_work;

typedef struct {
    int *sparse, *dense;   /* Briggs-Torczon set over pc */
    int ndense;
    int *caps;             /* ndense * nslots, parallel to dense */
    /* Only the states that can actually consume a byte (or MATCH).
     * dense[] must hold every visited pc for dedup, but SPLIT/JMP/
     * SAVE/ASSERT can never match a byte, so stepping over them in the
     * inner loop is pure waste -- roughly half the program for a
     * typical pattern. tl[] is the subset the run loop iterates,
     * holding dense indices so caps stay addressable. */
    int *tl;
    int ntl;
} sl_rx_list;

typedef struct {
    sl_rx_list a, b;
    sl_rx_work *stk;
    int *w;                /* working capture slots */
    int nslots, nprog;
} sl_rx_vm;

static size_t sl_rx_scratch_size(int nprog, int nslots) {
    size_t per_list = (size_t)nprog * sizeof(int) * 3   /* sparse+dense+tl */
                    + (size_t)nprog * (size_t)nslots * sizeof(int);
    return 2 * per_list
         + (size_t)(2 * nprog + 8) * sizeof(sl_rx_work)
         + (size_t)nslots * sizeof(int);
}

static void sl_rx_vm_bind(sl_rx_vm *vm, void *mem, int nprog, int nslots) {
    unsigned char *p = (unsigned char *)mem;
    vm->nprog = nprog; vm->nslots = nslots;
    for (int k = 0; k < 2; k++) {
        sl_rx_list *l = k ? &vm->b : &vm->a;
        l->sparse = (int *)p; p += (size_t)nprog * sizeof(int);
        l->dense  = (int *)p; p += (size_t)nprog * sizeof(int);
        l->tl     = (int *)p; p += (size_t)nprog * sizeof(int);
        l->caps   = (int *)p; p += (size_t)nprog * (size_t)nslots * sizeof(int);
        l->ndense = 0; l->ntl = 0;
    }
    vm->stk = (sl_rx_work *)p; p += (size_t)(2 * nprog + 8) * sizeof(sl_rx_work);
    vm->w = (int *)p;
}

static int sl_rx_assert_ok(int kind, const unsigned char *s, size_t n, size_t pos) {
    int before = pos > 0 ? s[pos - 1] : -1;
    int after  = pos < n ? s[pos] : -1;
    switch (kind) {
    case RXA_BOT: return pos == 0;
    case RXA_EOT: return pos == n;
    case RXA_BOL: return pos == 0 || before == '\n';
    case RXA_EOL: return pos == n || after == '\n';
    case RXA_WORDB:
        return (before >= 0 && sl_rx_is_word(before)) !=
               (after  >= 0 && sl_rx_is_word(after));
    case RXA_NWORDB:
        return (before >= 0 && sl_rx_is_word(before)) ==
               (after  >= 0 && sl_rx_is_word(after));
    }
    return 0;
}

/* Epsilon-closure add. Explicit DFS stack; RXW_RESTORE entries undo a
 * SAVE once that whole subtree is done, which is what keeps capture
 * slots correct without copying them at every step. */
static void sl_rx_addthread(sl_rx_vm *vm, const sl_rx *re, sl_rx_list *l,
                            int pc0, const unsigned char *s, size_t n,
                            size_t pos) {
    int top = 0;
    int maxstk = 2 * vm->nprog + 8;
    vm->stk[top].kind = RXW_VISIT; vm->stk[top].pc = pc0; top++;
    while (top > 0) {
        sl_rx_work e = vm->stk[--top];
        if (e.kind == RXW_RESTORE) { vm->w[e.slot] = e.old; continue; }
        int pc = e.pc;
        if (pc < 0 || pc >= vm->nprog) continue;
        /* Sparse-set membership (Briggs-Torczon): O(1), and needs no
         * clearing between positions -- that is the whole point, and
         * it is why the list can be reset with ndense = 0 alone.
         *
         * The >= 0 test is load-bearing, not defensive: sparse[] is
         * deliberately left uninitialized (clearing it every step would
         * cost exactly what this structure exists to avoid), so on the
         * first touch of a pc it holds whatever malloc left behind. A
         * negative value there passes the < ndense test and indexes
         * dense[] out of bounds. Without this guard the engine
         * segfaulted in ~40% of runs under concurrency. */
        int si = l->sparse[pc];
        if (si >= 0 && si < l->ndense && l->dense[si] == pc)
            continue;
        l->sparse[pc] = l->ndense;
        l->dense[l->ndense] = pc;
        int slot_idx = l->ndense;
        l->ndense++;
        const sl_rx_inst *in = &re->prog[pc];
        switch (in->op) {
        case RX_JMP:
            if (top + 1 > maxstk) break;
            vm->stk[top].kind = RXW_VISIT; vm->stk[top].pc = in->x; top++;
            break;
        case RX_SPLIT:
            if (top + 2 > maxstk) break;
            /* push y first so x is popped first: x is the higher
             * priority branch, which is what makes matching
             * leftmost-FIRST (Perl-like) rather than leftmost-longest */
            vm->stk[top].kind = RXW_VISIT; vm->stk[top].pc = in->y; top++;
            vm->stk[top].kind = RXW_VISIT; vm->stk[top].pc = in->x; top++;
            break;
        case RX_SAVE: {
            int sl = in->arg;
            if (vm->nslots == 0) {
                /* is_match: nobody will read the captures, so a SAVE is
                 * just an epsilon step -- no slot write, no undo entry. */
                if (top + 1 > maxstk) break;
                vm->stk[top].kind = RXW_VISIT; vm->stk[top].pc = pc + 1; top++;
            } else if (sl < vm->nslots) {
                if (top + 2 > maxstk) break;
                vm->stk[top].kind = RXW_RESTORE; vm->stk[top].slot = sl;
                vm->stk[top].old = vm->w[sl]; top++;
                vm->w[sl] = (int)pos;
                vm->stk[top].kind = RXW_VISIT; vm->stk[top].pc = pc + 1; top++;
            } else {
                if (top + 1 > maxstk) break;
                vm->stk[top].kind = RXW_VISIT; vm->stk[top].pc = pc + 1; top++;
            }
            break; }
        case RX_ASSERT:
            if (sl_rx_assert_ok(in->arg, s, n, pos)) {
                if (top + 1 > maxstk) break;
                vm->stk[top].kind = RXW_VISIT; vm->stk[top].pc = pc + 1; top++;
            }
            break;
        default:
            /* a consuming instruction, or MATCH: it becomes a real
             * thread, so snapshot the capture slots for it. Skipped
             * wholesale for is_match (nslots == 0), which is what
             * makes the boolean path markedly cheaper than find(). */
            if (vm->nslots)
                memcpy(l->caps + (size_t)slot_idx * vm->nslots, vm->w,
                       (size_t)vm->nslots * sizeof(int));
            l->tl[l->ntl++] = slot_idx;
            break;
        }
    }
}

/* Run the machine over s[start..n). Fills out[] with nslots offsets.
 * Returns 1 on match, 0 on no match. */
static int sl_rx_run(sl_rx_vm *vm, const sl_rx *re, const unsigned char *s,
                     size_t n, size_t start, int *out, int want_caps) {
    sl_rx_list *cl = &vm->a, *nl = &vm->b;
    cl->ndense = 0; nl->ndense = 0;
    cl->ntl = 0; nl->ntl = 0;
    int matched = 0;
    for (int i = 0; i < vm->nslots; i++) vm->w[i] = -1;

    for (size_t pos = start; ; pos++) {
        if (cl->ntl == 0 && matched) break;
        /* seed a new start thread at each position unless anchored or
         * we already have a match (leftmost wins) */
        if (!matched && (!re->anchored_start || pos == start)) {
            for (int i = 0; i < vm->nslots; i++) vm->w[i] = -1;
            if (vm->nslots) vm->w[0] = (int)pos;
            sl_rx_addthread(vm, re, cl, 0, s, n, pos);
        }
        if (cl->ntl == 0) { if (pos >= n) break; else continue; }

        int c = pos < n ? s[pos] : -1;
        nl->ndense = 0; nl->ntl = 0;
        for (int k = 0; k < cl->ntl; k++) {
            int t = cl->tl[k];
            int pc = cl->dense[t];
            const sl_rx_inst *in = &re->prog[pc];
            int *caps = cl->caps + (size_t)t * vm->nslots;
            int ok = 0;
            switch (in->op) {
            case RX_BYTE:  ok = (c >= 0 && c == in->arg); break;
            case RX_CLASS: ok = (c >= 0 && sl_rx_cls_has(&re->classes[in->cls], c)); break;
            case RX_ANY:   ok = (c >= 0 && c != '\n'); break;
            case RX_ANYNL: ok = (c >= 0); break;
            case RX_MATCH:
                /* leftmost-first: the highest-priority thread to reach
                 * MATCH wins, and every lower-priority thread in this
                 * list is abandoned */
                if (want_caps) {
                    memcpy(out, caps, (size_t)vm->nslots * sizeof(int));
                    out[1] = (int)pos;
                }
                matched = 1;
                cl->ntl = k;   /* cut lower-priority threads */
                goto stepped;
            default: ok = 0; break;
            }
            if (ok) {
                if (vm->nslots)
                    memcpy(vm->w, caps, (size_t)vm->nslots * sizeof(int));
                sl_rx_addthread(vm, re, nl, pc + 1, s, n, pos + 1);
            }
        }
    stepped:
        { sl_rx_list *tmp = cl; cl = nl; nl = tmp; }
        if (pos >= n) break;
    }
    return matched;
}

/* ---- compile ------------------------------------------------------ */

static void sl_rx_free_parser(sl_rx_parser *ps) {
    for (int i = 0; i < ps->npool; i++) sl_rx_free(ps->pool[i]);
    sl_rx_free(ps->pool);
    sl_rx_free(ps->cls);
}

/* Which bytes can begin a match? Used by find() to memchr past
 * impossible start positions. Bails (returns 0) whenever an assertion
 * or a possible empty match makes the answer not a simple byte set --
 * a missing prefilter only costs speed, a wrong one costs correctness. */
static int sl_rx_compute_first(sl_rx *re) {
    int *seen = (int *)sl_rx_calloc((size_t)re->nprog, sizeof(int));
    int *stk = (int *)sl_rx_malloc((size_t)re->nprog * sizeof(int));
    if (!seen || !stk) { sl_rx_free(seen); sl_rx_free(stk); return 0; }
    int top = 0, ok = 1;
    stk[top++] = 0;
    memset(re->first, 0, sizeof(re->first));
    while (top > 0 && ok) {
        int pc = stk[--top];
        if (pc < 0 || pc >= re->nprog || seen[pc]) continue;
        seen[pc] = 1;
        const sl_rx_inst *in = &re->prog[pc];
        switch (in->op) {
        case RX_JMP:   if (top < re->nprog) stk[top++] = in->x; break;
        case RX_SAVE:  if (top < re->nprog) stk[top++] = pc + 1; break;
        case RX_SPLIT:
            if (top + 1 < re->nprog) { stk[top++] = in->x; stk[top++] = in->y; }
            else ok = 0;
            break;
        case RX_ASSERT: ok = 0; break;              /* too subtle: bail */
        case RX_MATCH:  ok = 0; break;              /* can match empty */
        case RX_BYTE:   re->first[(in->arg & 0xff) >> 3] |=
                            (unsigned char)(1u << (in->arg & 7)); break;
        case RX_CLASS:  for (int b = 0; b < 256; b++)
                            if (sl_rx_cls_has(&re->classes[in->cls], b))
                                re->first[b >> 3] |= (unsigned char)(1u << (b & 7));
                        break;
        default: ok = 0; break;                     /* ANY: no useful filter */
        }
    }
    sl_rx_free(seen); sl_rx_free(stk);
    if (!ok) return 0;
    int count = 0;
    for (int b = 0; b < 256; b++)
        if ((re->first[b >> 3] >> (b & 7)) & 1) count++;
    return count > 0 && count < 200;   /* a filter this wide earns nothing */
}

static void sl_rx_destroy(sl_rx *re) {
    if (!re) return;
    sl_rx_free(re->prog); sl_rx_free(re->classes);
    for (int i = 0; i < SL_RX_SLOTS; i++) sl_rx_free(re->scratch[i]);
    sl_rx_free(re);
}

/* Returns NULL and fills err[] on failure. */
static sl_rx *sl_rx_compile(const char *pat, char *err, size_t errsz) {
    sl_rx_parser ps;
    memset(&ps, 0, sizeof(ps));
    ps.p = pat; ps.n = strlen(pat); ps.i = 0;

    sl_rx_node *root = sl_rx_parse_alt(&ps);
    if (!root || ps.err[0]) {
        snprintf(err, errsz, "%s", ps.err[0] ? ps.err : "invalid pattern");
        sl_rx_free_parser(&ps); return NULL;
    }
    if (ps.i != ps.n) {
        /* only an unbalanced ) can stop parse_alt early */
        snprintf(err, errsz, "unmatched ) at offset %zu", ps.i);
        sl_rx_free_parser(&ps); return NULL;
    }

    sl_rx *re = (sl_rx *)sl_rx_calloc(1, sizeof(*re));
    if (!re) { snprintf(err, errsz, "out of memory"); sl_rx_free_parser(&ps); return NULL; }
    re->ngroups = ps.ngroups;
    re->nslots = 2 * (ps.ngroups + 1);

    sl_rx_emit_ctx ec;
    ec.cap = SL_RX_MAX_INSTS; ec.n = 0; ec.failed = 0;
    ec.prog = (sl_rx_inst *)sl_rx_calloc((size_t)ec.cap, sizeof(sl_rx_inst));
    if (!ec.prog) { snprintf(err, errsz, "out of memory");
                    sl_rx_free(re); sl_rx_free_parser(&ps); return NULL; }
    sl_rx_emit1(&ec, RX_SAVE, 0, -1);
    sl_rx_emit(&ec, root);
    sl_rx_emit1(&ec, RX_SAVE, 1, -1);
    sl_rx_emit1(&ec, RX_MATCH, 0, -1);
    if (ec.failed) {
        snprintf(err, errsz, "pattern too complex (exceeds %d instructions)",
                 SL_RX_MAX_INSTS);
        sl_rx_free(ec.prog); sl_rx_free(re); sl_rx_free_parser(&ps); return NULL;
    }

    re->nprog = ec.n;
    re->prog = (sl_rx_inst *)sl_rx_realloc(ec.prog, (size_t)ec.n * sizeof(sl_rx_inst));
    if (!re->prog) re->prog = ec.prog;    /* shrink failing is harmless */
    if (ps.ncls) {
        re->classes = (sl_rx_class *)sl_rx_malloc((size_t)ps.ncls * sizeof(sl_rx_class));
        if (!re->classes) { snprintf(err, errsz, "out of memory");
                            sl_rx_destroy(re); sl_rx_free_parser(&ps); return NULL; }
        memcpy(re->classes, ps.cls, (size_t)ps.ncls * sizeof(sl_rx_class));
        re->ncls = ps.ncls;
    }
    sl_rx_free_parser(&ps);

    /* anchored if the very first thing (past SAVE 0) is ^ or \A */
    if (re->nprog > 1 && re->prog[1].op == RX_ASSERT &&
        (re->prog[1].arg == RXA_BOL || re->prog[1].arg == RXA_BOT))
        re->anchored_start = 1;
    re->has_first = sl_rx_compute_first(re);

    /* One slot up front so the common single-matcher path never
     * allocates during a match; the rest appear only under real
     * concurrency. */
    for (int i = 0; i < SL_RX_SLOTS; i++) atomic_store(&re->scratch_busy[i], 0);
    re->scratch[0] = sl_rx_malloc(sl_rx_scratch_size(re->nprog, re->nslots));
    if (!re->scratch[0]) { snprintf(err, errsz, "out of memory");
                           sl_rx_destroy(re); return NULL; }
    return re;
}

/* ---- matching entry points --------------------------------------- */

/* Claim the regex's reusable scratch, or malloc a private one if
 * another task is mid-match on the same compiled regex. */
static int sl_rx_match_core(sl_rx *re, const unsigned char *s, size_t n,
                            size_t start, int *out, int want_caps) {
    if (start > n) return 0;
    /* first-byte prefilter: skip start positions that cannot begin a
     * match. Only valid when unanchored and the filter is exact. */
    if (re->has_first && !re->anchored_start) {
        size_t p = start;
        while (p < n && !((re->first[s[p] >> 3] >> (s[p] & 7)) & 1)) p++;
        if (p >= n) {
            /* still try at n: a pattern could match empty at the end,
             * but compute_first already bailed for those, so no match */
            return 0;
        }
        start = p;
    }
    void *mem = NULL;
    int slot = -1;
    for (int i = 0; i < SL_RX_SLOTS; i++) {
        if (atomic_exchange(&re->scratch_busy[i], 1) == 0) {
            if (!re->scratch[i]) {
                re->scratch[i] =
                    sl_rx_malloc(sl_rx_scratch_size(re->nprog, re->nslots));
                if (!re->scratch[i]) {
                    atomic_store(&re->scratch_busy[i], 0);
                    break;
                }
            }
            mem = re->scratch[i];
            slot = i;
            break;
        }
    }
    if (!mem) {   /* every slot busy: private block, never block */
        mem = sl_rx_malloc(sl_rx_scratch_size(re->nprog, re->nslots));
        if (!mem) return 0;
    }
    sl_rx_vm vm;
    /* is_match binds ZERO capture slots: the VM then skips every slot
     * write, snapshot and undo entry. Same machine, same linear-time
     * guarantee, far less memory traffic on the boolean hot path. */
    sl_rx_vm_bind(&vm, mem, re->nprog, want_caps ? re->nslots : 0);
    int r = sl_rx_run(&vm, re, s, n, start, out, want_caps);
    if (slot >= 0) atomic_store(&re->scratch_busy[slot], 0);
    else sl_rx_free(mem);
    return r;
}

static bool sl_regex_is_match(void *rev, const char *s) {
    sl_rx *re = (sl_rx *)rev;
    if (!re || !s) return false;
    int out[2];
    return sl_rx_match_core(re, (const unsigned char *)s, strlen(s), 0,
                            out, 0) ? true : false;
}

static bool sl_regex_is_match_bytes(void *rev, sl_bytes *b) {
    sl_rx *re = (sl_rx *)rev;
    if (!re || !b) return false;
    int out[2];
    return sl_rx_match_core(re, b->ptr, (size_t)b->len, 0, out, 0) ? true : false;
}

/* [] on no match, else [start,end, g1s,g1e, ...] as byte offsets. */
static sl_arr *sl_regex_find_core(sl_rx *re, const unsigned char *s, size_t n,
                                  long long from) {
    sl_arr *a = sl_arr_new(sizeof(long long), 0);
    if (!re || from < 0 || (size_t)from > n) return a;
    int *out = (int *)sl_rx_calloc((size_t)re->nslots, sizeof(int));
    if (!out) return a;
    if (sl_rx_match_core(re, s, n, (size_t)from, out, 1)) {
        for (int i = 0; i < re->nslots; i++) {
            long long v = out[i];
            sl_arr_push(a, &v, sizeof(long long));
        }
    }
    sl_rx_free(out);
    return a;
}

static sl_arr *sl_regex_find(void *rev, const char *s) {
    if (!s) return sl_arr_new(sizeof(long long), 0);
    return sl_regex_find_core((sl_rx *)rev, (const unsigned char *)s,
                              strlen(s), 0);
}

static sl_arr *sl_regex_find_at(void *rev, const char *s, long long from) {
    if (!s) return sl_arr_new(sizeof(long long), 0);
    return sl_regex_find_core((sl_rx *)rev, (const unsigned char *)s,
                              strlen(s), from);
}

static sl_arr *sl_regex_find_bytes(void *rev, sl_bytes *b) {
    if (!b) return sl_arr_new(sizeof(long long), 0);
    return sl_regex_find_core((sl_rx *)rev, b->ptr, (size_t)b->len, 0);
}

static sl_arr *sl_regex_find_bytes_at(void *rev, sl_bytes *b, long long from) {
    if (!b) return sl_arr_new(sizeof(long long), 0);
    return sl_regex_find_core((sl_rx *)rev, b->ptr, (size_t)b->len, from);
}

static long long sl_regex_groups(void *rev) {
    sl_rx *re = (sl_rx *)rev;
    return re ? (long long)re->ngroups : 0;
}

static void sl_regex_free(void *rev) { sl_rx_destroy((sl_rx *)rev); }

static sl_res_rawptr_str *sl_regex_ok_ptr(void *v) {
    sl_res_rawptr_str *r = (sl_res_rawptr_str *)sl_gc_alloc(
        sizeof(sl_res_rawptr_str), sl_gc_trace_sl_res_rawptr_str);
    r->ok = true; r->v = v; return r;
}

static sl_res_rawptr_str *sl_regex_err_ptr(const char *msg) {
    sl_res_rawptr_str *r = (sl_res_rawptr_str *)sl_gc_alloc(
        sizeof(sl_res_rawptr_str), sl_gc_trace_sl_res_rawptr_str);
    r->ok = false; r->e = sl_strdup(msg ? msg : "invalid pattern"); return r;
}

/* Split from sl_regex_compile below, and noinline on purpose.
 *
 * Growing a task stack RELOCATES it: sl_task_stack_grow mallocs a new
 * buffer, copies, fixes the saved frame-pointer chain, and frees the
 * old one. It cannot fix an interior stack pointer the optimizer has
 * parked in a callee-saved register -- so any frame that both holds
 * the address of one of its own locals AND spans the growth is left
 * pointing into freed memory. That is not hypothetical: with err[]
 * and the parser state in the same frame as the sl_rt_need_stack
 * call, ASan caught a heap-use-after-free in sl_rx_emit reading the
 * main task's freed 8KB stack.
 *
 * Keeping every address-taken local down here, and the growth up in a
 * caller that takes no addresses at all, means the whole relocation
 * completes before this frame exists. Same discipline sl_tls.c
 * follows by calling sl_rt_need_stack as an entry point's first act. */
__attribute__((noinline))
static sl_res_rawptr_str *sl_regex_compile_body(const char *pat) {
    char err[192];
    err[0] = 0;
    sl_rx *re = sl_rx_compile(pat, err, sizeof(err));
    if (!re) return sl_regex_err_ptr(err);
    return sl_regex_ok_ptr(re);
}

static sl_res_rawptr_str *sl_regex_compile(const char *pat) {
    if (!pat) return sl_regex_err_ptr("nil pattern");
    /* Parsing recurses with pattern nesting, so grow first -- and take
     * no interior pointers in this frame, see above. Matching
     * deliberately does NOT grow; see the STACK note at the top. */
    sl_rt_need_stack(SL_RX_COMPILE_STACK);
    return sl_regex_compile_body(pat);
}
