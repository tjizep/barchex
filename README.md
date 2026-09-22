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
