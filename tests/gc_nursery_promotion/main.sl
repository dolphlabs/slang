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

let i = 0;
let keep: [Item] = [];
while i < 100000 {
    let r = make_ok(i);
    guard let item = r else {
        println("FAIL ok() came back as an error");
        exit(1);
    }
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
