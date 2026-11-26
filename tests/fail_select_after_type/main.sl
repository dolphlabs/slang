let ch: chan[int] = make_chan(1);
select {
    case let v = chan_recv(ch) {
        println(v ?? 0);
    }
    case after("10ms") {
        println("timeout");
    }
}
