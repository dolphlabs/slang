fn key(n: int) -> bytes {
    let k = b"";
    for i in 0..32 { k = k + to_bytes(to_str((i + n) % 10)); }
    return k;
}

fn ring() -> Keyring {
    let kr = keyring();
    let _a = add_key(kr, "k1", key(1));
    return kr;
}

fn test_should_seal_and_open_with_the_same_aad() {
    let kr = ring();
    let box = seal(kr, b"123-45-6789", b"user:42") ?? b"";
    assert((open(kr, box, b"user:42") ?? b"") == b"123-45-6789", "round trip");
    if let _x = open(kr, box, b"user:43") { panic("opened under another aad"); }
    assert((key_id(box) ?? "") == "k1", "key id");
}

fn test_should_give_each_value_its_own_data_key() {
    let kr = ring();
    let a = seal(kr, b"same", b"") ?? b"";
    let b = seal(kr, b"same", b"") ?? b"";
    assert(a != b, "two seals of one value are identical");
}

fn test_should_refuse_altered_boxes() {
    let kr = ring();
    let box = seal(kr, b"secret", b"ctx") ?? b"";
    for at in [0, 1, 4, 10, len(box) - 1] {
        let bad = box[0..at] + crypto_flip(box[at] as int) + box[at + 1..];
        if let _x = open(kr, bad, b"ctx") { panic("altered byte " + to_str(at) + " still opened"); }
    }
    if let _y = open(kr, box[0..len(box) - 5], b"ctx") { panic("truncated box opened"); }
    if let _z = open(kr, b"", b"ctx") { panic("empty box opened"); }
}

// the byte b with its low bit flipped, as a one-byte value
fn crypto_flip(b: int) -> bytes {
    let out = b"\x00";
    out[0] = (b ^ 1) as u8;
    return out;
}

fn test_should_rotate_keys_and_rewrap_without_touching_the_value() {
    let kr = ring();
    let old_box = seal(kr, b"payload", b"a") ?? b"";
    let _k2 = add_key(kr, "k2", key(2));
    let new_box = seal(kr, b"payload", b"a") ?? b"";
    assert((key_id(new_box) ?? "") == "k2", "newest key seals");
    assert((open(kr, old_box, b"a") ?? b"") == b"payload", "old box after rotation");
    let moved = rewrap(kr, old_box) ?? b"";
    assert((key_id(moved) ?? "") == "k2", "rewrap key");
    assert(moved[len(moved) - 20..] == old_box[len(old_box) - 20..], "sealed value changed");
    let _r = remove_key(kr, "k1");
    assert((open(kr, moved, b"a") ?? b"") == b"payload", "rewrapped box needs the old key");
    if let _x = open(kr, old_box, b"a") { panic("opened with a removed key"); }
    if let _y = remove_key(kr, "k2") { panic("removed the current key"); }
}

fn test_should_validate_keys() {
    let kr = keyring();
    if let _a = seal(kr, b"x", b"") { panic("sealed without a key"); }
    if let _b = add_key(kr, "short", b"too short") { panic("short key accepted"); }
    if let _c = add_key(kr, "", key(1)) { panic("empty id accepted"); }
    if let _d = use_key(kr, "none") { panic("unknown key used"); }
}
