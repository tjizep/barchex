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
  server provisioned with a different shard count, and the file-source
  fall-through.
- `test_watchdog.py` sends to a local webhook: the climbing alert, the
  recovery message, retry after a refused delivery, the message formats, and
  `INSTALL`/`UNINSTALL`.

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