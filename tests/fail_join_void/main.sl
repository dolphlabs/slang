fn shout() {
    println("hi");
}

let h = spawn shout();
join_wait(h);
