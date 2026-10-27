# lent design

lent (Luau entities) is a planned ORM for barch, written in Luau and modelled on Go's
[ent](https://entgo.io). Applications declare their schema in Luau code and
read and write typed rows, indexes and edges inside barch transactions. Query
builders do the work that SQL does elsewhere.

This page records the plan and the decisions made so far. The key and row
codecs, the schema language, the key layout, migrations, row reads and
writes, queries and edges are built. The open questions below are what
remains.

| part | module | status |
|---|---|---|
| key codec | `lent.KEYCODEC` | built, see [README](../README.md#what-it-contains) |
| row codecs | `lent.ROWCODEC` | built, see [README](../README.md#what-it-contains) |
| schema language and field ids | `lent.SCHEMA` | built, see [README](../README.md#what-it-contains) |
| storage layout | `lent.LAYOUT` | built, see [README](../README.md#what-it-contains) |
| graph catalog and migrations with paged index builds | `lent.MIGRATE` | built, see [README](../README.md#what-it-contains) |
| create, get, update and delete with index upkeep | `lent.CLIENT` | built, see [README](../README.md#what-it-contains) |
| bulk create and unique-index upsert | `lent.CLIENT` | built, see [README](../README.md#what-it-contains) |
| queries and edges | `lent.CLIENT` | built, see [README](../README.md#what-it-contains) |
| query-wide update and delete | `lent.CLIENT` | built, see [README](../README.md#what-it-contains) |
| edge joins: `has`, `has<Edge>With` and `with` eager loading | `lent.CLIENT` | built, see [README](../README.md#what-it-contains) |
| cursor pagination: `cursor` and `after` | `lent.CLIENT` | built, see [README](../README.md#what-it-contains) |
| value rules, `time` fields and hooks | `lent.SCHEMA`, `lent.CLIENT` | built, see [README](../README.md#what-it-contains) |
| computed fields, computed on read or stored and filled by `migrate` | `lent.SCHEMA`, `lent.MIGRATE`, `lent.CLIENT` | built, see [README](../README.md#what-it-contains) |
| enum, JSON and bytes fields | `lent.SCHEMA`, `lent.ROWCODEC`, `lent.VALUES` | built, see [README](../README.md#what-it-contains) |
| aggregates: `sum`, `min`, `max`, `aggregate` over fields or `value` functions, and `groupBy` | `lent.CLIENT` | built, see [README](../README.md#what-it-contains) |
| edge fields: values stored on a link | `lent.SCHEMA`, `lent.MIGRATE`, `lent.CLIENT` | built, see [README](../README.md#what-it-contains) |
| path edges: `edge.through`, stored or not, and multi-hop `follow` | `lent.SCHEMA`, `lent.MIGRATE`, `lent.CLIENT` | built, see [README](../README.md#what-it-contains) |

## What barch provides

lent depends on these barch behaviors. Each one shapes a decision below.

- **An optimistic transaction is serializable.** `COMMITTX` checks every key
  the transaction read and every range it walked, so unique checks and range
  queries are safe in one. A read that finds a key missing counts too, so of
  two inserts that both find a unique key free, the second to commit gets
  `TXCONFLICT`; `tests/test_lent_tx.py` checks this for `GET`, `EXISTS` and an
  empty range. lent runs its work through `barch.tx.run`, which retries on
  `TXCONFLICT`, `TXDEADLOCK` and `TXLOCKTIMEOUT`.
- **A transaction covers one space.** A lent client is bound to the space it
  runs in, and every table it uses lives there. The lent modules live in the
  `lent` space and run against the caller's space when required from it.
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
  exclusive for a write, so lent reads the catalog once per transaction. A
  graph read conflicts like a key read, which `tests/test_client.py` checks.
- **`get(key, true)` takes the exclusive lock at once.** A pessimistic `get`
  locks a key shared, so two inserts of one unique value would both hold the
  shared lock and deadlock when they write. `lent.CLIENT` reads every key it
  is about to write with `get(key, true)`, which orders them.

## Schema

An application declares its schema in Luau code kept in git, the same way Go
lent uses Go code:

```lua
local lent = require("lent.SCHEMA")

local User = lent.schema "User" {
    format = "binary",
    fields = {
        lent.field.string "email":unique(),
        lent.field.string "name",
        lent.field.int "age":optional(),
    },
    edges = { lent.edge.to "posts" "Post" },
    indexes = { lent.index("name", "age") },
}
local Post = lent.schema "Post" {
    fields = { lent.field.string "title" },
    edges = { lent.edge.from "author" "User":ref "posts":unique() },
}
return lent.graph { User, Post }
```

The builders live under `lent.field` and `lent.edge`, as in Go ent's `field`
and `edge` packages. Each field, index and edge can also be a plain table of
the same options, such as `{ dir = "from", name = "author", target = "User",
ref = "posts" }`, which spells out what the chained calls set and can be
built as data. A module's global named `string` would hide the string
library from the code that requires it.

Every field gets a row codec id. `lent.ids` keeps the ids an earlier version
gave out, follows `:was("old_name")` across a rename, and numbers new fields
after the highest id ever used, so a dropped field's old values are skipped
rather than read as a new field. The catalog will store each table's ids and
next id.

`MIGRATE` writes the declared schema into the graph as the catalog, so the
schema can be browsed and linked:

```
/lent/version                              bumped by each schema change
/lent/compiled                             the whole schema as JSON
/lent/tables/user/table                    leaf: name, format, next field id
/lent/tables/user/fields/email             leaf: kind, id, optional, unique, default
/lent/tables/user/indexes/by_email/spec    leaf: unique, state while building
/lent/tables/user/indexes/by_email/on/1    link to the email field's node
/lent/edges/user_posts/from                link to the user table's node
/lent/edges/user_posts/to                  link to the post table's node
```

At run time lent reads `/lent/compiled` inside the transaction with one
`GRAPH GET` and caches it for the call. The rest of the tree is for browsing
and linking. A writer whose cached `/lent/compiled` changes before commit
conflicts and runs again, including a build page whose schema version stays
the same.

`migrate(app, pageSize)` advances a migration by a bounded amount in each
stored-function call. Its default budget is 1,000 row visits or removed
index entries across all indexes. The catalog keeps the target schema and
committed progress, and `done = false` asks the caller to resume with the
same schema. Completed pages survive a later page's error or timeout.

The target schema becomes active with the first page. Queries use ready
indexes while unfinished indexes carry `state = "building"`. Writes keep
building indexes current; a building unique index checks the table for
duplicates, including rows beyond its cursor. Old entries are removed
before a replacement builds, and row writes to an affected table are
refused until its pending drops finish. The last build page commits its
entries and readiness together. See the [migration reference](../README.md#what-it-contains)
for limits and recovery.

`plan` compares the stored schema with the declaration. `apply` retains the
whole-plan operation for a caller that already owns a transaction; it
refuses a pending paged migration. Applications use `migrate` to manage the
page transactions.

## Rules and hooks

A schema's rules come in two parts. Rules that are values, `min`, `max`,
`minLen`, `maxLen`, `match` and `immutable`, are stored in the catalog with
the field, so every client of the space checks them, including one in
another function that never loaded the schema code. Functions cannot be
stored, so `validate`, `updateDefault`, a function `default` and hooks run
only in a client made with `lent.open(app)`. Go ent compiles both into
generated code; here the catalog keeps what it can.

Hooks run before the write in the caller's transaction, which makes a hook
that writes another table atomic with the write. Each write call runs in a
`barch.tx.savepoint`, so a refused call takes back its hooks' writes along
with its own, and a caller that catches the error goes on with the
transaction as it was before the call. Calls nest: a hook that catches a
refused write it made keeps its other writes. A multi-row write is one
call, so a refusal takes back all of its rows.

A `time` field is an `int` of Unix milliseconds, and `lent.now()` answers
`barch.time()`. A call replayed from a Raft log reads the time its entry was
logged, so a default of `lent.now` stores the same value on every member.

Enum and bytes fields share string key encoding, so their indexes and
cursor pages follow byte order. Enums carry their allowed strings in the
catalog. A migration can add choices or relax an enum to a string; removing
choices is refused to keep existing rows readable.

JSON fields preserve structured values, including the distinction between
null and a missing field, and between empty arrays and objects. Applications
use `lent.jsonArray`, `lent.parseJson` and `lent.encodeJson` for those
distinctions. JSON equality is structural; JSON filters run on decoded
values and the fields support predicate filters. JSON indexes and ordering
are refused. Defaults, write inputs and old hook snapshots are copied so
nested edits keep each row's values independent.

Binary rows store bytes as raw data and JSON values as length-prefixed
JSON text. Text and JSON rows store bytes as hex. The catalog encodes byte
and JSON defaults explicitly and restores them in `load`, preserving binary
bytes and empty JSON arrays across migration pages and reloads.

## Storage layout

Rows, index entries and edges are `barch.store` keys in the application's
space. `<table>`, `<index>` and `<edge>` are encoded strings, and the other
parts are encoded with the column's kind:

```
lent.r<table><pk>                   row
lent.i<table><index><values><pk>    "" (non-unique index entry)
lent.u<table><index><values>        pk (unique index entry)
lent.e<edge><from><to>              "" (edge, forward)
lent.E<edge><to><from>              "" (edge, reverse)
lent.n<table>                       the last pk given out, for id = "int"
```

Every part ends itself, so a range over an encoded prefix holds exactly the
keys that start with those values. A write reads the old row, works out which
index keys changed, and updates the row and those keys in one transaction.

A table's primary keys are `barch.uuid()` strings by default, encoded with
the `uuid` kind as 33 bytes. barch.uuid() answers UUIDv7 ids that one server
hands out in increasing order, so rows sort in creation order and creates in
one table share no key. Ids from different servers are ordered only to the
millisecond. A table declared with `id = "int"` takes integer keys from the
`lent.n` counter, so concurrent creates in it conflict and retry. The catalog
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
lent.tx(function(c)
    local u = c.User:create { email = "a@b", name = "A" }
    c.Post:create { title = "hi", author = u }
    return c.User:query():where("email", "=", "a@b")
        :queryPosts():order("title", "desc"):limit(10):all()
end)
```

Luau metatables build the clients at run time, so lent needs no code
generation step; `queryPosts` is looked up when it is called. A query uses
the index with the longest prefix matched by its equality filters plus one
range filter. Without a matching index it scans the table and filters each
row. `:using(index)` names the index to use, and `:explain()` answers the
plan. Index bounds may let in extra keys, so every filter is checked again
on the row. A table scan reads each row's value with its key, and a unique
index scan reads each pk the same way, with `barch.store.rangeValues`. A
scan that stops at a limit starts with a page of that many keys, at least
16, and doubles each page up to 1000, so it reads few values past the
limit. Other index scans read keys only, since their keys hold the pk.

Following an edge collects the linked ids, then reads those rows in id
order. When the query's filters narrow an index on the target, or its order
matches one and it has a limit, it reads that index's keys and only the
linked rows among them. It gives up on the index after as many keys as there
are linked ids, so the index read costs at most as many keys as the follow
has links.

A link's values live in the value of its forward edge key. A links query
scans the edge keys of each matching row and reads that value for each
link, and `whereEdge` after a follow walks the last hop again from the rows
before it, keeping the far ends of the links that match.

A path edge (`edge.through`) names a chain of edges. Following it collects
the distinct ids at each hop before the next, so its cost grows with the
distinct rows along the path. A stored path edge keeps one link per pair of
rows a path joins, holding the number of paths, in a store named as an
`edge.to` of the same name would be. A link change at hop i changes the
paths by the paths into the link through hops before i, counted after the
change, times the paths out of it through hops after i, counted before the
change; summed over each hop on that store, this stays exact when a path
crosses the same store twice. Its `migrate` fill counts each source row's
paths, and reads walk the hops until the fill finishes. A driving `has` on a path
edge walks the hops backwards from its matches. Paths are declared: a
search over the schema for a path between two tables could pick a different
path after a new edge is added, and change what an existing query means.

Cursor pages replace `offset` for paging. A cursor holds the order's field
and direction, the last row's value and its id, so a page whose index read
comes in that order starts at the key the cursor names, while `offset`
reads and skips the rows before the page. A `desc` page counts the keys
below the cursor and reads them from the end; barch answers that count from
node counts, inside a transaction too.

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
