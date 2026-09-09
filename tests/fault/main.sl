println(until_hit(until_never()));
println(until_hit(until_of(1)));

let f = fault_timeout();
println(fault_kind(f));
println(f == fault_timeout());
println(f == fault_reset());
println(f);
println(fault_reset());
println(fault_closed());
println(fault_io());
println(fault_refused());

println(to_str(fault_io()));

println(fault_code(fault_io()));
println(fault_op(fault_io()));

let p = peer_v4(127, 0, 0, 1, 8080);
println(peer_port(p));
println(p == peer_v4(127, 0, 0, 1, 8080));
println(p == peer_v4(10, 0, 0, 1, 8080));
println(p);

let t = trip_new();
println(t.down());
t.pull();
println(t.down());
