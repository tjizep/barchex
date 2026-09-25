# Test Suite

The suite starts a temporary `barchd`, loads the function sources from this
checkout with `SETF`, and drives them the way a client would: over HTTP, over
RESP, and against local stand-ins for the services they call. Every test keeps
its own key spaces and its own port, so the suite is repeatable and can run
beside a development server.

## What it covers

- `test_sigv4.py` checks the signer against the request examples AWS publishes.
- `test_spaces_viewer.py` starts HTTP for the `spaces` space and runs the
  viewer end to end: registration, the first account becoming admin, the
  session cookie, the admin and non-admin API split, key and function writes,
  space creation, sign-on, and sign-out.
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
  query latency across thousands of HNSW vectors, creates thousands of HTTP
  sign-on sessions under CPU pressure, and checks that the configured memory
  ceiling rejects writes while the server remains available. An optional soak
  grows and queries the vector graph for a bounded interval.

## Running

Install `pytest` and `redis` for Python, then:

```sh
pytest -q tests
```

The tests look for the barch build used in this workspace. For another build,
set `BARCHD` to its executable path:

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
