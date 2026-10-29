# barchex

Extensions for barch, packaged as a git repository that barchd can install.

## Install with barchd -g

Start barchd with the repository, and it installs barchex on startup and
again on every sync:

```
barchd --port 14000 --dir data -g https://github.com/tjizep/barchex
```

`package.luau` at the root of the repository says what goes where. Each sync
creates the `vectors`, `s3`, `watchdog` and `lent` key spaces and loads each
folder of the same name into its space.

The space viewer that used to be part of barchex is a repository of its own now,
[barch-spaces](https://github.com/tjizep/barch-spaces). To have it beside barchex,
give barchd both:

```
barchd --port 14000 --dir data \
  -g https://github.com/tjizep/barchex \
  -g https://github.com/tjizep/barch-spaces user=default
```

The `tests/`, `docs/` and `examples/` folders are left out of the server. To install
barchex into a barchd that is already running, use `FUNCTIONS SYNC` as
described in [Install with FUNCTIONS SYNC](#install-with-functions-sync).

## What it contains

Each folder that `package.luau` loads becomes a key space with that name.

```
package.luau       →  how barchd -g installs this repository
vectors/
  vectors.luau     →  function VECTORS    (vectors.SET/CLOSEST/TUNE/PARAMS)
  vgraph.luau      →  required by VECTORS (HNSW graph over nk f32 vectors)
s3/
  s3.luau          →  function S3         (S3 client, file source, CALLF S3 …)
  sigv4.luau       →  function SIGV4      (SHA-256, HMAC and AWS SigV4 in Luau)
  backup.luau      →  function BACKUP     (a key space to a bucket and back)
watchdog/
  watchdog.luau    →  function WATCHDOG   (mail or webhook when error rates climb)
lent/
  keycodec.luau    →  function KEYCODEC   (order-preserving keys for lent indexes)
  rowcodec.luau    →  function ROWCODEC   (lent rows as json, text or binary)
  schema.luau      →  function SCHEMA     (lent tables, fields, indexes and edges)
  layout.luau      →  function LAYOUT     (the store keys of lent rows, indexes and edges)
  migrate.luau     →  function MIGRATE    (the lent catalog and index builds)
  expr.luau        →  function EXPR       (expression filters for lent queries)
  client.luau      →  function CLIENT     (lent rows, edges and queries)
docs/             →  the reference pages listed below
examples/
  blog/            →  a blog on lent, installed by hand (see its README)
```

## Documentation

Each module has a reference page in `docs/`:

| page | covers |
|---|---|
| [docs/vectors.md](docs/vectors.md) | VECTORS: store vectors and find the closest ones |
| [docs/s3.md](docs/s3.md) | S3, SIGV4 and BACKUP: bucket access, file stores that fall through to a bucket, and key space backups |
| [docs/watchdog.md](docs/watchdog.md) | WATCHDOG: alerts by mail or webhook when error rates climb |
| [docs/lent/codecs.md](docs/lent/codecs.md) | lent KEYCODEC, ROWCODEC and LAYOUT: keys, stored rows and store keys |
| [docs/lent/schema.md](docs/lent/schema.md) | lent SCHEMA: tables, fields, indexes, edges, value rules, hooks, policies, computed fields and views |
| [docs/lent/migrate.md](docs/lent/migrate.md) | lent MIGRATE: the catalog and paged index builds |
| [docs/lent/client.md](docs/lent/client.md) | lent CLIENT: transactions, row writes, upserts, edges and path edges |
| [docs/lent/queries.md](docs/lent/queries.md) | lent queries: filters, index choice, cursors, aggregates, paged aggregates, joins and views |

[docs/lent-design.md](docs/lent-design.md) holds the plan for lent, an ORM
over barch transactions, and [docs/sql-survey.md](docs/sql-survey.md)
checks how lent covers public SQL workloads.

## Install with FUNCTIONS SYNC

To add barchex to a server that is already running, configure the repository
in the `configuration` space and sync it:

```
CONFIG SET functions_dir /path/to/checkouts

USE configuration
SET git/repositories/barchex/url    https://github.com/tjizep/barchex.git
SET git/repositories/barchex/pull   on
SET git/repositories/barchex/branch main
SET git/repositories/barchex/as     keys
SET git/repositories/barchex/space  off

FUNCTIONS SYNC barchex
FUNCTIONS STATUS
USE vectors
KEYSF
```

The sync applies `package.luau` the same way `barchd -g` does: it creates the
four spaces and loads the four folders. Leave
`as` on `keys` and `space` off; barch refuses a package that lists folders
while either is set to something else.
