import "strings";
import "io";

// Command-line flags: declare them on a Set, parse the argument list, read
// the values back from the Parsed result.
//
//     let fs = flags.new("greet", "print a greeting");
//     fs.add_str("name", "n", "world", "who to greet");
//     fs.add_int("count", "c", 1, "how many times");
//     fs.add_bool("loud", "l", false, "shout");
//     let p = fs.parse_or_exit(proc.args());
//     println(p.get_str("name"));
//
// `parse` takes the list exactly as proc.args() returns it and skips
// element 0, the program name. The positional arguments come back without
// it, so a subcommand can parse what is left of its parent with the same
// call: element 0 of `p.args()` is the subcommand's own name. A parent that
// has subcommands calls `stop_at_first_arg()` so that the subcommand's own
// flags are left alone:
//
//     let global = flags.new("tool", "");
//     global.add_bool("verbose", "v", false, "chatty output");
//     global.stop_at_first_arg();
//     let g = global.parse_or_exit(proc.args());
//     // g.args() is ["push", "--force", "origin"]; parse it again with the
//     // subcommand's own Set.
//
// Declaring a flag wrongly (empty or duplicate name, a short name that is
// not one character) and reading one that was never declared are bugs in
// the program, not in its input, and panic. Anything a user can type wrong
// comes back as an `err` from `parse`.

enum Kind {
    Str,
    Int,
    Float,
    Bool,
    List,
}

pub gc struct Flag {
    name: str,
    short: str,         // one character, or "" for none
    kind: Kind,
    usage: str,
    required: bool,
    def_str: str,
    def_int: int,
    def_float: float,
    def_bool: bool,
}

// The declared flags. Build one with `new`, add flags, then `parse`.
pub gc struct Set {
    prog: str,
    about: str,
    takes: str,         // positional-argument synopsis for the usage line
    stop_early: bool,   // flags end at the first positional argument
    flags: [Flag],
}

// What `parse` found: every declared flag with its value (the default when
// the command line did not set it), the positional arguments, and whether
// -h / --help was given.
pub gc struct Parsed {
    strs: map[str]str,
    ints: map[str]int,
    floats: map[str]float,
    bools: map[str]bool,
    lists: map[str][str],
    given: map[str]bool,
    rest: [str],
    help: bool,
}

// A flag set for the program `prog`. `about` is one line for the top of
// the usage text ("" for none).
pub fn new(prog: str, about: str) -> Set {
    return Set { prog: prog, about: about, takes: "[args...]",
                 stop_early: false, flags: [] };
}

fn index_of_name(s: Set, name: str) -> int {
    let i = 0;
    while i < len(s.flags) {
        if s.flags[i].name == name {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn index_of_short(s: Set, short: str) -> int {
    let i = 0;
    while i < len(s.flags) {
        if s.flags[i].short == short {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn declare(s: Set, name: str, short: str, kind: Kind, usage: str) -> Flag {
    if name == "" || strings.has_prefix(name, "-") || strings.contains(name, "=")
        || strings.contains(name, " ") {
        panic("flags: '" + name + "' is not a usable flag name");
    }
    if name == "help" {
        panic("flags: --help is built in");
    }
    if index_of_name(s, name) >= 0 {
        panic("flags: --" + name + " is declared twice");
    }
    if len(short) > 1 || short == "-" || short == "=" {
        panic("flags: the short name of --" + name + " must be one character");
    }
    if short != "" {
        if short == "h" {
            panic("flags: -h is built in");
        }
        if index_of_short(s, short) >= 0 {
            panic("flags: -" + short + " is declared twice");
        }
    }
    let f = Flag {
        name: name,
        short: short,
        kind: kind,
        usage: usage,
        required: false,
        def_str: "",
        def_int: 0,
        def_float: 0.0,
        def_bool: false
    };
    push(s.flags, f);
    return f;
}

impl Set {
    // `--name value`, `--name=value`, `-n value`, `-nvalue`. Pass "" as
    // `short` for a flag with no short form.
    pub fn add_str(self: Set, name: str, short: str, def: str, usage: str) {
        let f = declare(self, name, short, Kind.Str, usage);
        f.def_str = def;
    }

    // Like add_str, for a base-10 integer.
    pub fn add_int(self: Set, name: str, short: str, def: int, usage: str) {
        let f = declare(self, name, short, Kind.Int, usage);
        f.def_int = def;
    }

    // Like add_str, for a float.
    pub fn add_float(self: Set, name: str, short: str, def: float, usage: str) {
        let f = declare(self, name, short, Kind.Float, usage);
        f.def_float = def;
    }

    // `--name` sets it true, `--name=false` (or `--no-name`) sets it false.
    // Short bool flags combine: `-vq` is `-v -q`.
    pub fn add_bool(self: Set, name: str, short: str, def: bool, usage: str) {
        let f = declare(self, name, short, Kind.Bool, usage);
        f.def_bool = def;
    }

    // A repeatable string flag: `-I a -I b` gives ["a", "b"]. Empty when
    // never given.
    pub fn add_list(self: Set, name: str, short: str, usage: str) {
        declare(self, name, short, Kind.List, usage);
    }

    // Make `name` mandatory: `parse` fails if the command line leaves it
    // out (unless --help was asked for). A default is meaningless for a
    // required flag, and the usage text says "required" instead.
    pub fn require(self: Set, name: str) {
        let i = index_of_name(self, name);
        if i < 0 {
            panic("flags: --" + name + " cannot be required, it is not declared");
        }
        self.flags[i].required = true;
    }

    // What follows the options on the usage line: "<file>...", "[dir]".
    // "" for a program that takes no positional arguments.
    pub fn set_takes(self: Set, takes: str) {
        self.takes = takes;
    }

    // Treat the first positional argument, and everything after it, as
    // positional -- even what looks like a flag. Needed for programs with
    // subcommands, where the rest belongs to the subcommand.
    pub fn stop_at_first_arg(self: Set) {
        self.stop_early = true;
    }
}

fn new_parsed(s: Set) -> Parsed {
    // empty maps take their type from an annotation, not from the field
    let strs: map[str]str = {};
    let ints: map[str]int = {};
    let floats: map[str]float = {};
    let bools: map[str]bool = {};
    let lists: map[str][str] = {};
    let given: map[str]bool = {};
    let p = Parsed {
        strs: strs,
        ints: ints,
        floats: floats,
        bools: bools,
        lists: lists,
        given: given,
        rest: [],
        help: false
    };
    for f in s.flags {
        if f.kind == Kind.Str {
            p.strs[f.name] = f.def_str;
        }
        if f.kind == Kind.Int {
            p.ints[f.name] = f.def_int;
        }
        if f.kind == Kind.Float {
            p.floats[f.name] = f.def_float;
        }
        if f.kind == Kind.Bool {
            p.bools[f.name] = f.def_bool;
        }
        if f.kind == Kind.List {
            let empty: [str] = [];
            p.lists[f.name] = empty;
        }
    }
    return p;
}

fn bad_value(f: Flag, raw: str, why: str) -> result[bool, str] {
    return err("--" + f.name + ": invalid value \"" + raw + "\" (" + why + ")");
}

// Store `raw` as the value of `f`, converting it to the flag's type.
fn assign(p: Parsed, f: Flag, raw: str) -> result[bool, str] {
    if f.kind == Kind.Str {
        p.strs[f.name] = raw;
    }
    if f.kind == Kind.Int {
        let r = to_int(raw);
        guard let v = r else let e = err_of(r) {
            return bad_value(f, raw, e);
        }
        p.ints[f.name] = v;
    }
    if f.kind == Kind.Float {
        let r = to_float(raw);
        guard let v = r else let e = err_of(r) {
            return bad_value(f, raw, e);
        }
        p.floats[f.name] = v;
    }
    if f.kind == Kind.Bool {
        if raw == "true" || raw == "1" {
            p.bools[f.name] = true;
        } else {
            if raw == "false" || raw == "0" {
                p.bools[f.name] = false;
            } else {
                return bad_value(f, raw, "want true or false");
            }
        }
    }
    if f.kind == Kind.List {
        p.lists[f.name] = p.lists[f.name] + [raw];
    }
    p.given[f.name] = true;
    return ok(true);
}

// `--name`, `--name=value`, `--name value`, `--no-name`. `i` is the index
// of the token; returns the index of the next one to look at.
fn parse_long(s: Set, p: Parsed, args: [str], i: int) -> result[int, str] {
    let body = strings.slice(args[i], 2, len(args[i]));
    let name = body;
    let val = "";
    let has_val = false;
    let eq = strings.find(body, "=");
    if eq >= 0 {
        name = strings.slice(body, 0, eq);
        val = strings.slice(body, eq + 1, len(body));
        has_val = true;
    }
    if name == "help" {
        p.help = true;
        return ok(i + 1);
    }
    let at = index_of_name(s, name);
    if at < 0 {
        // --no-verbose for a bool flag `verbose`
        if strings.has_prefix(name, "no-") {
            let base = strings.slice(name, 3, len(name));
            let bi = index_of_name(s, base);
            if bi >= 0 && s.flags[bi].kind == Kind.Bool {
                if has_val {
                    return err("--" + name + " takes no value");
                }
                p.bools[base] = false;
                p.given[base] = true;
                return ok(i + 1);
            }
        }
        return err("unknown flag --" + name);
    }
    let f = s.flags[at];
    if f.kind == Kind.Bool {
        if !has_val {
            val = "true";
        }
        let r = assign(p, f, val);
        guard let done = r else let e = err_of(r) {
            return err(e);
        }
        return ok(i + 1);
    }
    let next = i + 1;
    if !has_val {
        if next >= len(args) {
            return err("--" + name + " needs a value");
        }
        val = args[next];
        next = next + 1;
    }
    let r = assign(p, f, val);
    guard let done = r else let e = err_of(r) {
        return err(e);
    }
    return ok(next);
}

// `-n`, `-n value`, `-nvalue`, `-n=value`, and clusters of bool flags
// (`-vq`). A value flag ends the cluster: whatever follows it in the token
// is its value.
fn parse_short(s: Set, p: Parsed, args: [str], i: int) -> result[int, str] {
    let tok = args[i];
    let pos = 1;
    while pos < len(tok) {
        let c = strings.slice(tok, pos, pos + 1);
        if c == "h" {
            p.help = true;
            pos = pos + 1;
            continue;
        }
        let at = index_of_short(s, c);
        if at < 0 {
            return err("unknown flag -" + c);
        }
        let f = s.flags[at];
        if f.kind == Kind.Bool {
            let r = assign(p, f, "true");
            guard let done = r else let e = err_of(r) {
                return err(e);
            }
            pos = pos + 1;
            continue;
        }
        let val = strings.slice(tok, pos + 1, len(tok));
        let next = i + 1;
        if val == "" {
            if next >= len(args) {
                return err("-" + c + " needs a value");
            }
            val = args[next];
            next = next + 1;
        } else {
            if strings.has_prefix(val, "=") {
                val = strings.slice(val, 1, len(val));
            }
        }
        let r = assign(p, f, val);
        guard let done = r else let e = err_of(r) {
            return err(e);
        }
        return ok(next);
    }
    return ok(i + 1);
}

impl Set {
    // Parse `args` -- proc.args(), or the positional list a parent parse
    // left behind. Element 0 is the program (or subcommand) name and is
    // skipped. Flags and positional arguments may be mixed; `--` ends the
    // flags, and a lone `-` is a positional argument (the usual "stdin").
    //
    // Fails, with a message fit to show a user, on an unknown flag, a
    // missing or malformed value, or a required flag left out. `-h` and
    // `--help` do not fail: check `wants_help()` on the result.
    pub fn parse(self: Set, args: [str]) -> result[Parsed, str] {
        let p = new_parsed(self);
        let i = 1;
        while i < len(args) {
            let tok = args[i];
            if tok == "--" {
                i = i + 1;
                while i < len(args) {
                    push(p.rest, args[i]);
                    i = i + 1;
                }
                break;
            }
            if tok == "-" || !strings.has_prefix(tok, "-") {
                if self.stop_early {
                    while i < len(args) {
                        push(p.rest, args[i]);
                        i = i + 1;
                    }
                    break;
                }
                push(p.rest, tok);
                i = i + 1;
                continue;
            }
            let r: result[int, str] = ok(0);
            if strings.has_prefix(tok, "--") {
                r = parse_long(self, p, args, i);
            } else {
                r = parse_short(self, p, args, i);
            }
            guard let next = r else let e = err_of(r) {
                return err(e);
            }
            i = next;
        }
        if !p.help {
            for f in self.flags {
                if f.required && !has(p.given, f.name) {
                    return err("missing required flag --" + f.name);
                }
            }
        }
        return ok(p);
    }

    // `parse` for a program's own command line, with the conventional
    // failure handling: a usage error prints "prog: message" and a pointer
    // to --help on stderr and exits 2; --help prints the usage text on
    // stdout and exits 0.
    pub fn parse_or_exit(self: Set, args: [str]) -> Parsed {
        let r = self.parse(args);
        guard let p = r else let e = err_of(r) {
            io.eprintln(self.prog + ": " + e);
            io.eprintln("Try '" + self.prog + " --help' for usage.");
            exit(2);
        }
        if p.help {
            print(self.usage());
            exit(0);
        }
        return p;
    }

    // The help text: usage line, the `about` line, then every flag in the
    // order it was declared with its default.
    pub fn usage(self: Set) -> str {
        let out = "Usage: " + self.prog + " [options]";
        if self.takes != "" {
            out = out + " " + self.takes;
        }
        out = out + "\n";
        if self.about != "" {
            out = out + "\n" + self.about + "\n";
        }
        out = out + "\nOptions:\n";

        let lefts: [str] = [];
        let rights: [str] = [];
        let width = 0;
        for f in self.flags {
            let left = "      --" + f.name;
            if f.short != "" {
                left = "  -" + f.short + ", --" + f.name;
            }
            if f.kind != Kind.Bool {
                left = left + " <" + kind_word(f.kind) + ">";
            }
            push(lefts, left);
            push(rights, describe(f));
            if len(left) > width {
                width = len(left);
            }
        }
        push(lefts, "  -h, --help");
        push(rights, "show this help");
        if len(lefts[len(lefts) - 1]) > width {
            width = len(lefts[len(lefts) - 1]);
        }
        let i = 0;
        while i < len(lefts) {
            out = out + lefts[i] + strings.repeat(" ", width - len(lefts[i]) + 2)
                + rights[i] + "\n";
            i = i + 1;
        }
        return out;
    }
}

fn kind_word(k: Kind) -> str {
    if k == Kind.Int {
        return "int";
    }
    if k == Kind.Float {
        return "float";
    }
    return "str";
}

// The usage sentence plus its default, or "(required)".
fn describe(f: Flag) -> str {
    let d = f.usage;
    if f.required {
        return d + " (required)";
    }
    if f.kind == Kind.Str && f.def_str != "" {
        return d + " (default: \"" + f.def_str + "\")";
    }
    if f.kind == Kind.Int {
        return d + " (default: " + to_str(f.def_int) + ")";
    }
    if f.kind == Kind.Float {
        return d + " (default: " + strings.from_float(f.def_float) + ")";
    }
    if f.kind == Kind.Bool && f.def_bool {
        return d + " (default: true)";
    }
    return d;
}

impl Parsed {
    // The value of the str flag `name`: what the command line gave, or the
    // default. Panics if no str flag by that name was declared.
    pub fn get_str(self: Parsed, name: str) -> str {
        if !has(self.strs, name) {
            panic("flags: no str flag --" + name + " was declared");
        }
        return self.strs[name];
    }

    pub fn get_int(self: Parsed, name: str) -> int {
        if !has(self.ints, name) {
            panic("flags: no int flag --" + name + " was declared");
        }
        return self.ints[name];
    }

    pub fn get_float(self: Parsed, name: str) -> float {
        if !has(self.floats, name) {
            panic("flags: no float flag --" + name + " was declared");
        }
        return self.floats[name];
    }

    pub fn get_bool(self: Parsed, name: str) -> bool {
        if !has(self.bools, name) {
            panic("flags: no bool flag --" + name + " was declared");
        }
        return self.bools[name];
    }

    // Every value of the list flag `name`, in command-line order.
    pub fn get_list(self: Parsed, name: str) -> [str] {
        if !has(self.lists, name) {
            panic("flags: no list flag --" + name + " was declared");
        }
        return self.lists[name];
    }

    // Did the command line set `name` -- as opposed to it holding its
    // default? Works for every kind of flag.
    pub fn is_set(self: Parsed, name: str) -> bool {
        return has(self.given, name);
    }

    // The positional arguments, in order, without the program name.
    pub fn args(self: Parsed) -> [str] {
        return self.rest;
    }

    // Was -h or --help given?
    pub fn wants_help(self: Parsed) -> bool {
        return self.help;
    }
}
