enum Bad {
    Owned(own int),
}

let x = Bad.Owned(1);
switch x {
    default {}
}
