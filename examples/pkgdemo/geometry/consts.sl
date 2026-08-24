// geometry/consts.sl - package-level variables
//
// In an imported package, top-level 'let' declarations become
// package globals. They must be initialized with constant literals.

pub let origin_x = 0;
pub let pi = 3.14159;

// private global: not visible to importers
let secret = 42;

// pub fn defined in another file of this package is callable here
pub fn double_it(n: int) -> int {
    return n * 2;
}