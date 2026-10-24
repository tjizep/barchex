# ent design

ent is a planned ORM for barch, written in Luau and modelled on Go's
[ent](https://entgo.io). Applications declare their schema in Luau code and
read and write typed rows, indexes and edges inside barch transactions. Query
builders do the work that SQL does elsewhere.

This page records the plan and the decisions made so far. The key and row
codecs, the schema language, the key layout, migrations, row reads and
writes, queries and edges are built. The open questions below are what
remains.

| part | module | status |
|---|---|---|
| key codec | `ent.KEYCODEC` | built, see [README](../README.md#what-it-contains) |
| row codecs | `ent.ROWCODEC` | built, see [README](../README.md#what-it-contains) |
| schema language and field ids | `ent.SCHEMA` | built, see [README](../README.md#what-it-contains) |
| storage layout | `ent.LAYOUT` | built, see [README](../README.md#what-it-contains) |
| graph catalog and migrations | `ent.MIGRATE` | built, see [README](../README.md#what-it-contains) |
| create, get, update and delete with index upkeep | `ent.CLIENT` | built, see [README](../README.md#what-it-contains) |
| queries and edges | `ent.CLIENT` | built, see [README](../README.md#what-it-contains) |
| edge joins: `has`, `has<Edge>With` and `with` eager loading | `ent.CLIENT` | built, see [README](../README.md#what-it-contains) |

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
  refused, and earlier barch builds gave a key with a `\1` byte back cut short
  from `RANGE` and `KEYS`. The key codec avoids all four.
- **`barch.store.range` answers keys only**, at most 10,000 per call. Reading
  a row found through an index costs one more `get`.

- **A pessimistic transaction locks what it walks.** `RANGE`, `COUNT` and
  `barch.store.range` take a shared lock on `[lo, hi)`, so a key written
  into that range by anyone else waits for the transaction to end.
- **`GRAPH` and `barch.graph` run inside a transaction.** In a pessimistic
  transaction every `GRAPH` call locks the whole graph, shared for a read and
  exclusive for a write, so ent reads the catalog once per transaction. A
  graph read conflicts like a key read, which `tests/test_client.py` checks.
- **`get(key, true)` takes the exclusive lock at once.** A pessimistic `get`
  locks a key shared, so two inserts of one unique value would both hold the
  shared lock and deadlock when they write. `ent.CLIENT` reads every key it
  is about to write with `get(key, true)`, which orders them.

## Schema

An application declares its schema in Luau code kept in git, the same way Go
ent uses Go code:

```lua
local ent = require("ent.SCHEMA")

local User = ent.schema "User" {
    format = "binary",
    fields = {
        ent.field.string "email":unique(),
        ent.field.string "name",
        ent.field.int "age":optional(),
    },
    edges = { ent.edge.to "posts" "Post" },
    indexes = { ent.index("name", "age") },
}
local Post = ent.schema "Post" {
    fields = { ent.field.string "title" },
    edges = { ent.edge.from "author" "User":ref "posts":unique() },
}
return ent.graph { User, Post }
```

The builders live under `ent.field` and `ent.edge`, as in Go ent's `field`
and `edge` packages. A module's global named `string` would hide the string
library from the code that requires it.

Every field gets a row codec id. `ent.ids` keeps the ids an earlier version
gave out, follows `:was("old_name")` across a rename, and numbers new fields
after the highest id ever used, so a dropped field's old values are skipped
rather than read as a new field. The catalog will store each table's ids and
next id.

`MIGRATE` writes the declared schema into the graph as the catalog, so the
schema can be browsed and linked:

```
/ent/version                              bumped by every migration
/ent/compiled                             the whole schema as JSON
/ent/tables/user/table                    leaf: name, format, next field id
/ent/tables/user/fields/email             leaf: kind, id, optional, unique, default
/ent/tables/user/indexes/by_email/spec    leaf: unique
/ent/tables/user/indexes/by_email/on/1    link to the email field's node
/ent/edges/user_posts/from                link to the user table's node
/ent/edges/user_posts/to                  link to the post table's node
```

At run time ent reads `/ent/compiled` inside the transaction with one
`GRAPH GET` and caches it for the call. The rest of the tree is for browsing
and linking. A migration that commits during a transaction changes
`/ent/compiled`, so that transaction conflicts and runs again.

`MIGRATE` splits a migration into `plan`, which compares the stored schema
with the declared one and refuses unsafe changes, and `apply`, which drops
and builds index entries and rewrites the catalog. Both run in one
transaction today, so an index build reads the whole table at once. Large
tables will need builds in pages, with the index marked `building` until the
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
ent.n<table>                       the last pk given out, for id = "int"
```

Every part ends itself, so a range over an encoded prefix holds exactly the
keys that start with those values. A write reads the old row, works out which
index keys changed, and updates the row and those keys in one transaction.

A table's primary keys are `barch.uuid()` strings by default, encoded with
the `uuid` kind as 33 bytes. barch.uuid() answers UUIDv7 ids that one server
hands out in increasing order, so rows sort in creation order and creates in
one table share no key. Ids from different servers are ordered only to the
millisecond. A table declared with `id = "int"` takes integer keys from the
`ent.n` counter, so concurrent creates in it conflict and retry. The catalog
records each table's id kind, and `migrate` refuses to change it, since the
stored keys and edges hold ids of that kind.

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
`float` field when it fits that kind. A `json` row names fields, so renaming
a field in a `json` table would need its rows rewritten, so `MIGRATE`
refuses it for now.

## Queries

```lua
ent.tx(function(c)
    local u = c.User:create { email = "a@b", name = "A" }
    c.Post:create { title = "hi", author = u }
    return c.User:query():where("email", "=", "a@b")
        :queryPosts():order("title", "desc"):limit(10):all()
end)
```

Luau metatables build the clients at run time, so ent needs no code
generation step; `queryPosts` is looked up when it is called. A query uses
the index with the longest prefix matched by its equality filters plus one
range filter. Without a matching index it scans the table and filters each
row. `:using(index)` names the index to use, and `:explain()` answers the
plan. Index bounds may let in extra keys, so every filter is checked again
on the row.

Following an edge collects the linked ids, then reads those rows in id
order. A later version could intersect them with an index on the target.

Joins go through edges, as in Go ent, and each is an index nested loop over
edge keys. `has<Edge>With(fn)` picks one of two ways to run. When the
filter reads part of the target table through an index, it runs first and
the reverse edges of its matches give the candidate rows. Otherwise each
candidate row's edges are walked and the linked rows tested, each one once.
`with<Edge>(fn)` runs one query per answered row over that row's links, so
`fn`'s order and limit apply per row. Joins on plain fields are left out:
a relationship worth joining on is declared as an edge.

## Open questions

- **Unique edges in pessimistic transactions.** `link` checks a unique edge
  with a range read, which takes a shared lock. Two links to one row at once
  can both hold it and deadlock; `barch.tx.run` retries on `TXDEADLOCK`. An
  exclusive range read would order them instead.
- **Counts and offsets inside a transaction.** `order(..., "desc")` reads
  pages from the end with `barch.store.count` and the offset of
  `barch.store.range`. Outside a transaction barch answers both from node
  counts. Inside one, every shard reads through the transaction's overlay,
  so both walk every key in the range: over 20,000 rows a `desc` query with
  a limit of 5 takes about 10 ms, against 2 ms for `asc`. It still reads
  only the rows it answers. Counting the overlay's keys on top of the node
  counts would make both cheap again. To do: try barch's ordered sharded key
  space configuration, which may keep counts and offsets cheap inside a
  transaction.
- **Range with values.** A range that answers keys and values would remove
  the `get` per row.
