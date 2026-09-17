// Two variants with the same name in one enum must be rejected.
enum Status {
    Pending,
    Paid,
    Pending,
}
println(Status.Pending);
