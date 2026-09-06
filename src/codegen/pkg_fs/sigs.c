#include "../internal.h"

const NatSig FS_SIGS[] = {
    {"fs", "open", 1, {NA_STR}, "result[i32,str]", 0},
    {"fs", "create", 1, {NA_STR}, "result[i32,str]", 0},
    {"fs", "read", 2, {NA_INT, NA_INT}, "result[bytes,str]", 0},
    {"fs", "write", 2, {NA_INT, NA_BYTES}, "result[i32,str]", 0},
    {"fs", "close", 1, {NA_INT}, "result[bool,str]", 0},
    {"fs", "mkdir", 1, {NA_STR}, "result[bool,str]", 0},
};

const int FS_SIGS_LEN = sizeof(FS_SIGS) / sizeof(FS_SIGS[0]);
