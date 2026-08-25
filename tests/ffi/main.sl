// C interop: extern fn declarations, the 'link' directive, and the
// rawptr opaque pointer type, exercised end to end against a tiny
// hand-written C fixture library (tests/ffi/lib.c). run_tests.sh
// builds libslffi.a and points LIBRARY_PATH at it before compiling
// this file.

link "slffi";

extern fn sl_ffi_add(a: i32, b: i32) -> i32;
extern fn sl_ffi_greet(name: str) -> str;
extern fn sl_ffi_counter_new(start: i32) -> rawptr;
extern fn sl_ffi_counter_next(h: rawptr) -> i32;
extern fn sl_ffi_counter_free(h: rawptr);
extern fn sl_ffi_sum_bytes(ptr: rawptr, len: i32) -> i32;
extern fn sl_ffi_null() -> rawptr;

println(sl_ffi_add(2, 40));
println(sl_ffi_greet("slang"));

// rawptr: an opaque handle round-tripped through extern calls; it is
// foreign (malloc'd) memory, so it is freed explicitly, not by the GC
let h = sl_ffi_counter_new(10);
println(sl_ffi_counter_next(h));
println(sl_ffi_counter_next(h));
println(sl_ffi_counter_next(h));
sl_ffi_counter_free(h);

// bytes_ptr() hands a bytes buffer's raw pointer across the FFI
// boundary; len() supplies the matching length
let buf = b"\x01\x02\x03\x04";
println(sl_ffi_sum_bytes(bytes_ptr(buf), len(buf) as i32));

// nullptr is rawptr's null value, comparable with == / !=
if sl_ffi_null() == nullptr {
    println("null ok");
} else {
    println("FAIL null");
}
