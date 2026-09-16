// two default arms: only one can ever run, so it is a typo, not a choice
let c: chan[int] = make_chan(1);
select {
    case let v = chan_recv(c) { println("a"); }
    default { println("b"); }
    default { println("c"); }
}
