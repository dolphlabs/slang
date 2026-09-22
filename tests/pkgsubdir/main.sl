// A pinned package whose code lives in a sub-directory of its
// repository: `pkg demo git <url> tag v1 dir src`.
//
// The repository also holds examples/broken.sl, which is not slang at
// all. Compiling this program proves the consumer took src/ and nothing
// else -- a library can ship its examples, docs and tests without
// pushing them into everyone's build.
import "demo";

let g = demo.hello("slang");
println(g.text);
