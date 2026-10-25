# Blog example

A small blog built on lent: users write posts, follow each other and star
posts. It shows a schema module, `MIGRATE`, `CLIENT` writes in a transaction,
and queries that follow edges.

`package.luau` does not load `examples/`, so install it yourself. The lent
modules must be in the `lent` space first, which `barchd -g` or
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
`schema.luau` and run `SETF` for it again.

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

Ids are `barch.uuid()` strings, which grow over time, so `posts` and
`timeline` sort by id, highest first. Pass the id `post` answered to `star`.

```
CALLF BLOG user ann@x Ann        -> "019a1f3c-7d2e-7a41-9b3c-5e6f7a8b9c0d"
CALLF BLOG user cy@x Cy          -> "019a1f3c-7d31-7c02-8e15-2a3b4c5d6e7f"
CALLF BLOG post ann@x hello hi   -> "019a1f3c-7d35-7f19-a4d6-0b1c2d3e4f50"
CALLF BLOG follow cy@x ann@x     -> OK
CALLF BLOG star 019a1f3c-7d35-7f19-a4d6-0b1c2d3e4f50   -> 1
CALLF BLOG timeline cy@x         -> 1) "019a1f3c-7d35-7f19-a4d6-0b1c2d3e4f50 1 hello"
```

## Errors

| Error | Cause |
|---|---|
| `BLOG has no user <email>` | no user has that email |
| `BLOG has no post <id>` | `star` names a post that does not exist |
| `LENT table Post wants a uuid id, got <id>` | `star` names something that is not a lowercase uuid |
| `BLOG wants a count of 1 or more, got <n>` | `n` is not a whole number of 1 or more |
| `BLOG has no command <name>` | the first argument is not a command above |
| `LENT table User index by_email is unique, and row <id> already has email=<email>` | `user` reuses an email |

A command that fails changes nothing.
