# lent TODO

This page lists the work that remains on lent, the ORM described in
[docs/lent-design.md](docs/lent-design.md). The schema language, migrations
with paged index builds, row reads and writes with index upkeep, bulk create
and upsert, query reads and writes, aggregates over fields and values,
`groupBy` and paged aggregates, edges, path edges and computed fields (each stored or not), edge
joins, edge fields, cursor pages, value rules, `time`, `enum`, `json` and
`bytes` fields, hooks and privacy policies are built.

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
- **Column formats.** Rows are stored whole in the `binary`, `text` or
  `json` format. A column format stores each field in its own key space in
  the graph, in blocks of many rows. A block holds fixed-length values for
  fields that have them, or a header of value lengths followed by the
  values, which can be compressed. Luau buffers can pack and read the
  blocks. A query that reads a few fields of many rows then reads only
  those fields' blocks.
- **Analytics queries.** `aggregate` and `groupBy` take `avg`, `distinct`,
  `having`, group order and paging, and `aggregatePage` runs them across
  calls over tables too large for one. A state grows with its groups and
  distinct values, so many groups need a stored partial result, such as a
  scratch table.
- **SQL schema conversion (lower priority).** Turn `CREATE TABLE` and
  `CREATE INDEX` statements into a `lent.graph` declaration, and report the
  parts that have no lent form so the user decides each case.
