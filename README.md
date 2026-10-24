# barchex

Extensions for barch, packaged as a git repository that barchd can install.

## Install with barchd -g

Start barchd with the repository, and it installs barchex on startup and
again on every sync:

```
barchd --port 14000 --dir data -g https://github.com/tjizep/barchex
```

`package.luau` at the root of the repository says what goes where. Each sync
creates the `vectors`, `s3`, `watchdog` and `ent` key spaces and loads each
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
ent/
  keycodec.luau    →  function KEYCODEC   (order-preserving keys for ent indexes)
  rowcodec.luau    →  function ROWCODEC   (ent rows as json, text or binary)
  schema.luau      →  function SCHEMA     (ent tables, fields, indexes and edges)
  layout.luau      →  function LAYOUT     (the store keys of ent rows, indexes and edges)
  migrate.luau     →  function MIGRATE    (the ent catalog and index builds)
  client.luau      →  function CLIENT     (ent rows, edges and queries)
docs/
  ent-design.md    →  the plan for ent, an ORM over barch transactions
examples/
  blog/            →  a blog on ent, installed by hand (see its README)
```



VECTORS is the `examples/hnsw` index with nk vectors in place of words.
`vectors.SET <name> <buffer>` stores a point; pass the vector as ONE argument:
a packed f32 buffer (dim*4 bytes, e.g. Python `struct.pack('<384f', *vec)`).
`vectors.CLOSEST <buffer> [k]` returns the nearest name, or name/distance
pairs when k is given. Do NOT pass one argument per component (the colon form
`vectors:SET` is parsed by the builtin SET first, which treats a third arg
as an EX/NX/GET option and refuses it before the function is reached).
Distance defaults to cosine. TUNE can switch it to `euclidean` and back
without a rebuild; TUNE also sets M/efConstruction/efSearch/heuristic, and
PARAMS reports them. Write through the dotted form in the space (`USE vectors`
first; the colon form writes a plain key). The barch-spaces console takes its command
list from that repository's `spaces/commands.json`; add the four VECTORS commands
there if its dropdown should offer them.

S3 works with AWS and any service that speaks its API (MinIO, R2, B2, Wasabi).
The function sandbox does not provide hashing or a clock, so SIGV4 implements
SHA-256 and HMAC in plain Luau and gets the time from a key's expiry.
`s3.SIGV4` (the dotted name is the command and works from any space) checks
the signer against the example requests in AWS's SigV4 documentation.
Settings are keys in `configuration`. For
`require("s3.S3").client("<profile>")`, `s3.<profile>.<name>` overrides
`s3.<name>`:

```
USE configuration
SET s3.endpoint    https://s3.eu-west-1.amazonaws.com   # or http://127.0.0.1:9000
SET s3.region      eu-west-1
SET s3.access_key  AKIA...
SET s3.secret_key  ...
SET s3.path_style  1          # default 0 on amazonaws.com, 1 anywhere else
```

The secret cannot be a `…password` key: scripts cannot read those, and this
secret must sign requests. Anyone who can read `configuration` can therefore
see it.

From a stored function, require it inside the handler rather than at the top:

```lua
local s3 = require("s3.S3")
local body, why = s3.get("bucket", "path/key")     -- nil and why.status 404 if missing
s3.put("bucket", "path/key", body, "text/plain")
local page = s3.list("bucket", { prefix = "path/", delimiter = "/" })
local url = s3.presign("bucket", "path/key", 3600)
local up = s3.upload("bucket", "big/key")            -- multipart: up:part(body) ... up:finish()
```

`s3.S3 LS bucket [prefix]`, `GET`, `STAT`, `PUT`, `DEL`, `URL`, `BUCKETS`
and `CHECK` do the same from a RESP connection (or `CALLF S3 …` in the `s3`
space). Calling out to the network requires the `outbound` ACL category.
From the [barch-spaces](https://github.com/tjizep/barch-spaces) viewer, select the `s3` space and use the `CALLF S3 …` form in the
Call box or the console; the console does not accept the dotted `s3.S3`
command. The viewer calls out as its HTTP user, so that user needs
`outbound` too. `ACL SETUSER` adds a category to the user's rule:

```
ACL SETUSER web on +outbound
```

Without it, a call fails with `http.request needs the outbound category`.
Older barch builds refuse these calls from the viewer with "cannot call
'CALLF', it blocks"; a build that runs a nested CALLF inline runs them. A
file source is not affected because barch calls it directly.

A space's file store can fall through to a bucket: a missing file is fetched
the first time it is requested and becomes an ordinary stored file afterward.
Set the options before the space is first loaded (barch reads them when it
loads a space), then add these two small functions to it:

```
USE configuration
SET photos.fs_source          S3SOURCE
SET photos.fs_source_list     S3LIST          # optional: FS LS … SOURCE shows the bucket
SET s3.source.photos          my-bucket/photos # bucket[/prefix]
SET photos.function_deadline_ms 30000        # the default second is short for a network call

USE photos
SETF S3SOURCE "function call(path) return require('s3.S3').source(path) end"
SETF S3LIST   "function call(dir) return require('s3.S3').listing(dir) end"
```

The listing offers a bucket's objects one level at a time. A sub-folder appears
once something in it has been fetched, because barch lists a source's names as
files. The viewer's Files tab shows what has been fetched.

`s3.BACKUP` copies a whole key space to a bucket with barch's streaming save
and restores it with the streaming load:

```
s3.BACKUP SAVE orders my-bucket/nightly          # answers the name, e.g. 20260924T060703Z
s3.BACKUP LIST orders my-bucket/nightly          # oldest first; "(unfinished)" has no manifest
s3.BACKUP LOAD orders my-bucket/nightly          # the latest complete one, or name one
s3.BACKUP DROP orders my-bucket/nightly 20260924T060703Z
s3.BACKUP @backup SAVE ...                       # s3.backup.* settings
```

A backup is `nightly/orders/<name>/shard-0000` … one object per shard, plus
`dictionary.bin` when the space has a zstd dictionary, plus `manifest.json`,
which is written last. A save captures one moment: if no
transaction is open, BACKUP starts one, streams every shard to the bucket, and
commits. It commits after a failure too, because a ROLLBACK would also undo
other clients' writes. Writes continue while it runs; barch keeps the pages
from the BEGIN point copy-on-write until the commit. Run it inside your own
BEGIN to save that moment, and the commit remains yours. A failed save removes
what it wrote and aborts its upload.

When the space is compressed, the backup carries its zstd dictionary in
`dictionary.bin`. barch stores a compressed value as bytes that name the
dictionary they were made with, so a restore into a space without that
dictionary cannot read them. LOAD sets the backup's dictionary on the space
before it replaces the shards, so the values read back even on a server that
never held it. Setting a dictionary is refused when the space already has a
different one, so restore a compressed backup into a fresh or cleared space, or
into one whose dictionary is the same.

A shard larger than `s3.part_size` (default 8 MB, at least 5 MB) is uploaded in
parts, so a save holds about one part in memory. A load holds only one shard at
a time, because barch collects a shard in full before replacing it. Before it
touches the space, LOAD checks that the shard count matches and that every
shard object exists at the size specified by the manifest, and checks the
dictionary the same way when the backup carries one. LOAD is refused
inside a transaction and on a range-sharded space. SAVE needs read rights in
the space, LOAD needs write rights, and both need `outbound`.

BACKUP's `--@barch {"deadline_ms": 30000}` header gives the function 30 s of
running time, barch's default `function_deadline_max_ms`; waiting on S3 does
not count. The entire run, including waits, is limited to
`function_wall_factor` times that value, 300 s by default. The limits of the
space the connection is in (`USE`) apply, so for a larger space raise
`<space>.function_deadline_max_ms` and the header, or raise the wall factor.

A run stopped at the ceiling ends with `FUNCTION timeout`. If it stops during
an upload, as it almost always does, the save still commits but cannot remove
what it wrote, because every request after the ceiling fails immediately. If
it stops while Luau is running, the timeout cannot be caught and the space is
left in its transaction, so copy-on-write pages keep growing. After a timeout,
COMMIT in that space if it is still in a transaction. Do not ROLLBACK: that
would undo every write since the BEGIN. Then DROP the backup that LIST shows
as unfinished. An abandoned multipart upload remains in the bucket until a
lifecycle rule with `AbortIncompleteMultipartUpload` clears it.

WATCHDOG monitors barch's error counters (`INFO ERRORS` and `foreign_errors`
from `INFO FOREIGN`) and sends an alert when one starts climbing, when all of
them become quiet again, and when barchd restarts. A counter triggers an alert
when the last `window` contains at least `min_count` errors at more than
`factor` times the rate during the preceding `baseline`; bursts that continue
become the baseline. It sends at most one alert per counter per `cooldown`.
If a mail server or webhook rejects a message, WATCHDOG retries it on the next
tick through that sink only.

```
USE configuration
SET mail.server   smtp://smtp.example.com:587     # see barch's docs for mail.*
SET mail.from     "barch <barch@example.com>"
SET watchdog.to   ops@example.com, oncall@example.com
SET watchdog.webhook https://hooks.slack.com/services/...   # and/or instead of mail

watchdog.WATCHDOG INSTALL        # a cron entry, configuration:cron/jobs/watchdog
watchdog.WATCHDOG TEST           # a test message to every sink
watchdog.WATCHDOG STATUS         # each counter's window, rate and baseline
```

| setting | default | |
|---|---|---|
| `watchdog.every` | `1m` | the tick, for INSTALL |
| `watchdog.window`, `watchdog.baseline` | `5m`, `1h` | |
| `watchdog.factor`, `watchdog.min_count` | `3`, `5` | |
| `watchdog.cooldown` | `30m` | |
| `watchdog.restart` | `1` | `0` disables restart messages |
| `watchdog.webhook_format` | `json` | `text` and `content`, which Slack, Mattermost, and Discord read, plus the fields individually; `plain` sends the text with a `Title` header for ntfy |
| `watchdog.webhook_auth` | | an `Authorization` header to send |
| `watchdog.counters` | all but `net_errors` | comma-separated list |
| `watchdog.name` | `barchd:<port>` | name used for this server in messages |

`net_errors` is not watched by default: barch 0.5.8 counts a client closing
its connection after a command as one. The webhook's `Authorization` value
cannot be a `…password` key, since scripts cannot read those. Anyone who can
read `configuration` can therefore see it. The cron user needs `outbound`.
After a restart, barch 0.5.8 does not load the `watchdog` space until something
touches it, so cron cannot call into it until `watchdog:DBSIZE` wakes it up.
An install from `package.luau` opens `watchdog` on every sync, including the
first one after a restart.

KEYCODEC encodes values as key text that `barch.store.range` walks in value
order. It is the first part of ent, an ORM planned in
[docs/ent-design.md](docs/ent-design.md). Require it from any space:

```lua
local kc = require("ent.KEYCODEC")
local key = "ent.i.user.by_age" .. kc.pack({ "int", "string" }, { 42, "ann" })
local values, next = kc.unpack(key, 2, #"ent.i.user.by_age" + 1)  -- { 42, "ann" }
local lo = "ent.i.user.by_age" .. kc.encode("int", 42)
local keys = barch.store.range(lo, kc.after(lo), 100)            -- every age 42
```

| kind | values | order |
|---|---|---|
| `int` | integers from -2^53 to 2^53 | numeric |
| `float` | any number except NaN; -0 is stored as 0 | numeric, `-inf` to `inf` |
| `string` | any bytes | byte order, a prefix before its extensions |
| `bool` | `false`, `true` | `false` first |
| `uuid` | 36 lowercase characters, as `barch.uuid()` answers | the uuid's text order |
| `time` | as `int`, for Unix milliseconds | numeric |

`nil` encodes as null for every kind and sorts before every value. `encode`
raises an error for a value of the wrong kind, a fractional or out-of-range
`int`, NaN, and a uuid that is not 36 lowercase characters. Encoded values
contain no space, NUL or `\1` byte, which barch would otherwise read as a
tuple separator or refuse, and which earlier barch builds cut short in a
range. Start each key with a prefix that begins with a letter, such as
`ent.`, so barch keeps the whole key as text. `after(prefix)` answers the
exclusive upper bound for a range over every key that starts with `prefix`.
`ent.KEYCODEC` runs the module's self-check and answers `ok`.

ROWCODEC turns a row table into a stored value and back. Compile the
table's fields once with `fields`, then call `encode` with a format and the
schema version, and `decode` with the stored value:

```lua
local rc = require("ent.ROWCODEC")
local users = rc.fields({
    { name = "email", kind = "string", id = 1 },
    { name = "age", kind = "int", id = 2, optional = true },
})
barch.store.set("ent.r.user.1", rc.encode(users, "binary", 3, { email = "a@b", age = 41 }))
local row, version, format = rc.decode(users, barch.store.get("ent.r.user.1"))
```

| field key | required | values |
|---|---|---|
| `name` | yes | a letter, then letters, digits and `_` |
| `kind` | yes | `string`, `int`, `float`, `bool`, or `time`, which is stored as an `int` |
| `id` | yes | 1 to 65535, unique in the table; keep it when the field is renamed |
| `optional` | no | `true` lets the row leave the field nil; default `false` |

| format | stored value | limits |
|---|---|---|
| `json` | a JSON object keyed by field name, with the version in `_v` | strings must be UTF-8; no infinite floats |
| `text` | `t<version>`, then a tab and `<id>=<value>` per field | none |
| `binary` | `b`, a u32 version, then an id, a tag and a value per field | none |

`encode` raises an error for a key the fields do not define, a missing value
for a field that is not optional, a value of the wrong kind, NaN, and a
version outside 0 to 2^32-1. `decode` reads every format and answers the
row, the schema version it was written with and the format. A row written
with an older field list reads with the current one: added fields are nil,
values for removed fields are skipped, an `int` value reads into a `float`
field, and a whole-number `float` value in range reads into an `int` field.
Other kind changes raise an error until the rows are rewritten. `ent.ROWCODEC` runs the module's self-check and answers `ok`.

SCHEMA declares ent tables in Luau. `ent.schema` checks one table and
`ent.graph` checks the tables together; each raises an error that starts with
`SCHEMA` and names the problem:

```lua
local ent = require("ent.SCHEMA")
local User = ent.schema "User" {
    format = "json",                              -- default "binary"
    fields = {
        ent.field.string "email":unique(),        -- adds unique index by_email
        ent.field.string "name",
        ent.field.int "age":optional(),
        ent.field.bool "admin":default(false),
    },
    edges = { ent.edge.to "posts" "Post" },
    indexes = { ent.index("name", "age") },       -- index by_name_age
}
local Post = ent.schema "Post" {
    id = "int",                                   -- ids 1, 2, 3, ...
    fields = { ent.field.string "title" },
    edges = { ent.edge.from "author" "User":ref "posts":unique() },
}
local app = ent.graph { User, Post }
local version, fields = ent.ids(User, previous)   -- fields for rc.fields
```

| builder | modifiers |
|---|---|
| `ent.field.string`, `.int`, `.float`, `.bool`, `.time` | `:optional()`, `:unique()`, `:default(v)`, `:was("old_name")`, and the value rules below |
| `ent.index(field, ...)` | `:unique()`, `:name("by_x")` |
| `ent.edge.to "name" "Table"` | `:unique()` |
| `ent.edge.from "name" "Table"` | `:ref "to_edge"` (required), `:unique()` |

Every table has a primary key named `id`, so a field cannot use that name.
By default each new row's id is a `barch.uuid()` string, such as
`019a1f3c-7d2e-7a41-9b3c-5e6f7a8b9c0d`. Ids from one server sort in creation
order, and creates in one table never conflict over the id. Set
`id = "int"` for ids 1, 2, 3 and so on from a counter per table, which makes
concurrent creates in that table conflict and retry. A table keeps its id
kind once it has a catalog; see MIGRATE. A table's keys use its name in snake case, so `BlogPost` stores as
`blog_post`. `ent.edge.to "posts" "Post"` on `User` stores as `user_posts`,
and an `ent.edge.from` reads that edge backwards.

A `time` field holds Unix milliseconds as an integer. `ent.now()` answers
the current time that way, from `barch.time()`. In a call replayed from a
Raft log, it answers the time the entry was logged, so every member stores
the same value.

Value rules check each value that `create` and `update` write:

```lua
ent.schema "Post" {
    fields = {
        ent.field.string "title":notEmpty():maxLen(80),
        ent.field.string "slug":match("^[%l%d-]+$"):unique():immutable(),
        ent.field.int "stars":min(0):max(5):default(0),
        ent.field.string "body":validate(function(v)
            return not string.find(v, "spam") or "no spam"   -- the refusal's reason
        end),
        ent.field.time "created_at":default(ent.now):immutable(),
        ent.field.time "updated_at":default(ent.now):updateDefault(ent.now),
    },
    hooks = {
        ent.hook.create(function(c, row)
            row.slug = row.slug or (string.gsub(string.lower(row.title), "%W+", "-"))
        end),
    },
}
```

| modifier | fields | effect |
|---|---|---|
| `:min(n)`, `:max(n)` | `int`, `float`, `time` | the value is at least or at most `n` |
| `:minLen(n)`, `:maxLen(n)` | `string` | the value's length in bytes is at least or at most `n` |
| `:notEmpty()` | `string` | the same as `:minLen(1)` |
| `:match(pattern)` | `string` | the value contains a match for the Luau string pattern; anchor it with `^` and `$` to match the whole value |
| `:validate(fn)` | any | `fn(value)` refuses the value by answering `false` or a message, or by raising an error; a field may have several |
| `:immutable()` | any | `update` refuses to change the value |
| `:default(fn)` | any | `create` calls `fn()` when the row leaves the field nil |
| `:updateDefault(fn)` | any but immutable | `update` calls `fn()` when the update leaves the field unchanged |

`:min`, `:max`, `:minLen`, `:maxLen`, `:match` and `:immutable` are stored in
the catalog, so every client of the space enforces them once `migrate` has
run. A new rule applies to later writes; it leaves stored rows as they are.
`update` checks only the values it changes.

Functions stay in code: `:validate`, `:updateDefault`, a function
`:default`, and hooks run only in a client opened with the graph; see
`ent.open` under CLIENT. A function default fills only new rows, so a new
required field also needs a value default, or `:optional()`, for the rows
stored before it.

`ent.hook.create(fn)`, `ent.hook.update(fn)` and `ent.hook.delete(fn)` run
before the write, inside its transaction, in the order they are listed:

| hook | called as | runs |
|---|---|---|
| `create` | `fn(c, row)` | after defaults, before the value rules |
| `update` | `fn(c, id, row, old)` | after `updateDefault`, before the value rules |
| `delete` | `fn(c, id, old)` | when the row exists, before it is removed |

A hook may change `row` and may read and write other tables through `c`.
An error it raises refuses the write. Writes a hook made before a refusal
stay in the transaction, so a caller that catches the error and goes on
keeps them.

`ent.ids(table, previous)` gives each field a ROWCODEC id. Pass `nil` for a
new table, or the first answer of the previous version's call. A field keeps
its id under its name or its `:was` name, and new fields are numbered after
the highest id ever used, so a dropped field's id is never reused.
`ent.SCHEMA` runs the module's self-check and answers `ok`.

LAYOUT names the store keys ent uses in the application's space: rows
(`lay.row(t, pk)`), index entries (`lay.entry(t, ix, row, pk)`), edges and a
table's pk counter. `lay.walk(prefix, each)` calls `each(key)` for every key
under a prefix, a page at a time, and `each` may remove the key it is given.
`lay.scan(lo, hi, each)` and `lay.scan_back(lo, hi, each)` call `each(key)`
for the keys in `[lo, hi)`, in key order or highest first, and stop when
`each` answers `true`.
`ent.LAYOUT` runs the module's self-check and answers `ok`.

MIGRATE puts a schema into the space that calls it. Call it from that space
with the answer of `ent.graph`:

```lua
local m = require("ent.MIGRATE")
local report = m.migrate(app)  -- { version = 2, changed = true,
                               --   steps = { "build User.by_email" } }
local compiled = m.load()      -- the schema in the catalog, or nil
```

`migrate` runs in one `barch.tx.run` transaction. It drops the entries of
removed or changed indexes, builds new indexes from the stored rows, and
writes the catalog under `/ent` in the space's graph. If it raises an error,
nothing is written. Running it again with the same schema writes nothing and
answers the current version.

`migrate` raises an error that starts with `MIGRATE` for a change that would
leave stored rows unreadable:

- a table missing from the schema;
- a new field that is neither `:optional()` nor has a value `:default()`;
- a kind change other than `int` to `float`, or `int` to or from `time`;
- a field rename in a table that has stored `json` rows;
- a unique index whose values two stored rows already share;
- a change to a table's `id` kind.

Index builds read the whole table in that one transaction, so a large table
can exceed the function deadline. `ent.MIGRATE` runs the self-check of the
planning step and answers `ok`.

CLIENT reads and writes the rows of a migrated space and keeps their indexes
current. Call `ent.tx` from the application's space:

```lua
local ent = require("ent.CLIENT")
ent.tx(function(c)
    local u = c.User:create { email = "a@b", name = "ann" }  -- u.id, a uuid
    c.User:get(u.id)                         -- the row, or nil
    c.User:by("email", "a@b")                -- the row, through by_email
    c.User:update(u.id, { name = "al" }, { "age" })  -- sets name, clears age
    c.User:delete(u.id)                      -- false if there was no row
end)
```

| call | answers | raises an error when |
|---|---|---|
| `create(values)` | the row with its new `id` | a unique index already holds its values, a field is unknown, a value has the wrong kind or breaks a value rule, or a required field is missing |
| `get(id)` | the row, or `nil` | `id` does not fit the table's id kind: a lowercase uuid, or a positive integer for `id = "int"` |
| `by(index, values...)` | the row, or `nil` | there is no such unique index, or the number of values differs from its fields |
| `update(id, values, clear)` | the stored row | there is no row `id`, it changes an immutable field, or as for `create` |
| `delete(id)` | `true`, or `false` if there was no row | `id` does not fit the table's id kind |

`by` takes an index name, such as `by_email`, or a field name with a unique
`by_<field>` index. Rows are tables of field values plus `id`. A field the
stored row lacks reads as its `:default()`.

To run a schema's function defaults, `:validate` functions and hooks, open
the client with the graph the space was migrated with:

```lua
local db = ent.open(app)        -- app: the answer of ent.graph
db.tx(function(c) ... end)      -- db.client(pessimistic) inside a transaction
```

`ent.open` raises an error when the graph declares a table or field that the
space's catalog lacks; run `migrate` first. Value rules stored in the catalog
apply with or without it.

`ent.tx(fn, pessimistic)` runs `fn(c)` in `barch.tx.run`, which retries on
a conflict, and answers what `fn` answers. With `pessimistic` true, a row or
unique entry about to be written is read with the exclusive lock, so two
writers of one value wait for each other. Inside a transaction you already
run, `ent.client(pessimistic)` answers the same `c`. A table with
`id = "int"` takes each new id from one counter, so concurrent creates in
that table conflict and retry. A refused call writes nothing apart from what
its hooks wrote, so `fn` can catch its error and go on.

Edges link rows. Pass an edge's name to `create` with an id, a row, or a
list of them, or call `link` and `unlink`:

```lua
local p = c.Post:create { title = "hi", author = u }   -- edge.from author
c.User:link("friends", u.id, v.id)                    -- edge.to friends
c.User:unlink("friends", u.id, v.id)                  -- false if not linked
```

A `:unique()` edge links each row to at most one row, and `create` and
`link` refuse a second one. `delete` removes the row's edges in both
directions, including edges that only the other table declares.

Queries read through the best index for their filters:

```lua
c.User:query()
    :where("name", "=", "ann")            -- = ~= < <= > >=
    :where("age", ">", 30)
    :where(function(r) return r.age % 2 == 0 end)
    :order("age", "desc"):offset(10):limit(10)
    :all()                                -- or first, ids, count
c.User:query():where("id", "=", u.id):queryPosts():all()  -- follow an edge
```

| method | effect |
|---|---|
| `where(field, op, value)` | keeps rows where the comparison holds; a field without a value matches only `= nil` |
| `where(fn)` | keeps rows for which `fn(row)` is true |
| `order(field, dir)` | sorts by `field`, `"asc"` by default or `"desc"`; `asc` puts equal values in id order and missing values first, and `desc` reverses both |
| `limit(n)`, `offset(n)` | applied after the order |
| `cursor(row)` | a string that marks `row`'s place in the query's order |
| `after(cursor)` | keeps the rows after the cursor's row; with no `order`, the query orders by id |
| `using(name)` | reads through the named index, or `"id"` for the table |
| `follow(edge)`, `query<Edge>()` | a query over the rows the matches link to |
| `has(edge)`, `has<Edge>()` | keeps rows with at least one link through `edge` |
| `has(edge, fn)`, `has<Edge>With(fn)` | keeps rows linked to a row that matches the query `fn(q)` builds with `where`, `has` and `using` |
| `with(edge, fn)`, `with<Edge>(fn)` | loads each answered row's links into `row.<edge>`; `fn` is optional and may filter, order and limit them |
| `all()`, `first()`, `ids()`, `count()` | runs the query |
| `explain()` | the plan, such as `by_name_age = name range age` |

The query picks the index whose leading fields match the most `=` filters,
then one range filter on the next field. When that index already returns
rows in the requested order, the query stops reading at the limit.
A `desc` order reads the index from the end and stops the same way.
Otherwise `explain` ends with `then sort`, and the query reads every
matching row before sorting. A
unique index is used only when every one of its fields has an `=` filter,
because it leaves out rows with a missing value. Filters on other fields
are checked on each row read.

Use `cursor` and `after` to page through a query. Each page starts where the
last one ended, so later pages cost the same as the first, and rows added or
removed between pages do not shift the next page as they would with
`offset`:

```lua
local q = c.Post:query():order("stars", "desc"):limit(20)
local page = q:all()
local cur = q:cursor(page[#page])     -- hand this to the caller
-- later, with the same order:
local next = c.Post:query():order("stars", "desc"):limit(20):after(cur):all()
```

A cursor is a hex string that records the order's field and direction, the
row's value and its id. `after` raises an error when the query's order
differs from the cursor's. When the index read already comes in the
cursor's order, the read starts at the cursor and `explain` adds
`from cursor`; otherwise each row is checked and `explain` ends with
`after cursor`.

`has` and `with` join through edges:

```lua
-- users with a post of 5 stars or more
c.User:query():hasPostsWith(function(p) p:where("stars", ">=", 5) end):all()
-- each user with their three best posts in u.posts
c.User:query():withPosts(function(p) p:order("stars", "desc"):limit(3) end):all()
-- each post with its author in p.author, a row or nil
c.Post:query():withAuthor():all()
```

A `has` filter that reads part of its table through an index runs first,
and the rows linked to its matches become the candidates. `explain` shows
this as `has posts from (by_stars range stars)`. Any other `has` checks the
edges of each candidate row, which `explain` shows as `has posts`. A `has`
filter with `order`, `limit`, `offset` or `with` raises an error.

`with` runs after the outer query's `limit`, one query per answered row,
and only for `all` and `first`. An edge with one row at its far end loads a
row or `nil`; any other edge loads a list. Loaded edges are extra keys on
the row, so pass `update` only the fields to change.

Errors start with `ENT`, or with `ROWCODEC` for a value of the wrong kind or
a missing required field. `ent.CLIENT` runs a self-check inside a
transaction it rolls back and answers `ok`.

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
