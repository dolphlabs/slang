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
