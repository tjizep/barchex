# lent TODO

This page lists the work that remains on lent, the ORM described in
[docs/lent-design.md](docs/lent-design.md). The schema language, migrations
with paged index builds, row reads and writes with index upkeep, bulk create
and upsert, query reads and writes, aggregates over fields and values,
`groupBy`, edges, path edges and computed fields (each stored or not), edge
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
- **Statistics and a better planner.** The planner picks an index by how
  many leading fields its filters match. Statistics such as row counts and
  key counts per index, or key counts read at plan time, would let it pick
  the narrower of two candidate indexes. Keep the plan predictable and show
  the choice in `explain`.
- **Column formats.** Rows are stored whole in the `binary`, `text` or
  `json` format. A column format stores each field in its own key space in
  the graph, in blocks of many rows. A block holds fixed-length values for
  fields that have them, or a header of value lengths followed by the
  values, which can be compressed. Luau buffers can pack and read the
  blocks. A query that reads a few fields of many rows then reads only
  those fields' blocks.
- **Analytics queries.** `aggregate`, `groupBy`, `count`, `sum`, `min` and
  `max` read every matching row in one function call. Analytics needs more
  aggregates, filters on groups, and a way to run aggregates over tables too
  large for one call, such as paged partial results.
- **SQL schema conversion (lower priority).** Turn `CREATE TABLE` and
  `CREATE INDEX` statements into a `lent.graph` declaration, and report the
  parts that have no lent form so the user decides each case.
