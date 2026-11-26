enum Node {
    Leaf,
    Branch(Node),
}

let n = Node.Leaf;
switch n {
    default {}
}
