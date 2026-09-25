# barchex

Extensions for barch, packaged as a git repository that `FUNCTIONS SYNC` can
install.

A top-level folder becomes a key space with that name. Do not set
`git/repositories/barchex/space` — that would dump every folder into one
space and wipe whatever functions were already there.

```
spaces/
  spacesapi.luau   →  function SPACESAPI  (GET/POST /api/admin/*)
  spacesui.luau    →  function SPACESUI   (GET /spaces)
  users.luau       →  function USERS      (accounts in this space)
  spaces.html      →  key spaces.html
vectors/
  vectors.luau     →  function VECTORS    (vectors.SET/CLOSEST/TUNE/PARAMS)
  vgraph.luau      →  required by VECTORS (HNSW graph over nk f32 vectors)
s3/
  s3.luau          →  function S3         (S3 client, file source, CALLF S3 …)
  sigv4.luau       →  function SIGV4      (SHA-256, HMAC and AWS SigV4 in Luau)
  backup.luau      →  function BACKUP     (a key space to a bucket and back)
watchdog/
  watchdog.luau    →  function WATCHDOG   (mail or webhook when error rates climb)
```

USERS keeps `user:`, `sess:` and `admin:` keys in `spaces`. Until an admin
exists, the viewer treats you as a local admin. The first account to register
— or the first existing account to sign on — becomes admin.
It does not use a `users` key space.

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
first; the colon form writes a plain key). The console shares its command list
(`spaces/commands.json`); add the four VECTORS commands there
if the dropdown should offer them.

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
These commands do not work from the viewer's Call box or Console yet: those
run CALLF from inside an HTTP handler, and barch refuses a nested CALLF whose
function waits on the network ("cannot call 'CALLF', it blocks"). A file
source is not affected because barch calls it directly.

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
USE spaces
KEYSF
```

`as = keys` is required: `as = fs` would put the Luau in the file store, where
it would never become a function.

`SPACESUI` only answers when HTTP is started in the `spaces` space. The HTTP
user also needs the rights requested by the page's buttons: `SETUSER` states
the complete rule, and `+dangerous` lets Import and Export through
(`IMPORT` carries the `dangerous` category; `EXPORT` does not).

```
ACL SETUSER web on +read +write +data +keys +function +config +dangerous
```

`+admin` is not a grantable right — `admin` is a preset name, and command
requirements that say `admin` are ignored by `cats2vec`. A `SETUSER` that
includes it therefore fails with `ACL category not found`.
