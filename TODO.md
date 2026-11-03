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
- **Column tables.** `format = "column"` needs `int` ids and shares
  conflicts and locks across each block. Without `block`, a field's values
  of one block stay within 524,032 bytes. `migrate` refuses a format change
  to or from `column`. See `docs/lent/codecs.md`.
- **Changing a column table's block size.** `migrate` refuses a change of
  `block`. A paged rebuild would copy each block's rows into blocks of the
  new rows, the way index builds page, and switch the catalog when it ends.

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
- **Typed column blocks.** Column blocks hold every number as an f64. Store
  `int` fields that fit as `i8` or `i32` blocks, so scans read a half to an
  eighth of the bytes. Decide how a block widens when its values outgrow
  `i8`. Typed blocks can use the header that blocks of a table with `block`
  start with: its version and tag bytes can name the element type, and the
  rows sizing then takes the element width.
- **Dictionary text blocks.** Grouping by a text field runs at about half
  the rate of grouping by a number: each block needs an `offsets` pass, and
  the grouper hashes every row's string. Store a text block with few
  distinct values as a dictionary block, tagged in its header: its distinct
  values in sorted order, then one code per slot, `i8` while the block holds
  at most 255 values and `i32` above that. The codes follow the order of the
  values within the block, so:
  - a group runs the grouper on the codes, then maps the block's few codes
    to the scan's groups by their strings;
  - a range condition finds its bounds in the sorted values with one binary
    search per block and filters the codes as numbers; equality and `in`
    mark the passing codes and call `filterIn`;
  - `min`, `max` and ordering compare codes.

  Each block keeps its own dictionary, so a new value re-sorts and recodes
  one block, which a write already rewrites, and writers to different
  blocks share no dictionary key. A block uses the plain text layout once
  its distinct values pass a limit, so names and phone numbers stay plain.
  A table-wide ordered dictionary would make codes comparable across
  blocks, but every new value between two others then relabels codes in
  many blocks; see order-maintenance labeling (Dietz and Sleator, 1987),
  order-preserving dictionaries for column stores (Binnig, Hildenbrand and
  Färber, SIGMOD 2009) and the delta merge of SAP HANA. The rows sizing
  takes the code width plus the dictionary's share of the block.
- **SQL schema conversion (lower priority).** Turn `CREATE TABLE` and
  `CREATE INDEX` statements into a `lent.graph` declaration, and report the
  parts that have no lent form so the user decides each case.
