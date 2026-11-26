enum Bad {
    A = 1,
    B(int),
}

let x = Bad.B(2);
switch x {
    default {}
}
