# ent design

ent is a planned ORM for barch, written in Luau and modelled on Go's
[ent](https://entgo.io). Applications declare their schema in Luau code and
read and write typed rows, indexes and edges inside barch transactions. Query
builders do the work that SQL does elsewhere.

This page records the plan and the decisions made so far. The key and row
codecs are built; the remaining parts are planned.

| part | module | status |
|---|---|---|
| key codec | `ent.KEYCODEC` | built, see [README](../README.md#what-it-contains) |
| row codecs | `ent.ROWCODEC` | built, see [README](../README.md#what-it-contains) |
| schema code, graph catalog, `MIGRATE` | | planned |
| create, get, update and delete with index upkeep | | planned |
| queries and edges | | planned |

## What barch provides

ent depends on these barch behaviors. Each one shapes a decision below.

- **An optimistic transaction is serializable.** `COMMITTX` checks every key
  the transaction read and every range it walked, so unique checks and range
  queries are safe in one. A read that finds a key missing counts too, so of
  two inserts that both find a unique key free, the second to commit gets
  `TXCONFLICT`; `tests/test_ent_tx.py` checks this for `GET`, `EXISTS` and an
  empty range. ent runs its work through `barch.tx.run`, which retries on
  `TXCONFLICT`, `TXDEADLOCK` and `TXLOCKTIMEOUT`.
- **A transaction covers one space.** An ent client is bound to the space it
  runs in, and every table it uses lives there. The ent modules live in the
  `ent` space and run against the caller's space when required from it.
- **Keys are text that barch may reinterpret.** A space in a key makes it a
  tuple, a key that parses as a number is stored as that number, a NUL is
  refused, and a `\1` byte comes back cut short from `RANGE` and `KEYS`.
  The key codec avoids all four.
- **`barch.store.range` answers keys only**, at most 10,000 per call. Reading
  a row found through an index costs one more `get`.

These barch changes are in progress:

- `barch.graph` reads and writes inside a transaction. Until then, a
  transaction cannot read the catalog.
- `RANGE` and `COUNT` inside a pessimistic transaction. Whether a pessimistic
  range locks the range decides how a pessimistic unique check works; see
  [Open questions](#open-questions).

## Schema

An application declares its schema in Luau code kept in git, the same way Go
ent uses Go code:

```lua
local ent = require("ent.SCHEMA")

return ent.schema "User" {
    format = "binary",
    fields = {
        ent.string "email":unique(),
        ent.string "name",
        ent.int "age":optional(),
    },
    edges = { ent.to "posts" "Post" },
    indexes = { ent.index("name", "age") },
}
```

`MIGRATE` writes the declared schema into the graph as the catalog, so the
schema can be browsed and linked:

```
/ent/version                            bumped by every migration
/ent/tables/user/fields/email           leaf: type, nullable, default
/ent/tables/user/indexes/by_email/on/1  link to the email field's node
/ent/edges/user_posts/from              link to the user table's node
/ent/edges/user_posts/to                link to the post table's node
```

At run time ent reads the catalog inside the transaction and caches it for
the call. Each transaction reads `/ent/version`, so a migration that commits
during a transaction makes that transaction conflict and run again. A
migration changes the catalog and builds new indexes in one transaction.
Indexes on large tables are built in pages and marked `building` until the
last page commits, because one transaction has to finish within the
function deadline.

## Storage layout

Rows, index entries and edges are `barch.store` keys in the application's
space. `<table>`, `<index>` and `<edge>` are encoded strings, and the other
parts are encoded with the column's kind:

```
ent.r<table><pk>                   row
ent.i<table><index><values><pk>    "" (non-unique index entry)
ent.u<table><index><values>        pk (unique index entry)
ent.e<edge><from><to>              "" (edge, forward)
ent.E<edge><to><from>              "" (edge, reverse)
```

Every part ends itself, so a range over an encoded prefix holds exactly the
keys that start with those values. A write reads the old row, works out which
index keys changed, and updates the row and those keys in one transaction.

Primary keys are integers for now. An ordered UUID library will replace them;
a UUID key will use the `string` kind, so the layout stays the same.

Edges start as store keys because they page in key order. Graph-backed edges,
with a row's node linked under each row that points at it, can be tried once
the basics work.

## Row formats

Each table names its row format. Every stored row records the schema
version it was written with, and `ROWCODEC` reads any format, so a table can
change format and convert its rows over time.

| format | stored value | fields named by | use |
|---|---|---|---|
| `json` | a JSON object with the version in `_v` | name | rows other tools read as JSON; strings must be UTF-8 |
| `text` | `t<version>` then tab-separated `<id>=<value>` | field id | rows a person reads with `GET` |
| `binary` | `b`, a u32 version, then (id, tag, value) entries | field id | compact rows that hold any bytes |

Field ids stay with a field for the table's life. A row written by an older
schema reads with the current field list: a field added since reads as nil,
a removed field's value is skipped, and a number reads into an `int` or
`float` field when it fits that kind. A `json` row names fields, so renaming a field in a `json` table
needs `MIGRATE` to rewrite its rows.

## Queries

```lua
ent.tx(function(c)
    local u = c.User:create { email = "a@b", name = "A" }
    c.Post:create { title = "hi", author = u }
    return c.User:query():where("email", "=", "a@b")
        :queryPosts():order("created", "desc"):limit(10):all()
end)
```

Luau metatables build the typed clients at run time, so ent needs no code
generation step. A query uses the index with the longest prefix matched by
its equality filters plus one range filter. Without a matching index it scans
the table and filters each row. `:using(index)` names the index to use.

## Open questions

- **Pessimistic unique checks.** If a pessimistic range locks the range, a
  unique check is a range read. Otherwise ent writes the `ent.u` key before
  checking it, so the key lock orders two inserts of the same value.
- **Descending order.** `barch.store.range` walks forward only, so
  `order(..., "desc")` with a limit reads the whole range. A reverse range, or
  a descending key encoding, would fix this.
- **Range with values.** A range that answers keys and values would remove
  the `get` per row.
