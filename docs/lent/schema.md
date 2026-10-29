# lent schema

SCHEMA declares lent tables in Luau. `lent.schema` checks one table and
`lent.graph` checks the tables together; each raises an error that starts with
`SCHEMA` and names the problem:

```lua
local lent = require("lent.SCHEMA")
local User = lent.schema "User" {
    format = "json",                              -- default "binary"
    fields = {
        lent.field.string "email":unique(),        -- adds unique index by_email
        lent.field.string "name",
        lent.field.int "age":optional(),
        lent.field.bool "admin":default(false),
    },
    edges = { lent.edge.to "posts" "Post" },
    indexes = { lent.index("name", "age") },       -- index by_name_age
}
local Post = lent.schema "Post" {
    id = "int",                                   -- ids 1, 2, 3, ...
    fields = { lent.field.string "title" },
    edges = { lent.edge.from "author" "User":ref "posts":unique() },
}
local app = lent.graph { User, Post }
local version, fields = lent.ids(User, previous)   -- fields for rc.fields
```

`lent.graph` also takes views made with `lent.view`, which name a query
that the client reads like a table; see [views](queries.md#views).

| builder | modifiers |
|---|---|
| `lent.field.string`, `.int`, `.float`, `.bool`, `.time` | `:optional()`, `:unique()`, `:default(v)`, `:was("old_name")`, and the value rules below |
| `lent.field.decimal` | the same modifiers, plus required `:scale(n)` |
| `lent.field.enum` | the same modifiers, plus required `:values("choice", ...)` |
| `lent.field.bytes` | the same modifiers and byte-length rules |
| `lent.field.json` | `:optional()`, `:default(v)`, `:was("old_name")`, `:immutable()`, `:validate(fn)` and `:updateDefault(fn)` |
| any field builder | `:computed(fn)`, and `:stored(revision)` to store it; see computed fields below |
| `lent.index(field, ...)` | `:unique()`, `:name("by_x")`, `:edges("edge", ...)`; see indexes with edges below |
| `lent.edge.to "name" "Table"` | `:unique()`, `:fields { ... }` |
| `lent.edge.from "name" "Table"` | `:ref "to_edge"` (required), `:unique()` |
| `lent.edge.through "name" "Table"` | `:via "edge.edge"` (required), `:stored()`; see [path edges](client.md#path-edges) |

## Plain tables

Fields, indexes and edges can also be plain tables of the same options.
Each option takes the modifier's name, and `true` stands for a modifier
without an argument. This declares the same `Post` as above:

```lua
local Post = lent.schema "Post" {
    id = "int",
    fields = { { kind = "string", name = "title" } },
    edges = {
        { dir = "from", name = "author", target = "User", ref = "posts", unique = true },
    },
}
```

| plain table | keys |
|---|---|
| field | `kind` and `name` (required), `values` (required for `enum`), `scale` (required for `decimal`), `optional`, `unique`, `default`, `was`, `computed`, and the value rules below; `validate` takes a function or a list of them |
| index | `on`, a list of field names (required), `edges`, a list of edge names, `unique`, `name` |
| edge | `dir`, `"to"`, `"from"` or `"through"`, `name` and `target` (required), `ref`, `unique`, `fields`, `via` (a dotted string or a list of names), `stored` |

A plain table goes through the same checks as the builder, and a key it
does not recognise raises an error, so a misspelt option fails when the
schema loads. The two forms can be mixed in one table.

## Indexes with edges

An index can also hold the rows that a row links to. `:edges("order")` adds
the id of the row that the `order` edge links to after the index's fields,
so a unique index can cover a key such as a line's number within its order:

```lua
local Line = lent.schema "Line" {
    id = "int",
    fields = { lent.field.int "n" },
    edges = { lent.edge.from "order" "Order":ref "lines":unique() },
    indexes = { lent.index("n"):edges("order"):unique() },   -- index by_n_order
}
```

Each index edge must be an `edge.to` or `edge.from` with `:unique()`, so it
links a row to at most one row. The default name joins the field names and
then the edge names. `create`, `link` and `unlink` move the row's index
entries as they change its links, and a unique index raises the same error
as for a duplicate field value when a link gives two rows the same values.
A unique index leaves out a row whose edge links no row, as it does for a
missing field value. A plain index keeps that row, and the missing link
sorts first.

`by` and `upsert` take a linked row, or its id, for each edge after the
field values; see CLIENT. Queries filter on fields, so a query can use a
plain index with edges through its fields, and cannot use a unique index
with edges.

## Ids and keys

Every table has a primary key named `id`, so a field cannot use that name.
By default each new row's id is a `barch.uuid()` string, such as
`019a1f3c-7d2e-7a41-9b3c-5e6f7a8b9c0d`. Ids from one server sort in creation
order, and creates in one table never conflict over the id. Set
`id = "int"` for ids 1, 2, 3 and so on from a counter per table, which makes
concurrent creates in that table conflict and retry. A table keeps its id
kind once it has a catalog; see MIGRATE.

To keep a dataset's own keys, give `id` to `create`. The value must fit the
table's id kind, and `create` raises `already has a row <id>` when that id is
taken. In an `id = "int"` table, a given id above the counter moves the
counter up, so later rows without an id continue above it. A row keeps its
id: `update` and query `update` raise `keeps each row's id; only create
takes an id` when `values` holds `id`.

A table's keys use its name in snake case, so `BlogPost` stores as
`blog_post`. `lent.edge.to "posts" "Post"` on `User` stores as `user_posts`,
and an `lent.edge.from` reads that edge backwards.

## Time fields

A `time` field holds Unix milliseconds as an integer. `lent.now()` answers
the current time that way, from `barch.time()`. In a call replayed from a
Raft log, it answers the time the entry was logged, so every member stores
the same value.

Use the date helpers to read and write times as calendar dates. They work
in UTC on the Gregorian calendar, for years 1 to 9999:

| helper | answers |
|---|---|
| `lent.date(text)` | the time of ISO 8601 text: a date such as `"1995-03-15"`, or a date and time such as `"1995-03-15T10:20:30.250Z"`; a space may replace `T`, seconds and milliseconds are optional, and the zone is `Z`, `+hh:mm` or `-hh:mm`, or UTC when left out |
| `lent.date(year, month, day, hour, minute, second, ms)` | the time of those parts; the parts after `day` default to 0 |
| `lent.dateParts(t)` | a table of `year`, `month`, `day`, `hour`, `minute`, `second`, `millisecond` and `weekday`, from 1 for Monday to 7 for Sunday |
| `lent.year(t)`, `lent.month(t)`, `lent.day(t)` | one part of `t` |
| `lent.addMonths(t, n)` | `t` moved by `n` calendar months at the same time of day; a day past the end of the new month becomes its last day, so January 31 plus one month is February 28 or 29 |
| `lent.formatDate(t)`, `lent.formatTime(t)` | `"1995-03-15"`, and `"1995-03-15T10:20:30.250Z"` |

Every helper except `lent.date` answers `nil` for a `nil` time, so a
computed field can read an optional `time` field. Invalid text, an
impossible date such as `1995-02-29`, and a time that is not a whole number
of milliseconds raise an error that names the helper, such as
`date wants a date such as 1995-03-15 or 1995-03-15T10:20:30Z, got "1995-02-29"`.
A day is 86400000 milliseconds, so add days with arithmetic:

```lua
local Order = lent.schema "Order" {
    fields = {
        lent.field.time "placed",
        lent.field.int "year":computed(function(o) return lent.year(o.placed) end):stored(),
    },
    indexes = { lent.index("year") },
}
local due = lent.date("1995-03-15") + 90 * 86400000
```

## Decimal fields

Use a `decimal` field for amounts such as money, which keep a fixed number
of digits after the point. `:scale(n)` is required and sets that number,
from 0 to 15:

```lua
lent.field.decimal "price":scale(2):min(0)
```

Decimal values are Luau numbers. Each write rounds the value to the scale,
half away from zero, as the number's shortest text reads, so `2.675` stores
as `2.68` and `0.1 + 0.2` as `0.3`. Defaults and computed fields round the
same way. A value holds at most 15 digits, so a scale of 2 allows up to
`9999999999999.99`. A larger value, a string, NaN or an infinity raises
`wants a decimal of at most 15 digits with 2 after the point, got <value>`.

A `sum` of a decimal field adds whole units of the scale, so ten values of
`0.1` total exactly `1`. A `sum` with a `value` function adds plain numbers.
Filters and indexes compare the value you give, so compare with a value at
the field's scale: `where("price", "=", 0.1 + 0.2)` matches no row, because
`0.1 + 0.2` is `0.30000000000000004`.

Rows store a decimal as a float. `migrate` turns a `decimal` field into a
`float` field without rewriting rows, and refuses a change of scale.

## Enum, bytes and JSON fields

Enums hold one of the strings listed in `:values`. The choices must be
distinct, non-empty UTF-8 strings. Enum fields support indexes, unique
constraints, comparisons and cursor pages. Their order is the byte order
of their labels, so changing the declaration order leaves query ordering
the same.

Bytes fields hold Luau strings containing arbitrary bytes, including NUL
and invalid UTF-8. They support indexes, unique constraints, comparisons,
cursor pages and byte-length rules. JSON fields hold structured values:

```lua
local Document = lent.schema "Document" {
    fields = {
        lent.field.enum "state":values("draft", "published"):default("draft"),
        lent.field.bytes "content":optional():maxLen(1048576),
        lent.field.json "metadata":default({ tags = lent.jsonArray(), properties = {} }),
    },
    indexes = { lent.index("state") },
}
```

For JSON, use plain tables with string keys for objects and dense lists
numbered from 1 for arrays. `{}` is an empty object; use `lent.jsonArray()`
for an empty array, or `lent.jsonArray(list)` to mark a list as an array.
Strings, finite numbers and booleans are also valid JSON values. Use
`simdjson.null` for JSON null. Leave a field `nil` to use its create default,
or mark it `:optional()` to allow a missing value.

Use `lent.parseJson(text)` to parse JSON input and
`lent.encodeJson(row.metadata)` to emit a JSON field value. These helpers
preserve empty arrays and objects. JSON strings and object keys must be
UTF-8, object keys must be unique, and nesting is limited to 128 object or
array levels. Cycles, sparse or mixed-key arrays, functions, NaN and infinity
raise an error. `lent.parseJson` preserves signed 64-bit integer tokens
exactly; values outside the exact Luau-number range (`±2^53`) use barch's
native `integer` type. Other JSON numbers use Luau numbers.

lent takes a Luau `integer`, which `simdjson.parse` answers for whole
numbers beyond 32 bits, wherever it takes a number: field and link values,
ids, filter values and expression parameters, `limit`, `offset`, schema
bounds and defaults, and the results of default, update and computed
functions. lent turns an integer from -2^53 to 2^53 into a Luau number, so
rows and query results hold numbers. A larger integer raises the field's
usual error, such as `ROWCODEC field n wants int, got 9007199254740993`,
because a number would round it.

`where("metadata", "=", value)` and `~=` compare JSON structurally: object
key order is ignored, array order matters, and an empty array differs from
an empty object. Use `where(fn)` to filter nested properties. JSON fields
reject indexes and unique constraints when the schema loads, and reject
ordering and range comparisons in queries.

Each row receives its own copy of a JSON default. Writes copy JSON inputs
before hooks run, and hooks receive an independent `old` snapshot. An
immutable JSON field compares by value, so an equal replacement is allowed
and an in-place nested change is refused. Updating a JSON field replaces
its whole value.

## Value rules

Value rules check each value that `create` and `update` write:

```lua
lent.schema "Post" {
    fields = {
        lent.field.string "title":notEmpty():maxLen(80),
        lent.field.string "slug":match("^[%l%d-]+$"):unique():immutable(),
        lent.field.int "stars":min(0):max(5):default(0),
        lent.field.string "body":validate(function(v)
            return not string.find(v, "spam") or "no spam"   -- the refusal's reason
        end),
        lent.field.time "created_at":default(lent.now):immutable(),
        lent.field.time "updated_at":default(lent.now):updateDefault(lent.now),
    },
    hooks = {
        create = { function(c, row)
            row.slug = row.slug or (string.gsub(string.lower(row.title), "%W+", "-"))
        end },
    },
}
```

| modifier | fields | effect |
|---|---|---|
| `:min(n)`, `:max(n)` | `int`, `float`, `decimal`, `time` | the value is at least or at most `n` |
| `:minLen(n)`, `:maxLen(n)` | `string`, `enum`, `bytes` | the value's length in bytes is at least or at most `n` |
| `:notEmpty()` | `string`, `enum`, `bytes` | the same as `:minLen(1)` |
| `:match(pattern)` | `string`, `enum` | the value contains a match for the Luau string pattern; anchor it with `^` and `$` to match the whole value |
| `:validate(fn)` | any | `fn(value)` refuses the value by answering `false` or a message, or by raising an error; a field may have several |
| `:immutable()` | any | `update` refuses to change the value |
| `:default(fn)` | any | `create` calls `fn()` when the row leaves the field nil |
| `:updateDefault(fn)` | any but immutable | `update` calls `fn()` when the update leaves the field unchanged |

Enum choices, `:min`, `:max`, `:minLen`, `:maxLen`, `:match` and `:immutable`
are stored in the catalog, so every client of the space enforces them once
`migrate` has run. A new rule applies to later writes; it leaves stored rows
as they are.
`update` checks only the values it changes.

Functions stay in code: `:validate`, `:updateDefault`, a function
`:default`, `:computed`, hooks and policies run only in a client opened with
the graph; see [`lent.open`](client.md#open-a-client-with-the-graph). A function default fills only new rows, so a new
required field also needs a value default, or `:optional()`, for the rows
stored before it.

## Hooks

Declare hooks under `create`, `update` and `delete`, each with a list of
functions as in the example above. Each list is optional and defaults to
empty. Hooks run before the write, inside its transaction, in list order:

| hook | called as | runs |
|---|---|---|
| `create` | `fn(c, row)` | after defaults, before the value rules |
| `update` | `fn(c, id, row, old)` | after `updateDefault`, before the value rules |
| `delete` | `fn(c, id, old)` | when the row exists, before it is removed |

`lent.hook.create(fn)`, `lent.hook.update(fn)` and `lent.hook.delete(fn)` also
declare hooks as list entries, such as `hooks = { lent.hook.create(fn) }`.
You can combine these entries with the named operation lists. For each
operation, the builder entries run in list order, followed by the functions
in its named list. Unknown operation names, invalid lists and non-function
entries in a named list raise a `SCHEMA` error when the schema loads.

A hook may change `row` and may read and write other tables through `c`.
An error it raises refuses the write and takes back what the hook wrote, as
described for [`lent.tx`](client.md#transactions-and-write-errors).

A write from a hook runs the written table's hooks too, so hooks can nest.
They nest at most 16 deep, counting the hooks that policy rules' writes
run; set a different limit with `lent.open(app, { hookDepth = n })`. A hook
run past that limit raises an error such as `LENT table Ping
create hooks nest more than 16 deep; each write from a hook runs hooks
again, here through table Ping create, table Pong create`, which names each
table and operation on the way. This stops a hook that creates a row of its
own table, or two tables whose hooks create each other, without an end
condition. The error passes up through each hook like any hook error, so
unless a hook catches it, the first write is refused and every row the
chain wrote is taken back.

## Privacy policies

Declare a `policy` to decide which rows a viewer reads and which writes a
viewer makes, as in Go ent's privacy layer. `query` rules run when a query
starts, and `mutation` rules run before each write's hooks:

```lua
lent.schema "Post" {
    fields = { lent.field.string "title", lent.field.bool "public":default(false),
               lent.field.int "owner" },
    policy = {
        query = {
            function(c, viewer, q)
                if viewer and viewer.admin then return lent.allow end
            end,
            function(c, viewer, q)
                -- everyone reads public posts; members also read their own
                local id = viewer and viewer.id
                q:where(function(r) return r.public or r.owner == id end)
            end,
        },
        mutation = {
            function(c, viewer, m)
                if viewer == nil then return lent.deny("sign in") end
                -- c reads every post, so the rule sees the stored owner
                if m.op ~= "create" and c.Post:get(m.id).owner ~= viewer.id then
                    return lent.deny("not the owner")
                end
            end,
        },
    },
}
```

Each part is an optional list of functions, called in list order as
`fn(c, viewer, q)` or `fn(c, viewer, m)`. A rule answers `lent.allow` to let
the call through, `lent.deny` or `lent.deny("reason")` to refuse it, or `nil`
to leave the decision to the next rule. When every rule answers `nil`, the
call goes ahead; end a list with a rule that answers `lent.deny` to refuse
whatever the rules before it leave undecided. A refusal raises
`LENT table Post policy denies <call>`, followed by `: reason` when the rule
gave one, such as `LENT table Post policy denies update of row 3: not the
owner`. Any other answer raises an error that names the rule.

`viewer` is the value given to `db.tx` or `db.client`; see `lent.open` under
CLIENT. `c` is a client of the same transaction that runs no policy, so a
rule can read rows the viewer cannot read. Hooks get the viewer's client, so
their reads and writes go through the policies.

A query rule receives the new query `q` and narrows it with `where` or
`has`. The rules run for every query on the table, including those that
`get`, `by`, `follow`, `with` and each hop of a multi-edge `follow` make, so
those calls answer only the rows the viewer can read. Query `update` and
`delete` write only those rows. `has` filters and `links` queries read links
without the far table's query rules, as Go ent's edge predicates do, which
lets a rule filter with `has`. `edge` answers `nil` when the viewer cannot
read either row. An `edge.through` reaches its target without the rules of
the tables between.

A mutation rule receives `m`, whose fields depend on `m.op`:

| `m.op` | fields of `m` | runs for |
|---|---|---|
| `create` | `row`, after defaults | `create`, `createMany` and an `upsert` that creates |
| `update` | `id`, `row` after `updateDefault`, `old` | `update`, query `update` and an `upsert` that updates |
| `delete` | `id`, `old` | `delete` and query `delete` when the row exists |
| `link` | `edge`, `id`, `other`, `values` | `link`, and each link that `create` makes after its `create` rules |
| `unlink` | `edge`, `id`, `other` | `unlink` |

The table whose method makes the call runs its rules: `c.User:link("posts",
u, p)` runs User's rules and leaves Post's alone. Deleting a row removes its
links without `unlink` rules.

## Computed fields

Use `:computed(fn)` for a value derived from the row each time it is read,
such as the time between two `time` fields:

```lua
lent.schema "Shift" {
    fields = {
        lent.field.time "clockIn",
        lent.field.time "clockOut":optional(),
        lent.field.int "worked":computed(function(r)
            return r.clockOut and r.clockOut - r.clockIn   -- nil while open
        end),
    },
}
-- total hours per user
c.Shift:query():groupBy("user"):aggregate { worked = { fn = "sum", field = "worked" } }
```

The client calls `fn(row)` for every row it answers, from `get`, `by`,
`create`, `update` and queries, and for the `old` row hooks receive. `row`
holds the stored fields, `id` and the computed fields declared before this
one. A `nil` answer means the field has no value; any other answer must fit
the field's kind, or the read raises an error.

Use a computed field by name in `where`, `order`, `cursor`, `groupBy` and
aggregates. A computed field without `:stored()` keeps no value in the row,
which has these consequences:

- A query checks a filter on a computed field against each row it reads,
  so the filter never picks an index. An index on a computed field raises
  a `SCHEMA` error.
- `create`, `update` and query `update` raise an error for a value or a
  `clear` of a computed field.
- A computed field takes no option except an enum's `:values` and
  `:stored()`.
- `migrate` ignores computed fields, so adding, changing or removing one
  needs no migration and applies to every row at once.
- Like hooks, computed fields exist only in a client opened with the graph.
  A plain client raises `has no field` when a query names one.

Add `:stored()` to keep the value in the row, so an index can use it:

```lua
lent.schema "Shift" {
    fields = {
        lent.field.time "clockIn",
        lent.field.time "clockOut":optional(),
        lent.field.int "worked":computed(function(r)
            return r.clockOut and r.clockOut - r.clockIn
        end):stored(),
    },
    indexes = { lent.index("worked") },
}
```

In a plain table, set `stored = true`, or the revision number.

The client calls the function on `create`, `update`, query `update` and
`upsert`, after the hooks run, and stores the answer. `row` holds the
row's stored fields, without `id`, and the new values of the stored
computed fields declared before this one. A `nil` answer stores no value;
any other answer must fit the field's kind, or the write raises an error.

- Reads answer the stored value without calling the function, so a client
  opened without the graph reads it too. Writing rows of the table from
  such a client raises an error, because it cannot compute the value.
- A stored computed field may be `:unique()`, named in an index and renamed
  with `:was()`. It takes no other option except an enum's `:values`.
- `migrate` computes the field for the rows stored before it: when you add
  a stored computed field, or turn a stored field into one. It fills the
  rows in pages before it builds the field's indexes; see MIGRATE.
- Changing the function leaves stored values as they are. Raise the
  revision with the change, as in `:stored(2)`, and `migrate` computes
  every row again and rebuilds the indexes on the field. Until then, a
  client opened with the new graph raises
  `is declared with stored revision 2, and this space's catalog has stored revision 1; run MIGRATE`.

## Field ids

`lent.ids(table, previous)` gives each field a ROWCODEC id. Pass `nil` for a
new table, or the first answer of the previous version's call. A field keeps
its id under its name or its `:was` name, and new fields are numbered after
the highest id ever used, so a dropped field's id is never reused.
`lent.SCHEMA` runs the module's self-check and answers `ok`.
