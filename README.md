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
```

USERS keeps `user:`, `sess:` and `admin:` keys in `spaces`. With none yet,
the viewer treats you as a local admin. It does not use a `users` key space.

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

`SPACESUI` only answers if HTTP is started in the `spaces` space.
