// Two variants with the same explicit value in one enum must be rejected
// (from_int couldn't tell them apart).
enum Status {
    Pending = 5,
    Paid = 5,
}
println(Status.Pending);
