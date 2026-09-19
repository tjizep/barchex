# barchex

The key-space viewer from the barch shop example, as a git repository
`FUNCTIONS SYNC` can install.

| File | What git sync does with it |
|---|---|
| `spacesapi.luau` | stored function `SPACESAPI` — `GET`/`POST /api/admin/*` |
| `spacesui.luau` | stored function `SPACESUI` — `GET /spaces` |
| `spaces.html` | ordinary key `spaces.html` (not a file-store file) |

A git repository is the truth for **one key space's functions**. Syncing this
into `shop` would delete `SHOPAPI`, `SHOPUI` and the rest. Install it into a
space of its own:

```
CONFIG SET functions_dir /home/test/shop-run/functions

USE configuration
SET git/repositories/barchex/url    https://github.com/tjizep/barchex.git
SET git/repositories/barchex/pull   on
SET git/repositories/barchex/branch main
SET git/repositories/barchex/space  barchex
SET git/repositories/barchex/as     keys

FUNCTIONS SYNC barchex
FUNCTIONS STATUS
USE barchex
KEYSF
```

`as = keys` is required: `as = fs` would put the Luau in the file store and
it would never become a function.

To publish onto a shop that is already serving HTTP (same port, without
replacing the shop's other functions):

```
USE barchex
GETF SPACESAPI
USE shop
SETF SPACESAPI <that source> RELOAD
FS PUT /app/spaces.html <spaces.html>
```

`SPACESUI` only answers if the HTTP conf lists it.
