// pkgdemo/main.sl - demonstrates slang packages
//
// Directory layout:
//   main.sl            this file (entry point)
//   geometry/shapes.sl  pub fns + private helper
//   geometry/consts.sl  pub lets + private let
//   textutil/greet.sl   pub fn

import "geometry";
import "textutil";

// qualified access to exported functions
println(geometry.area(3.0, 4.0));
println(textutil.shout("hello"));

// qualified access to exported variables
println(geometry.origin_x);
println(geometry.pi);

// unqualified calls still work within the same package
fn helper() -> int {
    return 7;
}
println(helper());

let local = 5;
println(local + geometry.double_it(local));