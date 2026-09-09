/* Signatures for the 'sql' package's native functions -- a thin
 * SQLite driver. See native.c's native_check/native_gen for the
 * table-driven dispatch these plug into, and internal.h for the
 * NatSig/NatArgKind types. Every fallible call returns
 * result[_, str] carrying sqlite3_errmsg text, matching the
 * net/fs visibility story. NA_I64/NA_F64 keep bind values from
 * being truncated through native.c's default i32 marshaling. */

#include "../internal.h"

const NatSig SQL_SIGS[] = {
    {"sql", "open", 1, {NA_STR}, "result[rawptr,str]", 0},
    {"sql", "close", 1, {NA_RAWPTR}, NULL, 0},
    {"sql", "exec", 2, {NA_RAWPTR, NA_STR}, "result[int,str]", 0},
    {"sql", "last_insert_id", 1, {NA_RAWPTR}, "int", 0},
    {"sql", "prepare", 2, {NA_RAWPTR, NA_STR}, "result[rawptr,str]", 0},
    {"sql", "finalize", 1, {NA_RAWPTR}, NULL, 0},
    {"sql", "reset", 1, {NA_RAWPTR}, "result[bool,str]", 0},

    {"sql", "bind_int", 3, {NA_RAWPTR, NA_I64, NA_I64}, "result[bool,str]", 0},
    {"sql", "bind_float", 3, {NA_RAWPTR, NA_I64, NA_F64}, "result[bool,str]", 0},
    {"sql", "bind_text", 3, {NA_RAWPTR, NA_I64, NA_STR}, "result[bool,str]", 0},
    {"sql", "bind_blob", 3, {NA_RAWPTR, NA_I64, NA_BYTES}, "result[bool,str]", 0},
    {"sql", "bind_null", 2, {NA_RAWPTR, NA_I64}, "result[bool,str]", 0},

    {"sql", "step", 1, {NA_RAWPTR}, "result[bool,str]", 0},
    {"sql", "col_count", 1, {NA_RAWPTR}, "int", 0},
    {"sql", "col_name", 2, {NA_RAWPTR, NA_I64}, "str", 0},
    {"sql", "col_is_null", 2, {NA_RAWPTR, NA_I64}, "bool", 0},
    {"sql", "col_int", 2, {NA_RAWPTR, NA_I64}, "int", 0},
    {"sql", "col_float", 2, {NA_RAWPTR, NA_I64}, "float", 0},
    {"sql", "col_text", 2, {NA_RAWPTR, NA_I64}, "str", 0},
    {"sql", "col_blob", 2, {NA_RAWPTR, NA_I64}, "bytes", 0},
};

const int SQL_SIGS_LEN = sizeof(SQL_SIGS) / sizeof(SQL_SIGS[0]);
