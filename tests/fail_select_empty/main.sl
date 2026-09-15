// a select with only a default arm waits for nothing and is a mistake
select {
    default { println("no"); }
}
