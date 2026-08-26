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

static const NatSig *find_any_sig(const char *pkg, const char *fname) {
    const NatSig *ns = find_sig(TIME_SIGS, TIME_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(NET_SIGS, NET_SIGS_LEN, pkg, fname);
    if (!ns)
        ns = find_sig(PROC_SIGS, PROC_SIGS_LEN, pkg, fname);
    return ns;
}

/* Validate a call into a native package and return its slang return
 * type. */
const char *native_check(CG *cg, const char *pkg, const char *fname,
                                Expr *e) {
    const NatSig *ns = find_any_sig(pkg, fname);
    if (!ns)
        cg_error(e->line, "package '%s' has no function '%s'", pkg, fname);
    int n = e->as.call.nargs;
    if (n != ns->nargs)
        cg_error(e->line,
                 "function '%s.%s' expects %d argument(s), got %d", pkg,
                 fname, ns->nargs, n);
    if (ns->is_tls)
        cg->want_tls = 1;

    for (int i = 0; i < n; i++) {
        const char *at = infer_type(cg, e->as.call.args[i]);
        int ok;
        const char *want;
        switch (ns->argkinds[i]) {
        case NA_STR:    ok = is_str(at);    want = "a str";    break;
        case NA_BYTES:  ok = is_bytes(at);  want = "bytes";    break;
        case NA_RAWPTR: ok = is_rawptr(at); want = "a rawptr"; break;
        default:        ok = is_int(at);    want = "an integer"; break;
        }
        if (!ok)
            cg_error(e->line, "%s.%s argument %d must be %s (got %s)", pkg,
                     fname, i + 1, want, at);
    }
    return ns->ret;
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
    sb_append(&sb, xasprintf("sl_%s_%s(", sanitize_pkg(pkg),
                             sanitize_ident(fname)));
    int nargs = e->as.call.nargs;
    StrBuf prelude;
    sb_init(&prelude);
    int seq_id = nargs > 1 ? cg->tmp_id++ : -1;
    int ambient_mark = cg->ambient_count;
    for (int i = 0; i < nargs; i++) {
        if (i)
            sb_append(&sb, ", ");
        const char *at = infer_type(cg, e->as.call.args[i]);
        char *a = gen_expr(cg, e->as.call.args[i]);
        const char *cast_t = at;
        if (!is_str(at) && !is_bytes(at) && !is_rawptr(at)) {
            cast_t = !strcmp(pkg, "time") ? "int" : "i32";
            a = maybe_cast(cg, cast_t, at, a);
        }
        a = sequence_one(cg, seq_id, i, ctype_of(cg, cast_t), cast_t, a,
                         e->as.call.args[i], &prelude);
        sb_append(&sb, a);
    }
    cg->ambient_count = ambient_mark;
    sb_append(&sb, ")");
    const char *rt = infer_type(cg, e);
    const char *rc = (!rt || !strcmp(rt, "void")) ? NULL : ctype_of(cg, rt);
    return wrap_safepoint(cg, e, rc, prelude.data, sb.data);
}
