// Verify that `extern fn` automatically switches from an 8 KB task stack
// to the OS worker stack so deep C recursion and large C stack frames
// do not overflow task stacks or corrupt heap memory.

link "slffi";

extern fn sl_ffi_deep_stack(depth: i32, out: ptr[i32]) -> i32;
extern fn sl_ffi_big_frame(seed: i32) -> i32;

// ---- 1. direct call from main ----
let main_out: i32 = 0;
let r_deep = sl_ffi_deep_stack(24, &mut main_out);
let r_big = sl_ffi_big_frame(7);
println(r_deep);
println(main_out);
println(r_big);

// ---- 2. concurrent spawned tasks (8 KB task stacks) + GC allocations ----
fn worker(id: int, ch: chan[int]) {
    let sum = 0;
    for i in 0..8 {
        let label = "t-" + to_str(id) + "-" + to_str(i);
        let local_out: i32 = 0;
        let ret = sl_ffi_deep_stack(24, &mut local_out);
        let big = sl_ffi_big_frame(10);
        if ret != local_out || ret != 2475 || big != 80 || len(label) == 0 {
            println("FAIL worker");
            exit(1);
        }
        sum = sum + (ret as int) + (big as int);
    }
    chan_send(ch, sum);
}

let ch: chan[int] = make_chan(16);
for w in 0..16 {
    spawn worker(w, ch);
}
let total = 0;
for w in 0..16 {
    total = total + (chan_recv(ch) ?? -1);
}
println(total);

// ---- 3. extern fn through a function value ----
fn call_via_fn(f: fn(i32, ptr[i32]) -> i32) -> i32 {
    let slot: i32 = 0;
    let res = f(24, &mut slot);
    if res != slot {
        println("FAIL fn_val");
        exit(1);
    }
    return res;
}
println(call_via_fn(sl_ffi_deep_stack));

// ---- 4. spawn directly on an extern fn ----
let h = spawn sl_ffi_big_frame(10);
println(join_wait(h) ?? -1);
