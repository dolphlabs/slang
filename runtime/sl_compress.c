#include <zlib.h>

/* The 'compress' package: gzip, zlib and raw DEFLATE over zlib.
 *
 * ---- green-thread rules this file obeys ---------------------------
 *
 * Every zlib call is bracketed with sl_rt_preempt_disable/enable. zlib
 * allocates through its own allocator (which lands in malloc), and an
 * async preemption inside malloc resumes the task on a different worker
 * while libc's arena locks still record the old thread as owner -- the
 * same hazard that made SQLite abort roughly one run in a hundred
 * before sl_sql.c was bracketed, and that sl_regex.c hit as
 * _os_unfair_lock_unowned_abort across 43 unbracketed mallocs.
 *
 * deflateInit2 reserves on the order of 256 KiB of working state up
 * front, so the stack is grown before the call for the same reason
 * sl_crypto.c and sl_tls.c grow theirs: the allocation itself is on the
 * heap, but the call path into it is deeper than a green task's
 * starting stack.
 *
 * ---- the output limit ----------------------------------------------
 *
 * Decompression checks its ceiling INSIDE the loop, before each
 * inflate() call, rather than by inspecting the result afterwards.
 * Checking afterwards means the allocation already happened, which is
 * exactly what the limit exists to prevent -- a 400 KiB input that
 * expands to 4 GiB must never reach 4 GiB of resident memory on the way
 * to being rejected. The buffer grows geometrically but is never
 * allowed past max_out. */

/* zlib's streaming interface wants a fixed scratch buffer per call. 64
 * KiB is large enough that a typical HTTP response finishes in one or
 * two passes and small enough to sit on a grown task stack. */
#define SL_Z_CHUNK 65536

/* Growth needs headroom in the deep C path that zlib's allocator takes;
 * the same size sl_crypto.c settled on for OpenSSL's dyld excursion. */
#define SL_COMPRESS_STACK() sl_rt_need_stack(SL_TASK_DYLD_STACK_SIZE)

static sl_res_bytes_str *sl_z_ok(sl_bytes *b) {
    sl_res_bytes_str *r = (sl_res_bytes_str *)sl_gc_alloc(
        sizeof(sl_res_bytes_str), sl_gc_trace_sl_res_bytes_str);
    r->ok = true;
    r->v = b;
    return r;
}

static sl_res_bytes_str *sl_z_err(const char *msg) {
    sl_res_bytes_str *r = (sl_res_bytes_str *)sl_gc_alloc(
        sizeof(sl_res_bytes_str), sl_gc_trace_sl_res_bytes_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

/* zlib reports a code and sometimes a message; prefer the message,
   because "data error" locates the problem and "-3" does not. */
static const char *sl_z_why(z_streamp zs, int rc) {
    if (zs && zs->msg) return zs->msg;
    switch (rc) {
    case Z_MEM_ERROR: return "out of memory";
    case Z_DATA_ERROR: return "corrupt or truncated input";
    case Z_BUF_ERROR: return "truncated input";
    case Z_STREAM_ERROR: return "invalid parameters";
    case Z_VERSION_ERROR: return "zlib version mismatch";
    default: return "zlib failed";
    }
}

/* windowBits selects the container: 15 is zlib (RFC 1950), 15|16 adds a
 * gzip wrapper (RFC 1952), and -15 means raw DEFLATE with no header at
 * all (RFC 1951). See pkg_compress/sigs.c on why all three are exposed. */
static sl_res_bytes_str *sl_z_compress(sl_bytes *in, int level,
                                       int window_bits) {
    SL_COMPRESS_STACK();
    if (level < 0 || level > 9)
        return sl_z_err("compression level must be between 0 and 9");

    long long inlen = in ? in->len : 0;
    const unsigned char *inptr = in ? in->ptr : (const unsigned char *)"";

    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    sl_rt_preempt_disable();
    int rc = deflateInit2(&zs, level, Z_DEFLATED, window_bits, 8,
                          Z_DEFAULT_STRATEGY);
    sl_rt_preempt_enable();
    if (rc != Z_OK)
        return sl_z_err(sl_z_why(&zs, rc));

    /* deflateBound is zlib's own worst case, so one allocation and one
       pass suffice -- no growth loop, and no chance of a short write. */
    sl_rt_preempt_disable();
    unsigned long bound = deflateBound(&zs, (unsigned long)inlen);
    sl_rt_preempt_enable();

    unsigned char *out = (unsigned char *)sl_gc_alloc(
        (size_t)(bound > 0 ? bound : 1), NULL);

    zs.next_in = (Bytef *)inptr;
    zs.avail_in = (uInt)inlen;
    zs.next_out = out;
    zs.avail_out = (uInt)bound;

    sl_rt_preempt_disable();
    rc = deflate(&zs, Z_FINISH);
    unsigned long produced = zs.total_out;
    const char *why = (rc != Z_STREAM_END) ? sl_z_why(&zs, rc) : NULL;
    deflateEnd(&zs);
    sl_rt_preempt_enable();

    if (why)
        return sl_z_err(why);

    sl_bytes *b = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes),
                                          sl_gc_trace_bytes);
    b->len = (long long)produced;
    b->ptr = (unsigned char *)sl_gc_alloc(
        (size_t)(produced > 0 ? produced : 1), NULL);
    if (produced) memcpy(b->ptr, out, (size_t)produced);
    return sl_z_ok(b);
}

static sl_res_bytes_str *sl_z_decompress(sl_bytes *in, long long max_out,
                                         int window_bits, const char *who) {
    SL_COMPRESS_STACK();
    if (max_out < 0)
        return sl_z_err("max_out must not be negative");
    if (!in || in->len == 0)
        return sl_z_err("empty input");

    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    sl_rt_preempt_disable();
    int rc = inflateInit2(&zs, window_bits);
    sl_rt_preempt_enable();
    if (rc != Z_OK)
        return sl_z_err(sl_z_why(&zs, rc));

    zs.next_in = (Bytef *)in->ptr;
    zs.avail_in = (uInt)in->len;

    /* The buffer is allowed to reach max_out + 1, not max_out, and the
       limit is enforced on what was actually PRODUCED.
       
       One byte of slack, so that an output of exactly max_out does not
       depend on WHEN zlib reports Z_STREAM_END. It fills the buffer;
       whether it then declares the stream finished on that same call or
       waits for one with room to spare is an internal detail of how the
       trailer is drained. If it ever waits, a buffer capped at exactly
       max_out would look full-at-the-ceiling and a response the caller
       sized exactly right would be rejected.

       Honesty about this guard: the zlib here (1.2.12) does report
       Z_STREAM_END on the filling call, so removing the slack does NOT
       fail the test -- the behaviour it protects against could not be
       reproduced on this platform. It stays because the alternative is
       depending on an internal detail across every zlib the compiler
       might link, and "too big" is better decided by measuring the
       output than by inferring it from a full buffer.

       What IS demonstrated: the post-loop check below is load-bearing
       (removing it breaks the one-byte-short case), and the ceiling
       check inside the loop is load-bearing to the point that removing
       it makes this loop spin rather than over-allocate. */
    long long hard = max_out + 1;

    /* Start at a multiple of the input and grow, rather than allocating
       max_out up front: a caller may pass a generous ceiling for a
       response that turns out to be 2 KiB, and reserving the ceiling
       would make the limit itself the memory problem. */
    size_t cap = (size_t)(in->len * 4);
    if (cap < SL_Z_CHUNK) cap = SL_Z_CHUNK;
    if ((long long)cap > hard) cap = (size_t)hard;
    if (cap == 0) cap = 1;
    unsigned char *out = (unsigned char *)sl_gc_alloc(cap, NULL);
    size_t have = 0;

    for (;;) {
        if (have == cap) {
            /* The ceiling is enforced HERE, before the allocation that
               would cross it -- see this file's header. */
            if ((long long)cap >= hard) {
                sl_rt_preempt_disable();
                inflateEnd(&zs);
                sl_rt_preempt_enable();
                char m[160];
                snprintf(m, sizeof(m),
                         "%s: output exceeds the %lld byte limit "
                         "(decompression bomb?)", who, max_out);
                return sl_z_err(m);
            }
            size_t next = cap * 2;
            if ((long long)next > hard) next = (size_t)hard;
            unsigned char *bigger = (unsigned char *)sl_gc_alloc(next, NULL);
            memcpy(bigger, out, have);
            out = bigger;
            cap = next;
        }

        zs.next_out = out + have;
        zs.avail_out = (uInt)(cap - have);

        uInt in_before = zs.avail_in;
        size_t have_before = have;

        sl_rt_preempt_disable();
        rc = inflate(&zs, Z_NO_FLUSH);
        sl_rt_preempt_enable();

        have = cap - zs.avail_out;

        /* zlib's contract says Z_OK implies progress and Z_BUF_ERROR is
           how it reports the absence of it, so this should be
           unreachable. It is here because the alternative to being
           wrong about that is an infinite loop, and a hang is the least
           useful diagnosis available -- the same reason the mutex
           checks for recursive locking rather than trusting callers.
           Found by deliberately disabling the ceiling below, which made
           this loop spin instead of failing. */
        if (rc == Z_OK && zs.avail_in == in_before && have == have_before) {
            sl_rt_preempt_disable();
            inflateEnd(&zs);
            sl_rt_preempt_enable();
            return sl_z_err("zlib made no progress (corrupt input)");
        }

        if (rc == Z_STREAM_END)
            break;
        if (rc == Z_OK || rc == Z_BUF_ERROR) {
            /* Z_BUF_ERROR with input left and no output room means grow
               and continue; with no input left it means truncated. */
            if (rc == Z_BUF_ERROR && zs.avail_in == 0 && have < cap) {
                sl_rt_preempt_disable();
                inflateEnd(&zs);
                sl_rt_preempt_enable();
                return sl_z_err("truncated input");
            }
            continue;
        }
        {
            const char *why = sl_z_why(&zs, rc);
            char m[192];
            snprintf(m, sizeof(m), "%s: %s", who, why);
            sl_rt_preempt_disable();
            inflateEnd(&zs);
            sl_rt_preempt_enable();
            return sl_z_err(m);
        }
    }

    sl_rt_preempt_disable();
    inflateEnd(&zs);
    sl_rt_preempt_enable();

    /* The stream can finish exactly as it crosses into the slack byte,
       so the limit is checked once more on the real figure. */
    if ((long long)have > max_out) {
        char m[160];
        snprintf(m, sizeof(m),
                 "%s: output exceeds the %lld byte limit "
                 "(decompression bomb?)", who, max_out);
        return sl_z_err(m);
    }

    sl_bytes *b = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes),
                                          sl_gc_trace_bytes);
    b->len = (long long)have;
    b->ptr = (unsigned char *)sl_gc_alloc(have > 0 ? have : 1, NULL);
    if (have) memcpy(b->ptr, out, have);
    return sl_z_ok(b);
}

/* Level 6 rather than Z_DEFAULT_COMPRESSION, which is the same 6 spelled
   as -1. Naming it means gzip() and gzip_level(b, 6) are visibly the
   same call, instead of differing by a sentinel. */
static sl_res_bytes_str *sl_compress_gzip(sl_bytes *in) {
    return sl_z_compress(in, 6, 15 | 16);
}

static sl_res_bytes_str *sl_compress_gzip_level(sl_bytes *in,
                                                long long level) {
    return sl_z_compress(in, (int)level, 15 | 16);
}

static sl_res_bytes_str *sl_compress_deflate(sl_bytes *in) {
    return sl_z_compress(in, 6, 15);
}

static sl_res_bytes_str *sl_compress_deflate_raw(sl_bytes *in) {
    return sl_z_compress(in, 6, -15);
}

static sl_res_bytes_str *sl_compress_gunzip(sl_bytes *in, long long max_out) {
    return sl_z_decompress(in, max_out, 15 | 16, "gunzip");
}

static sl_res_bytes_str *sl_compress_inflate(sl_bytes *in, long long max_out) {
    return sl_z_decompress(in, max_out, 15, "inflate");
}

static sl_res_bytes_str *sl_compress_inflate_raw(sl_bytes *in,
                                                 long long max_out) {
    return sl_z_decompress(in, max_out, -15, "inflate_raw");
}
