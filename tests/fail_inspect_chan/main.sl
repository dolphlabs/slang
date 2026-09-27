// Channels have no readable form; inspect rejects them at compile time.
let c: chan[int] = make_chan(1);
println(inspect(c));
