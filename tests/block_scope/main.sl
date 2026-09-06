fn shadow() {
    let x = 1;
    if true {
        let x = 2;
        println(x);
    }
    println(x);
}

fn loop_body_dies() {
    let n = 0;
    while n < 1 {
        let inner = 7;
        println(inner);
        n = n + 1;
    }
    println(n);
}

fn for_binding() {
    let i = 100;
    for i in 0..3 {
        println(i);
    }
    println(i);
}

shadow();
loop_body_dies();
for_binding();
println("ok");
