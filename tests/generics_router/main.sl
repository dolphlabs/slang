// Proof that a library can carry application-defined state: Router[S]
// and Ctx[S] generic over S, method dispatch on the instance, plain
// handlers over one concrete instance, and a generic dispatch fn.
// The app's own App flows through router and middleware shapes a
// framework would own without the framework naming it.
struct App {
    greeting: str,
    hits: int,
}

gc struct Ctx[S] {
    path: str,
    state: S,
}

struct Route[S] {
    path: str,
    handler: fn(Ctx[S]) -> str,
}

struct Router[S] {
    routes: [Route[S]],
}

impl Router[S] {
    fn handle(self: Router[S], ctx: Ctx[S]) -> str {
        for r in self.routes {
            if r.path == ctx.path {
                return r.handler(ctx);
            }
        }
        return "404";
    }
}

fn hello(ctx: Ctx[App]) -> str {
    return ctx.state.greeting;
}

fn hits(ctx: Ctx[App]) -> str {
    return to_str(ctx.state.hits);
}

fn dispatch[S](r: Router[S], ctx: Ctx[S]) -> str {
    return r.handle(ctx);
}

let app = App { greeting: "hi", hits: 7 };
let routes: [Route[App]] = [
    Route[App] { path: "/hi", handler: hello },
    Route[App] { path: "/hits", handler: hits }
];
let router = Router[App] { routes: routes };
println(dispatch(router, Ctx[App] { path: "/hi", state: app }));
println(dispatch(router, Ctx[App] { path: "/hits", state: app }));
println(dispatch(router, Ctx[App] { path: "/nope", state: app }));
