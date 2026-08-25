// chan_send's value must match the channel's declared element type
let ch: chan[int] = make_chan(2);
chan_send(ch, "not an int");
