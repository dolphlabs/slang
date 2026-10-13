// strings.find/rfind/contains/has_prefix/has_suffix/count/find_field only
// read their arguments, so a call to one is no collection point and gets
// no safepoint bracket (run_tests.sh counts the brackets in the generated
// C). Values live across those calls must survive collections that happen
// elsewhere: this keeps a list of fresh strings alive through a loop of
// leaf calls and allocating ones, under a 16 KB nursery in the GC lists.
import "strings";

fn classify(line: str) -> int {
    if strings.has_prefix(line, "date:") || strings.has_prefix(line, "Date:") {
        return 1;
    }
    if strings.has_suffix(line, ";") && strings.contains(line, "=") {
        return 2;
    }
    return strings.count(line, "a") + strings.find(line, "b") + strings.rfind(line, "c");
}

let block = to_bytes("Content-Length: 3\r\nX: y");
let kept: [str] = [];
let total = 0;
let i = 0;
while i < 20000 {
    let fresh = "line-" + to_str(i) + "-abc";
    push(kept, fresh);
    let upper = strings.to_upper(fresh);    // allocates: keeps its bracket
    total = total + classify(fresh) + classify(upper) + classify("date: x") +
            classify("k=v;");
    if strings.find_field(block, "content-length") < 0 {
        println("find_field");
    }
    i = i + 1;
}
println(total);
println(len(kept));
println(kept[0] + " " + kept[19999]);
