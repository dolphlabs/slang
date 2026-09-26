enum Status { Pending, Paid, Shipped, }
let s: Status = Status.Paid;
switch s {
  case Status.Paid { println("paid"); }
  case Status.Pending { println("pending"); }
}
