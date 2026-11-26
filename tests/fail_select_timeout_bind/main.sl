let ch: chan[int] = make_chan(1);
select {
    case let t = after(1000) {
        println("timeout");
    }
}
