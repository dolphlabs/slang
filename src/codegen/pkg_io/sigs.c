/* Signatures for the 'io' package's native functions -- see native.c's
 * native_check/native_gen for the table-driven dispatch these plug
 * into, and internal.h for the NatSig/NatArgKind types.
 *
 * `io` is the process's standard streams: what a command-line program
 * needs that print/println and proc.args() don't already give it.
 * Reading is here because there was no way to do it: fs.read(0, n)
 * happened to work (fd 0 is an fd) but blocked a whole worker thread,
 * left a prompt sitting unflushed in stdout, and handed back raw
 * chunks rather than lines.
 *
 * Error model, per the README's opt/result/fault rule:
 *   read_line   result[opt[str], str]   none = end of input (absence,
 *               not failure); err = the read itself failed
 *   read_all    result[bytes, str]      EOF is how it finishes, so it
 *               has no opt to return; err = the read failed or the
 *               input was too large to hold
 * The write side (eprint/eprintln/flush) cannot fail in a way a caller
 * can act on -- a closed stderr has nowhere left to report it -- so
 * those return nothing, like log.
 *
 * Nothing here needs a link flag: it is all libc. It does run on the
 * net reactor (parking the task, not the thread, while it waits for
 * input), so importing `io` pulls in that runtime -- see program.c. */

#include "../internal.h"

const NatSig IO_SIGS[] = {
    {"io", "read_line", 0, {0}, "result[opt[str],str]", 0},
    {"io", "read_all", 0, {0}, "result[bytes,str]", 0},

    /* NA_STR_FAULT, like log: a fault (err_of on a net/fs result) prints
       with its op and errno without a manual to_str. */
    {"io", "eprint", 1, {NA_STR_FAULT}, NULL, 0},
    {"io", "eprintln", 1, {NA_STR_FAULT}, NULL, 0},

    {"io", "flush", 0, {0}, NULL, 0},
    {"io", "is_tty", 1, {NA_INT}, "bool", 0},
};

const int IO_SIGS_LEN = sizeof(IO_SIGS) / sizeof(IO_SIGS[0]);
