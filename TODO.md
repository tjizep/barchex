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
- **Read many blocks in one call.** With `barch.vec`, a column scan's
  kernels take under 1 µs per block, and reading the blocks takes nearly
  all the rest. On 409,600 rows in a transaction, a sum runs at 85 million
  rows/s, and reading its presence and field blocks alone takes as long.
  Each block costs about 11 µs in a transaction and 7 µs outside one:
  `getBufferAt` copies the value twice and logs the read. A call that
  answers buffers for many keys, or a read-only view of a stored value,
  would remove most of it; [docs/barch-vec.md](docs/barch-vec.md) describes
  both.

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
- **Typed and dictionary column blocks.** Column blocks hold every number as
  an f64 and every string as bytes. Store `int` fields that fit as `i8` or
  `i32` blocks, and short repeated strings as `i8` or `i32` codes into a
  per-table dictionary, so scans read a half to an eighth of the bytes
  and filter, group and fold codes with `barch.vec`. Equality, `in` and
  groups work on codes directly; other string conditions mark the passing
  codes once and call `filterIn`. Decide how a block widens when its values
  outgrow `i8`, and how the dictionary stays bounded.
- **SQL schema conversion (lower priority).** Turn `CREATE TABLE` and
  `CREATE INDEX` statements into a `lent.graph` declaration, and report the
  parts that have no lent form so the user decides each case.
