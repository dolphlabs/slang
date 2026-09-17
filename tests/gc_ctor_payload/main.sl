// ok(), err() and some() used to allocate their wrapper BEFORE evaluating
// the payload, holding the wrapper in a C local no safepoint knew about.
// A payload containing a call enters a safepoint, a safepoint can
// collect, and the collection freed the wrapper -- the payload was then
// stored into memory already handed to another object. The same for a
// `gc` box. Hidden while the collector treated each task's recent
// allocations as roots.
//
// Each payload below makes a call that allocates, so across a million
// iterations collections land inside payload evaluation many times over,
// and every value is checked after it is built.

gc struct Item {
    name: str,
    n: int,
}

fn label(i: int) -> str {
    return "item-" + to_str(i);
}

fn make_ok(i: int) -> result[Item, str] {
    return ok(Item { name: label(i), n: i });
}

fn make_err(i: int) -> result[int, str] {
    return err(label(i));
}

fn make_some(i: int) -> opt[str] {
    return some(label(i));
}

let i = 0;
let keep: [Item] = [];
while i < 1000000 {
    let r = make_ok(i);
    guard let item = r else {
        println("FAIL ok() came back as an error");
        exit(1);
    }
    if item.n != i || item.name != label(i) {
        println("FAIL ok() payload corrupted at " + to_str(i));
        exit(1);
    }
    let er = make_err(i);
    guard let x = er else let e = err_of(er) {
        if e != label(i) {
            println("FAIL err() payload corrupted at " + to_str(i));
            exit(1);
        }
    }
    let s = make_some(i) ?? "";
    if s != label(i) {
        println("FAIL some() payload corrupted at " + to_str(i));
        exit(1);
    }
    // keep a little alive so the heap is not all garbage
    if i % 1000 == 0 {
        push(keep, item);
    }
    i = i + 1;
}
let j = 0;
while j < len(keep) {
    if keep[j].n != j * 1000 || keep[j].name != label(j * 1000) {
        println("FAIL kept item corrupted");
        exit(1);
    }
    j = j + 1;
}
println("PASS");
