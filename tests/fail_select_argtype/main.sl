// chan_recv in a select arm still needs a chan
select {
    case let v = chan_recv(5) { println("no"); }
}
