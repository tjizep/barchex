# barch.vec: vector kernels for column scans

barch provides `barch.vec`, a table of native functions that filter, group
and aggregate typed values held in Luau buffers. lent calls them to scan
column blocks and blocks of fixed-width rows. This page specifies them for
barch's C++ version. The Luau reference in the lent repository defines every
result and error, and lent's tests run against both versions:

- reference: `/home/test/projects/barchex/lent/vec.luau` (`lent.VEC`)
- conformance tests: `/home/test/projects/barchex/tests/test_vec.py`
- benchmark: `/home/test/projects/barchex/tests/bench_vec.py`

The reference runs at 45 to 55 million elements/s for number kernels and 10
to 20 million for strings. The native version runs at 1 to 7 billion
elements/s for number kernels and 0.6 to 3 billion for strings, as
[Testing](#testing) lists.

## Scope

Every function is pure: it reads the buffers it is given and writes only the
output buffers. It touches no store key, transaction, lock or read log, so
it is safe in any space, inside or outside a transaction. Register the
table as `barch.vec` in every space's Luau state.

Use the NumKong dispatch already linked into barch
(`src/foreign/nk_luau.cpp`) or the same pattern: probe the CPU at run time
and pick AVX-512, AVX2, NEON or a scalar loop. Keep a scalar path that
matches the reference exactly; the tests compare against it.

## Elements and layouts

A column of elements lives in a buffer `b`. Element `i` starts at byte
`off + i * stride`. A column block packs its elements, so `stride` is the
element's width. A block of fixed-width rows holds one element per row, so
`stride` is the row's width. Elements may be unaligned; the tests use a
31-byte row, so load with `memcpy` or unaligned loads.

| kind | element, little-endian | width | nil |
|---|---|---|---|
| `i8` | int8 | 1 | equal to `none` |
| `i16` | int16 | 2 | equal to `none` |
| `i32` | int32 | 4 | equal to `none` |
| `i64` | int64 | 8 | equal to `none` |
| `f64` | float64 | 8 | NaN |
| `str` | u32 start, then u32 length + 1; the bytes are `b[start, start + length)` | 8 | length + 1 = 0 |

`none` is an optional Luau number that marks nil in the integer kinds, such
as code 0 of a dictionary column. Pass `nil` when the column has no nil.
`f64` ignores `none` and treats NaN as nil. `str` ignores it too.

lent uses `i16` for the short blocks of `int` columns whose values fit in
16 bits, and for the codes of dictionary blocks with more than 255
distinct values. It follows the same rules as the other integer kinds in
every function.

Most functions take candidates as `sel, n`. When `sel` is a buffer, the
candidates are the u32 indexes `sel[0..n)`, in that order. When `sel` is
`nil`, they are `0` to `n - 1`, which is the dense path to optimize first.
Output buffers come from the caller, so one set serves block after block.
An output may be the same buffer as `sel`; writes never pass reads, so
in-place compaction works.

## Functions

### `vec.mask(m, off, n, out) -> count`

Writes the u32 index of each byte of `m[off, off + n)` that is not 0 into
`out`, in order, and answers how many it wrote. lent's presence block (1
byte per slot) becomes the selection of slots that hold rows.

### `vec.filter(kind, b, off, stride, op, value, none, sel, n, out) -> count`

Writes the candidates whose element passes `element op value` into `out`,
in order, and answers how many it wrote. `op` is `=`, `~=`, `<`, `<=`, `>`
or `>=`.

- Number kinds compare as exact real numbers. An integer column with `<
  2.5` keeps 2, and `= 2.5` keeps nothing. Turn `op` and `value` into
  integer bounds once per call, clamped to the kind's range, then compare
  integers. `value` is never NaN.
- `str` compares with a Luau string by bytes, as `memcmp` over the shorter
  length and then the shorter string first.
- A nil element passes `~=` and fails every other op.
- `f64` follows IEEE: `-0 = 0` holds.

### `vec.filterIn(kind, b, off, stride, set, sel, n, out) -> count`

For kinds `i8`, `i16` and `i32`. Writes the candidates whose code `c` has
`0 <= c < buffer.len(set)` and `set[c] ~= 0` into `out`, in order, and
answers how many it wrote. A dictionary column tests any condition on its
strings this way: lent marks the codes whose strings pass, then one call
tests the block. For `i8`, a 256-entry table lookup per element suffices;
with `buffer.len(set) <= 16` or 32, `pshufb`/`tbl` lookups test 16 or 32
codes at once. For `i16`, `set` holds up to 65,536 bytes, so look up each
element in it.

### `vec.fold(kind, b, off, stride, none, sel, n, gids, out)`

Adds each candidate's element to its group's record in `out`. The k-th
candidate, counting from 0 in candidate order, belongs to group
`gids[k]`, a u32, or to group 0 when `gids` is `nil`. Group `g`'s record is
four f64s at byte `32 * g`:

| bytes | value |
|---|---|
| 0 | count of non-nil elements |
| 8 | their sum |
| 16 | their least |
| 24 | their greatest |

The caller starts each record at `0, 0, inf, -inf` and folds block after
block into it, so `fold` adds to the existing values. Nil elements change
nothing. `str` updates only the count.

Sums of integer kinds must be exact while every partial sum stays within
+-2^53; accumulate them in int64 and add to the record once per call. An
`f64` sum may add in any order; the tests allow a relative error of 1e-9.
Least and greatest of `i64` values past 2^53 may round when stored as f64.

### `vec.grouper(kind) -> g`

Answers a grouper: userdata that numbers the distinct values of one kind
from 0, in the order it first meets them, across every call to `g:ids`.
Nil is one value. `-0` and `0` are one value, keyed `0`. Its ids serve as a
`groupBy`'s group ids and as a dictionary's codes.

- `g:ids(b, off, stride, none, sel, n, gids) -> size` writes the group id
  of the k-th candidate at `gids[k]`, a u32, adds groups for values it
  hasn't met, and answers how many groups it then holds.
- `g:key(id)` answers the value of group `id`, a number or a string, or
  `nil` for the nil group.
- `g:size()` answers how many groups it holds.

For `i8` keys, a 256-entry direct table maps a value to its id with no
hashing. For other kinds, use an open-addressing hash table. `i16` keys may
use a direct table of 65,536 entries. lent can create a grouper for each
block, so keep creating an `i16` grouper and its first `g:ids` call on
1,024 elements about as cheap as an `i8` grouper's: allocate the table
lazily, or hash until the grouper holds many values. A grouper over many
distinct values grows, so allocate through the Luau state's allocator or
report its size to the garbage collector, so a function's memory limit
covers it.

### `vec.offsets(b, off, n, start, out) -> end`

Turns `n` u32 lengths at `b[off]`, each a length + 1 or 0 for nil, whose
values are stored one after another from byte `start`, into `str` elements
in `out`: element i is the start of value i and its length + 1. A nil
element's start is where the next value starts. Answers the byte after the
last value. lent's text blocks store their values this way.

## Errors

Raise these messages, with no position prefix (as `error(msg, 0)` does). The
tests check them exactly.

| case | message |
|---|---|
| unknown kind | `vec.filter: unknown kind u8` (with the function's name and the kind) |
| unknown op | `vec.filter: unknown op !=` |
| an element past the end of `b`, or `sel` shorter than `4 * n` | `vec.filter: reads past the end of a buffer` |
| `str` with a non-string value | `vec.filter: kind str compares with a string` |
| a number kind with a non-number value | `vec.filter: kind i32 compares with a number` |
| `stride` below 1 or fractional | `vec.filter: stride must be a whole number from 1` |
| `off` or `n` below 0 or fractional | `vec.filter: off must be a whole number from 0` |
| `filterIn` with another kind | `vec.filterIn: takes kind i8, i16 or i32` |
| `gids` shorter than `4 * n` | `vec.fold: takes a buffer of n u32 group ids or nil for gids` |
| `mask` or `offsets` past the end | `vec.mask: reads past the end of a buffer` |
| `grouper` with an unknown kind | `vec.grouper: unknown kind u8` |
| `g:key` with an id it doesn't hold | `vec.key: has no group 0` |

Check bounds before the loop: for dense candidates, the last element
`off + (n - 1) * stride + width` must lie within `b`. For a `sel`, check
each index, or take the largest index first, and raise the same "reads
past the end" message. The reference raises Luau's own buffer error for a
bad `sel` index; the tests accept any error there. Writes past the end of
an output buffer raise an error too; size outputs as `4 * n` bytes for
indexes and `32 * groups` for records.

## Testing

From `/home/test/projects/barchex`, with `pytest` and `redis` installed for
Python:

```bash
BARCHD=/home/test/barch/cmake-build-release/barchd pytest -q tests/test_vec.py
BARCHD=/home/test/barch/cmake-build-release/barchd python -m tests.bench_vec
```

`test_vec.py` runs each test twice, as `ref` on `lent.VEC` and as `native`
on `barch.vec`. The native runs skip on a barch without `barch.vec`, and
the native `i16` runs skip while `vec.grouper("i16")` raises. The benchmark
adds `native` columns when `barch.vec` exists and times each measurement
for 200 ms, or the milliseconds its argument gives. Leave the lent files
unchanged; report a disagreement with the reference so lent's owner decides
which side changes.

Rates on one machine, in millions of elements/s, blocks of 1,024 elements,
column layout, as the reference and then native:

| kernel | i8 | i16 | i32 | i64 | f64 | str |
|---|---:|---:|---:|---:|---:|---:|
| `filter`, dense | 53 / 4,490 | 52 / 4,240 | 54 / 4,130 | 46 / 2,500 | 55 / 4,050 | 21 / 1,170 |
| `filter`, half the slots in `sel` | 89 / 1,190 | 83 / 1,130 | 85 / 1,140 | 78 / 1,370 | 90 / 1,340 | 22 / 650 |
| `filterIn`, dense | 42 / 4,440 | 41 / 3,580 | 42 / 3,980 | | | |
| `fold`, one group | 49 / 6,650 | 49 / 8,320 | 50 / 7,380 | 46 / 4,510 | 53 / 5,680 | 60 / 2,940 |
| `fold`, 16 groups | 50 / 980 | 50 / 1,020 | 50 / 1,000 | 44 / 1,080 | 53 / 1,020 | 56 / 2,430 |
| `g:ids`, 16 distinct values | 32 / 2,640 | 32 / 1,360 | 33 / 1,140 | 27 / 1,190 | 30 / 1,110 | 10 / 600 |
| `mask` | 200 / 5,510 | | | | | |

In the row layout the reference runs at the same rates, and native dense
`filter` and one-group `fold` run at 1.5 to 2.8 billion, since each element
sits in its own row. A plain Luau loop that only sums an `f64` block runs
at 52 million, the same as the reference `fold`.

## Where the time goes after this

At 1 to 2 billion elements/s a 1,024-element block takes under 1 µs, so
per-block costs outside the kernel decide the speed of a scan. lent reads
each block with `barch.store.getBufferAt`, which copies the value and, in a
transaction, logs the read; that logging costs about 3.7 µs per block today.
Later, two additions would remove most of it: a read that answers buffers
for many keys in one call, and a read-only view of a stored value with no
copy. Neither is needed for the first version.
