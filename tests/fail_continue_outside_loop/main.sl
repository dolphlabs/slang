// continue only makes sense inside a loop -- inside a function body
// but with no enclosing loop is still outside a loop
fn f() {
    continue;
}
f();
