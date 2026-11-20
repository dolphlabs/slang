// A field store into a list element is bounds-checked like any index.
struct P { x: int }
let xs: [P] = [P { x: 1 }];
xs[3].x = 2;
