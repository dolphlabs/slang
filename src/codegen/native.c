/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "internal.h"

#include <string.h>

/* Each native package with fixed-signature functions (i.e. every one
 * except json, which is generic over a target type -- see
 * pkg_json/dispatch.c) keeps its own NatSig table in its own
 * pkg_<name>/sigs.c. Adding a package means adding one line here. */
static const NatSig *find_sig(const NatSig *sigs, int len, const char *pkg,
                              const char *fname) {
    for (int i = 0; i < len; i++)
        if (!strcmp(sigs[i].pkg, pkg) && !strcmp(sigs[i].name, fname))
            return &sigs[i];
    return NULL;
}

/* Every signature of native package pkg, in table order (slangc doc). */
/* Whether pkg.name is a pure C leaf. A call to one is not a
 * safepoint: nothing in it can collect, so the bracket that roots live
 * values and checks for a stop is pure cost (about 16 ns a call on the
 * request path, where http checks header names with strings.has_prefix).
 * A task async-preempted inside one is scanned conservatively, like any
 * other C code in the program's text. */
int native_is_leaf(const char *pkg, const char *name) {
    /* All of math reads its arguments and computes (runtime/sl_math.c),
     * except the format* family, which builds a str. */
    if (!strcmp(pkg, "math"))
        return strncmp(name, "format", 6) != 0;
    /* Each one only reads its arguments: checked in runtime/sl_strings.c,
     * where none allocates or calls out. Add a native here only after
     * reading its C the same way. */
    static const char *const leaves[] = {
        "strings.find", "strings.rfind", "strings.contains",
        "strings.has_prefix", "strings.has_suffix", "strings.count",
        "strings.find_field",
        /* reads the clock and the date cache's atomics; never allocates */
        "time.put_http_date",
    };
    size_t pl = strlen(pkg);
    for (size_t i = 0; i < sizeof(leaves) / sizeof(leaves[0]); i++) {
        const char *l = leaves[i];
        if (!strncmp(l, pkg, pl) && l[pl] == '.' && !strcmp(l + pl + 1, name))
            return 1;
    }
    return 0;
}

int native_sigs_of(const char *pkg, const NatSig **out, int max) {
    const struct { const NatSig *sigs; int len; } tabs[] = {
        {TIME_SIGS, TIME_SIGS_LEN},       {NET_SIGS, NET_SIGS_LEN},
        {PROC_SIGS, PROC_SIGS_LEN},       {FS_SIGS, FS_SIGS_LEN},
        {LOG_SIGS, LOG_SIGS_LEN},         {CRYPTO_SIGS, CRYPTO_SIGS_LEN},
        {SQL_SIGS, SQL_SIGS_LEN},         {REGEX_SIGS, REGEX_SIGS_LEN},
        {OS_SIGS, OS_SIGS_LEN},           {STRINGS_SIGS, STRINGS_SIGS_LEN},
        {ENCODING_SIGS, ENCODING_SIGS_LEN}, {COMPRESS_SIGS, COMPRESS_SIGS_LEN},
        {IO_SIGS, IO_SIGS_LEN},           {MATH_SIGS, MATH_SIGS_LEN},
    };
    int n = 0;
    for (size_t t = 0; t < sizeof(tabs) / sizeof(tabs[0]); t++)
        for (int i = 0; i < tabs[t].len && n < max; i++)
            if (!strcmp(tabs[t].sigs[i].pkg, pkg))
                out[n++] = &tabs[t].sigs[i];
    return n;
}

/* A native package's function names that fname could have meant. */
static const char *suggest_native(const char *pkg, const char *fname) {
    const NatSig *sigs[512];
    const char *names[512];
    int n = native_sigs_of(pkg, sigs, 512);
    for (int i = 0; i < n; i++)
        names[i] = sigs[i]->name;
    return did_you_mean(fname, names, n);
}

static const NatSig *find_any_sig(const char *pkg, const char *fname) {
    const NatSig *ns = find_sig(TIME_SIGS, TIME_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(NET_SIGS, NET_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(PROC_SIGS, PROC_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(FS_SIGS, FS_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(LOG_SIGS, LOG_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(CRYPTO_SIGS, CRYPTO_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(SQL_SIGS, SQL_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(REGEX_SIGS, REGEX_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(OS_SIGS, OS_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(STRINGS_SIGS, STRINGS_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(ENCODING_SIGS, ENCODING_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(COMPRESS_SIGS, COMPRESS_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(IO_SIGS, IO_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(MATH_SIGS, MATH_SIGS_LEN, pkg, fname);
    return ns;
}

const NatSig *native_find_sig(const char *pkg, const char *fname) {
    return find_any_sig(pkg, fname);
}

static NatArgKind nat_argkind(const char *pkg, const char *fname, int i) {
    const NatSig *ns = find_any_sig(pkg, fname);
    if (!ns || i < 0 || i >= ns->nargs)
        return NA_INT;
    return ns->argkinds[i];
}

/* Validate a call into a native package and return its slang return
 * type. */
const char *native_check(CG *cg, const char *pkg, const char *fname,
                                Expr *e) {
    const NatSig *ns = find_any_sig(pkg, fname);
    if (!ns)
        cg_error(e->line, "package '%s' has no function '%s'%s", pkg, fname,
                 suggest_native(pkg, fname));
    int n = e->as.call.nargs;
    if (n != ns->nargs)
        cg_error(e->line,
                 "function '%s.%s' expects %d argument(s), got %d", pkg,
                 fname, ns->nargs, n);
    if (ns->is_tls)
        cg->want_tls = 1;
    if (!strcmp(pkg, "net") &&
        (!strcmp(fname, "lookup_srv_until") ||
         !strcmp(fname, "lookup_txt_until")))
        cg->want_dns = 1;
    if (!strcmp(pkg, "proc") && !strcmp(fname, "shutdown_requested"))
        cg->want_shutdown = 1;
    if (!strcmp(pkg, "os") && (!strcmp(fname, "watch") || !strcmp(fname, "watch_next") || !strcmp(fname, "watch_close")))
        cg->want_fswatch = 1;

    const char *argt[8] = {0};
    for (int i = 0; i < n; i++) {
        const char *at = infer_type(cg, e->as.call.args[i]);
        argt[i] = at;
        int ok;
        const char *want;
        switch (ns->argkinds[i]) {
        case NA_NUM:
        case NA_NUM_FLT:
            ok = is_num(at);
            want = "a number";
            break;
        case NA_NUM_INT:
            ok = is_int(at);
            want = "an integer";
            break;
        case NA_STR:    ok = is_str(at);    want = "a str";    break;
        case NA_STR_FAULT:
            ok = is_str(at) || is_fault(at);
            want = "a str or fault";
            break;
        case NA_BYTES:  ok = is_bytes(at);  want = "bytes";    break;
        case NA_RAWPTR: ok = is_rawptr(at); want = "a rawptr"; break;
        case NA_WIRE:
            ok = is_wire(at);
            want = "a wire";
            break;
        case NA_F64:
            ok = is_flt(at) || is_int(at);
            want = "a float";
            break;
        case NA_ARR_STR:
            ok = is_arr(at) && is_str(arr_elem(at));
            want = "a [str]";
            break;
        case NA_ARR_BYTES:
            ok = is_arr(at) && is_bytes(arr_elem(at));
            want = "a [bytes]";
            break;
        case NA_UNTIL:
            ok = is_until(at);
            want = "an until (try until_of(time.mono() + ns))";
            break;
        default: /* NA_INT, NA_I64 */
            ok = is_int(at);
            want = "an integer";
            break;
        }
        if (!ok)
            cg_error(e->line, "%s.%s argument %d must be %s (got %s)", pkg,
                     fname, i + 1, want, at);
    }
    const char *t = math_type_of_args(ns, e->as.call.args, argt, e->line);
    return t ? math_ret_type(ns, t) : ns->ret;
}

/* Tier 10: arguments would otherwise be embedded directly as sibling
 * call arguments to the runtime helper, whose relative evaluation
 * order C leaves unspecified -- this site never went through the
 * original sequencing fix (found while extending safepoint brackets
 * to native calls; every native function with 2+ arguments, across
 * net/time/proc, had this latent Risk 1 gap already). Sequenced one
 * argument at a time via sequence_one, same as gen_call's own
 * arguments, so a nested call in a later argument can see an earlier
 * one's already-registered temp. The whole call is then wrapped with
 * a safepoint bracket built from e->live_set, closing the "native
 * calls bypass gen_call's bracket entirely" gap: infer_type(cg, e)
 * is consulted for the result type, guarded against BOTH void
 * conventions in this compiler -- infer_call's hand-written builtin
 * cases return the string "void", but native_check (this file)
 * returns a NatSig->ret field that's genuinely NULL for void
 * (confirmed directly: time.sleep's own table entry, pkg_time/sigs.c). */
char *native_gen(CG *cg, const char *pkg, const char *fname,
                        Expr *e) {
    StrBuf sb;
    sb_init(&sb);
    int nargs = e->as.call.nargs;
    /* math's T (pkg_math/dispatch.c): the C function is instantiated per
     * type, sl_math_abs_i32, and each NA_NUM argument is cast to T. */
    const NatSig *ns = find_any_sig(pkg, fname);
    const char *mt = NULL;
    if (ns && !strcmp(pkg, "math")) {
        const char *argt[8] = {0};
        for (int i = 0; i < nargs && i < 8; i++)
            argt[i] = infer_type(cg, e->as.call.args[i]);
        mt = math_type_of_args(ns, e->as.call.args, argt, e->line);
    }
    if (mt)
        sb_append(&sb, xasprintf("sl_math_%s_%s(", sanitize_ident(fname),
                                 math_suffix(mt)));
    else
        sb_append(&sb, xasprintf("sl_%s_%s(", sanitize_pkg(pkg),
                                 sanitize_ident(fname)));
    StrBuf prelude;
    sb_init(&prelude);
    int seq_id = nargs > 1 ? cg->tmp_id++ : -1;
    int ambient_mark = cg->ambient_count;
    for (int i = 0; i < nargs; i++) {
        if (i)
            sb_append(&sb, ", ");
        const char *at = infer_type(cg, e->as.call.args[i]);
        NatArgKind ak = nat_argkind(pkg, fname, i);
        char *a = gen_expr(cg, e->as.call.args[i]);
        const char *cast_t = at;
        if (mt && (ak == NA_NUM || ak == NA_NUM_INT || ak == NA_NUM_FLT)) {
            cast_t = mt;
            a = maybe_cast(cg, cast_t, at, a);
        } else if (ak == NA_STR_FAULT && is_fault(at)) {
            a = conv_to_str(cg, at, a);
            cast_t = "str";
        } else if (ak == NA_F64) {
            cast_t = "float";
            a = maybe_cast(cg, cast_t, at, a);
        } else if (ak == NA_I64) {
            cast_t = "int";
            a = maybe_cast(cg, cast_t, at, a);
        } else if (ak == NA_ARR_STR) {
            cast_t = "[str]"; /* already sl_arr *; must not fall through
                                 to the i32 default below */
        } else if (ak == NA_ARR_BYTES) {
            cast_t = "[bytes]"; /* already sl_arr *, like [str] above */
        } else if (ak == NA_WIRE) {
            cast_t = "wire"; /* already sl_wire; must not fall through
                                to the i32 default below */
        } else if (ak == NA_UNTIL) {
            cast_t = "until"; /* already int64_t; no conversion, but the
                                 cast_t must not fall through to the i32
                                 default below and truncate the deadline */
        } else if (!is_str(at) && !is_bytes(at) && !is_rawptr(at) &&
                   !is_wire(at)) {
            cast_t = !strcmp(pkg, "time") ? "int" : "i32";
            a = maybe_cast(cg, cast_t, at, a);
        }
        a = sequence_one(cg, seq_id, i, ctype_of(cg, cast_t), cast_t, a,
                         e->as.call.args[i], &prelude);
        sb_append(&sb, a);
    }
    const char *rt = infer_type(cg, e);
    const char *rc = (!rt || !strcmp(rt, "void")) ? NULL : ctype_of(cg, rt);
    if (!strcmp(pkg, "math")) {
        if (math_takes_at(fname))
            sb_append(&sb, xasprintf("%s%s", nargs ? ", " : "",
                                     panic_at(cg, e->line)));
        /* math's opts are by value, with nothing allocated: the C
         * function takes an out pointer and says whether it wrote one. */
        if (rt && is_opt(rt)) {
            const char *inner = opt_inner(rt);
            int id = cg->tmp_id++;
            sb_append(&sb, xasprintf("%s&_sl_mv%d)", nargs ? ", " : "", id));
            char *call = sb.data;
            sb_init(&sb);
            sb_append(&sb, xasprintf(
                "({ %s _sl_mv%d; bool _sl_mh%d = %s; %s _sl_mo%d = { 0 }; "
                "_sl_mo%d.has = _sl_mh%d; if (_sl_mh%d) _sl_mo%d.v = _sl_mv%d; "
                "_sl_mo%d; })",
                ctype_of(cg, inner), id, id, call, rc, id, id, id, id, id, id,
                id));
            char *result = wrap_safepoint(cg, e, rc, prelude.data, sb.data);
            cg->ambient_count = ambient_mark;
            return result;
        }
    }
    sb_append(&sb, ")");
    /* Natives build their results and opts on the heap (the runtime
     * predates by-value ones and returns `sl_res_* *` / `sl_opt_* *`);
     * slang holds both by value, so the call's struct is copied out here. The box is garbage
     * from this point, and nothing else holds it. */
    if (rt && (is_result(rt) || is_opt(rt))) {
        char *boxed = xasprintf("(*%s)", sb.data);
        sb_init(&sb);
        sb_append(&sb, boxed);
    }
    /* Tier 10: wrap_safepoint must see every sequenced argument's
     * ambient registration -- a native function (net/time/proc) has no
     * safepoint bracket of its own to protect them once "passed" the
     * way a real slang callee would; THIS call's own bracket (built
     * here) is the only thing that can. Popping ambient before this
     * call (mirroring gen_call's tail, safe there only because a real
     * slang callee protects its own params once entered) left any
     * multi-argument native call's later arguments unrooted at this
     * bracket's own entry checkin whenever an earlier argument wasn't
     * independently live afterward -- the same class of bug found via
     * a stress test forcing a real collection through push/chan_send/
     * has/del (expr.c). */
    char *result = wrap_safepoint(cg, e, rc, prelude.data, sb.data);
    cg->ambient_count = ambient_mark;
    return result;
}
