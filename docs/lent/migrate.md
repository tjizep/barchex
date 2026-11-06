# lent migrations

MIGRATE applies a schema and builds or removes its indexes in bounded
pages. Call `migrate` from the application's space with the answer of
`lent.graph`, outside an open transaction:

```lua
local m = require("lent.MIGRATE")
local report = m.migrate(app, 1000)
local compiled = m.load()      -- the active schema, or nil before the first migration
```

Call it again with the same schema in later stored-function calls until
`report.done` is `true`. Each call runs in one `barch.tx.run` transaction
and persists its progress under `/lent` in the space's graph. Separate
function calls give each page its own function deadline.

The optional page size defaults to `1000` and accepts whole numbers from
`1` to `10000`. It bounds the total row visits, removed index entries and
removed column blocks across all steps in that call. Each fill and index build visits every
row, including rows whose missing values leave them out of a unique index.

| report field | meaning |
|---|---|
| `version` | the active schema version; it advances on the first committed page and stays the same while the migration resumes |
| `changed` | `true` when this call installs a schema or advances pending work |
| `done` | `true` when every step is complete |
| `processed` | row visits plus removed index entries and column blocks in this call, at most the page size |
| `steps` | the migration's list of `drop Table.index`, `fill Table.field,...` and `build Table.index` operations, in that order, with `drop Table.edge` and `fill Table.edge` for stored path edges, `drop view View` and `fill view View` for [stored views](queries.md#stored-views), `drop Table.field blocks` for a field dropped from a `column` table, `drop Table` and `drop Table.edge` for a dropped table and its edges, and `copy Table blocks` or `copy Table rows` with `drop Table old blocks` or `drop Table old rows` for a change of format or `block`; empty for an unchanged, completed schema |

The target schema becomes active with the first committed page. An index
being built has `state = "building"` in its `m.load().tables` index entry
and its `/lent/tables/<table>/indexes/<index>/spec` JSON. Ready indexes have
no `state` field. The last index entries and the readiness change commit
together.

A fill computes stored computed fields, described in [computed fields](schema.md#computed-fields), for the rows
stored before them and writes each row again. While it runs, the fields
have `state = "filling"`, and a client opened with the graph computes them
on every read, so reads answer the new values before the fill reaches a
row. A client opened without the graph reads the stored values, which are
missing or old until the fill reaches the row.

A stored view's fill reads every row of its table and adds it to its
group. While it runs, the view has `state = "filling"`: writes keep the
groups of the rows the fill has passed current, and reading the view
raises a `LENT` error until the fill completes.

Queries choose ready indexes or read the table while an index builds.
`using`, `by` and `upsert` raise a `LENT` error if they request a building
index. Creates, updates and deletes maintain building indexes. Successful
writes of new or changed indexed values scan the table to check uniqueness
while a unique index is building, so these writes can cost more until the
build finishes.

Index replacements and removals drop old entries first. Creating, updating
or deleting rows in an affected table raises a `LENT` error until that
table's pending index drops finish. Reads continue, and other tables remain
writable. A `column` table stays writable while its dropped fields' blocks
are removed.

An error or timeout rolls back the current page; earlier pages and their
schema changes stay committed. Call `migrate` with the same schema to
resume. Reduce the page size if a page times out. If a unique build finds
duplicate stored values, find the rows with a query, correct or delete the
duplicates, then resume. Finish the pending migration before changing the
schema again.

A migration that fits in one page remains atomic. Once a migration is
complete, calling it with the same schema writes nothing and answers
`changed = false`, `done = true` and the current version.

`migrate` raises an error that starts with `MIGRATE` for unsupported schema
changes or a unique-index conflict:

- a table missing from the schema that `lent.drop` does not name; see
  [dropping a table](#dropping-a-table);
- a new field that is neither `:optional()` nor has a value `:default()`;
- a kind change other than `int` to `float`, `decimal` to `float`, `int`
  to or from `time`, or `enum` to `string`;
- a change to a `decimal` field's scale;
- removing a value from an enum's choices without `:replaces`, or from an
  edge field's choices; see [removing enum choices](#removing-enum-choices);
- a unique index whose values two stored rows already share;
- a stored computed field whose function answers a value that does not fit
  the field for a stored row;
- a change to a table's `id` kind;
- an `edge.to` or `edge.from` that takes the name of a stored path edge in
  the same migration.

Adding enum choices preserves stored rows and their indexes. Byte and JSON
defaults are preserved in the catalog, including binary bytes, JSON null
and empty arrays; `m.load()` returns their Luau values.

## Removing enum choices

To remove a choice from a stored enum field, list the remaining choices in
`:values` and name the choice that each removed one's rows take with
`:replaces`:

```lua
lent.field.enum "state"
    :values("new", "done")
    :replaces { old = "done" }
```

`migrate` rewrites the rows that hold `"old"` to `"done"` with a fill step
and rebuilds the indexes on the field around it. For a `Task` table with a
`by_state` index on `state`, the steps are `drop Task.by_state`,
`fill Task.state` and `build Task.by_state`. The fill visits every row and
writes only the rows it changes. Each row visit and each removed index entry
counts as one toward the page size.

While the fill runs:

- creating, updating or deleting rows raises a `LENT` error until the
  index drops finish, as described above;
- reads answer the removed choice for each row the fill has not reached;
- writing a removed choice raises `LENT table Task field state wants one of
  ["new","done"], got "old"`;
- `m.load()` lists the field's `replaces` map, which leaves the catalog when
  the fill finishes.

If a replacement gives two rows the same values in a unique index, the
index build stops with the unique-index error; correct one of the rows and
resume. Remove the `:replaces` entry once `report.done` is `true`; later
migrations ignore it while the field's choices stay the same.

`migrate` refuses a removed choice that `:replaces` leaves out, with
`MIGRATE table Task field state removes enum value "old"; name the choice
its rows take with :replaces`. It refuses every removed choice of an edge
field, since stored links may hold it. `lent.graph` checks the map itself:
each key must be a choice missing from `:values`, and each value one of the
choices in `:values`.

## Renaming a field

Rename a stored field with `:was`, which names the field's previous name:

```lua
lent.field.string "headline":was("title")
```

The field keeps its row codec id, so `text`, `binary` and `column` rows
need no rewrite. `json` rows name their fields, so a table that has stored
`json` rows, under its current format or an earlier one, gets a
`fill Table.headline` step that rewrites each `json` row with the new name.
The fill writes each row in the table's current format, so a rename made
with a change from `json` to `binary` or `text` converts the rows too. In
every format, `migrate` rebuilds the indexes on a renamed field.

While the fill runs, reads answer every row's value under the new name, and
a write stores the row with the new name. `m.load()` lists the old name in
the field's `renames` entry until the fill finishes. Remove `:was` once
`report.done` is `true`; later migrations ignore it.

A dropped field's values stay in `json` rows until those rows are written
again. A new field that later takes the dropped name reads no value from
the rows written before its migration, and a field renamed to that name
reads those rows under its old name.

## Dropping a table

To drop a stored table and everything it stores, remove its `lent.schema`
declaration and the edges of other tables that name it, add
`lent.drop "Table"` to the graph, and run `migrate`:

```lua
local app = lent.graph {
    User,
    lent.drop "Session",
}
```

The first page removes the table from the catalog, so `m.load()` and new
clients no longer list it. A client opened with a graph that still declares
the table raises `LENT table Session is declared, and this space's catalog
lacks it; run MIGRATE`. Drop steps then remove the table's keys in pages:

| step | removes |
|---|---|
| `drop Table` | the table's rows or column blocks, index entries, id counter and planner statistics |
| `drop Table.edge` | the links of each edge to or from the table, one step per edge |

Each removed key counts as one toward the page size.

Remove the `lent.drop` entry once `report.done` is `true`. While the entry
stays, `migrate` answers `changed = false` for a table that is already gone.
To declare a table of the same name again, finish the drop first:
`lent.graph` raises `SCHEMA table Session is declared and dropped; migrate
with the drop, then declare the table again` for a graph that does both.
The new table starts empty, and an `id = "int"` table numbers its rows from
1 again.

A stored table that is missing from the graph and that `lent.drop` does not
name stops the migration with `MIGRATE table Session is missing from the
schema; declare it, or name it with lent.drop to drop it and its rows`. The
table keeps its rows, so a declaration left out by mistake loses nothing.

## Changing a table's format or block size

Change a stored table's `format` to or from `column`, or the `block` of a
`column` table, and run `migrate` as for any other change. The migration
copies the table's rows with a copy step, which runs after the migration's
other steps, then removes the old rows or blocks with a drop step:

| change | steps |
|---|---|
| a row format to `column` | `copy Table blocks`, `drop Table old rows` |
| `column` to a row format | `copy Table rows`, `drop Table old blocks` |
| a `column` table's `block` | `copy Table blocks`, `drop Table old blocks` |

A change between `json`, `text` and `binary` needs no copy: each row keeps
its format until it is written again. A table that moves to `column` needs
`id = "int"`.

Each copied row counts as one row visit toward the page size, and each
removed row or block as one key. The copy writes rows at about the
`createMany` rate of the new format: on one machine, it copied 102,400 rows
of three fields with a page size of 5,000 in these times:

| from | to | seconds |
|---|---|---|
| `column`, `"htap"` blocks | `column`, `"scan"` blocks | 8 |
| `column`, `"scan"` blocks | `column`, `"htap"` blocks | 3 |
| `binary` | `column`, `"htap"` blocks | 4 |
| `binary` | `column`, `"scan"` blocks | 7 |
| `column`, either block size | `binary` | 2 |

Reads use the old rows or blocks until the page that copies the last row.
That page switches the table to the new format or blocks when it commits,
and `m.load()` then answers the new `format` and `block`. The table stays
writable during the copy. A write to a row that the copy has already
reached also updates the new copy, so it costs about twice as much until
the copy finishes. The table holds both copies of its rows until the drop
step removes the old ones.

## Planner statistics

`analyze` reads a table's rows and ready indexes and stores statistics that
queries use to choose an index; see
[planner statistics](queries.md#planner-statistics). Call it from the
application's space, outside an open transaction, and pass the answered
`state` to the next call until `done` is `true`:

```lua
local m = require("lent.MIGRATE")
local r = m.analyze("Order")             -- table name, state, page size
while not r.done do
    r = m.analyze("Order", r.state)
end
```

Each call reads up to the page size in keys, runs in one `barch.tx.run`
transaction and commits. Pass the state to a later stored-function call to
give each page its own function deadline. The page size defaults to `10000`
and accepts whole numbers from `1` to `1000000`. A `column` table's rows
count one key per block of 1,024 rows. On one machine, `analyze` read
200,000 rows and 4 indexes, 1,000,000 keys, at about 860,000 keys/s, with
pages of 50,000 keys taking at most 91 ms.

| answer field | meaning |
|---|---|
| `done` | `true` when the table's rows and every ready index are read |
| `processed` | keys read in this call, at most the page size |
| `state` | present while `done` is `false`; pass it to the next call |

`analyze` saves each index's statistics when it finishes reading that index,
so an error or timeout keeps the indexes earlier pages finished. It skips an
index that is still building. A state belongs to one table and schema
version; after a migration, start again without a state.

`statistics(name)` answers what `analyze` stored, or `nil` before the
table's first `analyze`. Its keys are `id` for the table's rows and the index
names. An index added or changed since the last `analyze` has no entry.

| field | meaning |
|---|---|
| `keys` | the rows or index keys read |
| `distinct` | for each count of leading index fields, the distinct values seen; empty for `id` |
| `analyzed` | the time `analyze` saved the entry, in Unix milliseconds |

`analyze` raises an error that starts with `MIGRATE`:

- `analyze has no table X; migrate a schema with it first`;
- `analyze page size must be a whole number from 1 to 1000000`;
- `analyze needs its own transaction; call it outside a transaction`;
- `analyze takes a state that an earlier analyze answered, or nil to start`;
- `analyze state comes from another table or schema version; start again
  without a state`.

## Low-level calls

`plan(previous, app)` describes a migration. The low-level `apply(plan)`
runs a whole plan inside a caller-opened transaction and refuses a pending
paged migration; use `migrate` for paged work. `lent.MIGRATE` runs the
planning self-check and answers `ok`.
