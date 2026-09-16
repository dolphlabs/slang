// a chan_send arm produces no value, so there is nothing to bind
let c: chan[int] = make_chan(1);
select {
    case let v = chan_send(c, 1) { println("no"); }
}
