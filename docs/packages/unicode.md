# unicode

> Package unicode.

Text as people write it: UTF-8 validation, characters rather than bytes,
case-insensitive comparison and canonical normalisation, from the Unicode
18.0 tables. Use it for usernames, display names, length limits and search;
`strings` stays the tool for protocol text.

```slang
import "unicode";

unicode.valid(s);                       // strict UTF-8: no overlongs or surrogates
unicode.valid_bytes(body);              // the same check on bytes, before to_str
unicode.count("café 😀");               // 6 characters (len is 10 bytes)
unicode.truncate(bio, 160);             // first 160 characters, none split
unicode.runes("aé");                    // [97, 233]: code points
unicode.encode(0x1F600) ?? "";          // "😀"; none for a surrogate or U+0000

unicode.fold("Straße");                 // "strasse": full case folding
unicode.equal_fold("STRASSE", "straße"); // true
unicode.nfc(name);                      // composed form: store and compare this
unicode.nfd(name);                      // decomposed form
unicode.is_nfc(name);                   // true when nfc(name) == name
```

The same text can arrive as different bytes: `é` is one code point
(U+00E9) from most keyboards and two (`e` + U+0301) from some, so two
strings that both display as `café` can compare unequal. Normalise with `nfc` at the boundary,
before storing or comparing. For a case-insensitive key, such as a
username that must be unique however it is capitalised, store
`unicode.nfc(unicode.fold(unicode.nfd(name)))`, or compare with
`equal_fold`, which implements the Standard's canonical caseless match
(D145) and so treats `"STRASSE"`, `"straße"` and a decomposed spelling as
equal.

**Invalid UTF-8 is repaired, not guessed at.** The checks report it
(`valid` is false, `is_nfc` is false); every transform (`fold`, `nfc`,
`nfd`, `truncate`, `runes`) replaces each malformed sequence with U+FFFD,
as the Standard recommends, so its output is always valid UTF-8. Code that
must reject bad input rather than repair it calls `valid` first.

**Cost.** Native, reading each `str` in place. `valid`, `valid_bytes`,
`count`, `is_nfc` and `equal_fold` allocate nothing on the GC heap, and
`fold`, `nfc`, `nfd` and `truncate` return their input itself, with no
allocation, when it is already in the requested form, which covers ASCII
and nearly all real text. Long runs of combining marks are reordered in
linear time, so hostile input cannot make normalisation quadratic. The
tables add about 125 KB to a program that imports the package, and
nothing to one that does not.

Out of scope: compatibility normalisation (NFKC/NFKD, which maps `ﬁ` to
`fi` and full-width letters to ASCII), grapheme clusters (a flag emoji
or an accented letter can be more than one code point, and `truncate`
counts code points), and locale-specific casing (Turkish dotted and
dotless i).

The tables come from the Unicode data files under the Unicode License v3.
Its notice is compiled into every program that imports `unicode`, so the
binary carries it wherever it goes; see `THIRD_PARTY.md` and
`LICENSES/Unicode-3.0.txt`.

## API

### `unicode.valid(str) -> bool`

### `unicode.valid_bytes(bytes) -> bool`

### `unicode.count(str) -> int`

### `unicode.runes(str) -> [int]`

### `unicode.encode(int) -> opt[str]`

### `unicode.truncate(str, int) -> str`

### `unicode.fold(str) -> str`

### `unicode.equal_fold(str, str) -> bool`

### `unicode.nfc(str) -> str`

### `unicode.nfd(str) -> str`

### `unicode.is_nfc(str) -> bool`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
