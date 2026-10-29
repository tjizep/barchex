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

## Store keys with LAYOUT

LAYOUT names the store keys lent uses in the application's space: rows
(`lay.row(t, pk)`), index entries (`lay.entry(t, ix, row, pk)`), edges and a
table's pk counter. `lay.walk(prefix, each)` calls `each(key)` for every key
under a prefix, a page at a time, and `each` may remove the key it is given.
`lay.scan(lo, hi, each)` and `lay.scan_back(lo, hi, each)` call `each(key)`
for the keys in `[lo, hi)`, in key order or highest first, and stop when
`each` answers `true`. `lay.scan_values(lo, hi, each, first)` and
`lay.scan_back_values(lo, hi, each, first)` call `each(key, value)` the same
way. Their first page holds `first` keys, 1000 by default, and each later
page twice as many up to 1000; pass a small `first` when `each` will stop
early.
`lent.LAYOUT` runs the module's self-check and answers `ok`.
