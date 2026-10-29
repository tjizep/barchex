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
`1` to `10000`. It bounds the total row visits and removed index entries
across all indexes in that call. Each fill and index build visits every
row, including rows whose missing values leave them out of a unique index.

| report field | meaning |
|---|---|
| `version` | the active schema version; it advances on the first committed page and stays the same while the migration resumes |
| `changed` | `true` when this call installs a schema or advances pending work |
| `done` | `true` when every index drop, fill and build is complete |
| `processed` | row visits plus removed index entries in this call, at most the page size |
| `steps` | the migration's list of `drop Table.index`, `fill Table.field,...` and `build Table.index` operations, in that order, with `drop Table.edge` and `fill Table.edge` for stored path edges; empty for an unchanged, completed schema |

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
table's pending drops finish. Reads continue, and other tables remain
writable.

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
- an `edge.to` or `edge.from` that takes the name of a stored path edge in
  the same migration.

Adding enum choices preserves stored rows and their indexes. Byte and JSON
defaults are preserved in the catalog, including binary bytes, JSON null
and empty arrays; `m.load()` returns their Luau values.

`plan(previous, app)` describes a migration. The low-level `apply(plan)`
runs a whole plan inside a caller-opened transaction and refuses a pending
paged migration; use `migrate` for paged work. `lent.MIGRATE` runs the
planning self-check and answers `ok`.
