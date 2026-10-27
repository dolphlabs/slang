# sort

> Package sort.

Sorting lists in place with Go's `sort` engine shape, plus binary
search over what is already sorted. `ints`, `floats` and `strings`
sort by native comparison; `by` sorts any list of anything by a key
function returning `int`, `float` or `str`; `by_stable` keeps equal
keys in their original order; the `search` functions binary-search a
sorted list and answer `opt[int]`.

```slang
import "sort";

let xs = [5, 3, 9, 1, 3];
sort.ints(xs);                       // in place, ascending
let i = sort.search_ints(xs, 3) ?? -1;

let users = load_users();
sort.by(users, user_age);            // key fn -> int, float or str
sort.by_stable(users, user_name);    // equal keys keep original order

let names: [str] = [];
for u in users { push(names, u.name); }
sort.strings(names);

let fs = [3.5, 1.0, 0.0 / 0.0, 0.5];
sort.floats(fs);                     // NaN values sort first (Go's rule)
```

The unstable sorts allocate nothing; each runs an entry pass that
answers already-sorted and fully-reversed lists in one scan, and the
quicksort settles each duplicate group in one partition pass, so
four-valued million-element lists sort in tens of milliseconds.
`by_stable` merges with one scratch list of about n/2 elements.

## API

### `fn ints(xs: [int]) -> [int]`

Sorts xs in place, ascending. Unstable. Answers an already-sorted or strictly descending list in one scan, and duplicate-heavy data in no more passes than its distinct values take to settle, so the whole call is allocation-free either way.

### `fn floats(xs: [float]) -> [float]`

Same engine over floats, with a total order despite the type's own: NaN values sort before every number and equal to each other (Go's `sort.Float64s` rule), which is what makes the partition finite.

### `fn strings(xs: [str]) -> [str]`

Same engine over strings, bytewise: `""` sorts first, and the order is exactly what `<` gives — bytes, not locale, not Unicode points.

### `fn by[T, K](xs: [T], key: fn(T) -> K) -> [T]`

Sorts xs in place by key, ascending. Unstable: when two keys are equal, which was first is whatever the comparisons fell into. A call is free to permute equal keys differently on a re-run, so anything whose output must not change between runs uses `by_stable`.

### `fn by_stable[T, K](xs: [T], key: fn(T) -> K) -> [T]`

Sorts xs in place by key, ascending, and equal keys keep their original order: an adaptive merge sort. Natural runs are kept (a strictly descending run is reversed, which keeps order for equal keys, since a strictly descending run has none), windows of 32 are insertion-sorted, and runs merge bottom-up taking the left on equal keys. Nearly-sorted data therefore costs about one comparison per element, not n log n.

### `fn search_ints(xs: [int], v: int) -> opt[int]`

The first index of v in xs, sorted ascending, or none. On a list which is not sorted the result is defined but useless; it never reads past the list.

### `fn search_floats(xs: [float], v: float) -> opt[int]`

Same contract over floats: that includes searching for NaN, which finds the first NaN and sorts first under sort.floats. The index found for a searched NaN is where the first NaN of the list sits.

### `fn search_strings(xs: [str], v: str) -> opt[int]`

Same contract over strings: the first index of an exactly equal string, bytewise as `sort.strings` orders them.

### `fn search_by[T, K](xs: [T], key: fn(T) -> K, v: K) -> opt[int]`

Lower bound over a list already sorted by key: the first index whose key is not before v. Equality is `!(a < b) && !(b < a)`, which is `==` for int and str keys; for a float key it reads equal NaNs -- both raw comparisons false -- as a hit, the same reading `by` gives them.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
