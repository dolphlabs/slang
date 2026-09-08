let o: opt[int] = none;
guard let x = o else let e = err_of(o) {
    exit(0);
}
