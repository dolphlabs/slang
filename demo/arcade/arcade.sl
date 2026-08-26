// arcade: the demo's domain types, shared between main.sl's routes
// and the json package (every one of these round-trips through
// json.decode/json.encode -- see main.sl). Decode targets are kept
// separate from stored/returned shapes (NewMessage vs Message) since
// the client shouldn't get to set server-owned fields like a
// timestamp.

pub struct NewMessage {
    author: str,
    text: str,
    mood: opt[str],
}

pub struct Message {
    author: str,
    text: str,
    mood: opt[str],
    at_ms: int,
}

pub struct Player {
    name: str,
    best: i32,
    rolls: i32,
}

pub struct RollRequest {
    player: str,
}

pub struct RollResult {
    player: str,
    a: i32,
    b: i32,
    total: i32,
    is_double: bool,
    best: i32,
    rolls: i32,
}

pub struct Stats {
    uptime_ms: int,
    requests: int,
    active_tasks: int,
    message_count: int,
    player_count: int,
    pid: i32,
}

pub fn is_double(a: i32, b: i32) -> bool {
    return a == b;
}
