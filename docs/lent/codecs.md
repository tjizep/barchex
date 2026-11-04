# lent codecs and store layout

lent stores rows, index entries and edges as keys in the application's
space. KEYCODEC turns values into keys that sort in value order, ROWCODEC
turns rows into stored values, and LAYOUT names the keys. The other lent
pages build on these: [schema](schema.md), [migrations](migrate.md),
[rows and edges](client.md) and [queries](queries.md).

## Order-preserving keys with KEYCODEC

KEYCODEC encodes values as key text that `barch.store.range` walks in value
order. It is the first part of lent (Luau entities), an ORM planned in
[docs/lent-design.md](../lent-design.md). Require it from any space:

```lua
local kc = require("lent.KEYCODEC")
local key = "lent.i.user.by_age" .. kc.pack({ "int", "string" }, { 42, "ann" })
local values, next = kc.unpack(key, 2, #"lent.i.user.by_age" + 1)  -- { 42, "ann" }
local lo = "lent.i.user.by_age" .. kc.encode("int", 42)
local keys = barch.store.range(lo, kc.after(lo), 100)            -- every age 42
```

| kind | values | order |
|---|---|---|
| `int` | integers from -2^53 to 2^53 | numeric |
| `float` | any number except NaN; -0 is stored as 0 | numeric, `-inf` to `inf` |
| `string` | any bytes | byte order, a prefix before its extensions |
| `bool` | `false`, `true` | `false` first |
| `uuid` | 36 lowercase characters, as `barch.uuid()` answers | the uuid's text order |
| `time` | as `int`, for Unix milliseconds | numeric |
| `decimal` | as `float`; SCHEMA rounds values to the field's scale | numeric |
| `enum` | a string label; SCHEMA and ROWCODEC check the allowed values | byte order of the label |
| `bytes` | any bytes in a Luau string | the same byte order as `string` |

`nil` encodes as null for every kind and sorts before every value. `encode`
raises an error for a value of the wrong kind, a fractional or out-of-range
`int`, NaN, and a uuid that is not 36 lowercase characters. Encoded values
contain no space, NUL or `\1` byte, which barch would otherwise read as a
tuple separator or refuse, and which earlier barch builds cut short in a
range. Start each key with a prefix that begins with a letter, such as
`lent.`, so barch keeps the whole key as text. `after(prefix)` answers the
exclusive upper bound for a range over every key that starts with `prefix`.
`lent.KEYCODEC` runs the module's self-check and answers `ok`.

## Stored rows with ROWCODEC

ROWCODEC turns a row table into a stored value and back. Compile the
table's fields once with `fields`, then call `encode` with a format and the
schema version, and `decode` with the stored value:

```lua
local rc = require("lent.ROWCODEC")
local users = rc.fields({
    { name = "email", kind = "string", id = 1 },
    { name = "age", kind = "int", id = 2, optional = true },
})
barch.store.set("lent.r.user.1", rc.encode(users, "binary", 3, { email = "a@b", age = 41 }))
local row, version, format = rc.decode(users, barch.store.get("lent.r.user.1"))
```

| field key | required | values |
|---|---|---|
| `name` | yes | a letter, then letters, digits and `_` |
| `kind` | yes | `string`, `int`, `float`, `decimal`, `bool`, `time`, `enum`, `json` or `bytes`; `time` uses integer storage and `decimal` float storage |
| `id` | yes | 1 to 65535, unique in the table; keep it when the field is renamed |
| `optional` | no | `true` lets the row leave the field nil; default `false` |
| `values` | for `enum` | a non-empty list of distinct, non-empty UTF-8 strings |

| format | stored value | limits |
|---|---|---|
| `json` | a JSON object keyed by field name, with the version in `_v` | string fields must be UTF-8; floats must be finite; bytes use hexadecimal strings |
| `text` | `t<version>`, then a tab and `<id>=<value>` per field | bytes use hexadecimal strings; JSON values use escaped JSON text |
| `binary` | `b`, a u32 version, then an id, a tag and a value per field | bytes use raw data; JSON values use length-prefixed JSON text |

Bytes round-trip in all three formats. Hexadecimal storage takes two
characters per byte in `json` and `text` rows; use `binary` for compact byte
storage. JSON field validation applies in every row format.

`encode` raises an error for a key the fields do not define, a missing value
for a field that is not optional, a value of the wrong kind, NaN, and a
version outside 0 to 2^32-1. `decode` reads every format and answers the
row, the schema version it was written with and the format. A row written
with an older field list reads with the current one: added fields are nil,
values for removed fields are skipped, an `int` value reads into a `float`
field, and a whole-number `float` value in range reads into an `int` field.
Enum values use string storage, so they also read as strings. Use MIGRATE
to check a schema change's storage compatibility. `lent.ROWCODEC` runs the
module's self-check and answers `ok`. The codecs and schema use
`lent.VALUES` for structured value handling; install it with the other lent
modules. `lent.VALUES` also answers `ok` for its self-check. CLIENT requires
`lent.EXPR` for its expression filters, so install it with CLIENT;
`lent.EXPR` answers `ok` for its self-check.

## Column tables with COLUMNS

Set `format = "column"` on a table to store its rows by field in blocks. A
query that reads a few fields of many rows then reads only those fields'
blocks. Choose it for tables you scan and aggregate more often than you
write one row at a time. The table's API, queries, indexes, edges, hooks and
policies work the same as in the row formats.

```lua
lent.schema "Trip" {
    id = "int",                -- required for format = "column"
    format = "column",
    fields = { lent.field.time "pickup", lent.field.float "fare",
               lent.field.string "zone" },
}
```

Measured on 40,960 trips of 10 fields, on one machine:

| work | `column` | `binary` |
|---|---|---|
| `aggregatePage` sum of one field, pages of 10,240 rows | 18,000,000 rows/s | 140,000 rows/s |
| `groupBy` and sum, pages of 10,240 rows | 9,000,000 rows/s | 128,000 rows/s |
| `count` with a filter | 26,000,000 rows/s | 160,000 rows/s |
| `createMany`, 1,024 rows per transaction | 13,000 rows/s | 25,000 rows/s |
| `get`, one per transaction | 3,800 rows/s | 5,200 rows/s |
| `update` of one field, one per transaction | 2,200 rows/s | 4,100 rows/s |
| `create`, one per transaction | 960 rows/s | 3,800 rows/s |

A `create` falls to about 200 rows/s in a nearly full block of 200-byte
strings, since each write copies its block. Load rows with `createMany`.

`count` and aggregates read only the fields they filter, sort, group and
sum on, and `all`, `first` and `get` read every field. `count` and
aggregates read whole rows when the query has a filter function or a query
policy, when the table has computed fields, or when an aggregate takes a
`value` function.

A query with `order` and `limit` that reads the table by id keeps only the
rows that sort first. It reads the fields it filters and sorts on, skips
each row that sorts after the last row it keeps, and then reads every field
of the rows it answers. In a dictionary block it compares each row's code
with the code of that last value. A sort field with a `:default()` is
compared row by row. On 204,800 rows in `"scan"` blocks, `order` on a
`string` field with 1,000 values and `limit(10)` took 20 ms, and 60 ms with
`limit(1000)`; reading and sorting every row took 600 ms.

### Block size

Set `block` on a column table to choose how large its blocks are. Smaller
blocks make each write cheaper and conflict with fewer other writes. Larger
blocks make scans and aggregates faster.

```lua
lent.schema "Trip" {
    id = "int",
    format = "column",
    block = "htap",            -- or "balanced", "scan", or a byte count
    fields = { lent.field.time "pickup", lent.field.float "fare",
               lent.field.string "zone" },
}
```

| `block` | bytes per block | use |
|---|---:|---|
| `"htap"` | 4,096 | tables written row by row while queries scan them |
| `"balanced"` | 8,192 | tables that are both written and scanned |
| `"scan"` | 65,536 | tables loaded in bulk and then scanned |
| a whole number | 1,024 to 262,144 | your own trade-off |

lent fits each block close to the target size. The table and each field get
the power of two of rows nearest to it. A presence block takes 1 byte per
row, an `int` field 2 for the int16 of a short block, and other number
fields 8. A text field is sized as a dictionary block that holds its most
distinct values, half its rows: a 2-byte code per row, or 1 byte in blocks
of up to 256 rows, and per value 4 bytes plus the field's `maxLen`, its
longest `enum` choice, or 12 bytes, up to 33. A field never has more rows
than the presence blocks. With `block = "htap"`, presence blocks hold 4,096
rows, `int` fields 2,048, other number fields 512 and a `string` field
without `maxLen` 512.

An `int` block that holds a value outside -32,767 to 32,767 takes 8 bytes
per row, and a plain text block takes each value's length plus 4 bytes, so
these blocks can grow past the target size. A block that grows past
barch's value limit is stored in parts; see [Split
blocks](#split-blocks).

`migrate` records the rows in the catalog when it creates the table or adds
a field, and a field keeps them after that. `migrate` refuses a change of
`block` on a stored table with `changes block from A to B; copy its rows
into a new table to change its block size`. A table without `block` keeps
1,024 rows in every block.

On 409,600 rows of three fields, one `aggregate` call and one `update` of
one row per transaction ran at these rates on one machine:

| `block` | sum | filtered sum | `groupBy` and sum | `update` | `createMany` |
|---|---:|---:|---:|---:|---:|
| none, 1,024 rows | 78 million rows/s | 42 million rows/s | 36 million rows/s | 420 µs | 24,000 rows/s |
| `1024` | 21 million rows/s | 15 million rows/s | 11 million rows/s | 350 µs | 30,000 rows/s |
| `"htap"` | 57 million rows/s | 49 million rows/s | 37 million rows/s | 410 µs | 29,000 rows/s |
| `"balanced"` | 97 million rows/s | 86 million rows/s | 64 million rows/s | 460 µs | 26,000 rows/s |
| `"scan"` | 205 million rows/s | 155 million rows/s | 90 million rows/s | 1,450 µs | 12,000 rows/s |

The sum reads a `float` field, the filter compares an `int` field, and the
group key is a `string` field with 10 values, which tables with `block`
store in dictionary blocks; see [Stored blocks](#stored-blocks). An
`update` copies each block it writes, so its cost grows with the block, and
so does a concurrent writer's chance of a conflict on that block.

### Stored blocks

Ids split into blocks: the block is `floor(id / rows)`, and the slot is the
id's place in its block. Each presence block has a key, and each field one
key per block of its own rows that holds a value. A block of a table with
`block` starts with a header that holds its rows, and a read whose header
disagrees with the catalog fails with `the stored blocks do not match the
schema`.

| block | stored value | fields |
|---|---|---|
| presence | a 16-byte header, then 1 byte per slot, 1 for a slot that holds a row; without `block`, the 1,024 bytes, then the row count as an int32 | every table |
| number | an 8-byte header, then an f64 per slot, with NaN for nil; without `block`, no header | `int`, `float`, `decimal`, `time`, `bool` |
| short | with `block` only: an 8-byte header, then an int16 per slot, with -32,768 for nil | `int` |
| text | a 24-byte header with the bytes in use, the slots in use and the count of long values, a u32 per slot holding its length plus 1 or 0 for nil, then the values in slot order; without `block`, the bytes and slots in use, then the same | `string`, `enum`, `json`, `bytes` |
| dictionary | with `block` only: a 24-byte header with the count of distinct values, a code per slot (an int8 for up to 255 values, otherwise an int16), then the distinct values sorted by byte, each with its length | `string`, `enum`, `json`, `bytes` |

With `block`, a text block whose values repeat is stored as a dictionary
block. Each slot holds a code: 1 byte while the block holds up to 255
distinct values, and 2 bytes past that. The codes follow the sorted order
of the values, so a filter compares codes, a `groupBy` groups them, and
`min`, `max` and `order` with `limit` compare them, without reading the
strings of each row. A new text block starts as a
dictionary block. It becomes a plain text block when a write would give
it more distinct values than half its rows or a value longer than 32
bytes. It becomes a dictionary block again when an update or delete that
removes a value leaves it with no value longer than 32 bytes and at most
half its rows in distinct values. The block keeps a lower bound of its
distinct values and counts them only when a write brings that bound down to
the limit, so updates to a block of mostly distinct values stay as fast as
other plain text writes. Reads and query answers are the same for both
kinds.

A block of up to 511 rows holds at most 255 distinct values, so 2-byte
codes need larger blocks: a `string` field without `maxLen` has 1,024-row
blocks on `"balanced"` and 8,192-row blocks on `"scan"`. On `"scan"`
blocks of 409,600 rows with 1,000 distinct values, dictionary blocks took
2.0 MB where plain text took 4.9 MB, and a `groupBy` on the field ran 30%
to 80% faster.

With `block`, an `int` block whose values lie within -32,767 to 32,767 is
stored as a short block, which takes a quarter of the bytes of a number
block. A new `int` block starts short when its first value fits. It becomes
a number block when a write stores a value outside that range, and short
again when an update or delete removes the last such value. Reads and
query answers are the same for both kinds. The rows sizing counts 2 bytes
per row for every `int` field, so a short block fills the target block
size, and a number block, at 8 bytes per row, is four times that size. On
409,600 rows with an `int` field of values 0 to 99, short blocks shrank
that field from 3.3 MB to 0.83 MB, and a filter or `groupBy` on it ran 15%
to 60% faster.

With `block`, a text block keeps the first 33 bytes of a value longer than
32 bytes, and the whole value is stored under its own key. Reads, filters
and groups use the whole value. A scan reads those keys only for the long
values it filters, groups or returns. A scan that filters or groups on a
text field runs the Luau loops for each block that holds a long value of it.

#### Split blocks

With `block`, a number block of an `int` field or a text block whose value
and key would pass barch's limit of 524,032 bytes is stored in parts of
262,144 bytes. Part 0 stays at the block's key and keeps the header, whose
uint16 at bytes 2 and 3 holds the number of parts, or 0 for a block stored
whole. Part p is stored at the block's key followed by `/` and p. A block
returns to one key when a write shrinks it under the limit, and deleting
the block's last row removes all its parts. Reads and query answers are the
same for split and whole blocks.

A block splits only when it outgrows its sizing. With `block = 262144`, an
`int` block of 131,072 rows splits into 5 parts when it holds a value
outside -32,767 to 32,767. A text block of 32,768 rows splits as a plain
block of about 12,000 values of 40 bytes, or as a dictionary block of
about 13,000 distinct values of 32 bytes. Scans read every part, and a
text write rewrites every part, so each costs as much as on a whole block
of the same size. A write or `get` of one `int` row reads and changes only
the part that holds its slot. A read that finds a part missing fails with
`has lost part P of N`.

These rules apply to a column table:

- **Ids.** The table needs `id = "int"`. A `uuid` table has no block numbers,
  and `lent.schema` refuses it with `has format column, which needs id =
  "int"`.
- **Value size.** A key and value together hold at most 524,032 bytes.
  Without `block`, all values of a text field in one block share one store
  value, and a write past that limit fails with `would hold N bytes in
  column block B`. With `block`, each long value has its own key, and a
  longer value fails with `would hold a value of N bytes`. Keep large
  values in a `binary` table.
- **Conflicts.** Rows in one block share its keys. Two transactions that
  create rows in one block, or write one field in one block, conflict in
  optimistic mode and wait for each other in pessimistic mode. Keep
  concurrent writers on different blocks, or batch their rows in one writer.
- **Format changes.** `migrate` refuses a change to or from `column` with
  `changes format from A to B; copy its rows into a new table to move them
  to or from column`.
- **Block changes.** `migrate` refuses a change of `block`; see
  [block size](#block-size).
- **Dropped fields.** `migrate` removes a dropped field's blocks in pages,
  with a `drop Table.field blocks` step. Writes to the table continue while
  the step runs.

### Scans in barch's block loop

`count`, `aggregate` and `aggregatePage` on a column table fold its blocks
in one loop inside barch, a run of rows at a time as long as the smallest
block the call reads. The loop tests the filters on a
block's field values, then adds the rows that pass to their groups, and
creates no row tables. When barch provides the vector kernels `barch.vec`,
described in [barch.vec](../barch-vec.md), the loop runs each step as one
native call over the block. Otherwise it runs Luau loops, which give the
same answers.

On 409,600 rows in a transaction, on one machine, one `aggregate` call ran
at these rates:

| fold | with `barch.vec` | Luau loops |
|---|---:|---:|
| sum of a `float` field | 85 million rows/s | 48 million rows/s |
| the same sum, filtered on an `int` field | 51 million rows/s | 31 million rows/s |
| the same sum, grouped by a `string` field with 10 values | 42 million rows/s | 14 million rows/s |

These rates are for a table without `block`; see [block size](#block-size)
for larger blocks. With `barch.vec`, reading the blocks takes nearly all of
that time, about 11 µs per block for the presence block and one field, so each filter or key
on another field adds a block read. Each call also costs about 0.3 ms, so
small tables and small pages gain less.

A call uses the block loop when all of these hold:

- Each filter compares a stored field or `id` with a value, through
  `where(field, op, value)` or a `where` expression part such as
  `fare > 120`.
- The plan reads the table by id. A condition on an indexed field makes the
  query read rows through that index; `explain` shows the plan.
- Each `groupBy` key and aggregate field is a field of the table other than
  a `json` field, with no edge in its path.
- `aggregate` has no `order`, `limit` or `offset` on the query.

The loop uses `barch.vec` when the call also meets these:

- Each filter compares `id` or an `int`, `float`, `decimal` or `time`
  field with a number, or a `string`, `enum` or `bytes` field with a
  string.
- The call has at most one `groupBy` key.
- Each aggregate counts rows, or counts, sums, averages or finds the least
  or greatest of an `int`, `float`, `time` or `decimal` field, or finds the
  least or greatest of a `string`, `enum` or `bytes` field. A `decimal` sum
  or average, and a `distinct` aggregate, run the Luau loops. `min` and
  `max` of text compare codes in dictionary blocks, and run the Luau loops
  on the rows of a plain text block.
- No key or aggregate names `id`, and no filter, key or aggregate names a
  `bool` field or a field with a `:default()`.

Any other call reads its rows one at a time, at a million rows/s or less.
That includes a filter function, an expression part such as `qty + 1 > 3`,
`has`, `follow`, `after`, a query policy, computed fields, and an aggregate
with a `value` function.

### Compressed column blocks

Turn on barch's zstd compression with `CONFIG SET compression zstd` to
compress column blocks. barch's maintenance thread compresses keys that
nobody has read or written for a while, so blocks compress after a load
finishes. A write to a block stores that block uncompressed again until the
thread finds it cold. lent needs no setting for this. The setting covers the
row-format tables too. A space either compresses or evicts its cold keys, so
compression stays off while an eviction policy is set.

Measured on 40,960 generated trips of 10 fields, on one machine:

| block | uncompressed bytes | saved |
|---|---|---|
| number | 2,686,976 | 74% |
| presence | 42,148 | 97% |
| text, 2 distinct values | 332,104 | 97% |
| text, 260 distinct values | 437,656 | 89% |

Scans, `groupBy` and filtered `count` ran at the same speed compressed and
uncompressed. `get` ran about a third slower and `update` about an eighth
slower, since each decompresses one block per field it reads or writes.

`lent.COLUMNS` runs the module's self-check and answers `ok`. Install it with
CLIENT and MIGRATE, which both require it.

## Store keys with LAYOUT

LAYOUT names the store keys lent uses in the application's space: rows
(`lay.row(t, pk)`), index entries (`lay.entry(t, ix, row, pk)`), edges, a
table's pk counter, a column table's presence blocks
(`lay.present(t, block)`) and field blocks (`lay.column(t, field)` is the
prefix), and the scratch keys of a spilled paged aggregate
(`lay.scratch(run)` is the prefix; see
[many groups](queries.md#many-groups)), and a table's planner statistics
(`lay.stats(t)`; see [planner statistics](migrate.md#planner-statistics)).
`lay.walk(prefix, each)` calls
`each(key)` for every key under a prefix, a page at a time, and `each` may
remove the key it is given. `lay.scan(lo, hi, each)` and `lay.scan_back(lo, hi, each)` call `each(key)`
for the keys in `[lo, hi)`, in key order or highest first, and stop when
`each` answers `true`. `lay.scan_values(lo, hi, each, first)` and
`lay.scan_back_values(lo, hi, each, first)` call `each(key, value)` the same
way. Their first page holds `first` keys, 1000 by default, and each later
page twice as many up to 1000; pass a small `first` when `each` will stop
early.
`lent.LAYOUT` runs the module's self-check and answers `ok`.
