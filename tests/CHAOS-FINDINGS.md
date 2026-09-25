# HNSW Crash-Recovery Finding

## Summary

The opt-in no-`SAVE` crash test can expose incomplete HNSW records after an
unclean process kill. `barchd` restarts and loads the shard files, but some
recovered neighbor lists can refer to node IDs whose vector, reverse-ID, or
level records were not recovered. Treat this as a data-integrity failure, not a
clean rollback.

The outcome is timing-dependent. In one three-trial run, two trials recovered
cleanly and one failed structural validation. A separate trial also failed.
The failures below occurred with the seed graph retained and `vec.count` still
at 256. Startup succeeded; the observed failure was the recovered graph state.

## Reproduce

Run from the repository root. Increase the randomized trial count to raise the
chance of hitting the interruption window:

```sh
BARCH_STRESS=1 BARCH_SOAK=1 BARCH_CHAOS_TRIALS=10 \
  pytest -q -s tests/test_stress.py::test_ungraceful_hnsw_stream_recovery
```

Use the workspace virtual environment's `pytest` executable if it is not on
`PATH`. The test uses a private temporary data directory and port. It does not
call `SAVE` before killing `barchd`.

To compare AOF off with AOF enabled for the vector space, run:

```sh
BARCH_STRESS=1 BARCH_SOAK=1 BARCH_AOF_CHAOS=1 BARCH_CHAOS_TRIALS=3 \
  pytest -q -s tests/test_stress.py::test_ungraceful_hnsw_stream_recovery
```

The AOF trial sets global `aof_dir`, sets `vectors.aof` to `on` in the
`configuration` space, and uses `aof_durability=each`. On restart it restores
those settings before first opening `vectors`, so the server opens and replays
that space's log. The test verifies both that the log has records and that the
startup log reports replay before it checks HNSW structure.

Each trial inserts 256 seed vectors, sets `save_interval` to 1 ms, and waits
for ordinary shard autosaves to establish a baseline. Four clients then
pipeline eight `vectors.SET` calls each. The test sleeps for a random 5-50 ms
and sends `SIGKILL` while the pipelines are active. It restarts the same binary
against the same data directory, reinstalls the vector functions, and checks
the recovered records and graph references. The test keeps logs and includes
the startup log tail if the server does not boot.

The runtime `save_interval` setting also changes the maintenance poll delay in
the current configuration setter. This trial therefore exercises very frequent
shard saves as well as the crash window; it is an intentionally aggressive
recovery test, not a production-tuned autosave benchmark.

## Observed Failure

One failing trial reported:

```text
delay_ms=48.4 active_at_kill=32 attempted=32 acked=0 unknown_outcome=32
graph_count=256 complete_nodes=257 seed_retained=256/256 acked_lost=0
disconnects=4
```

Structural checks found node 257 with no reverse-ID or vector record, and
neighbor lists pointing to missing IDs 257-261. Another run retained exactly
256 complete nodes but had neighbor lists pointing to IDs 257 and 259 and a
neighbor-list owner for node 257 that was absent from the node records.

`acked=0` means none of the four client pipeline batches returned a complete
successful response before the kill. The writes had unknown outcomes; the test
does not assume that an in-flight write must survive. It requires the recovered
index to be internally consistent whether such writes are retained or dropped.

## AOF Comparison

Enable the AOF variant with `BARCH_AOF_CHAOS=1` as shown above. It sets
`vectors.aof=on`, a private `aof_dir`, and `aof_durability=each`, then confirms
that restart logs a change-log replay before checking the graph.

In three AOF-only trials, all three restarts passed structural validation. Each
replayed a complete additional node (`vec.count=257`, 257 complete nodes, all
256 seed nodes retained). In the paired no-AOF run, structural corruption was
reproduced. This is evidence that AOF helps for this workload, not proof that
every interrupted HNSW insert is atomic. The log records individual key
mutations, while one HNSW insert writes many keys; keep the graph validator and
run more crash windows before treating AOF as a complete fix.

## Relevant Code

- `tests/test_stress.py::test_ungraceful_hnsw_stream_recovery` builds the
  workload, kills and restarts the process, and validates the recovered graph.
- `vectors/vgraph.luau:415-482` writes `vec.count`, vector/name/reverse-ID/level
  records, then links and prunes neighbors through individual store writes.
- `vectors/vgraph.luau:398-410` updates the two sides of a link separately.
- `/home/test/barch/src/shard.cpp:625-649` saves an individual shard;
  `/home/test/barch/src/shard.cpp:2630-2644` triggers periodic shard saves.
- `/home/test/barch/src/key_space.cpp:586-646` enables one AOF per opted-in
  space, and `:826-1028` replays and diagnoses the log on load.
- `/home/test/barch/src/shard.cpp:1413-1419` appends each successful low-level
  key write to the space log. An HNSW insert consists of many such writes.
- `tests/conftest.py::Server` exposes the child process, data directory, binary,
  and startup log used by the restart test.

## Fix Acceptance

After a fix, repeat the crash test across several randomized trials. Every
successful restart must preserve the seed graph and either recover a complete
set of inserted nodes or discard incomplete in-flight insertions. Reject
missing vector/name/reverse-ID/level records, counts that disagree with
complete nodes, malformed neighbor buffers, and links to absent nodes. Keep
the server-boot check separate so parse/load failures remain distinguishable
from a graph that boots with inconsistent data.
