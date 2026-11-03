# lent TODO

This page lists the work that remains on lent, the ORM described in
[docs/lent-design.md](docs/lent-design.md). The schema language, migrations
with paged index builds, row reads and writes with index upkeep, bulk create
and upsert, query reads and writes, aggregates over fields and values,
`groupBy` and paged aggregates with many groups, edges, path edges and
computed fields (each stored or not), edge joins, edge fields, cursor pages,
value rules, `time`, `enum`, `json` and `bytes` fields, column tables, hooks
and privacy policies are built.

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
- **Column tables.** `format = "column"` needs `int` ids, keeps a field's
  values of one block within 524,032 bytes, and shares conflicts and locks
  across each block. `migrate` refuses a format change to or from `column`.
  See `docs/lent/codecs.md`.

## Needed from barch

- **Patch overlays that record only the changed bytes.** Inside a
  transaction, `setBufferAt`, `setF64At` and `setInt32At` copy the whole value
  through the overlay, log a read, and take an exclusive key lock in a
  pessimistic transaction, so their cost scales with the value. Outside a
  transaction, writing a row into 11 blocks reaches 70,000 to 100,000 rows/s;
  inside one it falls to about 2,500 rows/s on 8 KiB blocks and 260 on
  128 KiB. Column writes pay this: `create` runs at a quarter of the
  `binary` rate. With an overlay of changed bytes, lent can restore the text
  append it dropped, which gains only 5% over a rewrite today. Text blocks
  already keep the slots in use for it.
- **Vector folds over number blocks.** A column scan folds each block in a
  Luau loop. On 409,600 rows in a transaction, a sum reads 53 million rows/s,
  a sum under one filter 35 million and a sum grouped by a short `string`
  field 15 million. A hand-written Luau sum over the same blocks, outside a
  transaction, reaches about 90 million. Functions that run in native code
  would lift these limits: one that compares each f64 of a buffer with a
  value and answers the matching slots, and one that sums, counts, or takes
  the min or max of an f64 buffer over given slots, by group ids from
  another buffer. Each block read in a transaction also logs the read,
  which adds about 1.5 ms to the sum's 6.3 ms.

## Planned work

- **Survey of SQL workloads.** Take public example schemas and their
  queries, such as TPC-H and the New York taxi trip data, and check how
  well lent stores the data and answers the queries. List what is missing,
  such as views and `DECIMAL`, and add those features. The first pass, over
  TPC-H, the taxi data and Sakila, is in
  [docs/sql-survey.md](docs/sql-survey.md); its gaps section lists the
  features to add.
- **Count index keys without a conflict.** The planner breaks a tie between
  indexes with `barch.store.count`, which takes a range lock in a pessimistic
  transaction and joins the phantom check in an optimistic one. Counting an
  index the query then skips can block writers or abort the transaction.
  barch needs a count with no lock and no phantom log; lent then calls it in
  `plan_keys`, and the cost note under Index choice in
  `docs/lent/queries.md` goes away.
- **Statistics for a better planner.** Key counts break ties between
  indexes, and `explain` shows them. An `=` on one field still beats a range
  on another with fewer keys, because only equal matches are compared.
  Comparing every candidate needs the cheap count above or stored statistics
  such as row counts per index. Keep the plan predictable.
- **SQL schema conversion (lower priority).** Turn `CREATE TABLE` and
  `CREATE INDEX` statements into a `lent.graph` declaration, and report the
  parts that have no lent form so the user decides each case.
