# lent TODO

This page lists the work that remains on lent, the ORM described in
[docs/lent-design.md](docs/lent-design.md). The schema language, migrations,
row reads and writes with index upkeep, queries, edges, edge joins, cursor
pages, value rules, `time` fields and hooks are built.

## Next

1. **Bulk create and upsert.** Create many rows in one call, and create or
   update a row by a unique index.
2. **Update and delete on a query.** `query():where(...):update(values)` and
   `query():where(...):delete()` for every matching row.
3. **Paged index builds in `migrate`.** `migrate` builds each index in one
   transaction, so a large table can exceed the function deadline. Build in
   pages and mark the index `building` until the last page commits.

## Limits of what is built

- **Dropping a table.** `migrate` refuses a table missing from the schema.
- **Renaming a field of a `json` table.** Stored `json` rows name their
  fields, so `migrate` refuses the rename until those rows are rewritten.
- **Unique edges in pessimistic transactions.** Two `link` calls to one row
  at once can deadlock on the shared lock of the unique check.
  `barch.tx.run` retries on `TXDEADLOCK`; an exclusive range read would
  order the two calls.
- **Hooks as plain tables.** Fields, indexes and edges take plain tables;
  hooks still need `lent.hook.create(fn)` and the like. A form such as
  `hooks = { create = { fn } }` would match.

## Features

- **More field kinds:** enum, json and bytes.
- **Aggregates:** sum, min, max and group by. `count()` is the only one.
- **Privacy rules:** read and write policies per table, as in Go ent. They
  could build on hooks.
- **Edge fields:** values stored on a link.
- **Faster edge follows:** intersect the linked ids with an index on the
  target table, so a follow reads only the rows its filters keep.

## barch

- **Counts and offsets inside a transaction.** Inside a transaction,
  `barch.store.count` and the offset of `barch.store.range` walk every key in
  the range: about 8 to 10 ms against 1 to 2 ms over 20,000 keys. `desc`
  pages and `offset` pay this. Try barch's ordered sharded key space
  configuration, which may keep both cheap.
- **Range with values.** A range that answers keys and values would remove
  the `get` for each row read through an index.
- **Savepoints.** When a write is refused and the caller catches the error,
  the writes its hooks made stay in the transaction. A savepoint would let
  lent roll back to the start of the call.
