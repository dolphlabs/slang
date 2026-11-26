let ch: chan[int] = make_chan(1);
select {
    case let v = chan_recv(ch) when 123 {
        println(v ?? 0);
    }
}
