struct OwnRes {
    id: int,
}

impl OwnRes {
    fn close(self: &mut OwnRes) {
        println(self.id);
    }
}

fn f() -> own OwnRes {
    let r: own OwnRes = OwnRes { id: 7 };
    defer r.close();
    return r;
}

let x = f();
println(x.id);
