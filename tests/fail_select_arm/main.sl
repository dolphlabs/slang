// a select arm must be chan_recv/chan_send, not an arbitrary call
fn ready() -> bool { return true; }
let c: chan[int] = make_chan(1);
select {
    case let v = ready() { println("no"); }
}
