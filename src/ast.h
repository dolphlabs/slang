#ifndef SLANG_AST_H
#define SLANG_AST_H

/* Expression nodes */
typedef enum {
    EX_INT,
    EX_FLOAT,
    EX_STRING,
    EX_BYTES,
    EX_BOOL,
    EX_IDENT,
    EX_BINARY,
    EX_UNARY,
    EX_CALL,
    EX_CAST,   /* operand as T */
    EX_INDEX,  /* base[index] */
    EX_SLICE,  /* base[start..end] (either end optional) */
    EX_LIST    /* [a, b, c] */
} ExprKind;

typedef struct Expr Expr;

struct Expr {
    ExprKind kind;
    int line;
    union {
        struct { long long value; } int_lit;
        struct { double value; } float_lit;
        struct { char *value; } str_lit;
        struct { unsigned char *data; long long len; } bytes_lit;
        struct { int value; } bool_lit;
        struct { char *name; } ident;
        struct { char *op; Expr *lhs; Expr *rhs; } binary;
        struct { char *op; Expr *operand; } unary;
        struct { char *name; Expr **args; int nargs; } call;
        struct { char *ty; Expr *operand; } cast; /* slang type name */
        struct { Expr *base; Expr *index; } index;
        struct {
            Expr *base;
            Expr *start; /* NULL => from the beginning */
            Expr *end;   /* NULL => through the end */
            int inclusive;
        } slice;
        struct { Expr **elems; int nelems; } list;
    } as;
};

/* Statement nodes */
typedef enum {
    ST_LET,
    ST_ASSIGN,
    ST_IF,
    ST_WHILE,
    ST_FOR,
    ST_FOR_IN,
    ST_RETURN,
    ST_EXPR
} StmtKind;

typedef struct Stmt Stmt;

typedef struct {
    Stmt **stmts;
    int count;
    int cap;
} Block;

struct Stmt {
    StmtKind kind;
    int line;
    union {
        struct {
            char *name;
            char *type_ann; /* slang type name from 'let x: T = ...', or NULL */
            Expr *init;
            int is_pub;
        } let;
        struct {
            Expr *target; /* EX_IDENT or EX_INDEX */
            Expr *value;
        } assign;
        struct { Expr *cond; Block *then_blk; Block *else_blk; } if_stmt;
        struct { Expr *cond; Block *body; } while_stmt;
        struct {
            char *name;
            Expr *start;
            Expr *end;
            int inclusive;
            Block *body;
        } for_stmt;
        struct {
            char *name;   /* loop variable */
            Expr *iter;   /* iterable: [T] array or bytes */
            Block *body;
        } for_in;
        struct { Expr *value; } ret; /* value may be NULL */
        struct { Expr *expr; } expr_stmt;
    } as;
};

/* Function declarations */
typedef struct {
    char *name;
    char **params;      /* parameter names */
    char **param_types; /* slang type names: "int", "bytes", "[int]", ... */
    int nparams;
    char *ret_type;     /* slang type name, or NULL for void */
    Block *body;
    int is_pub;         /* exported from its package */
    int line;
} FuncDecl;

typedef struct {
    FuncDecl **funcs;
    int nfuncs;
    int fcap;
    Block *main_body;   /* top-level statements (executable only in main pkg) */
    char **import_paths;/* 'import "path"' statements, in order */
    int nimports;
    int icap;
} Program;

#endif /* SLANG_AST_H */