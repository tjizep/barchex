# lent client: rows and edges

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
| `create(values)` | the row with its `id`, given or new | a given `id` does not fit the table's id kind or is taken, a unique index already holds its values, a field is unknown, a value has the wrong kind or breaks a value rule, or a required field is missing |
| `createMany(rows)` | the created rows in input order; `{}` for an empty list | the list is malformed, or any row fails `create` |
| `get(id)` | the row, or `nil` | `id` does not fit the table's id kind: a lowercase uuid, or a positive integer for `id = "int"` |
| `by(index, values...)` | the row, or `nil` | there is no such ready unique index, or the number of values differs from its fields and edges |
| `update(id, values, clear)` | the stored row | there is no row `id`, it changes an immutable field, or as for `create` |
| `upsert(index, values)` | the row and a `created` boolean | `index` is `"id"` and `values.id` is missing or does not fit the table's id kind, the index is missing, building or non-unique, an indexed field is missing from `values`, an index edge in `values` names no row or several rows, or the selected `create` or `update` fails |
| `delete(id)` | `true`, or `false` if there was no row | `id` does not fit the table's id kind |

`by` takes an index name, such as `by_email`, or a field name with a unique
`by_<field>` index. For an index with edges, pass a linked row or its id
for each edge after the field values, as in
`c.Line:by("by_n_order", 1, order)`. Rows are tables of field values plus
`id`. A field the
stored row lacks reads as its `:default()`.

## Open a client with the graph

To run a schema's function defaults, `:validate` functions, hooks and
policies, open the client with the graph the space was migrated with:

```lua
local db = lent.open(app)                   -- app: the answer of lent.graph
db.tx(function(c) ... end, false, viewer)   -- db.client(pessimistic, viewer) inside a transaction
```

`viewer` is optional and can be any value, such as the signed-in user's
row. The policy rules receive it, and they receive `nil` when it is left out.

`lent.open(app, options)` takes an optional table of options:

| option | default | valid values | effect |
|---|---|---|---|
| `hookDepth` | `16` | a whole number of at least `1` | how deep hooks may nest before a write raises the depth error; see [hooks](schema.md#hooks) |

An unknown option or an invalid value raises an error when `lent.open` is
called.

`lent.open` raises an error when the graph declares a table or field that the
space's catalog lacks; run `migrate` first. Value rules stored in the catalog
apply with or without it.

## Transactions and write errors

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

## Create many rows and upsert

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
fields of a composite index, and one row or id for each of its edges. The lookup uses these values before defaults
and hooks run. A match keeps its `id` and updates the supplied fields;
omitted fields keep their stored values, subject to `updateDefault`. A
missing match runs `create`. The returned `created` flag is `true` for a new
row and `false` for an update. Each branch runs its usual defaults, rules
and hooks, and maintains every affected index. Edge values work on the
create branch; use `link` and `unlink` to change an existing row's edges.
A match already links to the index's edges' rows, so its update leaves those
edges as they are.

`upsert("id", values)` selects the row by `values.id`. It updates that row
with the other values, or creates a row with that id.

Concurrent upserts of the same indexed values select one row. Optimistic
transactions retry conflicts; pessimistic transactions take an exclusive
lock on the unique entry before choosing the branch.

## Edges

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

## Edge fields

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

## Path edges

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

## Errors

Errors start with `LENT`, or with `ROWCODEC` for a value of the wrong kind or
a missing required field. `lent.CLIENT` runs a self-check inside a
transaction it rolls back and answers `ok`.
