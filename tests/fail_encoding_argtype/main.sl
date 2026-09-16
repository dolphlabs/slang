// encoding.hex_encode takes `bytes`, not `str`. The two are genuinely
// different here -- hex_encode of a str would have to decide what to do
// with a NUL, and the answer is that the caller should say which they
// mean -- so the NatSig table must reject this at COMPILE time rather
// than let it marshal through as a pointer.
//
// Same shape as tests/fail_proc_getenv_argtype: it exercises the
// table-driven check in native.c, not this package in particular.
import "encoding";

println(encoding.hex_encode("not bytes"));
