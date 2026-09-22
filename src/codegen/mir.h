#ifndef SLANG_MIR_H
#define SLANG_MIR_H

#include "../ast.h"
#include "../loader.h"

#include <stdio.h>

typedef struct CG CG;

typedef struct MirPlace MirPlace;
typedef struct MirRvalue MirRvalue;
typedef struct MirStmt MirStmt;
typedef struct MirBlock MirBlock;
typedef struct MirFn MirFn;

typedef enum {
    MP_LOCAL,
    MP_FIELD,
    MP_DEREF,
    MP_INDEX
} MirPlaceKind;

struct MirPlace {
    MirPlaceKind kind;
    union {
        char *local;
        struct {
            MirPlace *base;
            char *field;
        } field;
        MirPlace *deref;
        struct {
            MirPlace *base;
            Expr *index;
        } index;
    } as;
};

typedef enum {
    MR_USE,
    MR_REF,
    MR_REFMUT,
    MR_EXPR
} MirRvalueKind;

struct MirRvalue {
    MirRvalueKind kind;
    MirPlace *place;
    Expr *expr;
    int line;
};

typedef enum {
    MS_ASSIGN,
    MS_EVAL
} MirStmtKind;

struct MirStmt {
    MirStmtKind kind;
    int line;
    MirPlace *dest;
    MirRvalue *src;
};

typedef enum {
    MT_NONE,
    MT_GOTO,
    MT_IF,
    MT_RETURN,
    MT_UNREACHABLE,
    MT_FOR_IN
} MirTermKind;

typedef struct {
    MirTermKind kind;
    int line;
    int target;
    MirPlace *cond;
    int then_bb;
    int else_bb;
    MirRvalue *ret;
    MirRvalue *iter;
    char *name;
    char *name2;
} MirTerm;

struct MirBlock {
    MirStmt **stmts;
    int nstmts;
    int cap;
    MirTerm term;
};

typedef struct {
    char *name;
    const char *ty;
} MirLocal;

struct MirFn {
    char *pkg;
    char *name;
    /* The type parameters in scope for the body this was lowered from, or
     * NULL. The borrow checker re-reads the original expressions (a struct
     * literal names its own type), so it has to put them back -- it runs
     * long after the cursor that installed them. Typed void * because
     * TypeEnv lives in internal.h, which this header precedes. */
    const void *tenv;
    /* The signature this body was lowered from. Set directly, rather than
     * re-derived from `name` by splitting on dots: an instance's display
     * name ("pkg.Box[int].get", three parts) does not fit the two-part
     * split that lookup used, so for every generic instance it silently
     * found nothing -- cur_ret stayed NULL and no parameter was marked as
     * one in borrowck's initial loan seeding (seed_params). Typed void *
     * for the same reason tenv is. */
    const void *sig;
    MirLocal *locals;
    int nlocals;
    int lcap;
    MirBlock *blocks;
    int nblocks;
    int bcap;
};

typedef struct {
    MirFn **items;
    int count;
    int cap;
} MirTable;

void compute_mir(CG *cg, Package *pkgs, int npkgs, int main_index);
void dump_mir(Package *pkgs, int npkgs, int main_index, FILE *out);

#endif
