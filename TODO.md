# lent TODO

This page lists the work that remains on lent, the ORM described in
[docs/lent-design.md](docs/lent-design.md). The schema language, migrations
with paged index builds, row reads and writes with index upkeep, bulk create
and upsert, query reads and writes, aggregates over fields and values,
`groupBy`, edges, path edges and computed fields (each stored or not), edge
joins, edge fields, cursor pages, value rules, `time`, `enum`, `json` and
`bytes` fields, and hooks are built.

## Limits of what is built

- **Dropping a table.** `migrate` refuses a table missing from the schema.
- **Renaming a field of a `json` table.** Stored `json` rows name their
  fields, so `migrate` refuses the rename until those rows are rewritten.
- **Removing enum choices.** `migrate` accepts added choices and refuses
  removing a choice, so stored enum values stay readable.
- **Unique edges in pessimistic transactions.** Two `link` calls to one row
  at once can deadlock on the shared lock of the unique check.
  `barch.tx.run` retries on `TXDEADLOCK`; an exclusive range read would
  order the two calls.

## Features

- **Privacy rules:** read and write policies per table, as in Go ent. They
  could build on hooks.

## barch

- **Savepoints.** When a write is refused and the caller catches the error,
  the writes its hooks made stay in the transaction. A savepoint would let
  lent roll back to the start of the call.
