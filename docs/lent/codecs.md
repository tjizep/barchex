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
| `aggregatePage` sum of one field | 610,000 rows/s | 130,000 rows/s |
| `groupBy` and sum | 375,000 rows/s | 112,000 rows/s |
| `count` with a filter | 1,110,000 rows/s | 153,000 rows/s |
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

Ids split into blocks of 1,024: the block is `floor(id / 1024)`, and the slot
is the id's place in its block. Each block has a presence key and one key per
field that holds a value in it.

| block | stored value | fields |
|---|---|---|
| presence | 1,024 bytes, 1 for a slot that holds a row, then the row count as an int32 | every table |
| number | an f64 per slot, with NaN for nil | `int`, `float`, `decimal`, `time`, `bool` |
| text | bytes in use, slots in use, a u32 per slot holding its length plus 1 or 0 for nil, then the values in slot order | `string`, `enum`, `json`, `bytes` |

These rules apply to a column table:

- **Ids.** The table needs `id = "int"`. A `uuid` table has no block numbers,
  and `lent.schema` refuses it with `has format column, which needs id =
  "int"`.
- **Value size.** All values of a text field in one block share one store
  value, and a key and value together hold at most 524,032 bytes. A write
  past that fails with `would hold N bytes in column block B`. Keep large
  values in a `binary` table.
- **Conflicts.** Rows in one block share its keys. Two transactions that
  create rows in one block, or write one field in one block, conflict in
  optimistic mode and wait for each other in pessimistic mode. Keep
  concurrent writers on different blocks, or batch their rows in one writer.
- **Format changes.** `migrate` refuses a change to or from `column` with
  `changes format from A to B; copy its rows into a new table to move them
  to or from column`.
- **Dropped fields.** A field dropped from the schema keeps its blocks in the
  store. They use space, and rows no longer read them.

`lent.COLUMNS` runs the module's self-check and answers `ok`. Install it with
CLIENT and MIGRATE, which both require it.

## Store keys with LAYOUT

LAYOUT names the store keys lent uses in the application's space: rows
(`lay.row(t, pk)`), index entries (`lay.entry(t, ix, row, pk)`), edges, a
table's pk counter, and a column table's presence blocks
(`lay.present(t, block)`) and field blocks (`lay.column(t, field)` is the
prefix). `lay.walk(prefix, each)` calls `each(key)` for every key
under a prefix, a page at a time, and `each` may remove the key it is given.
`lay.scan(lo, hi, each)` and `lay.scan_back(lo, hi, each)` call `each(key)`
for the keys in `[lo, hi)`, in key order or highest first, and stop when
`each` answers `true`. `lay.scan_values(lo, hi, each, first)` and
`lay.scan_back_values(lo, hi, each, first)` call `each(key, value)` the same
way. Their first page holds `first` keys, 1000 by default, and each later
page twice as many up to 1000; pass a small `first` when `each` will stop
early.
`lent.LAYOUT` runs the module's self-check and answers `ok`.
