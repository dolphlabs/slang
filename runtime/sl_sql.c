/* Runtime for the 'sql' native package: a thin SQLite driver.
 *
 * Every fallible entry point returns a result[_, str] whose error
 * string is SQLite's own message (sqlite3_errmsg / sqlite3_errstr) --
 * the same "keep the reason visible" contract sl_fs.c and sl_net.c
 * follow, so a bad query reads back exactly like a bad socket call.
 *
 * Handles (sqlite3 *, sqlite3_stmt *) cross into slang as opaque
 * rawptr, never GC-owned -- freed through sql.close / sql.finalize,
 * mirroring net.tls_close. SQLite calls block the worker; callers are
 * told (README) to keep them off the accept loop, same as fs.
 *
 * Two independent hazards guard every call into SQLite here, both
 * measured, neither sufficient alone:
 *
 * 1. STACK. Every entry point calls SL_SQL_STACK() first, exactly as
 *    sl_tls.c does for OpenSSL and for the same reason: a task's
 *    stack starts at 8KB and grows only at slang checkpoints, which a
 *    native chain has none of. SQLite recurses deeper than OpenSSL,
 *    so it asks for SL_TASK_SQL_STACK_SIZE. Without this, prepare/
 *    step/close ran off the end of the stack buffer into the heap:
 *    13 of 100 runs of tests/sql aborted inside malloc.
 *
 * 2. PREEMPTION. Every sqlite3_* call then sits inside a
 *    sl_rt_preempt_disable/enable bracket, as sl_crypto.c does around
 *    OpenSSL. An async preemption inside SQLite can resume the task on
 *    a different pool worker, and SQLite's serialized-mode mutexes
 *    track their owning OS thread -- so the call returns on a thread
 *    the mutex does not believe holds it. This only shows up under
 *    real concurrency: with 2000 spawned tasks doing SQL, 9 of 15 runs
 *    died (SIGILL) with the stack fix alone, and 0 of 15 with
 *    preemption disabled via SLANG_PREEMPT_QUANTUM_MS. Fixing the
 *    stack does not fix this, and vice versa.
 *
 * The bracket covers only the foreign call and never spans a return:
 * an early return while disabled would strand preempt_disable_depth
 * elevated for the life of the task. sl_gc_alloc / sl_strdup are
 * always reached with preemption re-enabled (crypto's rule), and a
 * const char * from sqlite3_errmsg points into SQLite's own heap, so
 * it stays valid across the copy that follows. */

#include <sqlite3.h>

/* ---- result[_, str] constructors (cf. sl_fs_ok_i32) ---------------- */

static sl_res_rawptr_str *sl_sql_ok_ptr(void *v) {
    sl_res_rawptr_str *r = (sl_res_rawptr_str *)sl_gc_alloc(
        sizeof(sl_res_rawptr_str), sl_gc_trace_sl_res_rawptr_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_rawptr_str *sl_sql_err_ptr(const char *msg) {
    sl_res_rawptr_str *r = (sl_res_rawptr_str *)sl_gc_alloc(
        sizeof(sl_res_rawptr_str), sl_gc_trace_sl_res_rawptr_str);
    r->ok = false;
    r->e = sl_strdup(msg ? msg : "sql error");
    return r;
}

static sl_res_bool_str *sl_sql_ok_bool(bool v) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_bool_str *sl_sql_err_bool(const char *msg) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = false;
    r->e = sl_strdup(msg ? msg : "sql error");
    return r;
}

static sl_res_int_str *sl_sql_ok_int(long long v) {
    sl_res_int_str *r = (sl_res_int_str *)sl_gc_alloc(
        sizeof(sl_res_int_str), sl_gc_trace_sl_res_int_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_int_str *sl_sql_err_int(const char *msg) {
    sl_res_int_str *r = (sl_res_int_str *)sl_gc_alloc(
        sizeof(sl_res_int_str), sl_gc_trace_sl_res_int_str);
    r->ok = false;
    r->e = sl_strdup(msg ? msg : "sql error");
    return r;
}

#define SL_SQL_STACK() sl_rt_need_stack(SL_TASK_SQL_STACK_SIZE)

/* Run one SQLite call inside the preemption bracket, assigning its
 * result to `dst`. Deliberately a statement, not an expression with a
 * return in it -- see the header note on never spanning a return. */
#define SL_SQL_CALL(dst, expr)                                            \
    do {                                                                  \
        sl_rt_preempt_disable();                                          \
        (dst) = (expr);                                                   \
        sl_rt_preempt_enable();                                           \
    } while (0)
#define SL_SQL_VOID(expr)                                                 \
    do {                                                                  \
        sl_rt_preempt_disable();                                          \
        (expr);                                                           \
        sl_rt_preempt_enable();                                           \
    } while (0)

/* Paired with SL_TASK_SQL_STACK_SIZE (sl_core.c) -- see the derivation
 * there. Applied per connection in sl_sql_open. */
#define SL_SQL_MAX_COMPOUND 50
#define SL_SQL_MAX_EXPR_DEPTH 400

/* stmt error text goes through its owning connection. The returned
 * pointer is SQLite's, valid until the next call on that connection
 * -- every caller hands it straight to sl_sql_err_* to be copied. */
static const char *sl_sql_stmt_err(sqlite3_stmt *st) {
    const char *m;
    sl_rt_preempt_disable();
    sqlite3 *db = sqlite3_db_handle(st);
    m = db ? sqlite3_errmsg(db) : "sql error";
    sl_rt_preempt_enable();
    return m;
}

/* ---- connection lifecycle ---------------------------------------- */

static sl_res_rawptr_str *sl_sql_open(const char *path) {
    if (!path)
        return sl_sql_err_ptr("invalid path");
    SL_SQL_STACK();
    sqlite3 *db = NULL;
    int rc;
    SL_SQL_CALL(rc, sqlite3_open_v2(path, &db,
                                    SQLITE_OPEN_READWRITE |
                                        SQLITE_OPEN_CREATE, NULL));
    if (rc != SQLITE_OK) {
        const char *m;
        SL_SQL_CALL(m, db ? sqlite3_errmsg(db) : sqlite3_errstr(rc));
        sl_res_rawptr_str *r = sl_sql_err_ptr(m);
        SL_SQL_VOID(sqlite3_close_v2(db));
        return r;
    }
    /* Bound SQLite's recursion so the stack requirement above is a
     * measured number rather than a hope. Stock limits (compound 500,
     * expr 1000) allow a legal query needing ~325KB of C stack, which
     * would force a task stack far too fat to spawn per connection.
     * These two caps hold the worst legal query to ~35KB, inside
     * SL_TASK_SQL_STACK_SIZE with margin; anything past them comes
     * back as a descriptive error ("too many terms in compound
     * SELECT", "Expression tree is too large") through the same
     * result[_, str] path as any other failure. Raising either
     * without re-measuring and raising the stack to match reopens the
     * silent heap-corruption failure. */
    SL_SQL_VOID(sqlite3_limit(db, SQLITE_LIMIT_COMPOUND_SELECT,
                              SL_SQL_MAX_COMPOUND));
    SL_SQL_VOID(sqlite3_limit(db, SQLITE_LIMIT_EXPR_DEPTH,
                              SL_SQL_MAX_EXPR_DEPTH));
    return sl_sql_ok_ptr(db);
}

static void sl_sql_close(void *db) {
    if (!db)
        return;
    SL_SQL_STACK();
    SL_SQL_VOID(sqlite3_close_v2((sqlite3 *)db));
}

static sl_res_int_str *sl_sql_exec(void *dbv, const char *sql) {
    sqlite3 *db = (sqlite3 *)dbv;
    if (!db)
        return sl_sql_err_int("nil connection");
    if (!sql)
        return sl_sql_err_int("nil sql");
    SL_SQL_STACK();
    char *emsg = NULL;
    int rc;
    SL_SQL_CALL(rc, sqlite3_exec(db, sql, NULL, NULL, &emsg));
    if (rc != SQLITE_OK) {
        sl_res_int_str *r = sl_sql_err_int(emsg ? emsg : sqlite3_errstr(rc));
        SL_SQL_VOID(sqlite3_free(emsg));
        return r;
    }
    long long changed;
    SL_SQL_CALL(changed, (long long)sqlite3_changes(db));
    return sl_sql_ok_int(changed);
}

static long long sl_sql_last_insert_id(void *dbv) {
    sqlite3 *db = (sqlite3 *)dbv;
    if (!db)
        return 0;
    SL_SQL_STACK();
    long long id;
    SL_SQL_CALL(id, (long long)sqlite3_last_insert_rowid(db));
    return id;
}

/* ---- prepared statements ---------------------------------------- */

static sl_res_rawptr_str *sl_sql_prepare(void *dbv, const char *sql) {
    sqlite3 *db = (sqlite3 *)dbv;
    if (!db)
        return sl_sql_err_ptr("nil connection");
    if (!sql)
        return sl_sql_err_ptr("nil sql");
    SL_SQL_STACK();
    sqlite3_stmt *st = NULL;
    int rc;
    SL_SQL_CALL(rc, sqlite3_prepare_v2(db, sql, -1, &st, NULL));
    if (rc != SQLITE_OK) {
        const char *m;
        SL_SQL_CALL(m, sqlite3_errmsg(db));
        return sl_sql_err_ptr(m);
    }
    if (!st)
        return sl_sql_err_ptr("empty statement");
    return sl_sql_ok_ptr(st);
}

static void sl_sql_finalize(void *st) {
    if (!st)
        return;
    SL_SQL_STACK();
    SL_SQL_VOID(sqlite3_finalize((sqlite3_stmt *)st));
}

static sl_res_bool_str *sl_sql_reset(void *stv) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return sl_sql_err_bool("nil statement");
    SL_SQL_STACK();
    int rc;
    sl_rt_preempt_disable();
    rc = sqlite3_reset(st);
    sqlite3_clear_bindings(st);
    sl_rt_preempt_enable();
    if (rc != SQLITE_OK)
        return sl_sql_err_bool(sl_sql_stmt_err(st));
    return sl_sql_ok_bool(true);
}

/* ---- binding (1-based index) ---------------------------------------- */

static sl_res_bool_str *sl_sql_bind_int(void *stv, long long idx, long long v) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return sl_sql_err_bool("nil statement");
    SL_SQL_STACK();
    int rc;
    SL_SQL_CALL(rc, sqlite3_bind_int64(st, (int)idx, (sqlite3_int64)v));
    if (rc != SQLITE_OK)
        return sl_sql_err_bool(sl_sql_stmt_err(st));
    return sl_sql_ok_bool(true);
}

static sl_res_bool_str *sl_sql_bind_float(void *stv, long long idx, double v) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return sl_sql_err_bool("nil statement");
    SL_SQL_STACK();
    int rc;
    SL_SQL_CALL(rc, sqlite3_bind_double(st, (int)idx, v));
    if (rc != SQLITE_OK)
        return sl_sql_err_bool(sl_sql_stmt_err(st));
    return sl_sql_ok_bool(true);
}

static sl_res_bool_str *sl_sql_bind_text(void *stv, long long idx,
                                         const char *v) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return sl_sql_err_bool("nil statement");
    SL_SQL_STACK();
    int rc;
    SL_SQL_CALL(rc, v ? sqlite3_bind_text(st, (int)idx, v, -1,
                                          SQLITE_TRANSIENT)
                      : sqlite3_bind_null(st, (int)idx));
    if (rc != SQLITE_OK)
        return sl_sql_err_bool(sl_sql_stmt_err(st));
    return sl_sql_ok_bool(true);
}

static sl_res_bool_str *sl_sql_bind_blob(void *stv, long long idx,
                                         sl_bytes *v) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return sl_sql_err_bool("nil statement");
    SL_SQL_STACK();
    int rc;
    SL_SQL_CALL(rc, v ? sqlite3_bind_blob(st, (int)idx, v->ptr,
                                          (int)v->len, SQLITE_TRANSIENT)
                      : sqlite3_bind_null(st, (int)idx));
    if (rc != SQLITE_OK)
        return sl_sql_err_bool(sl_sql_stmt_err(st));
    return sl_sql_ok_bool(true);
}

static sl_res_bool_str *sl_sql_bind_null(void *stv, long long idx) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return sl_sql_err_bool("nil statement");
    SL_SQL_STACK();
    int rc;
    SL_SQL_CALL(rc, sqlite3_bind_null(st, (int)idx));
    if (rc != SQLITE_OK)
        return sl_sql_err_bool(sl_sql_stmt_err(st));
    return sl_sql_ok_bool(true);
}

/* ---- stepping + column access (0-based index) --------------------- */

static sl_res_bool_str *sl_sql_step(void *stv) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return sl_sql_err_bool("nil statement");
    SL_SQL_STACK();
    int rc;
    SL_SQL_CALL(rc, sqlite3_step(st));
    if (rc == SQLITE_ROW)
        return sl_sql_ok_bool(true);
    if (rc == SQLITE_DONE)
        return sl_sql_ok_bool(false);
    return sl_sql_err_bool(sl_sql_stmt_err(st));
}

static long long sl_sql_col_count(void *stv) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return 0;
    SL_SQL_STACK();
    long long n;
    SL_SQL_CALL(n, (long long)sqlite3_column_count(st));
    return n;
}

static const char *sl_sql_col_name(void *stv, long long i) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return sl_strdup("");
    SL_SQL_STACK();
    const char *n;
    SL_SQL_CALL(n, sqlite3_column_name(st, (int)i));
    return sl_strdup(n ? n : "");
}

static bool sl_sql_col_is_null(void *stv, long long i) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return true;
    SL_SQL_STACK();
    int ty;
    SL_SQL_CALL(ty, sqlite3_column_type(st, (int)i));
    return ty == SQLITE_NULL;
}

static long long sl_sql_col_int(void *stv, long long i) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return 0;
    SL_SQL_STACK();
    long long v;
    SL_SQL_CALL(v, (long long)sqlite3_column_int64(st, (int)i));
    return v;
}

static double sl_sql_col_float(void *stv, long long i) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return 0.0;
    SL_SQL_STACK();
    double v;
    SL_SQL_CALL(v, sqlite3_column_double(st, (int)i));
    return v;
}

static const char *sl_sql_col_text(void *stv, long long i) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return sl_strdup("");
    SL_SQL_STACK();
    /* SQLite's buffer is valid only until the next step/reset/
     * finalize on this statement -- copy out before returning. */
    const unsigned char *t;
    SL_SQL_CALL(t, sqlite3_column_text(st, (int)i));
    return sl_strdup(t ? (const char *)t : "");
}

static sl_bytes *sl_sql_col_blob(void *stv, long long i) {
    sqlite3_stmt *st = (sqlite3_stmt *)stv;
    if (!st)
        return sl_bytes_new(NULL, 0);
    SL_SQL_STACK();
    const void *p;
    int n;
    sl_rt_preempt_disable();
    p = sqlite3_column_blob(st, (int)i);
    n = sqlite3_column_bytes(st, (int)i);
    sl_rt_preempt_enable();
    return sl_bytes_new((const unsigned char *)p, (long long)(n < 0 ? 0 : n));
}
