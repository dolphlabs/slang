// an extern fn with no matching symbol in any linked library must
// fail at link time, not silently succeed
extern fn sl_totally_undefined_ffi_symbol_xyz(n: i32) -> i32;
println(sl_totally_undefined_ffi_symbol_xyz(1));
