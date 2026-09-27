struct Rec {
    name: str,
    items: [int],
}

fn churn() {
    let i = 0;
    while i < 200 {
        let s = "padding-padding-" + to_str(i);
        push(["x"], s);
        i = i + 1;
    }
}

fn take(r: own Rec) -> int {
    churn();
    return len(r.name) + len(r.items);
}

let r: own Rec = Rec { name: "abc", items: [1, 2, 3, 4, 5] };
println(take(r));
