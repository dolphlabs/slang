let ch: chan[int] = make_chan(1);
let on = false;
select {
    case let v = chan_recv(ch) when on {
        println(v ?? 0);
    }
    case after(1000000) when false {
        println("timeout");
    }
}
