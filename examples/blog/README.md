# Blog example

A small blog built on ent: users write posts, follow each other and star
posts. It shows a schema module, `MIGRATE`, `CLIENT` writes in a transaction,
and queries that follow edges.

`package.luau` does not load `examples/`, so install it yourself. The ent
modules must be in the `ent` space first, which `barchd -g` or
`FUNCTIONS SYNC` gives you.

## Install

`BLOG` requires `blog.SCHEMA`, so put the schema in a space named `blog`.
`BLOG` keeps its rows in the space it runs in; install it in the space that
should hold the data:

```
USE blog
SETF SCHEMA "<contents of examples/blog/schema.luau>"
USE myblog
SETF BLOG "<contents of examples/blog/blog.luau>"
CALLF BLOG migrate
```

`migrate` answers the schema version. Call it again after you change
`schema.luau` and run `SETF` for it again. A second `SETF` of a function that
already exists answers `OK`, but current barch keeps running the first body,
so give the changed function a new name or install it in a new space.

## Commands

Each command runs in one transaction. Post lists answer one
`<id> <stars> <title>` line per post, and `n` defaults to 10.

| Command | Answers |
|---|---|
| `CALLF BLOG migrate` | the schema version |
| `CALLF BLOG user <email> <name>` | the new user's id |
| `CALLF BLOG post <email> <title> <body>` | the new post's id |
| `CALLF BLOG follow <email> <other email>` | `OK` |
| `CALLF BLOG star <post id>` | the post's stars after the star |
| `CALLF BLOG posts <email> [n]` | the user's newest `n` posts |
| `CALLF BLOG timeline <email> [n]` | the newest `n` posts by the users they follow |
| `CALLF BLOG top [n]` | the `n` posts with the most stars |

Ids grow over time, so `posts` and `timeline` sort by id, highest first.

```
CALLF BLOG user ann@x Ann        -> 1
CALLF BLOG user cy@x Cy          -> 2
CALLF BLOG post ann@x hello hi   -> 1
CALLF BLOG follow cy@x ann@x     -> OK
CALLF BLOG star 1                -> 1
CALLF BLOG timeline cy@x         -> 1) "1 1 hello"
```

## Errors

| Error | Cause |
|---|---|
| `BLOG has no user <email>` | no user has that email |
| `BLOG has no post <id>` | `star` names a post that does not exist |
| `BLOG wants a count of 1 or more, got <n>` | `n` is not a whole number of 1 or more |
| `BLOG has no command <name>` | the first argument is not a command above |
| `ENT table User index by_email is unique, and row <id> already has email=<email>` | `user` reuses an email |

A command that fails changes nothing.
