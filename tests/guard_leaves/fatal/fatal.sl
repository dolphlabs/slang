// A helper in another package: bail() never returns, so a guard in the
// importing package may end its else with fatal.bail(..).
pub fn bail(msg: str) {
    println("bail: " + msg);
    exit(0);
}
