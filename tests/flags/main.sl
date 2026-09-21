import "flags";
import "strings";

// The flags package: declaring, parsing, reading back, usage text, and the
// mistakes a program can make in declaring them. parse_or_exit's exit
// codes are covered by tests/flags_cli.

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn expect(cond: bool, what: str) {
    if !cond {
        die(what);
    }
}

fn demo() -> flags.Set {
    let fs = flags.new("greet", "print a greeting");
    fs.add_str("name", "n", "world", "who to greet");
    fs.add_int("count", "c", 1, "how many times");
    fs.add_float("ratio", "r", 0.5, "scale factor");
    fs.add_bool("loud", "l", false, "shout");
    fs.add_bool("color", "", true, "use colour");
    fs.add_list("include", "I", "extra directory");
    return fs;
}

// The parsed result; a failure to parse ends the test with its message.
fn parse_ok(fs: flags.Set, args: [str]) -> flags.Parsed {
    let r = fs.parse(args);
    guard let p = r else let e = err_of(r) {
        panic("parse failed: " + e);
    }
    return p;
}

// One-call reads, for the many checks that need only a single value: a
// method cannot be called on a call's result, so `parse_ok(...).get_int(...)`
// has to go through a local.
fn bool_of(args: [str], name: str) -> bool {
    let p = parse_ok(demo(), args);
    return p.get_bool(name);
}

fn int_of(args: [str], name: str) -> int {
    let p = parse_ok(demo(), args);
    return p.get_int(name);
}

fn help_of(fs: flags.Set, args: [str]) -> bool {
    let p = parse_ok(fs, args);
    return p.wants_help();
}

// The error message, or "" when the parse succeeded.
fn parse_err(fs: flags.Set, args: [str]) -> str {
    let r = fs.parse(args);
    guard let p = r else let e = err_of(r) {
        return e;
    }
    return "";
}

fn piped(xs: [str]) -> str {
    return strings.join(xs, "|");
}

fn defaults() {
    let p = parse_ok(demo(), ["greet"]);
    expect(p.get_str("name") == "world", "default name");
    expect(p.get_int("count") == 1, "default count");
    expect(p.get_float("ratio") == 0.5, "default ratio");
    expect(!p.get_bool("loud"), "default loud");
    expect(p.get_bool("color"), "default color");
    expect(len(p.get_list("include")) == 0, "default include");
    expect(len(p.args()) == 0, "no positionals");
    expect(!p.is_set("name"), "name not set");
    expect(!p.wants_help(), "no help");
    println("ok defaults");
}

fn long_forms() {
    let p = parse_ok(demo(), ["greet", "--name", "bob", "--count=3",
                              "--ratio", "2.25", "--loud", "x", "y"]);
    expect(p.get_str("name") == "bob", "--name value");
    expect(p.get_int("count") == 3, "--count=3");
    expect(p.get_float("ratio") == 2.25, "--ratio value");
    expect(p.get_bool("loud"), "--loud");
    expect(piped(p.args()) == "x|y", "positionals after flags");
    expect(p.is_set("name") && p.is_set("count") && p.is_set("loud"), "is_set");
    expect(!p.is_set("color"), "color untouched");
    println("ok long forms");
}

fn short_forms() {
    let p = parse_ok(demo(), ["greet", "-n", "al", "-c7", "-r=1.5", "-l"]);
    expect(p.get_str("name") == "al", "-n value");
    expect(p.get_int("count") == 7, "-c7");
    expect(p.get_float("ratio") == 1.5, "-r=1.5");
    expect(p.get_bool("loud"), "-l");

    // a bool flag can lead a cluster; a value flag ends it
    let q = parse_ok(demo(), ["greet", "-lc5"]);
    expect(q.get_bool("loud") && q.get_int("count") == 5, "-lc5");
    let r = parse_ok(demo(), ["greet", "-lc", "6", "z"]);
    expect(r.get_bool("loud") && r.get_int("count") == 6, "-lc 6");
    expect(piped(r.args()) == "z", "-lc 6 leaves z");
    println("ok short forms");
}

fn bools() {
    expect(!bool_of(["g", "--color=false"], "color"), "--color=false");
    expect(!bool_of(["g", "--no-color"], "color"), "--no-color");
    expect(bool_of(["g", "--loud=true"], "loud"), "--loud=true");
    expect(bool_of(["g", "--loud=1"], "loud"), "--loud=1");
    expect(!bool_of(["g", "--loud", "--no-loud"], "loud"), "--no-loud last");
    let p = parse_ok(demo(), ["g", "--no-color"]);
    expect(p.is_set("color"), "--no-color counts as set");
    println("ok bools");
}

fn lists() {
    let p = parse_ok(demo(), ["g", "-I", "a", "--include", "b", "-Ic", "--include=d"]);
    expect(piped(p.get_list("include")) == "a|b|c|d", "list order");
    println("ok lists");
}

fn positionals() {
    // flags and positionals mix; -- ends the flags; a lone - is positional
    let p = parse_ok(demo(), ["g", "a", "--loud", "-", "b", "--", "--name", "-x"]);
    expect(piped(p.args()) == "a|-|b|--name|-x", "mixed positionals");
    expect(p.get_bool("loud"), "flag between positionals");
    expect(p.get_str("name") == "world", "-- protects what follows");

    // the last occurrence wins; a value can look like a flag or a number
    let q = parse_ok(demo(), ["g", "--count", "1", "--count", "2", "--name", "-dash"]);
    expect(q.get_int("count") == 2, "last wins");
    expect(q.get_str("name") == "-dash", "value taken from the next token");
    expect(int_of(["g", "--count", "-5"], "count") == -5, "negative value");
    println("ok positionals");
}

fn errors() {
    let fs = demo();
    expect(parse_err(fs, ["g", "--nope"]) == "unknown flag --nope", "unknown long");
    expect(parse_err(fs, ["g", "--nope=1"]) == "unknown flag --nope", "unknown long with value");
    expect(parse_err(fs, ["g", "-z"]) == "unknown flag -z", "unknown short");
    expect(parse_err(fs, ["g", "-lz"]) == "unknown flag -z", "unknown in a cluster");
    expect(parse_err(fs, ["g", "--no-count"]) == "unknown flag --no-count", "--no- only negates bools");
    expect(parse_err(fs, ["g", "--name"]) == "--name needs a value", "long needs a value");
    expect(parse_err(fs, ["g", "-n"]) == "-n needs a value", "short needs a value");
    expect(parse_err(fs, ["g", "--count=abc"])
               == "--count: invalid value \"abc\" (not a base-10 integer)", "bad int");
    expect(parse_err(fs, ["g", "--count="]) != "", "empty int");
    expect(strings.has_prefix(parse_err(fs, ["g", "--ratio=x"]), "--ratio: invalid value \"x\""),
           "bad float");
    expect(parse_err(fs, ["g", "--loud=maybe"])
               == "--loud: invalid value \"maybe\" (want true or false)", "bad bool");
    expect(parse_err(fs, ["g", "--no-loud=1"]) == "--no-loud takes no value", "--no-x=value");
    // a value flag swallows the next token even when it is `--`
    expect(parse_err(fs, ["g", "--name", "--"]) == "", "--name -- takes -- as its value");
    println("ok errors");
}

fn help_and_required() {
    let fs = demo();
    expect(help_of(fs, ["g", "-h"]), "-h");
    expect(help_of(fs, ["g", "--help"]), "--help");
    expect(help_of(fs, ["g", "-lh"]), "-lh");

    let req = demo();
    req.require("name");
    expect(parse_err(req, ["g"]) == "missing required flag --name", "required missing");
    expect(parse_err(req, ["g", "--name", "x"]) == "", "required given");
    expect(parse_err(req, ["g", "--help"]) == "", "help skips required");
    println("ok help and required");
}

fn usage_text() {
    let fs = demo();
    fs.require("count");
    print(fs.usage());
    let bare = flags.new("tool", "");
    bare.set_takes("");
    bare.add_bool("v", "", false, "verbose");
    print(bare.usage());
}

fn subcommands() {
    let global = flags.new("tool", "");
    global.add_bool("verbose", "v", false, "chatty output");
    global.stop_at_first_arg();
    let g = parse_ok(global, ["tool", "-v", "push", "--force", "origin"]);
    expect(g.get_bool("verbose"), "global flag before the subcommand");
    expect(piped(g.args()) == "push|--force|origin", "the rest is left alone");

    let push = flags.new("push", "");
    push.add_bool("force", "f", false, "overwrite");
    let s = parse_ok(push, g.args());
    expect(s.get_bool("force"), "subcommand flag");
    expect(piped(s.args()) == "origin", "subcommand positional");

    // without the option, the parent would reject the subcommand's flag
    let greedy = flags.new("tool", "");
    greedy.add_bool("verbose", "v", false, "chatty output");
    expect(parse_err(greedy, ["tool", "push", "--force"]) == "unknown flag --force",
           "default mode parses flags after positionals");
    println("ok subcommands");
}

// ---- mistakes in the program itself: panics, seen through join_wait ------

fn declare_twice() -> int {
    let fs = flags.new("x", "");
    fs.add_int("n", "", 0, "");
    fs.add_str("n", "", "", "");
    return 0;
}

fn short_twice() -> int {
    let fs = flags.new("x", "");
    fs.add_int("a", "n", 0, "");
    fs.add_str("b", "n", "", "");
    return 0;
}

fn long_short() -> int {
    let fs = flags.new("x", "");
    fs.add_int("a", "nn", 0, "");
    return 0;
}

fn reserved() -> int {
    let fs = flags.new("x", "");
    fs.add_bool("help", "", false, "");
    return 0;
}

fn reserved_short() -> int {
    let fs = flags.new("x", "");
    fs.add_bool("hush", "h", false, "");
    return 0;
}

fn bad_name() -> int {
    let fs = flags.new("x", "");
    fs.add_bool("-x", "", false, "");
    return 0;
}

fn require_undeclared() -> int {
    let fs = flags.new("x", "");
    fs.require("ghost");
    return 0;
}

fn wrong_getter() -> int {
    let p = parse_ok(demo(), ["g"]);
    return p.get_int("name");
}

fn missing_getter() -> int {
    let p = parse_ok(demo(), ["g"]);
    return p.get_int("ghost");
}

fn panics_with(r: result[int, str], want: str, what: str) {
    guard let v = r else let e = err_of(r) {
        expect(strings.has_prefix(e, want), what + ": got \"" + e + "\"");
        return;
    }
    die(what + ": did not panic");
}

fn mistakes() {
    panics_with(join_wait(spawn declare_twice()), "flags: --n is declared twice", "duplicate name");
    panics_with(join_wait(spawn short_twice()), "flags: -n is declared twice", "duplicate short");
    panics_with(join_wait(spawn long_short()),
                "flags: the short name of --a must be one character", "long short");
    panics_with(join_wait(spawn reserved()), "flags: --help is built in", "reserved name");
    panics_with(join_wait(spawn reserved_short()), "flags: -h is built in", "reserved short");
    panics_with(join_wait(spawn bad_name()), "flags: '-x' is not a usable flag name", "bad name");
    panics_with(join_wait(spawn require_undeclared()),
                "flags: --ghost cannot be required, it is not declared", "require undeclared");
    panics_with(join_wait(spawn wrong_getter()),
                "flags: no int flag --name was declared", "getter of the wrong kind");
    panics_with(join_wait(spawn missing_getter()),
                "flags: no int flag --ghost was declared", "getter of an undeclared flag");
    println("ok mistakes");
}

defaults();
long_forms();
short_forms();
bools();
lists();
positionals();
errors();
help_and_required();
usage_text();
subcommands();
mistakes();
