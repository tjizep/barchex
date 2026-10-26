# Test Suite

The suite starts a temporary `barchd`, loads the function sources from this
checkout with `SETF`, and drives them the way a client would: over HTTP, over
RESP, and against local stand-ins for the services they call. Every test keeps
its own key spaces and its own port, so the suite is repeatable and can run
beside a development server.

## What it covers

- The viewer's tests moved to
  [barch-spaces](https://github.com/tjizep/barch-spaces) with the viewer.
- `test_sigv4.py` checks the signer against the request examples AWS publishes.
- `test_keycodec.py` runs the key codec's self-check and writes encoded ints,
  floats, strings, nulls and packed tuples into a space, then checks that
  `barch.store.range` walks them back in value order.
- `test_lent_tx.py` checks the transaction behavior lent's unique indexes need:
  a transaction that read a key as missing, by `GET`, `EXISTS` or an empty
  range, gets `TXCONFLICT` when another write to that key commits first.
- `test_rowcodec.py` runs the row codec's self-check, stores rows in each
  format and reads them back, reads rows written by an older field list, and
  checks that bad rows are refused before anything is stored.
- `test_schema.py` runs the schema self-check, declares tables from another
  space, carries a stored row across a field rename with `lent.ids`, and
  checks the errors for a missing table, an unknown index field and invalid
  hook declarations.
- `test_migrate.py` runs the layout and migration self-checks, migrates a
  space twice over stored rows, and checks the catalog, the index entries
  built and dropped, and that a unique index broken by stored rows rolls a
  single-page migration back.
- `test_migrate_pages.py` checks bounded index builds and drops, readiness,
  query fallback, live writes, unique checks beyond the build cursor, and
  repair after a failed unique page. It covers concurrent builders and
  writers, timeouts, saved-server restarts, transaction boundaries, and
  rebuilds after encoding or default changes, with all row formats and both
  id kinds.
- `test_client.py` runs the client self-check, then creates, reads, updates
  and deletes rows in optimistic and pessimistic transactions. It checks the
  index entries after each step, that a refused create leaves nothing
  behind, that old rows read a new field's default, the error messages, and
  that a migration committed during a transaction makes it conflict.
- `test_bulk.py` checks `createMany` and `upsert` with integer and UUID ids,
  all three row formats, defaults, hooks, indexes and edges. It checks
  rollback after a batch error, the writes kept when an error is caught,
  invalid inputs, immutable fields and concurrent upserts in optimistic and
  pessimistic transactions.
- `test_uuid.py` creates rows with `barch.uuid()` ids and checks that they
  sort in creation order, that get, by, update, delete, queries and edges
  work with them, including edges to a table with integer ids, the errors
  for ids of the wrong kind, and that `migrate` refuses to change a table's
  id kind.
- `test_query.py` runs queries in optimistic and pessimistic transactions
  and checks the rows and the index each one picks. It counts the rows a
  `desc` query reads to check that it stops at the limit. It also links, follows
  and unlinks edges, checks that `delete` removes a row's edges, runs `has`
  filters both ways and nested, loads edges with `with`, pages with
  `cursor` and `after` in each order, and checks the query and edge errors.
- `test_query_writes.py` checks query-wide `update` and `delete`, their
  affected-row counts, filters, edge follows, order and pagination. It
  checks hooks, rules, index and edge upkeep, rollback and caught errors,
  fixed selections while hooks add or remove rows, writes across index scan
  pages, and conflicts with new matching rows. The checks cover optimistic
  and pessimistic transactions, integer and UUID ids, and all row formats.
- `test_aggregates.py` checks `sum`, `min`, `max` and `aggregate` over
  filtered, ordered and limited queries and empty selections, aggregates of
  `value` functions, `groupBy` on fields, several fields and an edge, and the
  aggregate errors.
- `test_computed.py` reads computed fields from rows, hooks, edge follows,
  filters, orders, cursors, aggregates and `groupBy`, checks that `migrate`
  ignores them and that a client without the graph lacks them, and checks
  the errors for writing one and for a value of the wrong kind.
- `test_edge_fields.py` stores values on links through `create` and `link`,
  reads them from both ends, filters with `whereEdge` in `has` and `with`,
  migrates an edge from no fields to fields and refuses a new required
  field, and checks the errors for bad edge values.
- `test_rules.py` checks value rules, `time` fields, function defaults,
  `updateDefault`, immutable fields and hooks through `lent.open`. It checks
  plain-table, builder and mixed hook declarations and their execution order
  in optimistic and pessimistic transactions. It also checks catalog rules
  in a client opened without the graph, error messages, and the migrations
  that time fields and function defaults allow and refuse.
- `test_field_kinds.py` checks enum, JSON and bytes fields with both id
  kinds, all row formats, optimistic and pessimistic transactions, indexes,
  cursors, upsert and query writes. It checks structural JSON equality,
  null and missing values, empty arrays and objects, exact large integers,
  copied defaults and hook snapshots, immutable nested values, input errors,
  paged default migrations, enum expansion and storage compatibility.
- `test_blog.py` installs the blog example from `examples/blog/` and runs its
  commands: users, posts, follows, stars, timelines, paged migrations and its
  errors.
- `test_vectors.py` builds a clustered corpus, inserts it through
  `vectors.SET`, and checks the answers against a brute-force nearest
  neighbour: exact match under the default cosine metric, recall for `k`
  results, the euclidean switch, tuning presets, and dimension checks.
- `test_s3_backup.py` runs the S3 client and `BACKUP` against a local bucket:
  `GET`/`PUT`/`STAT`/`LS`/`DEL`/`URL`, multipart upload, a full `SAVE`/`LOAD`
  round trip, the unfinished-backup and corruption guards, a restore onto a
  server provisioned with a different shard count, a compressed space's
  dictionary carried to and set on a server that never held it, and the
  file-source fall-through.
- `test_watchdog.py` sends to a local webhook: the climbing alert, the
  recovery message, retry after a refused delivery, the message formats, and
  `INSTALL`/`UNINSTALL`.
- `test_stress.py` is opt-in. It measures concurrent inserts and p50/p95/p99
  query latency across thousands of HNSW vectors, and checks that the configured memory
  ceiling rejects writes while the server remains available. An optional soak
  grows and queries the vector graph for a bounded interval.

## Running

Install `pytest` and `redis` for Python, then:

```sh
pytest -q tests
```

The tests look for `../barch/cmake-build-release/barchd`, then
`../barch/cmake-build-relwithdebinfo/barchd`, then `barchd` on the `PATH`.
`test_lent_tx.py` needs a build with transactions. For another build, set
`BARCHD` to its executable path:

```sh
BARCHD=/path/to/barchd pytest -q tests
```

If no `barchd` is found the suite is skipped, so a checkout without a build
still collects cleanly.

## Stress and soak runs

Run the bounded stress cases separately from the fast suite:

```sh
BARCH_STRESS=1 pytest -q -s tests/test_stress.py
```

The defaults build 2,000 32-dimensional vectors and sign on 1,000 times using
up to 24 workers. The memory test sets the cap 16 MiB above the server's
measured logical key-space baseline. It alternates 1-byte values with 10 MiB
bursts made from 256 KiB keys, then deletes alternating keys and checks that
small and large writes recover. It then lowers the limit to one byte, expects
the next write to return `not enough memory`, and checks that the server stays
available. The workload attempts at most 40 MiB of payload and reports
allocator fragmentation and reusable bytes. The tests print throughput and
latency percentiles. Set `BARCH_STRESS_VECTORS`,
`BARCH_STRESS_DIM`, `BARCH_STRESS_SESSIONS`, `BARCH_STRESS_WORKERS`,
`BARCH_STRESS_HTTP_WORKERS`, `BARCH_STRESS_INSERT_P99_MS`,
`BARCH_STRESS_P99_MS`, or `BARCH_STRESS_HTTP_P99_MS` to adjust those bounds.

Add a time-bounded HNSW soak with:

```sh
BARCH_STRESS=1 BARCH_SOAK=1 BARCH_SOAK_SECONDS=300 \
  pytest -q -s tests/test_stress.py
```

The soak duration is limited to ten minutes per run and the operation count to
100,000. The same command also runs a restart-chaos case. It lets ordinary
shard autosaves checkpoint a seed graph, starts four pipelined HNSW writers,
waits a random 5-50 ms, and sends `SIGKILL` without issuing `SAVE`. It restarts
`barchd` on the same data directory, checks boot and stale-socket handling, then
validates node counts, vector/name/reverse-ID/level records, neighbor-list
encoding and references, and sample searches. The assertion allows in-flight
writes to disappear, while failing on dangling or incomplete graph state.
`save_interval` is set to 1 ms in this isolated server to exercise shard
autosaves around the crash window. It runs three independently randomized
kill windows by default; set `BARCH_CHAOS_TRIALS` from 1 to 10 to adjust them.
The current build can fail this assertion: one run restarted successfully with
`vec.count` still at 256 but also loaded an incomplete node and neighbor links
to missing node IDs. The test prints the trial's acknowledgements and structural
defects to make this data-loss case diagnosable. See
[CHAOS-FINDINGS.md](CHAOS-FINDINGS.md) for reproduction details and fix
acceptance checks.

Compare recovery with the vector space's AOF enabled:

```sh
BARCH_STRESS=1 BARCH_SOAK=1 BARCH_AOF_CHAOS=1 BARCH_CHAOS_TRIALS=3 \
  pytest -q -s tests/test_stress.py::test_ungraceful_hnsw_stream_recovery
```

This runs the same randomized trials with AOF off and with `vectors.aof=on`, a
temporary global `aof_dir`, and `aof_durability=each`. The test verifies that a
log is written and replayed before applying the same structural checks. AOF is
per key-space and records the individual key mutations made by a vector insert.

The memory test uses barch's `max_memory_bytes` limit with eviction disabled;
it checks barch's OOM response path and server health. It does not invoke the
host OOM killer or claim to test kernel-level memory exhaustion.
