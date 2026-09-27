// switch: statement and expression forms over int, str, bool and enum.
fn classify(code: int) -> str {
    switch code {
      case 200, 201 {
        return "ok";
      }
      case 404 {
        return "missing";
      }
      default {
        return "other";
      }
    }
}

println(classify(200));
println(classify(201));
println(classify(404));
println(classify(500));

// no default, no match: falls through silently
let quiet = 7;
switch quiet {
  case 1 { println("one"); }
  case 2 { println("two"); }
}
println("done");

// negative labels and multi-label arms
let negval = 0 - 3;
switch negval {
  case -3, -2 { println("neg"); }
  default { println("pos"); }
}

// str scrutinee matches by content, not identity
let who = "ada" + "";
switch who {
  case "ada" { println("greet"); }
  case "bob", "carol" { println("friend"); }
  default { println("stranger"); }
}

// bool scrutinee
switch 1 == 2 {
  case true { println("yes"); }
  case false { println("no"); }
}

enum Status {
    Pending,
    Paid,
    Shipped,
}

// exhaustive enum: no default needed, in both forms
let s: Status = Status.Paid;
switch s {
  case Status.Paid {
    println("paid");
  }
  case Status.Pending, Status.Shipped {
    println("waiting");
  }
}
let v: int = switch s {
  case Status.Paid { 1 }
  case Status.Pending { 2 }
  case Status.Shipped { 3 }
};
println(v);

// expression form over ints
let code = 404;
let label: str = switch code {
  case 200 { "ok" }
  case 404 { "missing" }
  default { "other" }
};
println(label);

// break exits the switch, not the code after it
switch 7 {
  case 7 {
    println("seven");
    break;
  }
  default { println("unreachable"); }
}
println("after");

// continue inside a switch still targets the enclosing loop;
// break inside a switch does not break the loop
let n = 0;
for i in 0..10 {
    switch i {
      case 2 { continue; }
      case 5 { break; }
      default { n = n + 1; }
    }
    n = n + 10;
}
println(n);

// arms infer against the binding: none/[] take their type from it,
// in any arm position
let pick = 2;
let maybe: opt[str] = switch pick {
  case 1 { none }
  default { some("d") }
};
println(maybe ?? "none");
let lists: [int] = switch pick {
  case 1 { [1] }
  default { [] }
};
println(len(lists));

// nested switches; inner break targets the inner switch
switch 2 {
  case 2 {
    switch 3 {
      case 3 { println("two-three"); break; }
      default { println("two-other"); }
    }
    println("after-inner");
  }
  default { println("outer-other"); }
}
