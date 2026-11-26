# barch.vec on cursors: kernels that read a value in place

This spec lets the `barch.vec` kernels read a cursor's current value where
they take a data buffer. A Luau function reads a column block with
`cur:read`, then passes the cursor to `vec.compare`, `vec.foldBits` or
another kernel. The kernel reads the stored bytes directly, so the block is
no longer copied into a Luau buffer first.

It replaces the stage 2 section of the cursor spec, `docs/barch-scan.md`,
which is kept outside the repository. Stage 1, `barch.store.cursor` and
`cur:read`, ships in barch `0f6d0fff6219`; this spec builds on it as
shipped.

## Use

```lua
local cur = barch.store.cursor(lo, hi)
local head = buffer.create(16)

-- read only the header; the whole value becomes the cursor's current value
local size = cur:read(key, head, 0, 0, 16)
if type(size) == "number" and buffer.readu16(head, 2) == 0 then
    -- the kernel reads the stored block from byte 8 onward
    local n = barch.vec.compare("i16", cur, 8 + off * 2, 2, ">", 10, none,
        unit, bits, 0)
end
```

Check `barch.vec.cursors` before passing a cursor. It is `true` on a barch
that accepts cursors and `nil` on one that doesn't, where a cursor argument
fails with the function's usual `takes a buffer of elements` error.

## The cursor's current value

Each successful `cur:read` makes the value it read the cursor's current
value. This holds for every form of the call: with or without `out`, and
for a partial read with `from` and `n`. The current value is always the
whole value, and its size is the size the read answered.

- The current value keeps the bytes the read saw until the next `read` on
  that cursor or the cursor's end.
- A write or savepoint rollback later in the transaction shows after the
  next `read`, as it does in a copied buffer.
- A read that answers `nil` or `barch.tomb`, and a read that fails, clear
  the current value. So does the cursor's end.

A cursor holds one current value. Use one cursor for each block you want
to pass to kernels at the same time, such as one per column and one for
presence.

## Which arguments take a cursor

These arguments accept a cursor:

| function | argument |
|---|---|
| `vec.mask(m, off, n, out)` | `m` |
| `vec.filter(kind, b, off, stride, op, value, none, sel, n, out)` | `b` |
| `vec.filterIn(kind, b, off, stride, set, sel, n, out)` | `b` |
| `vec.fold(kind, b, off, stride, none, sel, n, gids, out)` | `b` |
| `vec.compare(kind, b, off, stride, op, value, none, n, bits, bitsoff)` | `b` |
| `vec.foldBits(kind, b, off, stride, none, bits, bitsoff, n, gids, out)` | `b` |

The kernel treats the current value as a read-only buffer whose length is
the value's size. Offsets, strides, selections, results and the `reads past
the end of a buffer` error work as they do on a buffer of that length.

Every other argument stays a buffer, and a cursor there fails with that
argument's existing error. This covers `sel`, `set`, `gids`, `out`, `bits`
and every argument of `vec.bits`, `vec.maskBits` and `vec.offsets`. A
kernel call takes at most one cursor, so it holds at most one latch.
`g:ids` also keeps taking a buffer, because it allocates and raises errors
while it runs.

## How a kernel reads the value

### Holding the value

`cur:read` pins its value when all of these hold:

- the transaction has a snapshot;
- the value came from a snapshot layer, or from a space that has no source;
- the value is uncompressed, has no expiry and is not volatile.

It copies every other value into scratch memory that the cursor owns and
reuses. This covers overlay values, reads outside a transaction, compressed
values and longer source chains. A kernel reads a copied value with no
latch.

A pin holds the `shard_ptr`, the leaf's logical address, the size and the
space shard's epoch. It holds no raw pointer and no latch, so a pinned
value never blocks a writer between kernel calls.

Add the epoch to `debuggable_server_lock` and increment it in `unlock()`,
which every exclusive hold passes through, upgrades included. This covers
writes, defragmentation, page shrinking and compression, including call
sites that take `get_latch()` directly. `get_modifications()` counts only
inserts and deletes, so it misses moved leaves.

### Running a kernel

1. Validate every argument that needs the Luau state. Check bounds against
   the pinned size, which a re-seek can't change: a snapshot's value keeps
   its bytes even when its leaf moves.
2. Take the space shard's read latch.
3. If the epoch, shard object and routing are unchanged, resolve the
   logical address. Otherwise seek the key again beneath the overlay, in
   the snapshot's layers and then the space, and update the pin.
4. Run the kernel.
5. Release the latch, then push the count or raise the error. This
   includes the `reads past the end of a buffer` and `writes past the end of
   a buffer` statuses that kernels return.

Step 3 leaves out the overlay because it can change under a shared latch,
and because the current value predates any later write. A writer holding
the space shard's latch writes each layer, so that shard's epoch covers it.
Test this assumption with a concurrent writer.

Keep `vec_luau.cpp` independent of the store. Give it a small scoped view
interface that answers bytes and a size and releases on destruction, and a
hook that `function_api.cpp` sets to open a view on a cursor argument. A
host without the hook, such as the standalone vec tests, leaves
`vec.cursors` unset.

## Errors

Raise these with no position prefix, naming the function that was called.

| case | message |
|---|---|
| cursor with no current value | `vec.fold: the cursor has no value` |
| cursor used after it ended | `vec.fold: the cursor has ended` |
| a pinned value is missing when sought again | `vec.fold: the cursor's value is gone` |
| a cursor in an argument that needs a buffer | the argument's existing error, such as `vec.fold: takes a buffer for its results` |

A missing pinned value means the snapshot lost a value it should keep, so
treat it as a defect and report it. Pass on routing errors unchanged.

## Changes in lent

These follow in this repository once barch has the change and
`barch.vec.cursors` is `true`. On an older barch, lent keeps copying.

- **Column blocks.** In `load`, read the block's header with
  `cur:read(k, c.head, 0, 0, SHEAD)`. Check the part count and rows from
  the header, and give the kernels the cursor as the source's data. This
  header read is the block's only read: an int block passes its format's
  none whether or not it holds nils, so lent skips the nil count after the
  slots. This needs barch `05d5c09`, where `vec.fold` with a none runs
  about as fast as without one. On an older barch, `vec.fold` over these
  blocks runs about 2.5 times slower.
- **Blocks that still copy.** Split blocks, text and dictionary blocks,
  group keys and the Luau row fallback read the block with Luau buffer
  functions, so they keep copying. Route every Luau read of a column
  block through one accessor that copies the block on first use.
  `cursor_joined` reads parts through the column's cursor, so it copies
  into `c.whole` as it does now.
- **Presence blocks.** Read the 16-byte header for the rows, live count and
  end, and pass the presence cursor to `vec.mask` and `vec.compare`. Today
  `fold_block` zeroes the slots outside `a..z` in its copy. With a cursor,
  copy only the chunks that `a` or `z` cuts, into `job.presence`, and zero
  their slots outside the range. The end mark needs no zeroing, since no
  row lies at or past it.
- **Small blocks.** Read presence and number blocks of at least 16384
  bytes in place, and copy smaller ones. An int field's block counts 2
  bytes per row, an f64 block 8 and a presence block 1. Below 16 KB the
  header read costs about as much as the copy it saves. Tests call
  `in_place(bytes)` to change the threshold, and `in_place(nil)` to copy
  every block.

## Measurements

Measured on a Ryzen 9 7940HS (1 MB L2 per core, 16 MB L3) with 524,288
rows. The copy and query figures come from barch `0f6d0fff6219`, and the
kernel figures from `887548a`, which folds f64 `vec.foldBits` with vector
code.

`cur:read` copies at about 25 ns per KB above 64 KB, with no step at
64 KB. Per slot, that is about 0.025 ns for presence and i8 columns,
0.05 ns for i16 and 0.2 ns for f64.

The kernels cost the same per slot from 4K to 1M slots, so block size and
cache size don't change their speed. These are the AVX-512 figures, with
about 99% of the bits set:

| kernel | ns per slot |
|---|---:|
| `vec.compare` i8 | 0.07 |
| `vec.compare` i16 | 0.09 |
| `vec.compare` f64 | 0.15 |
| `vec.bits` and | 0.05 |
| `vec.foldBits` i16 | 0.13 |
| `vec.foldBits` f64 | 0.18 |

Before `887548a`, f64 `vec.foldBits` took 1.14 ns per slot, because it
folded partly set bits one element at a time. With AVX2 it now takes
0.22 ns.

`vec.fold` over a whole block, with no selection or group ids, costs this
much per slot at 64 KB blocks. Before `05d5c09`, a fold given a none took
0.63 ns per slot at every width and ISA, because its loop stayed scalar.

| kind | without a none | with a none |
|---|---:|---:|
| i8 | 0.03 | 0.065 |
| i16 | 0.03 | 0.07 |
| i32 | 0.06 | 0.14 |
| i64 | 0.14 | 0.15 |

Outside a transaction, `age > 10 sum` takes about 0.55 ns per row. Copying
its presence block and one or two i16 blocks takes 0.075 to 0.125 ns of
that. Removing the copies should make large i8 and i16 scans 10 to 20%
faster. An f64 sum filtered on an i16 column spends about 0.40 ns per row
in its kernels and 0.275 ns copying, so removing the copies should make it
up to 40% faster.

### Results in lent

Lent `799255f` on barch `05d5c09`, outside a transaction, with 524,288
rows. Each cell gives G rows per second when copying, then when reading
in place, on hash shards and then range shards. Blocks of 4 KB are below
the threshold, so both runs copy.

| block | `sum all` | `age > 10 sum` | `grouped sum` |
|---|---|---|---|
| 4 KB | 0.61, 0.60 / 0.73, 0.72 | 0.41, 0.40 / 0.46, 0.45 | 0.32, 0.33 / 0.37, 0.36 |
| 16 KB | 1.83, 1.90 / 2.03, 2.23 | 1.11, 1.17 / 1.17, 1.28 | 0.84, 0.82 / 0.85, 0.90 |
| 64 KB | 3.33, 3.47 / 3.55, 3.85 | 1.95, 2.20 / 1.97, 2.37 | 1.31, 1.39 / 1.36, 1.46 |
| 256 KB | 2.32, 2.57 / 2.40, 2.71 | 1.95, 2.32 / 2.01, 2.45 | 1.30, 1.45 / 1.34, 1.48 |

Against the acceptance targets below:

- With 524,288 rows, `age > 10 sum` is 11 to 17% faster at 64 KB blocks
  and 16 to 18% faster at 256 KB. `sum all` is 4 to 8% faster at 64 KB
  and 10 to 11% at 256 KB. `grouped sum` is 6% faster at 64 KB and 10%
  at 256 KB, because its group key column is still copied.
- With 64 rows, no query is slower by more than 0.006 ms, and queries on
  256 KB blocks are 9 to 28% faster.
- No other query is slower by more than 0.004 ms.

Whole queries gain less than the kernel measurements above, because the
copy is a smaller share of a query than of a kernel call.

## Testing

In barch:

- each kernel in the table above on a cursor against the same kernel on a
  copied buffer, at every `BARCH_VEC_ISA`, for pinned and copied values;
- a partial `cur:read` followed by a kernel that reads past the copied
  bytes, which must see the whole value;
- every error above, and a cursor in each argument that needs a buffer;
- a writer that replaces, deletes and compresses the pinned value between
  kernel calls, and the kernel still reading the snapshot's bytes;
- defragmentation, page shrinking, shard rebalancing and layer recycling
  between kernel calls, under AddressSanitizer;
- a kernel error followed by a write to the same shard, which must succeed.

In lent, run every query path with cursors and with copies and check that
the results match, including spans that start and end mid-block, blocks
with an end mark, legacy blocks, and split and text blocks:

```bash
BARCHD=/home/test/barch/cmake-build-release/barchd pytest -q tests
```

## Acceptance

Compare against `0f6d0fff6219` on the same machine, alternating the order of
runs, on hash and range shards.

- With 524,288 rows, `sum all`, `age > 10 sum` and `grouped sum` run at
  least 10% faster, inside and outside a transaction.
- With 64 rows, no query is slower by more than both 5% and 0.01 ms.
- No other query is slower by more than both 5% and 0.1 ms.
- The epoch costs writes at most 2%.

Leave the change out if it misses the first or the last target.
