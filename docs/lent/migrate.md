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
| `done` | `true` when every index drop, fill and build is complete |
| `processed` | row visits plus removed index entries and column blocks in this call, at most the page size |
| `steps` | the migration's list of `drop Table.index`, `fill Table.field,...` and `build Table.index` operations, in that order, with `drop Table.edge` and `fill Table.edge` for stored path edges and `drop Table.field blocks` for a field dropped from a `column` table; empty for an unchanged, completed schema |

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

- a table missing from the schema;
- a new field that is neither `:optional()` nor has a value `:default()`;
- a kind change other than `int` to `float`, `decimal` to `float`, `int`
  to or from `time`, or `enum` to `string`;
- a change to a `decimal` field's scale;
- removing a value from an enum's choices;
- a field rename in a table that has stored `json` rows;
- a unique index whose values two stored rows already share;
- a stored computed field whose function answers a value that does not fit
  the field for a stored row;
- a change to a table's `id` kind;
- a change of a table's format to or from `column`;
- an `edge.to` or `edge.from` that takes the name of a stored path edge in
  the same migration.

Adding enum choices preserves stored rows and their indexes. Byte and JSON
defaults are preserved in the catalog, including binary bytes, JSON null
and empty arrays; `m.load()` returns their Luau values.

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
