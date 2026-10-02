// json.decode at nesting depths up to the 512-level cap, on the main task
// and on a spawned one. Task stacks start at 8KB and grow only at slang
// safepoints, so a decoder that recursed in C once per level of input
// ran out of stack at a depth of about 80, long before the
// cap could reject anything. Depth here costs heap, or for a recursive
// target type, stack reserved at the call site.
import "json";
import "strings";

gc struct Req { id: int }

gc struct Node {
    v: int,
    next: opt[Node],
}

gc struct Tree {
    v: int,
    kids: [Tree],
}

gc struct Trie {
    v: int,
    sub: map[str]Trie,
}

// {"x":[[...]],"id":1}: an unknown key's value, skipped by the direct decoder
fn skipped(d: int) -> str {
    return "{\"x\":" + strings.repeat("[", d) + strings.repeat("]", d) + ",\"id\":1}";
}

// The same with "id" a string: the direct decoder declines it, so the input
// goes through the tree parser, which names the error.
fn tree(d: int) -> str {
    return "{\"x\":" + strings.repeat("[", d) + strings.repeat("]", d) + ",\"id\":\"1\"}";
}

// Arrays and objects alternating, d levels in all.
fn mixed(d: int) -> str {
    let open = "";
    let close = "";
    let i = 0;
    while i < d {
        if i % 2 == 0 {
            open = open + "{\"k\":";
            close = "}" + close;
        } else {
            open = open + "[";
            close = "]" + close;
        }
        i = i + 1;
    }
    return "{\"x\":" + open + "1" + close + ",\"id\":1}";
}

// A Node chain n deep: {"v":1,"next":{"v":2,...}}
fn chain(n: int) -> str {
    let s = "";
    let i = 1;
    while i <= n {
        s = s + "{\"v\":" + to_str(i);
        if i < n { s = s + ",\"next\":"; }
        i = i + 1;
    }
    return s + strings.repeat("}", n);
}

// A Node chain n deep whose last "v" is a string: the direct decoder
// declines it at the bottom, and the tree decoder then walks all n levels
// before naming the error, one "field 'next': " per level.
fn bad_chain(n: int) -> str {
    let s = "";
    let i = 1;
    while i < n {
        s = s + "{\"v\":" + to_str(i) + ",\"next\":";
        i = i + 1;
    }
    return s + "{\"v\":\"x\"}" + strings.repeat("}", n - 1);
}

fn tree_chain(n: int) -> str {
    let s = "";
    let i = 1;
    while i <= n {
        s = s + "{\"v\":" + to_str(i) + ",\"kids\":[";
        i = i + 1;
    }
    return s + strings.repeat("]}", n);
}

fn trie_chain(n: int) -> str {
    let s = "";
    let i = 1;
    while i <= n {
        s = s + "{\"v\":" + to_str(i) + ",\"sub\":{\"a\":";
        i = i + 1;
    }
    // the innermost is a leaf with an empty map
    s = s + "{\"v\":0,\"sub\":{}}";
    return s + strings.repeat("}}", n);
}

fn req(label: str, src: str) -> str {
    let r: result[Req, str] = json.decode(src);
    guard let v = r else let e = err_of(r) { return label + ": err " + e; }
    return label + ": ok " + to_str(v.id);
}

fn node_len(n: Node) -> int {
    let k = 1;
    let cur = n;
    while true {
        guard let nx = cur.next else { break; }
        cur = nx;
        k = k + 1;
    }
    return k;
}

fn node(label: str, src: str) -> str {
    let r: result[Node, str] = json.decode(src);
    guard let v = r else let e = err_of(r) { return label + ": err " + e; }
    return label + ": ok len=" + to_str(node_len(v));
}

fn tree_depth(t: Tree) -> int {
    let k = 1;
    let cur = t;
    while len(cur.kids) > 0 {
        cur = cur.kids[0];
        k = k + 1;
    }
    return k;
}

fn node_err(label: str, src: str) -> str {
    let r: result[Node, str] = json.decode(src);
    guard let v = r else let e = err_of(r) {
        return label + ": err of " + to_str(len(e)) + " bytes, ending " +
            strings.slice(e, len(e) - 40, len(e));
    }
    return label + ": ok len=" + to_str(node_len(v));
}

fn trees(label: str, src: str) -> str {
    let r: result[Tree, str] = json.decode(src);
    guard let v = r else let e = err_of(r) { return label + ": err " + e; }
    return label + ": ok depth=" + to_str(tree_depth(v));
}

fn trie_depth(t: Trie) -> int {
    let k = 1;
    let cur = t;
    while has(cur.sub, "a") {
        cur = cur.sub["a"];
        k = k + 1;
    }
    return k;
}

fn tries(label: str, src: str) -> str {
    let r: result[Trie, str] = json.decode(src);
    guard let v = r else let e = err_of(r) { return label + ": err " + e; }
    return label + ": ok depth=" + to_str(trie_depth(v));
}

// Every case, one line each. Depth counts the outer object too, so the
// nesting inside "x" is d - 1 deep for a total of d.
fn run(where: str) -> [str] {
    let out: [str] = [];
    for d in [100, 511, 512, 513] {
        let tag = where + " depth " + to_str(d);
        push(out, req(tag + " skipped", skipped(d - 1)));
        push(out, req(tag + " tree", tree(d - 1)));
        push(out, req(tag + " mixed", mixed(d - 1)));
    }
    push(out, node(where + " node chain 511", chain(511)));
    push(out, node(where + " node chain 512", chain(512)));
    push(out, node(where + " node chain 513", chain(513)));
    push(out, node_err(where + " node bad chain 511", bad_chain(511)));
    // each node is two levels, its object and its list or map, so 256
    // nodes reach the cap exactly (a trie chain ends in one more, a leaf)
    push(out, trees(where + " tree chain 256", tree_chain(256)));
    push(out, trees(where + " tree chain 257", tree_chain(257)));
    push(out, tries(where + " trie chain 255", trie_chain(255)));
    push(out, tries(where + " trie chain 256", trie_chain(256)));
    // malformed deep input still errors, without a crash
    push(out, req(where + " unclosed", "{\"x\":" + strings.repeat("[", 400)));
    push(out, node(where + " node unclosed", strings.repeat("{\"v\":1,\"next\":", 400)));
    return out;
}

fn worker(ch: chan[[str]]) {
    chan_send(ch, run("task"));
}

for line in run("main") { println(line); }

let ch: chan[[str]] = make_chan(1);
spawn worker(ch);
guard let lines = chan_recv(ch) else { exit(1); }
for line in lines { println(line); }
