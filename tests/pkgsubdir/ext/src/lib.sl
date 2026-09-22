pub struct Greeting {
    text: str,
}

pub fn hello(name: str) -> Greeting {
    return Greeting { text: "hi " + name };
}
