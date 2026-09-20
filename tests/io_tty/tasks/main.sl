// Waiting for stdin must park the task, not block the worker thread:
// two busy tasks have to finish while main sits in read_line, even with
// a single worker. (With a blocking read they never ran.)
import "io";

fn churn(id: int) {
    let n = 0;
    while n < 300 {
        let l: [str] = [];
        let i = 0;
        while i < 2000 { push(l, "x" + to_str(i)); i = i + 1; }
        n = n + 1;
    }
    println("task " + to_str(id) + " done");
}
spawn churn(1);
spawn churn(2);
let r = io.read_line();
guard let maybe = r else let e = err_of(r) { println("ERR: " + e); exit(1); }
println("main got input");
