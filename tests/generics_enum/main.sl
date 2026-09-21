// Enum references inside a generic method's body.
//
// A generic method is parsed FRESH for each instance, long after the
// enum rewrite has walked the program -- so `Status.Paid` in such a
// body was never rewritten and reached the type checker as an
// undefined variable. Each instance now runs the rewrite on its own
// body, for its own package's enums and for an imported package's.
import "orders";

enum Colour {
    Red,
    Green,
    Blue,
}

gc struct Tagged[T] {
    v: T,
    colour: Colour,
    status: orders.Status,
}

impl Tagged[T] {
    fn colour_name(self: Tagged[T]) -> str {
        return to_str(self.colour);
    }

    fn is_red(self: Tagged[T]) -> bool {
        return self.colour == Colour.Red;
    }

    // an imported package's enum, inside an instance body
    fn is_paid(self: Tagged[T]) -> bool {
        return self.status == orders.Status.Paid;
    }

    fn described(self: Tagged[T]) -> str {
        return orders.label(self.status);
    }

    // the associated functions, both packages
    fn parsed(self: Tagged[T], name: str) -> str {
        let c = Colour.from_str(name);
        guard let got = c else {
            let s = orders.Status.from_str(name);
            guard let st = s else {
                return "neither";
            }
            return "status " + to_str(st);
        }
        return "colour " + to_str(got);
    }

    fn as_int(self: Tagged[T]) -> int {
        return self.colour as i32;
    }
}

let a = Tagged[int] { v: 1, colour: Colour.Green, status: orders.Status.Paid };
println(a.colour_name());
println(a.is_red());
println(a.is_paid());
println(a.described());
println(a.parsed("Blue"));
println(a.parsed("Shipped"));
println(a.parsed("nope"));
println(a.as_int());

let b = Tagged[str] { v: "x", colour: Colour.Red, status: orders.Status.Pending };
println(b.is_red());
println(b.is_paid());
println(b.described());
