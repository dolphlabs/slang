// GC'd container types have no stable C representation and must not
// cross an extern fn boundary
extern fn sl_bad(m: map[str]int) -> i32;
