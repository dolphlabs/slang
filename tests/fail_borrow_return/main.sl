fn bad() -> &int {
    let x = 1;
    return &x;
}

println(*bad());
