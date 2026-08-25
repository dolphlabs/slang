// sending on a closed channel is a runtime error (checked, not UB);
// from the main task it terminates the whole process like any other
// unrecovered runtime error
let ch: chan[int] = make_chan(2);
chan_close(ch);
chan_send(ch, 5);
