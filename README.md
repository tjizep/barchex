# barchex

Extensions for barch, as a git repository `FUNCTIONS SYNC` can install.

A top-level folder is a key space of that name. Do not set
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
```

USERS keeps `user:`, `sess:` and `admin:` keys in `spaces`. With no admin
yet, the viewer treats you as a local admin, and the first account to
register — or the first existing account to sign on — becomes admin.
It does not use a `users` key space.

VECTORS is the `examples/hnsw` index with nk vectors instead of words.
`vectors.SET <name> <buffer>` stores a point, the vector as ONE argument:
a packed f32 buffer (dim*4 bytes, e.g. Python `struct.pack('<384f', *vec)`).
`vectors.CLOSEST <buffer> [k]` answers the nearest name, or name/distance
pairs with k — one arg per component is NOT accepted (the colon form
`vectors:SET` is parsed by the builtin SET first, which treats a third arg
as an EX/NX/GET option and refuses it before the function is reached).
Distance is cosine, switchable to `euclidean` with TUNE and back without a
rebuild; TUNE also sets M/efConstruction/efSearch/heuristic, PARAMS reports
them. Writes go through the dotted form in the space (`USE vectors` first;
the colon form writes a plain key). The console's command list
(`spaces/commands.json`) is shared; add the four VECTORS commands there
if the dropdown should offer them.

S3 works with AWS and anything that speaks its API (MinIO, R2, B2, Wasabi).
The function sandbox has no hashing and no clock, so SIGV4 brings SHA-256 and
HMAC in plain Luau, and reads the time off a key's expiry. `s3.SIGV4` (the
dotted name is the command, from any space) checks the signer against the
example requests in AWS's SigV4 documentation.
Settings are keys in `configuration`, and `s3.<profile>.<name>` overrides
`s3.<name>` for `require("s3.S3").client("<profile>")`:

```
USE configuration
SET s3.endpoint    https://s3.eu-west-1.amazonaws.com   # or http://127.0.0.1:9000
SET s3.region      eu-west-1
SET s3.access_key  AKIA...
SET s3.secret_key  ...
SET s3.path_style  1          # default 0 on amazonaws.com, 1 anywhere else
```

The secret can't be a `…password` key, because scripts can't read those and
this one has to sign. So anyone who can read `configuration` can see it.

From a stored function, inside the handler rather than at the top:

```lua
local s3 = require("s3.S3")
local body, why = s3.get("bucket", "path/key")     -- nil and why.status 404 if missing
s3.put("bucket", "path/key", body, "text/plain")
local page = s3.list("bucket", { prefix = "path/", delimiter = "/" })
local url = s3.presign("bucket", "path/key", 3600)
```

`s3.S3 LS bucket [prefix]`, `GET`, `STAT`, `PUT`, `DEL`, `URL`, `BUCKETS`
and `CHECK` do the same from a RESP connection (or `CALLF S3 …` in the `s3`
space); calling out needs the `outbound` ACL category. They don't work from
the viewer's Call box or Console yet: those run CALLF from inside an HTTP
handler, and barch refuses a nested CALLF whose function waits on the network
("cannot call 'CALLF', it blocks"). A file source isn't affected, because
barch calls it directly.

A space's file store can read through to a bucket: a missing file is fetched
from it the first time it's asked for, and it's an ordinary stored file after
that. Set the options before the space is first loaded (barch reads them when
it loads a space), then add the two small functions to it:

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

The listing offers a bucket's objects one level at a time. A sub-folder shows
up once something in it has been fetched, because barch lists a source's names
as files. The viewer's Files tab shows what has been fetched.

Known barch issue (0.5.8): a string a stored function returns loses its first
byte if that byte is `$`. barch keeps a leading `$` on RESP bulk strings as a
marker and strips it when reading one back, and a Luau string that starts with
`$` is taken for a marked one. Through a file source that means an object whose
content starts with `$` is stored a byte short, and a name starting with `$` is
listed without it. Fetch those through `s3.get` in your own code until barch
is fixed.

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

`as = keys` is required: `as = fs` would put the Luau in the file store and
it would never become a function.

`SPACESUI` only answers if HTTP is started in the `spaces` space. The HTTP
user also needs the rights the page's own buttons ask of it: `SETUSER` states
the whole rule, and `+dangerous` is what lets Import and Export through
(`IMPORT` carries the `dangerous` category; `EXPORT` does not).

```
ACL SETUSER web on +read +write +data +keys +function +config +dangerous
```

`+admin` is not a grantable right — `admin` is a preset name, and the command
requirements that say `admin` are ignored by `cats2vec` — so a `SETUSER` that
includes it fails with `ACL category not found`.
