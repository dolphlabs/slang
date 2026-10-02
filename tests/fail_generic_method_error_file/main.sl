// The mistake is on line 7 of THIS file. b.get() instantiates the method
// from gbox.sl in the middle of checking this function; the error used to
// be reported as gbox/gbox.sl:7 (the right line, the wrong file).
import "gbox";

fn first(b: gbox.Box[str]) -> opt[int] {
    return to_int(b.get());
}

println(to_str(first(gbox.Box[str] { v: "5" }) ?? 0));
