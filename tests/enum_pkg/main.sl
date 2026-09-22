// An enum declared in one package, used from another.
//
// A library whose API takes an enum is not usable unless the importing
// package can name the variants, and `orders.Status.Paid` parses as a
// FIELD of `orders.Status` (an identifier carries at most one dot), so
// the enum rewrite has to recognise that shape -- and the method shape
// `orders.Status.from_str(s)` with it.
import "orders";

let o = orders.Order { id: 1, status: orders.Status.Paid };
println(orders.describe(o));
println(to_str(orders.Status.Pending));
println(orders.Status.Paid as i32);
println(orders.Status.Shipped as i32);

// comparison, and a value flowing back into the declaring package
println(o.status == orders.Status.Paid);
println(orders.is_final(orders.Status.Cancelled));
println(orders.is_final(orders.Status.Paid));

// the associated functions
let r = orders.Status.from_str("Shipped");
guard let s = r else {
    println("BUG: from_str rejected a real variant");
    exit(1);
}
println(to_str(s));
let bad = orders.Status.from_str("Nope");
guard let _b = bad else let e = err_of(bad) {
    println("rejected: " + e);
    let fi = orders.Status.from_int(5);
    guard let s2 = fi else {
        println("BUG: from_int rejected 5");
        exit(1);
    }
    println(to_str(s2));
    let fb = orders.Status.from_int(99);
    guard let _f = fb else {
        println("from_int rejected 99");
        // as a map key, and inside this package's own struct
        let counts: map[orders.Status]int = {};
        counts[orders.Status.Paid] = 2;
        counts[orders.Status.Pending] = 1;
        println(counts[orders.Status.Paid] + counts[orders.Status.Pending]);
        println(orders.first_internal());
        exit(0);
    }
    println("BUG: 99 is not a variant");
    exit(1);
}
println("BUG: 'Nope' is not a variant");
