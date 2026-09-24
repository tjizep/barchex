# Test Suite

The suite starts a temporary `barchd`, loads the function sources from this
checkout with `SETF`, and exercises the functions over RESP. It covers the
published SigV4 vectors, account and session behavior, vector indexing,
S3 response handling and backup discovery, and watchdog state reporting.

Install `pytest` and `redis` for Python, then run:

```sh
pytest -q tests
```

The tests automatically look for the barch build used in this workspace. For
another build, set `BARCHD` to its executable path:

```sh
BARCHD=/path/to/barchd pytest -q tests
```
