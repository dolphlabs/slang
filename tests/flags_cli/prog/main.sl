import "flags";
import "proc";

// A real command line, for tests/flags_cli/check.py: parse_or_exit's
// stdout / stderr / exit status can only be seen from outside the process.

let fs = flags.new("cli", "a test program");
fs.add_str("name", "n", "world", "who to greet");
fs.add_int("count", "c", 1, "how many times");
fs.add_bool("loud", "l", false, "shout");
fs.set_takes("[words...]");

let p = fs.parse_or_exit(proc.args());
let greeting = "hello " + p.get_str("name");
if p.get_bool("loud") {
    greeting = greeting + "!";
}
let i = 0;
while i < p.get_int("count") {
    println(greeting);
    i = i + 1;
}
for a in p.args() {
    println("arg " + a);
}
