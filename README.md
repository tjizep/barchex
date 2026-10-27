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
  client.luau      →  function CLIENT     (lent rows, edges and queries)
docs/
  lent-design.md   →  the plan for lent, an ORM over barch transactions
examples/
  blog/            →  a blog on lent, installed by hand (see its README)
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
order. It is the first part of lent (Luau entities), an ORM planned in
[docs/lent-design.md](docs/lent-design.md). Require it from any space:

```lua
local kc = require("lent.KEYCODEC")
local key = "lent.i.user.by_age" .. kc.pack({ "int", "string" }, { 42, "ann" })
local values, next = kc.unpack(key, 2, #"lent.i.user.by_age" + 1)  -- { 42, "ann" }
local lo = "lent.i.user.by_age" .. kc.encode("int", 42)
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
| `enum` | a string label; SCHEMA and ROWCODEC check the allowed values | byte order of the label |
| `bytes` | any bytes in a Luau string | the same byte order as `string` |

`nil` encodes as null for every kind and sorts before every value. `encode`
raises an error for a value of the wrong kind, a fractional or out-of-range
`int`, NaN, and a uuid that is not 36 lowercase characters. Encoded values
contain no space, NUL or `\1` byte, which barch would otherwise read as a
tuple separator or refuse, and which earlier barch builds cut short in a
range. Start each key with a prefix that begins with a letter, such as
`lent.`, so barch keeps the whole key as text. `after(prefix)` answers the
exclusive upper bound for a range over every key that starts with `prefix`.
`lent.KEYCODEC` runs the module's self-check and answers `ok`.

ROWCODEC turns a row table into a stored value and back. Compile the
table's fields once with `fields`, then call `encode` with a format and the
schema version, and `decode` with the stored value:

```lua
local rc = require("lent.ROWCODEC")
local users = rc.fields({
    { name = "email", kind = "string", id = 1 },
    { name = "age", kind = "int", id = 2, optional = true },
})
barch.store.set("lent.r.user.1", rc.encode(users, "binary", 3, { email = "a@b", age = 41 }))
local row, version, format = rc.decode(users, barch.store.get("lent.r.user.1"))
```

| field key | required | values |
|---|---|---|
| `name` | yes | a letter, then letters, digits and `_` |
| `kind` | yes | `string`, `int`, `float`, `bool`, `time`, `enum`, `json` or `bytes`; `time` uses integer storage |
| `id` | yes | 1 to 65535, unique in the table; keep it when the field is renamed |
| `optional` | no | `true` lets the row leave the field nil; default `false` |
| `values` | for `enum` | a non-empty list of distinct, non-empty UTF-8 strings |

| format | stored value | limits |
|---|---|---|
| `json` | a JSON object keyed by field name, with the version in `_v` | string fields must be UTF-8; floats must be finite; bytes use hexadecimal strings |
| `text` | `t<version>`, then a tab and `<id>=<value>` per field | bytes use hexadecimal strings; JSON values use escaped JSON text |
| `binary` | `b`, a u32 version, then an id, a tag and a value per field | bytes use raw data; JSON values use length-prefixed JSON text |

Bytes round-trip in all three formats. Hexadecimal storage takes two
characters per byte in `json` and `text` rows; use `binary` for compact byte
storage. JSON field validation applies in every row format.

`encode` raises an error for a key the fields do not define, a missing value
for a field that is not optional, a value of the wrong kind, NaN, and a
version outside 0 to 2^32-1. `decode` reads every format and answers the
row, the schema version it was written with and the format. A row written
with an older field list reads with the current one: added fields are nil,
values for removed fields are skipped, an `int` value reads into a `float`
field, and a whole-number `float` value in range reads into an `int` field.
Enum values use string storage, so they also read as strings. Use MIGRATE
to check a schema change's storage compatibility. `lent.ROWCODEC` runs the
module's self-check and answers `ok`. The codecs and schema use
`lent.VALUES` for structured value handling; install it with the other lent
modules. `lent.VALUES` also answers `ok` for its self-check.

SCHEMA declares lent tables in Luau. `lent.schema` checks one table and
`lent.graph` checks the tables together; each raises an error that starts with
`SCHEMA` and names the problem:

```lua
local lent = require("lent.SCHEMA")
local User = lent.schema "User" {
    format = "json",                              -- default "binary"
    fields = {
        lent.field.string "email":unique(),        -- adds unique index by_email
        lent.field.string "name",
        lent.field.int "age":optional(),
        lent.field.bool "admin":default(false),
    },
    edges = { lent.edge.to "posts" "Post" },
    indexes = { lent.index("name", "age") },       -- index by_name_age
}
local Post = lent.schema "Post" {
    id = "int",                                   -- ids 1, 2, 3, ...
    fields = { lent.field.string "title" },
    edges = { lent.edge.from "author" "User":ref "posts":unique() },
}
local app = lent.graph { User, Post }
local version, fields = lent.ids(User, previous)   -- fields for rc.fields
```

| builder | modifiers |
|---|---|
| `lent.field.string`, `.int`, `.float`, `.bool`, `.time` | `:optional()`, `:unique()`, `:default(v)`, `:was("old_name")`, and the value rules below |
| `lent.field.enum` | the same modifiers, plus required `:values("choice", ...)` |
| `lent.field.bytes` | the same modifiers and byte-length rules |
| `lent.field.json` | `:optional()`, `:default(v)`, `:was("old_name")`, `:immutable()`, `:validate(fn)` and `:updateDefault(fn)` |
| any field builder | `:computed(fn)`, and `:stored(revision)` to store it; see computed fields below |
| `lent.index(field, ...)` | `:unique()`, `:name("by_x")` |
| `lent.edge.to "name" "Table"` | `:unique()`, `:fields { ... }` |
| `lent.edge.from "name" "Table"` | `:ref "to_edge"` (required), `:unique()` |
| `lent.edge.through "name" "Table"` | `:via "edge.edge"` (required), `:stored()`; see path edges below |

Fields, indexes and edges can also be plain tables of the same options.
Each option takes the modifier's name, and `true` stands for a modifier
without an argument. This declares the same `Post` as above:

```lua
local Post = lent.schema "Post" {
    id = "int",
    fields = { { kind = "string", name = "title" } },
    edges = {
        { dir = "from", name = "author", target = "User", ref = "posts", unique = true },
    },
}
```

| plain table | keys |
|---|---|
| field | `kind` and `name` (required), `values` (required for `enum`), `optional`, `unique`, `default`, `was`, `computed`, and the value rules below; `validate` takes a function or a list of them |
| index | `on`, a list of field names (required), `unique`, `name` |
| edge | `dir`, `"to"`, `"from"` or `"through"`, `name` and `target` (required), `ref`, `unique`, `fields`, `via` (a dotted string or a list of names), `stored` |

A plain table goes through the same checks as the builder, and a key it
does not recognise raises an error, so a misspelt option fails when the
schema loads. The two forms can be mixed in one table.

Every table has a primary key named `id`, so a field cannot use that name.
By default each new row's id is a `barch.uuid()` string, such as
`019a1f3c-7d2e-7a41-9b3c-5e6f7a8b9c0d`. Ids from one server sort in creation
order, and creates in one table never conflict over the id. Set
`id = "int"` for ids 1, 2, 3 and so on from a counter per table, which makes
concurrent creates in that table conflict and retry. A table keeps its id
kind once it has a catalog; see MIGRATE. A table's keys use its name in snake case, so `BlogPost` stores as
`blog_post`. `lent.edge.to "posts" "Post"` on `User` stores as `user_posts`,
and an `lent.edge.from` reads that edge backwards.

A `time` field holds Unix milliseconds as an integer. `lent.now()` answers
the current time that way, from `barch.time()`. In a call replayed from a
Raft log, it answers the time the entry was logged, so every member stores
the same value.

Enums hold one of the strings listed in `:values`. The choices must be
distinct, non-empty UTF-8 strings. Enum fields support indexes, unique
constraints, comparisons and cursor pages. Their order is the byte order
of their labels, so changing the declaration order leaves query ordering
the same.

Bytes fields hold Luau strings containing arbitrary bytes, including NUL
and invalid UTF-8. They support indexes, unique constraints, comparisons,
cursor pages and byte-length rules. JSON fields hold structured values:

```lua
local Document = lent.schema "Document" {
    fields = {
        lent.field.enum "state":values("draft", "published"):default("draft"),
        lent.field.bytes "content":optional():maxLen(1048576),
        lent.field.json "metadata":default({ tags = lent.jsonArray(), properties = {} }),
    },
    indexes = { lent.index("state") },
}
```

For JSON, use plain tables with string keys for objects and dense lists
numbered from 1 for arrays. `{}` is an empty object; use `lent.jsonArray()`
for an empty array, or `lent.jsonArray(list)` to mark a list as an array.
Strings, finite numbers and booleans are also valid JSON values. Use
`simdjson.null` for JSON null. Leave a field `nil` to use its create default,
or mark it `:optional()` to allow a missing value.

Use `lent.parseJson(text)` to parse JSON input and
`lent.encodeJson(row.metadata)` to emit a JSON field value. These helpers
preserve empty arrays and objects. JSON strings and object keys must be
UTF-8, object keys must be unique, and nesting is limited to 128 object or
array levels. Cycles, sparse or mixed-key arrays, functions, NaN and infinity
raise an error. `lent.parseJson` preserves signed 64-bit integer tokens
exactly; values outside the exact Luau-number range (`±2^53`) use barch's
native `integer` type. Other JSON numbers use Luau numbers.

`where("metadata", "=", value)` and `~=` compare JSON structurally: object
key order is ignored, array order matters, and an empty array differs from
an empty object. Use `where(fn)` to filter nested properties. JSON fields
reject indexes and unique constraints when the schema loads, and reject
ordering and range comparisons in queries.

Each row receives its own copy of a JSON default. Writes copy JSON inputs
before hooks run, and hooks receive an independent `old` snapshot. An
immutable JSON field compares by value, so an equal replacement is allowed
and an in-place nested change is refused. Updating a JSON field replaces
its whole value.

Value rules check each value that `create` and `update` write:

```lua
lent.schema "Post" {
    fields = {
        lent.field.string "title":notEmpty():maxLen(80),
        lent.field.string "slug":match("^[%l%d-]+$"):unique():immutable(),
        lent.field.int "stars":min(0):max(5):default(0),
        lent.field.string "body":validate(function(v)
            return not string.find(v, "spam") or "no spam"   -- the refusal's reason
        end),
        lent.field.time "created_at":default(lent.now):immutable(),
        lent.field.time "updated_at":default(lent.now):updateDefault(lent.now),
    },
    hooks = {
        create = { function(c, row)
            row.slug = row.slug or (string.gsub(string.lower(row.title), "%W+", "-"))
        end },
    },
}
```

| modifier | fields | effect |
|---|---|---|
| `:min(n)`, `:max(n)` | `int`, `float`, `time` | the value is at least or at most `n` |
| `:minLen(n)`, `:maxLen(n)` | `string`, `enum`, `bytes` | the value's length in bytes is at least or at most `n` |
| `:notEmpty()` | `string`, `enum`, `bytes` | the same as `:minLen(1)` |
| `:match(pattern)` | `string`, `enum` | the value contains a match for the Luau string pattern; anchor it with `^` and `$` to match the whole value |
| `:validate(fn)` | any | `fn(value)` refuses the value by answering `false` or a message, or by raising an error; a field may have several |
| `:immutable()` | any | `update` refuses to change the value |
| `:default(fn)` | any | `create` calls `fn()` when the row leaves the field nil |
| `:updateDefault(fn)` | any but immutable | `update` calls `fn()` when the update leaves the field unchanged |

Enum choices, `:min`, `:max`, `:minLen`, `:maxLen`, `:match` and `:immutable`
are stored in the catalog, so every client of the space enforces them once
`migrate` has run. A new rule applies to later writes; it leaves stored rows
as they are.
`update` checks only the values it changes.

Functions stay in code: `:validate`, `:updateDefault`, a function
`:default`, `:computed`, hooks and policies run only in a client opened with
the graph; see `lent.open` under CLIENT. A function default fills only new rows, so a new
required field also needs a value default, or `:optional()`, for the rows
stored before it.

Declare hooks under `create`, `update` and `delete`, each with a list of
functions as in the example above. Each list is optional and defaults to
empty. Hooks run before the write, inside its transaction, in list order:

| hook | called as | runs |
|---|---|---|
| `create` | `fn(c, row)` | after defaults, before the value rules |
| `update` | `fn(c, id, row, old)` | after `updateDefault`, before the value rules |
| `delete` | `fn(c, id, old)` | when the row exists, before it is removed |

`lent.hook.create(fn)`, `lent.hook.update(fn)` and `lent.hook.delete(fn)` also
declare hooks as list entries, such as `hooks = { lent.hook.create(fn) }`.
You can combine these entries with the named operation lists. For each
operation, the builder entries run in list order, followed by the functions
in its named list. Unknown operation names, invalid lists and non-function
entries in a named list raise a `SCHEMA` error when the schema loads.

A hook may change `row` and may read and write other tables through `c`.
An error it raises refuses the write and takes back what the hook wrote, as
described for `lent.tx` below.

Declare a `policy` to decide which rows a viewer reads and which writes a
viewer makes, as in Go ent's privacy layer. `query` rules run when a query
starts, and `mutation` rules run before each write's hooks:

```lua
lent.schema "Post" {
    fields = { lent.field.string "title", lent.field.bool "public":default(false),
               lent.field.int "owner" },
    policy = {
        query = {
            function(c, viewer, q)
                if viewer and viewer.admin then return lent.allow end
            end,
            function(c, viewer, q)
                -- everyone reads public posts; members also read their own
                local id = viewer and viewer.id
                q:where(function(r) return r.public or r.owner == id end)
            end,
        },
        mutation = {
            function(c, viewer, m)
                if viewer == nil then return lent.deny("sign in") end
                -- c reads every post, so the rule sees the stored owner
                if m.op ~= "create" and c.Post:get(m.id).owner ~= viewer.id then
                    return lent.deny("not the owner")
                end
            end,
        },
    },
}
```

Each part is an optional list of functions, called in list order as
`fn(c, viewer, q)` or `fn(c, viewer, m)`. A rule answers `lent.allow` to let
the call through, `lent.deny` or `lent.deny("reason")` to refuse it, or `nil`
to leave the decision to the next rule. When every rule answers `nil`, the
call goes ahead; end a list with a rule that answers `lent.deny` to refuse
whatever the rules before it leave undecided. A refusal raises
`LENT table Post policy denies <call>`, followed by `: reason` when the rule
gave one, such as `LENT table Post policy denies update of row 3: not the
owner`. Any other answer raises an error that names the rule.

`viewer` is the value given to `db.tx` or `db.client`; see `lent.open` under
CLIENT. `c` is a client of the same transaction that runs no policy, so a
rule can read rows the viewer cannot read. Hooks get the viewer's client, so
their reads and writes go through the policies.

A query rule receives the new query `q` and narrows it with `where` or
`has`. The rules run for every query on the table, including those that
`get`, `by`, `follow`, `with` and each hop of a multi-edge `follow` make, so
those calls answer only the rows the viewer can read. Query `update` and
`delete` write only those rows. `has` filters and `links` queries read links
without the far table's query rules, as Go ent's edge predicates do, which
lets a rule filter with `has`. `edge` answers `nil` when the viewer cannot
read either row. An `edge.through` reaches its target without the rules of
the tables between.

A mutation rule receives `m`, whose fields depend on `m.op`:

| `m.op` | fields of `m` | runs for |
|---|---|---|
| `create` | `row`, after defaults | `create`, `createMany` and an `upsert` that creates |
| `update` | `id`, `row` after `updateDefault`, `old` | `update`, query `update` and an `upsert` that updates |
| `delete` | `id`, `old` | `delete` and query `delete` when the row exists |
| `link` | `edge`, `id`, `other`, `values` | `link`, and each link that `create` makes after its `create` rules |
| `unlink` | `edge`, `id`, `other` | `unlink` |

The table whose method makes the call runs its rules: `c.User:link("posts",
u, p)` runs User's rules and leaves Post's alone. Deleting a row removes its
links without `unlink` rules.

Use `:computed(fn)` for a value derived from the row each time it is read,
such as the time between two `time` fields:

```lua
lent.schema "Shift" {
    fields = {
        lent.field.time "clockIn",
        lent.field.time "clockOut":optional(),
        lent.field.int "worked":computed(function(r)
            return r.clockOut and r.clockOut - r.clockIn   -- nil while open
        end),
    },
}
-- total hours per user
c.Shift:query():groupBy("user"):aggregate { worked = { fn = "sum", field = "worked" } }
```

The client calls `fn(row)` for every row it answers, from `get`, `by`,
`create`, `update` and queries, and for the `old` row hooks receive. `row`
holds the stored fields, `id` and the computed fields declared before this
one. A `nil` answer means the field has no value; any other answer must fit
the field's kind, or the read raises an error.

Use a computed field by name in `where`, `order`, `cursor`, `groupBy` and
aggregates. A computed field without `:stored()` keeps no value in the row,
which has these consequences:

- A query checks a filter on a computed field against each row it reads,
  so the filter never picks an index. An index on a computed field raises
  a `SCHEMA` error.
- `create`, `update` and query `update` raise an error for a value or a
  `clear` of a computed field.
- A computed field takes no option except an enum's `:values` and
  `:stored()`.
- `migrate` ignores computed fields, so adding, changing or removing one
  needs no migration and applies to every row at once.
- Like hooks, computed fields exist only in a client opened with the graph.
  A plain client raises `has no field` when a query names one.

Add `:stored()` to keep the value in the row, so an index can use it:

```lua
lent.schema "Shift" {
    fields = {
        lent.field.time "clockIn",
        lent.field.time "clockOut":optional(),
        lent.field.int "worked":computed(function(r)
            return r.clockOut and r.clockOut - r.clockIn
        end):stored(),
    },
    indexes = { lent.index("worked") },
}
```

In a plain table, set `stored = true`, or the revision number.

The client calls the function on `create`, `update`, query `update` and
`upsert`, after the hooks run, and stores the answer. `row` holds the
row's stored fields, without `id`, and the new values of the stored
computed fields declared before this one. A `nil` answer stores no value;
any other answer must fit the field's kind, or the write raises an error.

- Reads answer the stored value without calling the function, so a client
  opened without the graph reads it too. Writing rows of the table from
  such a client raises an error, because it cannot compute the value.
- A stored computed field may be `:unique()`, named in an index and renamed
  with `:was()`. It takes no other option except an enum's `:values`.
- `migrate` computes the field for the rows stored before it: when you add
  a stored computed field, or turn a stored field into one. It fills the
  rows in pages before it builds the field's indexes; see MIGRATE.
- Changing the function leaves stored values as they are. Raise the
  revision with the change, as in `:stored(2)`, and `migrate` computes
  every row again and rebuilds the indexes on the field. Until then, a
  client opened with the new graph raises
  `is declared with stored revision 2, and this space's catalog has stored revision 1; run MIGRATE`.

`lent.ids(table, previous)` gives each field a ROWCODEC id. Pass `nil` for a
new table, or the first answer of the previous version's call. A field keeps
its id under its name or its `:was` name, and new fields are numbered after
the highest id ever used, so a dropped field's id is never reused.
`lent.SCHEMA` runs the module's self-check and answers `ok`.

LAYOUT names the store keys lent uses in the application's space: rows
(`lay.row(t, pk)`), index entries (`lay.entry(t, ix, row, pk)`), edges and a
table's pk counter. `lay.walk(prefix, each)` calls `each(key)` for every key
under a prefix, a page at a time, and `each` may remove the key it is given.
`lay.scan(lo, hi, each)` and `lay.scan_back(lo, hi, each)` call `each(key)`
for the keys in `[lo, hi)`, in key order or highest first, and stop when
`each` answers `true`. `lay.scan_values(lo, hi, each, first)` and
`lay.scan_back_values(lo, hi, each, first)` call `each(key, value)` the same
way. Their first page holds `first` keys, 1000 by default, and each later
page twice as many up to 1000; pass a small `first` when `each` will stop
early.
`lent.LAYOUT` runs the module's self-check and answers `ok`.

MIGRATE applies a schema and builds or removes its indexes in bounded
pages. Call `migrate` from the application's space with the answer of
`lent.graph`, outside an open transaction:

```lua
local m = require("lent.MIGRATE")
local report = m.migrate(app, 1000)
local compiled = m.load()      -- the active schema, or nil before the first migration
```

Call it again with the same schema in later stored-function calls until
`report.done` is `true`. Each call runs in one `barch.tx.run` transaction
and persists its progress under `/lent` in the space's graph. Separate
function calls give each page its own function deadline.

The optional page size defaults to `1000` and accepts whole numbers from
`1` to `10000`. It bounds the total row visits and removed index entries
across all indexes in that call. Each fill and index build visits every
row, including rows whose missing values leave them out of a unique index.

| report field | meaning |
|---|---|
| `version` | the active schema version; it advances on the first committed page and stays the same while the migration resumes |
| `changed` | `true` when this call installs a schema or advances pending work |
| `done` | `true` when every index drop, fill and build is complete |
| `processed` | row visits plus removed index entries in this call, at most the page size |
| `steps` | the migration's list of `drop Table.index`, `fill Table.field,...` and `build Table.index` operations, in that order, with `drop Table.edge` and `fill Table.edge` for stored path edges; empty for an unchanged, completed schema |

The target schema becomes active with the first committed page. An index
being built has `state = "building"` in its `m.load().tables` index entry
and its `/lent/tables/<table>/indexes/<index>/spec` JSON. Ready indexes have
no `state` field. The last index entries and the readiness change commit
together.

A fill computes stored computed fields, described with SCHEMA, for the rows
stored before them and writes each row again. While it runs, the fields
have `state = "filling"`, and a client opened with the graph computes them
on every read, so reads answer the new values before the fill reaches a
row. A client opened without the graph reads the stored values, which are
missing or old until the fill reaches the row.

Queries choose ready indexes or read the table while an index builds.
`using`, `by` and `upsert` raise a `LENT` error if they request a building
index. Creates, updates and deletes maintain building indexes. Successful
writes of new or changed indexed values scan the table to check uniqueness
while a unique index is building, so these writes can cost more until the
build finishes.

Index replacements and removals drop old entries first. Creating, updating
or deleting rows in an affected table raises a `LENT` error until that
table's pending drops finish. Reads continue, and other tables remain
writable.

An error or timeout rolls back the current page; earlier pages and their
schema changes stay committed. Call `migrate` with the same schema to
resume. Reduce the page size if a page times out. If a unique build finds
duplicate stored values, find the rows with a query, correct or delete the
duplicates, then resume. Finish the pending migration before changing the
schema again.

A migration that fits in one page remains atomic. Once a migration is
complete, calling it with the same schema writes nothing and answers
`changed = false`, `done = true` and the current version.

`migrate` raises an error that starts with `MIGRATE` for unsupported schema
changes or a unique-index conflict:

- a table missing from the schema;
- a new field that is neither `:optional()` nor has a value `:default()`;
- a kind change other than `int` to `float`, `int` to or from `time`, or
  `enum` to `string`;
- removing a value from an enum's choices;
- a field rename in a table that has stored `json` rows;
- a unique index whose values two stored rows already share;
- a stored computed field whose function answers a value that does not fit
  the field for a stored row;
- a change to a table's `id` kind;
- an `edge.to` or `edge.from` that takes the name of a stored path edge in
  the same migration.

Adding enum choices preserves stored rows and their indexes. Byte and JSON
defaults are preserved in the catalog, including binary bytes, JSON null
and empty arrays; `m.load()` returns their Luau values.

`plan(previous, app)` describes a migration. The low-level `apply(plan)`
runs a whole plan inside a caller-opened transaction and refuses a pending
paged migration; use `migrate` for paged work. `lent.MIGRATE` runs the
planning self-check and answers `ok`.

CLIENT reads and writes the rows of a migrated space and keeps their indexes
current. Call `lent.tx` from the application's space:

```luau
local lent = require("lent.CLIENT")
lent.tx(function(c)
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
| `createMany(rows)` | the created rows in input order; `{}` for an empty list | the list is malformed, or any row fails `create` |
| `get(id)` | the row, or `nil` | `id` does not fit the table's id kind: a lowercase uuid, or a positive integer for `id = "int"` |
| `by(index, values...)` | the row, or `nil` | there is no such ready unique index, or the number of values differs from its fields |
| `update(id, values, clear)` | the stored row | there is no row `id`, it changes an immutable field, or as for `create` |
| `upsert(index, values)` | the row and a `created` boolean | the index is missing, building or non-unique, an indexed field is missing from `values`, or the selected `create` or `update` fails |
| `delete(id)` | `true`, or `false` if there was no row | `id` does not fit the table's id kind |

`by` takes an index name, such as `by_email`, or a field name with a unique
`by_<field>` index. Rows are tables of field values plus `id`. A field the
stored row lacks reads as its `:default()`.

To run a schema's function defaults, `:validate` functions, hooks and
policies, open the client with the graph the space was migrated with:

```lua
local db = lent.open(app)                   -- app: the answer of lent.graph
db.tx(function(c) ... end, false, viewer)   -- db.client(pessimistic, viewer) inside a transaction
```

`viewer` is optional and can be any value, such as the signed-in user's
row. The policy rules receive it, and they receive `nil` when it is left out.

`lent.open` raises an error when the graph declares a table or field that the
space's catalog lacks; run `migrate` first. Value rules stored in the catalog
apply with or without it.

`lent.tx(fn, pessimistic)` runs `fn(c)` in `barch.tx.run`, which retries on
a conflict, and answers what `fn` answers. With `pessimistic` true, a row or
unique entry about to be written is read with the exclusive lock, so two
writers of one value wait for each other. Inside a transaction you already
run, `lent.client(pessimistic)` answers the same `c`. A table with
`id = "int"` takes each new id from one counter, so concurrent creates in
that table conflict and retry.

Each write call (`create`, `createMany`, `update`, `upsert`, `delete`,
`link`, `unlink`, and query `update` and `delete`) runs in a
`barch.tx.savepoint`. When the call raises an error, every key it wrote,
including its hooks' writes, goes back to what the transaction held before
the call, and the error comes out unchanged. `fn` can catch the error and go
on with the transaction as it was. In a pessimistic transaction, the locks
the refused call took stay held until the transaction ends. Call the write
methods inside a transaction: outside one, a refused call keeps what it
wrote before the error.

Use `createMany` to create several rows and `upsert` to create or update a
row selected by a unique index:

```lua
db.tx(function(c)
    local rows = c.User:createMany {
        { email = "a@b", name = "ann" },
        { email = "c@d", name = "cy" },
    }
    local row, created = c.User:upsert("email", { email = "a@b", name = "al" })
    -- row.id is rows[1].id; created is false because that email already exists.
end)
```

`createMany` takes row-value tables numbered from 1 without gaps. It checks
the list's shape before creating any rows, then runs `create` once per row
in input order, with the same defaults, rules, hooks, indexes and edges.
The input tables keep their original values. All rows use the caller's
transaction; split large lists into separate transactions to stay within
the function deadline.

Multi-row writes (`createMany`, query `update` and query `delete`) stop at
the first error and take back every row they wrote, including the hooks'
writes. A caller that catches the error keeps the rows written by earlier
calls.

`upsert` accepts the same index names and field-name shorthand as `by`.
Supply a non-`nil` value for every field of the unique index, including all
fields of a composite index. The lookup uses these values before defaults
and hooks run. A match keeps its `id` and updates the supplied fields;
omitted fields keep their stored values, subject to `updateDefault`. A
missing match runs `create`. The returned `created` flag is `true` for a new
row and `false` for an update. Each branch runs its usual defaults, rules
and hooks, and maintains every affected index. Edge values work on the
create branch; use `link` and `unlink` to change an existing row's edges.

Concurrent upserts of the same indexed values select one row. Optimistic
transactions retry conflicts; pessimistic transactions take an exclusive
lock on the unique entry before choosing the branch.

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

An `edge.to` can store values on each link. Declare them with `:fields`, as
a table's fields, and the `edge.from` that refs the edge reads the same
values:

```lua
lent.edge.to "likes" "Post":fields {
    lent.field.time "at":default(lent.now):immutable(),
    lent.field.int "weight":default(1):min(1),
}

c.User:link("likes", u.id, p.id, { weight = 3 })  -- answers { at = ..., weight = 3 }
c.User:link("likes", u.id, p.id, { weight = 5 })  -- changes weight, keeps at
c.User:edge("likes", u.id, p.id)                  -- the values, or nil if not linked
c.Post:edge("likers", p.id, u.id)                 -- the same values from the edge.from
```

A new link fills missing values with defaults, so `create` with an edge
value links with the defaults. Linking an existing link again changes only
the values given and runs `:updateDefault` functions; with no values it
leaves the link as it is. Edge fields take the value rules, `:validate`,
`:immutable` and `:was`, and `migrate` checks their changes as it checks a
table's fields. An edge has no indexes, so its fields take no `:unique()`,
and they take no `:computed`. The names `from` and `to` hold the ends of a
link in `links` queries, so an edge field cannot use them. `migrate` accepts fields on an edge that already has links
when each new field is optional or has a stored default.

A path edge, declared with `lent.edge.through`, reaches the rows at the end
of a chain of edges. A customer reaches the products on the lines of their
orders in one step:

```lua
lent.schema "Customer" {
    fields = { lent.field.string "name" },
    edges = {
        lent.edge.to "orders" "Order",
        lent.edge.through "products" "Product":via "orders.lines.product",
    },
}

c.Customer:query():where("name", "=", "ann"):queryProducts():all()
c.Customer:query():hasProductsWith(function(p) p:where("color", "=", "red") end):all()
c.Customer:query():withProducts():all()     -- each row's products in row.products
```

`:via` takes the hops as one dotted string or as one name per argument.
The first hop is an edge of the declaring table, each later hop is an edge
of the table the hop before it reaches, and the last hop must reach the
table the path edge names. A hop may be another path edge. `graph` raises an
error naming the hop that does not fit, or a path edge that goes through
itself.

A path edge reads the links of its hops, so it reflects every `link`,
`unlink` and `delete` at once, and `migrate` only records it in the catalog.
Change its links through its hops; `link`, `unlink`, `edge` and a value
under its name in `create` or `update` raise an error. It has no fields, so
`whereEdge` inside its `has` or `with` raises an error too.

Each row a path reaches comes once, however many paths lead to it. Each hop
scans the edges of the distinct rows the hop before it reached, so the cost
grows with the number of distinct rows along the path, and a path from a few
rows stays cheap. A path edge is unique when every hop is unique, as a
line's `order.customer` is. A unique path edge loads a row or `nil` in
`with`, and `groupBy` can use it.

Add `:stored()` to keep a path edge's links in a store of its own:

```lua
lent.edge.through "products" "Product":via "orders.lines.product":stored()
```

Each stored link holds the number of paths between its two rows. Every
`link`, `unlink` and `delete` on a hop updates those numbers in the same
transaction, and a link goes when its last path does. Reading the edge then
scans one store, as an `edge.to` does, and `explain` names it, as in
`edge customer_products`. Writes pay for this: a link change on a hop walks
the path from that link to both ends, once for each stored path edge that
follows the hop. Store a path edge that queries read often across hops that
change rarely.

`migrate` fills a new stored path edge, or one whose `:via` changed, in
pages. It drops the store's old links, then counts the paths from each row
of the declaring table, and reports the steps as `drop Customer.products`
and `fill Customer.products`. Until the fill finishes, queries walk the
hops, and link changes keep the store current. Removing the edge or its
`:stored()` drops the store. To give an `edge.to` or `edge.from` the name of
a stored path edge, migrate once without the edge first; `migrate` raises
an error for the change in one step.

Queries read through the best index for their filters:

```lua
c.User:query()
    :where("name", "=", "ann")            -- = ~= < <= > >=
    :where("age", ">", 30)
    :where(function(r) return r.age % 2 == 0 end)
    :order("age", "desc"):offset(10):limit(10)
    :all()                                -- or first, ids, count
c.User:query():where("id", "=", u.id):queryPosts():all()  -- follow an edge
c.Customer:query():follow("orders.lines.product"):all()   -- follow several
```

| method | effect |
|---|---|
| `where(field, op, value)` | keeps rows where the comparison holds; a missing field equals `nil`, differs from non-`nil` values and fails range comparisons |
| `where(fn)` | keeps rows for which `fn(row)` is true |
| `order(field, dir)` | sorts by `field`, `"asc"` by default or `"desc"`; `asc` puts equal values in id order and missing values first, and `desc` reverses both |
| `limit(n)`, `offset(n)` | applied after the order |
| `cursor(row)` | a string that marks `row`'s place in the query's order |
| `after(cursor)` | keeps the rows after the cursor's row; with no `order`, the query orders by id |
| `using(name)` | reads through the named ready index, or `"id"` for the table |
| `follow(edge, ...)`, `query<Edge>()` | a query over the rows the matches reach through the edges, hop by hop; `follow("a.b")` equals `follow("a", "b")` |
| `has(edge)`, `has<Edge>()` | keeps rows with at least one link through `edge` |
| `has(edge, fn)`, `has<Edge>With(fn)` | keeps rows linked to a row that matches the query `fn(q)` builds with `where`, `has` and `using` |
| `with(edge, fn)`, `with<Edge>(fn)` | loads each answered row's links into `row.<edge>`; `fn` is optional and may filter, order and limit them |
| `whereEdge(field, op, value)`, `whereEdge(fn)` | inside the `fn` of `has` or `with`, or on the answer of `follow`, keeps the linked rows whose link values match, as `where` does for fields |
| `links(edge)` | a query over the links of the matches through an `edge.to` or `edge.from`, one row per link holding `from`, `to` and the link's values |
| `all()`, `first()`, `ids()`, `count()` | runs the query |
| `sum(field)`, `min(field)`, `max(field)` | runs the query and answers one aggregate |
| `aggregate(spec)`, `groupBy(...):aggregate(spec)` | runs the query and answers several aggregates, for all rows or per group |
| `update(values, clear)` | updates the selected rows and answers the affected-row count; both arguments are optional, as for a row's `update` |
| `delete()` | deletes the selected rows and answers the number it removed |
| `explain()` | the plan, such as `by_name_age = name range age` or `edge customer_likes in (by_color = color)` |

Write every row selected by a query with `update` or `delete`:

```lua
db.tx(function(c)
    local updated = c.User:query():where("name", "=", "ann")
        :update({ name = "anne" }, { "age" })
    local deleted = c.Post:query():where("stars", "=", 0)
        :order("id"):limit(100):delete()
end)
```

Both methods select the same IDs as `ids()`, including `where`, `has`, edge
follows, `using`, order, offset, limit and cursor filters. They collect all
target IDs before writing, then process them in query order. Changes to
indexed values or edges keep the original selection intact, and rows added
by hooks wait for a later query.

`update` passes `values` and `clear` to each row's `update`, so value rules,
immutable fields, `updateDefault` and hooks apply to every row. Calling it
with `{}` or without arguments runs update defaults and hooks. Its count
includes a successfully processed row even when its stored values stay the
same. `delete` runs each row's delete hooks and removes its indexes and
edges in both directions. It skips targets already removed by an earlier
hook; an update of such a target raises the usual missing-row error. An
empty selection returns `0`.

These methods use the caller's transaction and the multi-row error behavior
described above. All target IDs stay in memory until the writes finish.
Use an `id` cursor and `limit` to divide large updates across transactions;
a limited delete can run in separate transactions until it returns `0`.

The query picks the index whose leading fields match the most `=` filters,
then one range filter on the next field. When that index already returns
rows in the requested order, the query stops reading at the limit.
A `desc` order reads the index from the end and stops the same way.
Otherwise `explain` ends with `then sort`, and the query reads every
matching row before sorting. A
unique index is used only when every one of its fields has an `=` filter,
because it leaves out rows with a missing value. Filters on other fields
are checked on each row read.

A query from `follow` or `query<Edge>()`, or the query `with` runs for each
row, starts from the linked ids. When its filters narrow an index, or its
`order` matches an index and it has a `limit`, it reads that index's keys
and then only the linked rows among them; `explain` shows this as
`edge customer_likes in (by_color = color)`. If the index range holds more
keys than there are linked ids, the query stops reading the index and reads
each linked row, so the index read costs at most as many keys as the
follow has links. `using(name)` reads the named index to the end of its range.
Without `order`, rows come in index order when the index is read and in id
order otherwise.

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

Use `sum`, `min` and `max` for one value over the rows a query selects:

```lua
c.Post:query():sum("stars")                              -- 0 for no rows
c.Post:query():where("kind", "=", "news"):max("stars")   -- nil for no rows
```

Use `aggregate` for several values at once. Name each result and give its
function in `fn`, and its field in `field`:

```lua
local t = c.Post:query():aggregate {
    posts  = { fn = "count" },                  -- every selected row
    scored = { fn = "count", field = "score" }, -- rows with a score
    stars  = { fn = "sum", field = "stars" },
    newest = { fn = "max", field = "at" },
}
-- t.posts, t.scored, t.stars, t.newest
```

Use `groupBy` to aggregate each group of rows. Group by fields, or by an
edge with one row at its far end, such as a post's `author`, which groups by
the linked row's id:

```lua
for _, g in c.Post:query():groupBy("author"):aggregate {
    posts = { fn = "count" }, stars = { fn = "sum", field = "stars" },
} do
    print(g.author, g.posts, g.stars)
end
```

To aggregate a value worked out from each row, give a function in `value`
in place of `field`. It receives the row with its computed fields and
answers the value, or `nil` to skip the row:

```lua
c.Post:query():aggregate {
    letters = { fn = "sum", value = function(p) return #p.body end },
    starred = { fn = "count", value = function(p) return p.stars >= 4 or nil end },
}
```

Use `value` for a one-off value; declare a computed field for a value that
queries reuse.

| function | `field` or `value` | answers | for no values |
|---|---|---|---|
| `count` | optional | the rows, or the rows with a value | `0` |
| `sum` | required; an `int` or `float` field, or a function answering numbers | the total | `0` |
| `min`, `max` | required; any field kind except `json`, or a function answering numbers, strings or booleans | the least or greatest value, in the order `order` uses | `nil` |

A spec with both `field` and `value` raises an error. For `min` and `max`, a
function must answer one type for every row; a number after a string raises
an error. Rows without a value are skipped.

`groupBy` answers one row per group, holding the group's key values under
their names and each aggregate under its name. Groups come in key order,
with missing values first, the same order an index keeps. A row without a
value, or without a link through the edge, joins the group whose key is
`nil`. Call `aggregate()` with no spec to list the distinct key values. An
aggregate with the name of a group key raises an error, and so does a
`groupBy` on a `json` field or on an edge that can link a row to many rows.

Aggregates run over the rows the query selects after its filters, order,
offset, limit and cursor, so `order("stars", "desc"):limit(10):sum("stars")`
sums the top ten. They read and hold the same rows `all()` would, so a large
selection costs what `all()` costs.

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
edges of each candidate row, which `explain` shows as `has posts`. For a
path edge, the first way walks the hops backwards from the matches, and the
second stops at the first matching row each candidate reaches. A `has`
filter with `order`, `limit`, `offset` or `with` raises an error.

`with` runs after the outer query's `limit`, one query per answered row,
and only for `all` and `first`. An edge with one row at its far end loads a
row or `nil`; any other edge loads a list. Loaded edges are extra keys on
the row, so pass `update` only the fields to change.

For an edge with fields, each row `with` loads also holds its link's values
in `_edge`, and `whereEdge` filters on them:

```lua
-- each user with the posts they liked with weight 3 or more
c.User:query():withLikes(function(p) p:whereEdge("weight", ">=", 3) end):all()
-- u.likes[1]._edge.weight is the weight of the first loaded like
```

After `follow`, `whereEdge` filters the links of the last edge followed. A
row stays when at least one link that reaches it matches:

```lua
-- the posts ann liked with weight 3 or more
c.User:query():where("name", "=", "ann"):queryLikes():whereEdge("weight", ">=", 3):all()
-- the posts that the users cy follows liked with weight 3 or more
c.User:query():where("name", "=", "cy"):follow("follows", "likes")
    :whereEdge("weight", ">=", 3):all()
```

To read the values themselves, or to count and sum over links, call
`links(edge)`. It answers a query with one row per link from the matching
rows: `from` holds the matching row's id, `to` the linked row's id, and the
other keys hold the link's values, filled with defaults. From an
`edge.from`, `from` is the row of the table that declares the `edge.from`.
An edge without fields gives rows with only `from` and `to`.

```lua
local likes = c.User:query():links("likes")
likes:where("weight", ">=", 3):order("weight", "desc"):limit(10):all()
-- { { from = 2, to = 3, weight = 5 }, { from = 3, to = 2, weight = 4 }, ... }
likes:sum("weight")
-- per post: how many users liked it and their total weight
likes:groupBy("to"):aggregate {
    likers = { fn = "count" },
    weight = { fn = "sum", field = "weight" },
}
```

A links query takes `where`, `order`, `limit`, `offset`, `groupBy`, the
aggregates, `all`, `first`, `count` and `explain`; other query methods raise
an error. It reads the links of each matching row in id order and reads
each link's values, so its cost grows with the number of links. Without
`order`, links come in `from` then `to` order and the read stops at the
limit. With `order`, it reads every link, sorts them, and puts links with
equal values in `from` then `to` order. `explain` shows the plan of the
query the links come from, as in `links user_likes from (id)`.

Errors start with `LENT`, or with `ROWCODEC` for a value of the wrong kind or
a missing required field. `lent.CLIENT` runs a self-check inside a
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
