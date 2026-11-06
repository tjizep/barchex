# lent queries

Filter a query with an expression over the row's fields, and combine
conditions with `and`, `or`, `not` and parentheses. Queries read through the
best index for their filters:

```lua
-- 1. a page of users, oldest first
c.User:query()
    :where("(age >= min and name ~= 'ann') or name == 'bo'", { min = 30 })
    :order("age", "desc"):offset(10):limit(10)
    :all()                                -- or first, ids, count
-- 2. how many users are 60 or younger, or have no age
c.User:query():where("not (age > 60)"):count()
-- 3. the Post rows of one user, through the User edge posts
c.User:query():where(`id == {u.id}`):queryPosts():all()
-- 4. each Product that a Customer ordered, through three edges
c.Customer:query():follow("orders.lines.product"):all()
```

The same queries in SQL, with each edge written as a foreign key column,
such as `posts.author_id` for the `posts` edge:

```sql
-- 1.
SELECT * FROM users
WHERE (age >= 30 AND name <> 'ann') OR name = 'bo'
ORDER BY age DESC NULLS LAST, id DESC LIMIT 10 OFFSET 10;
-- 2. lent compares a missing value as nil, so `not (age > 60)` keeps it
SELECT count(*) FROM users WHERE age IS NULL OR age <= 60;
-- 3.
SELECT * FROM posts WHERE author_id = 1;  -- u.id
-- 4. each product once, however many lines name it
SELECT DISTINCT products.* FROM customers
JOIN orders ON orders.customer_id = customers.id
JOIN lines ON lines.order_id = orders.id
JOIN products ON products.id = lines.product_id;
```

`queryPosts()` and `follow` answer a query over the rows at the far end of
the edges, so `all()` answers `Post` or `Product` rows, each once. Chain
`where`, `order` and `limit` onto that query to filter and page them.

Each `where` call adds a condition that rows must also meet. `where` also
takes a single comparison, `where("age", ">", 30)`, and a Luau function of
the row, `where(function(r) return r.age % 2 == 0 end)`.

| method | effect |
|---|---|
| `where(expr, params)`, `where(expr, ...)` | keeps rows for which the expression string `expr` is true; `params` is an optional table of named values, and the values after an expression with `?`s fill them in order; see [expression filters](#expression-filters) |
| `where(field, op, value)` | keeps rows where the comparison holds, `op` being one of `=`, `~=`, `<`, `<=`, `>`, `>=`; a missing field equals `nil`, differs from non-`nil` values and fails range comparisons |
| `where(fn)` | keeps rows for which `fn(row)` is true |
| `order(field, dir)` | sorts by `field`, `"asc"` by default or `"desc"`; `asc` puts equal values in id order and missing values first, and `desc` reverses both |
| `limit(n)`, `offset(n)` | applied after the order |
| `cursor(row)` | a string that marks `row`'s place in the query's order |
| `after(cursor)` | keeps the rows after the cursor's row; with no `order`, the query orders by id |
| `using(name)` | reads through the named ready index, or `"id"` for the table |
| `follow(edge, ...)`, `query<Edge>()` | a query over the rows the matches reach through the edges, hop by hop; `follow("a.b")` equals `follow("a", "b")` |
| `has(edge)`, `has<Edge>()` | keeps rows with at least one link through `edge` |
| `has(edge, fn)`, `has<Edge>With(fn)` | keeps rows linked to a row that matches the query `fn(q)` builds with `where`, `has` and `using` |
| `hasNo(edge)`, `hasNo<Edge>()`, `hasNo(edge, fn)`, `hasNo<Edge>With(fn)` | keeps the rows that `has` with the same arguments leaves out, as SQL's `NOT EXISTS` does |
| `with(edge, fn)`, `with<Edge>(fn)` | loads each answered row's links into `row.<edge>`; `fn` is optional and may filter, order and limit them |
| `whereEdge(field, op, value)`, `whereEdge(fn)`, `whereEdge(expr, params)`, `whereEdge(expr, ...)` | inside the `fn` of `has` or `with`, or on the answer of `follow`, keeps the linked rows whose link values match, as `where` does for fields |
| `links(edge)` | a query over the links of the matches through an `edge.to` or `edge.from`, one row per link holding `from`, `to` and the link's values |
| `all()`, `first()`, `ids()` | runs the query |
| `count()` | answers how many rows match, after `offset` and `limit`; see [counting rows](#counting-rows) |
| `sum(field)`, `min(field)`, `max(field)` | runs the query and answers one aggregate |
| `aggregate(spec)`, `groupBy(...):aggregate(spec)` | runs the query and answers several aggregates, for all rows or per group |
| `groupBy(...):having(cond, params)`, `:having(cond, ...)`, `:order(name, dir)`, `:limit(n)`, `:offset(n)` | filters, orders and pages the groups before `aggregate(spec)` answers them |
| `aggregatePage(spec, state, pageSize)`, `groupBy(...):aggregatePage(spec, state, pageSize)` | reads one page of the rows and answers a report; the last page's report holds what `aggregate` answers; see [paged aggregates](#paged-aggregates) |
| `update(values, clear)` | updates the selected rows and answers the affected-row count; both arguments are optional, as for a row's `update` |
| `delete()` | deletes the selected rows and answers the number it removed |
| `explain()` | the plan, such as `by_name_age = name range age` or `edge customer_likes in (by_color = color)` |

## Expression filters

An expression filter is a Luau expression over the row's fields, with `id`,
the rows its edges link it to, and the names in `params`:

```lua
c.Emp:query():where("age > 10 and age <= 100 and salary < max", { max = 1000 })
c.Emp:query():where("(age or 0) * 2 > salary / 10 or name .. '!' == shout",
                    { shout = "eve!" })
```

It takes numbers, strings, `true`, `false` and `nil`, the names of fields,
computed fields and parameters, [edge names and dotted paths](#linked-rows-in-expressions), `and`, `or`, `not`, `==`, `~=`, `<`, `<=`,
`>`, `>=`, `+`, `-`, `*`, `/`, `//`, `%`, `^`, `..`, `#`, parentheses, the
calls `date(text)`, `year(t)`, `month(t)` and `day(t)`, which work as the
`lent` helpers of the same names, and [`like(text, pattern)`](#string-patterns).
Anything else is a syntax error, so an expression reads only the row and its
parameters. A parameter is a number, string, boolean or JSON table; a name
that is both a field and a parameter is an error, and so is a name that is
neither. Pass values through `params` to keep them out of the expression
text. A parameter set to `nil` is missing from its table, so compare with
the literal `nil` instead.

### Values in expressions

Put a program's value into an expression with a `?`, a named parameter or
Luau string interpolation:

```lua
c.User:query():where("name == ? and age > ?", name, 30)  -- values for the ?s
c.User:query():where("name == n", { n = name })          -- a named parameter
c.User:query():where(`id == {u.id}`)                     -- interpolation
```

Each `?` takes the next value after the expression. Pass one value for each
`?`; another count raises `has 2 ? and got 1 values for them`. A `?` value
can be `nil`, which compares as the literal `nil` does, or a JSON table, as
in `where("tags == ?", { "x" })`. An expression with a `?` reads every
value after it as a `?` value, so it takes no `params` table. A `?` inside
a string literal, as in `name == '?'`, is text.

Interpolation needs a backtick string; Luau keeps `{u.id}` in a `"..."` or
`'...'` string as literal text. It writes the value into the expression
text, which suits numbers, `true`, `false` and `nil`: a number's text reads
back as the same number, so `` `score == {s}` `` matches a stored `0.1`.

Pass strings, JSON tables and any value that comes from outside the program
as a `?` value or a parameter. An interpolated string becomes part of the expression's
syntax:

- `` `name == {name}` `` reads `ann` as a name and raises
  `has no field or parameter ann`;
- `` `name == '{name}'` `` and `` `name == "{name}"` `` work until a value
  holds the quote, such as `o'brien`, which raises
  `has an unfinished string`;
- a value such as `x' or name ~= 'x` turns
  `` `name == '{name}'` `` into an expression that matches every row.

A `?` value or parameter is always one value, whatever its text holds.
lent keeps the parsed form of the 256 most recent expression texts, and
each interpolated value makes a new text, so a query run in a loop parses
its expression on every call. With `?`s or parameters, the text stays the
same and is parsed once.

A call on a value or parameter is worked out once, so
`placed >= date('1995-01-01')` compares the field with a number, and an
index on `placed` can serve it. A call on a field runs for each row, so
`year(placed) == 1995` checks every row the rest of the query selects. To
read one year through an index on `placed`, compare with its bounds:
`placed >= date('1995-01-01') and placed < date('1996-01-01')`.

A missing field value is `nil`. A range comparison with `nil` is false, as
in `where(field, op, value)`, so `not (age > 20)` keeps rows without an age.
Arithmetic, `..`, `#` and calls with `nil` give `nil`. `==` and `~=` compare
JSON fields structurally. `where` checks the expression against the field kinds
when it is called: it raises an error for a range comparison on a `bool` or
`json` field, for a comparison of different kinds such as `age > 'ten'`, and
for arithmetic on a string. A value whose kind is known only per row, such
as `age or 'none'`, is checked as each row is read. Errors start with
`LENT table <name> query where "<expr>"` and give the column for a syntax
error.

Each part of an expression's top-level `and` that compares a field with a
value works like a `where(field, op, value)` filter, so an index can serve
it; a `bool` field on its own counts as `field = true`. With an index on
`age`, `explain()` shows `by_age range age` for the first example above.

An `or` whose sides each compare the same field with values, such as
`age < 20 or age > 100` or `name == 'ann' or name == 'eve'`, gives that
field a list of value ranges. A side may join several comparisons with
`and`, as in `(age > 1 and age < 5) or age > 100`. An index on the field
reads only the keys in those ranges, merging ranges that overlap, in index
order, so `order("age")` with a `limit` still stops early; `explain()`
shows `by_age 2 ranges age`. When a side has no comparison of that field
with a value, as in `age ~= 3` or `age == nil`, the query checks the `or`
on each row it reads. Every part of the expression is checked on each row
the index reads.

### Linked rows in expressions

Name an edge with one row at its far end, such as a line's `supplier`, to
read the linked row's id, and name a dotted path such as
`supplier.nation.name` to read a field of the row the path reaches. The
paths follow the same rules as [`groupBy`](#aggregates) paths: each step
before the last is an edge with one row at its far end, including a path
edge, and the last step names a field or another such edge. Use them to
compare two linked rows, as TPC-H Q5 does with the customer's and the
supplier's nation:

```lua
c.Lineitem:query()
    :where("customer.nation == supplier.nation and supplier.nation.region.name == ?",
           "AMERICA")
    :groupBy("supplier.nation.name")
    :aggregate { revenue = { fn = "sum", field = "extendedprice" } }
```

A path reads `nil` when a link along it is missing or leads to a row the
viewer's query rules hide. `nil == nil` is true, so the example above also
keeps lines whose customer and supplier both lack a nation; add
`customer.nation ~= nil` to leave them out.

Each run of the query reads a linked row once and reuses it for every row
that links to it. The parts of the expression that read only the row's own
fields still select an index, so in
`where("price >= 20 and supplier.nation.name == 'GERMANY'")` an index on
`price` reads the range and each row in it checks its supplier's nation.
To filter on the fields of one linked row through that row's indexes, use
[`has<Edge>With`](#joins-through-edges).

An edge that can link a row to many rows
raises `LENT table <name> edge <edge> can link a row to many rows, so where
cannot use it`, and a step the table lacks raises `LENT table <name> has no
field or edge <step>`.

## String patterns

`like(text, pattern)` is true when `text` matches `pattern`, as SQL's `LIKE`
does:

```lua
c.Part:query():where("like(type, 'PROMO%')")
c.Part:query():where("like(name, '%green%')")
c.Order:query():where("not like(comment, pattern)", { pattern = "%special%requests%" })
```

| in a pattern | matches |
|---|---|
| `%` | any run of characters, including none and including newlines |
| `_` | exactly one UTF-8 character |
| `\` followed by a character | that character, so `\%` is a literal `%` |
| anything else | itself, with upper and lower case kept distinct |

Inside an expression's quotes a backslash is written twice, so `'50\\%'` is
the pattern `50\%`. A pattern in `params` needs no such doubling. A pattern
that ends with a lone `\` raises an error.

A pattern that starts with literal text gives its field a value range, so an
index on a `string` field reads only the keys with that start, and
`like(type, 'PROMO%')` on an index on `type` shows `by_type range type` in
`explain()`. The pattern must be a value or parameter, and `or` combines these
ranges as it combines [comparisons](#expression-filters). A pattern that
starts with `%` or `_`, or comes from a field, reads every row the rest of the
query selects, and each row costs about the length of the text times the
length of the pattern.

`like` gives `nil` when the text or pattern is `nil`, so
`not like(note, 'x%')` keeps rows without a `note`. SQL's `NOT LIKE` drops
those rows; write `note ~= nil and not like(note, 'x%')` to do the same.

## Update and delete by query

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
described in [create many rows and upsert](client.md#create-many-rows-and-upsert). All target IDs stay in memory until the writes finish.
Use an `id` cursor and `limit` to divide large updates across transactions;
a limited delete can run in separate transactions until it returns `0`.

## Index choice

The query picks the index whose leading fields match the most `=` filters,
then one range filter, or the ranges of an expression's `or`, on the next
field. When that index already returns rows in the requested order, the
query stops reading at the limit. A `desc` order reads the index from the
end and stops the same way. Otherwise `explain` ends with `then sort`, and
the query reads every matching row before sorting. A `column` table read by
id with a `limit` keeps only the rows that sort first; see
[Column tables](codecs.md#column-tables-with-columns). A unique index leaves
out rows with a missing value, so it is used when every one of its fields
has an `=` filter, or when each field before the last has one and the last
has a range. Filters on other fields are checked on each row read.

When two indexes match equally well, the query counts the keys each one
would read and uses the smaller count. Equal counts keep the index declared
first. `explain` shows the comparison in brackets after the index it chose:

```
by_customer = customer [2 keys over by_status 38]
```

These counts take no lock and add nothing to the transaction's commit
check, so counting an index the query then skips holds up no writer and
causes no retry. Each count reads the store as it is at that moment: it
leaves out the transaction's own uncommitted writes and includes writes
other clients commit meanwhile. A count that is off changes only which
index the query reads; the rows it answers stay the same. The primary index
of a `column` table is the exception: the query counts its rows by reading
presence blocks, which locks and checks them as any read does. To skip the
counts, call `using(name)`, which reads the named index.

Key counts decide only between equal matches, so an index with one more `=`
field wins even when another index holds fewer keys. Store statistics with
`analyze` to compare every index, as the next section describes. Paged
aggregates keep the index declared first with no count or estimate, because
their state holds a place in that index. Queries from `follow`, `with` and
`query<Edge>()` also read with no count or estimate. A cursor records the
order's field and the row's id, so it keeps working when a later page reads a
different index.

### Planner statistics

Call `analyze` from MIGRATE to store statistics for a table's rows and
indexes; [planner statistics](migrate.md#planner-statistics) describes the
call. When every index that narrows a query has statistics, the query
estimates the keys each one would read and uses the smallest estimate. A
range on one field can then win over an `=` on another, and the comparison
reads no index. Equal estimates keep the better
match. `explain` marks estimates with `~`:

```
by_size range size [~3 keys over by_status ~38]
```

The estimate comes from up to 100 sample keys per index, so it is close for
a wide range and rough for a narrow one. When no sample falls in the range,
the estimate uses the index's count of distinct values.

With a `limit`, an index that already returns rows in the query's order
stops reading at the limit, so its estimate shrinks to the part of its range
the limit and offset reach. Without the limit, the same query sorts the rows
of the index with fewer keys:

```
by_status = status then sort [~38 keys over by_size ~39]
by_size range size [~3 keys over by_status ~38]            -- with limit(2)
```

Plans change only when `analyze` saves new statistics, so writes between
runs leave a query's plan as it was. Run `analyze` again after a load or a
large delete changes how values spread. An index that a migration adds or
replaces has no statistics until the next `analyze`, and until then the
query compares equal matches by key counts, as above. A unique index with an
`=` on every field reads at most one key, so the query uses it with no
comparison.

A query that compares estimates reads the table's statistics key. Saving new
statistics writes that key, so it conflicts with open transactions that read
it, as a write to any key they read does.

### Large values

Index keys hold `int` and `time` values up to +-2^53. A filter past that
limit, such as `where("size", "<", 1e300)`, compares as usual, and the query
reads every row of the table or chosen range to check it.

### Linked rows

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

## Counting rows

`count()` counts index keys and reads no row when the keys are exactly the
matching rows, so its cost stays about the same at any table size. In one
run over 40,000 rows, a count took 1 ms and reading the rows took 280 ms.

`count()` reads keys when the query has only these filters:

- no filters at all, which counts the table's rows;
- `=` with a value on the leading fields of the chosen index;
- ranges on the next field of that index, with finite values, up to +-2^53
  on `int` and `time` fields.

An expression such as `"size >= 3"` counts as the same filter. `order`,
`limit`, `offset` and `using` work with a key count.

Any other query reads its rows and costs what `all()` costs. That includes
a `where` function, `like`, an expression with `or`, `~=`, `= nil`, a filter
on a field outside the index, `has`, `hasNo`, `follow`, `after`, and links and
view queries. `explain()` shows which index a query reads. To count a large
selection of this kind across calls, use a `count` in
[`aggregatePage`](#paged-aggregates).

`aggregate` with `fn = "count"` always reads rows.

## Cursor pages

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

## Aggregates

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

To group by a field of a linked row, name it with a dotted path such as
`author.name` or `customer.nation.name`. Each step before the last is an
edge with one row at its far end, and the last step names a field of the
row the path reaches, or another such edge to group by its id. The group row
holds the value under the path's full text:

```lua
for _, g in c.Post:query():groupBy("author.team.name"):aggregate {
    posts = { fn = "count" },
} do
    print(g["author.team.name"], g.posts)
end
```

Each linked row is read once per call. A row without a link joins the
group whose key is `nil`, and so does a row whose path passes through or
reads a row that the viewer's query rules hide.

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
| `sum` | required; an `int`, `float` or `decimal` field, or a function answering numbers | the total, exact for an `int` or `decimal` field or with `scale` | `0` |
| `avg` | required; as for `sum` | the mean as a float | `nil` |
| `min`, `max` | required; any field kind except `json`, or a function answering numbers, strings or booleans | the least or greatest value, in the order `order` uses | `nil` |

A spec with both `field` and `value` raises an error. For `min` and `max`, a
function must answer one type for every row; a number after a string raises
an error. Rows without a value are skipped.

An `avg` is a float even over an `int` or `decimal` field. Over a `decimal`
field it adds the values exactly and then divides, so the answer is the
nearest float to the mean and keeps no fixed scale.

Set `scale = n`, from `0` to `15`, on a `sum` or `avg` with a `value`
function or a `float` field to add exactly, as a `decimal` field does. Each
value is rounded to `n` digits after the point and added as a whole number
of those units:

```lua
-- TPC-H revenue: prices and discounts with 2 digits make products with 4
c.Line:query():aggregate {
    revenue = { fn = "sum", scale = 4,
                value = function(l) return l.price * (1 - l.discount) end },
}
```

A plain float sum of the same values can end in rounding noise, such as
`3.3000000000000003` for a total of `3.3`. A rounded value must fit in 15
digits; a larger one raises `value answered <v>, which does not fit in 15
digits with <n> after the point`. `scale` on an `int` or `decimal` field
raises an error, since those sums are exact already.

Set `distinct = true` on a `count`, `sum` or `avg` to read each value once,
as SQL's `count(distinct ...)` does. It needs a `field` or `value`.

```lua
c.Post:query():aggregate {
    authors = { fn = "count", field = "author", distinct = true },
    kinds   = { fn = "count", value = function(p) return p.kind end, distinct = true },
}
```

`groupBy` answers one row per group, holding the group's key values under
their names and each aggregate under its name. Groups come in key order,
with missing values first, the same order an index keeps. A row without a
value, or without a link through the edge, joins the group whose key is
`nil`. Call `aggregate()` with no spec to list the distinct key values. An
aggregate with the name of a group key raises an error, and so does a
`groupBy` on a `json` field or on an edge that can link a row to many rows.

Call `having`, `order`, `limit` and `offset` between `groupBy` and
`aggregate` to filter, order and page the groups, as SQL's `HAVING`,
`ORDER BY` and `LIMIT` do after `GROUP BY`:

```lua
-- the ten authors with the most stars, among those with at least 3 posts
c.Post:query():groupBy("author")
    :having("posts >= n", { n = 3 })
    :order("stars", "desc"):limit(10)
    :aggregate { posts = { fn = "count" }, stars = { fn = "sum", field = "stars" } }
```

- `having(cond, params)` keeps the groups that match. `cond` is an
  expression string, as for `where`, over the group's keys and aggregates by
  name and the names in `params`, with values after it for its `?`s, or a function that receives the group row
  and answers whether to keep it. A dotted key such as `author.name` is one
  name in the expression. Each call adds a test, and a group must pass them
  all.
- A `having` test can compare each group with the total over every row the
  query selects, as TPC-H Q11 compares a part's stock value with the
  nation's. An expression reads aggregate `name` over all those rows as
  `total.name`, and a function receives the total row as its second
  argument. A `distinct` aggregate has no total, and an expression that
  reads one raises `reads total.name; a distinct aggregate has no total`.
- `order(name, dir)` orders the groups by a group key or aggregate, with
  `dir` `"asc"` (the default) or `"desc"`. Each call adds a sort key after
  the earlier ones, and groups that tie on all of them stay in key order.
  Missing values come first in ascending order and last in descending order.
- `limit(n)` and `offset(n)` page the groups after `having` and `order`.

An `order` name that is neither a group key nor an aggregate raises an error
when `aggregate` runs.

```lua
local spec = { value = { fn = "sum", value = function(s) return s.cost * s.qty end } }

-- parts that hold over 1% of the value in stock
c.Stock:query():groupBy("part")
    :having("value > total.value * 0.01")
    :order("value", "desc")
    :aggregate(spec)

-- the same test as a function of the group row and the total row
c.Stock:query():groupBy("part")
    :having(function(g, total) return g.value > total.value * 0.01 end)
    :aggregate(spec)
```

Aggregates run over the rows the query selects after its filters, order,
offset, limit and cursor, so `order("stars", "desc"):limit(10):sum("stars")`
sums the top ten. They read and hold the same rows `all()` would, so a large
selection costs what `all()` costs.

## Paged aggregates

For a selection too large for one function call, use `aggregatePage` on a
query or a `groupBy`. Each call reads one page and answers a report. Pass
the report's `state` to the next call, in the same function call or a later
one, until `done` is `true`. Keep the group rows of every report's `result`:

```lua
-- state is nil for the first page, then the state the last call answered
local r = c.Trip:query():groupBy("passengers")
    :aggregatePage({ trips = { fn = "count" } }, state)
for _, group in r.result or {} do
    -- keep each group row; a report holds some, all or none of them
end
if not r.done then
    -- answer r.state, and pass it to the next call
end
```

| report field | meaning |
|---|---|
| `done` | `true` on the last call of the run |
| `processed` | the rows this call read, or after a [spill](#many-groups) the scratch keys it read; at most the page size |
| `state` | when `done` is `false`, hex text for the next call |
| `result` | for a `groupBy`, a list of group rows after `having`, `order`, `limit` and `offset`; without `groupBy`, the aggregate row on the last call |

A `groupBy` run that keeps its groups in the state answers every group row
on its last call. A run that spills answers them across its last calls, in
order, as [many groups](#many-groups) describes. The loop above collects
both.

`pageSize` defaults to `10000` and takes whole numbers from `1` to
`1000000`. Choose a page that each call finishes within the function
deadline, and reduce it if a call times out.

Pages read the index or table in key order. After `follow`, or a `has`
that reads its matches first, pages read the linked ids in id order. The
query's `order` does not change an aggregate, so pages ignore it. A query
with `limit`, `offset` or `after` raises
`reads every matching row, so the query takes no limit, offset or after`.
Links and view queries raise their `reads table rows` error; aggregate those
in one call. `follow` and a `has` that reads its matches first collect their
linked ids again on every call.

Calls in separate function calls read separate transactions, so writes
between them change the answer. A row after the last page read counts as it
is when its page reads it. A row already read keeps the values it had then,
even after an update or delete. Keep writers away from the selection until
the last page for an answer from one moment.

A state works only with the query that answered it: the same table, schema
version, plan, group keys, aggregates, filter values, and `having`, `order`,
`limit` and `offset` calls. Any other state raises `state comes from another
query, aggregate or schema version; start again without a state`. A
migration between pages ends a run the same way; start again without a
state.

### Many groups

The state holds each group's running values and each value a `distinct`
aggregate has read, about 108 bytes per group with a `count` and a `sum`,
and each call decodes and encodes it. When a call ends with more than 1,000 groups and distinct
values, it moves them into scratch keys under `lent.a` in the space, and
from then on the state names the run and stays under 400 bytes. Set
`pageGroups` in [`lent.open`](client.md#open-a-client-with-the-graph) to change the limit;
`0` spills on the first call that leaves rows unread.

After a spill, each call adds its page's groups to the scratch keys, and to
one more key for the totals when a `having` test reads them. Once
the rows are read, each call reads up to the page size of scratch keys and
removes them. It first removes the values that `distinct` aggregates read.
With `order` calls, it then sorts the groups that pass `having` into order
keys. Last, it answers the groups in order, ties in group key order, and
after `limit` groups it removes the rest unread. The call that removes the
last key answers `done`.

Measured on 200,000 rows of a column table, with pages of 10,000:

| groups | calls | time | largest state |
|---|---|---|---|
| 100 | 20 | 0.5 s | 11 KB |
| 10,000 | 21 | 5.5 s | 394 bytes |
| 200,000 | 40 | 10 s | 394 bytes |

A spilled `sum` or `avg` of `float` values adds them in another order than
`aggregate` does, so its last digits can differ. `decimal` sums are exact.

A spilled run writes to the space, so it needs a caller with write rights,
or it fails with `FUNCTION not authorized to write there`. A function with
`"write": false` in its `--@barch` header fails with `FUNCTION declared
"write": false in its --@barch header, so it can't write`; give it a
`pageGroups` above its group count. Each call's scratch writes commit or
roll back with its transaction, so a call that fails leaves the state
before it valid.

A spilled run takes only its latest state. An older state raises `state is
older than the latest page of its run; pass the state that the latest page
answered`, which stops a retried call from counting a page twice. A state
of a finished or cancelled run raises `state belongs to a run that finished
or was cancelled; start again without a state`.

A run that stops before `done` keeps its scratch keys. Remove them with
`cancelAggregate` on any table of the space, passing the latest state until
`done` is `true`:

```lua
local r = c.Trip:cancelAggregate(state, 10000)  -- page size, 10000 by default
-- r.done, r.processed (keys removed) and, while r.done is false, r.state
```

A state that keeps its groups has no scratch keys, so `cancelAggregate`
answers `done` at once.

## Joins through edges

`has` and `with` join through edges:

```lua
-- users with a post of 5 stars or more
c.User:query():hasPostsWith(function(p) p:where("stars", ">=", 5) end):all()
-- each user with their three best posts in u.posts
c.User:query():withPosts(function(p) p:order("stars", "desc"):limit(3) end):all()
-- each post with its author in p.author, a row or nil
c.Post:query():withAuthor():all()
-- users without a post of 5 stars or more, as SQL's NOT EXISTS
c.User:query():hasNoPostsWith(function(p) p:where("stars", ">=", 5) end):all()
```

A `has` filter that reads part of its table through an index runs first,
and the rows linked to its matches become the candidates. `explain` shows
this as `has posts from (by_stars range stars)`. Any other `has` checks the
edges of each candidate row, which `explain` shows as `has posts`. For a
path edge, the first way walks the hops backwards from the matches, and the
second stops at the first matching row each candidate reaches. A `has`
filter with `order`, `limit`, `offset` or `with` raises an error.

`hasNo` keeps a row when no link through the edge reaches a matching row,
so rows without links stay. Its filter takes the same calls as a `has`
filter. A `hasNo` filter that reads part of its table through an index
also runs first, and its matches mark the rows to leave out; the candidates
still come from the rest of the query. `explain` shows `has no posts` or
`has no posts from (by_stars range stars)`. For an edge whose own name
starts with `no`, such as `noFly`, `hasNoFly()` keeps its `has` meaning;
call `hasNo("noFly")` or `hasNoNoFly()` for the negation.

A correlated subquery, which SQL runs once per outer row, runs as two
passes: the first computes the per-row values with `groupBy` and keeps them
by id, and the second compares each row with its value. Load the linked
row with `with` so the second pass can read its id:

```lua
-- posts with more stars than their author's average
local avg = {}
for _, g in c.Post:query():groupBy("author"):aggregate {
    stars = { fn = "avg", field = "stars" },
} do
    if g.author then avg[g.author] = g.stars end
end
local above = {}
for _, p in c.Post:query():withAuthor():all() do
    if p.author and p.stars > avg[p.author.id] then above[#above + 1] = p end
end
```

`with` runs after the outer query's `limit`, one query per answered row,
and only for `all` and `first`. An edge with one row at its far end loads a
row or `nil`; any other edge loads a list. Loaded edges are extra keys on
the row, so pass `update` only the fields to change.

## Edge fields in queries

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

## Views

A view gives a query a name, and you read its rows as you read a table's.
Declare it with `lent.view "Name" { fields, rows }`: `fields` lists the
fields each row holds, and `rows(c, params)` answers the rows as a list.
Put the view in `lent.graph` with the tables and open the client with that
graph, which makes the view `c.Name`:

```lua
local AuthorStats = lent.view "AuthorStats" {
    fields = {
        lent.field.string "name":optional(),   -- nil for posts without an author
        lent.field.int "posts",
        lent.field.int "stars",
    },
    -- c is the client the view is read from; params come from query(params)
    rows = function(c, params)
        local out = {}
        for _, g in c.Post:query():where("at >= since", params)
            :groupBy("author.name")
            :aggregate { posts = { fn = "count" }, stars = { fn = "sum", field = "stars" } } do
            out[#out + 1] = { name = g["author.name"], posts = g.posts, stars = g.stars }
        end
        return out
    end,
}
local db = lent.open(lent.graph { User, Post, AuthorStats })

db.tx(function(c)
    -- the ten authors with the most stars this year, among those with 3 posts
    return c.AuthorStats:query({ since = lent.date(2026, 1, 1) })
        :where("posts >= 3"):order("stars", "desc"):limit(10):all()
end)
```

A view field takes a kind and a name, plus `:optional()`, `:values(...)`
for an `enum` and `:scale(n)` for a `decimal`; any other modifier raises an
error. A view's name must differ from every table's. No key stores the rows
of a view with a `rows` function, so MIGRATE leaves it alone, and a client
opened without the graph has no `c.Name` for it. A
[stored view](#stored-views) keeps its rows in keys.

Each `all`, `first`, `count`, `groupBy` or aggregate call runs the
function again, in the caller's transaction. The function reads through
`c`, so the viewer's query rules apply to what it reads. Each answered row
keeps only the declared fields, so the function may answer table rows with
more keys. A field without a value that is not `:optional()`, or a value of
the wrong kind, raises an error that names the row's position, such as
`view AuthorStats row 3 field posts is int, got x`. A `decimal` value is
rounded to the field's scale.

A view query takes the same methods as a links query: `where`, `order`,
`limit`, `offset`, `groupBy`, the aggregates, `all`, `first`, `count` and
`explain`; other query methods raise an error. They run in memory over every
row the function answers, so a view costs what its function costs plus a
pass over its rows. Rows come in the order the function answers them, and
`order` keeps that order among rows with equal values. `explain` answers
`view AuthorStats rows, then filter in memory`.

### Stored views

A stored view keeps one row per group of a table's rows, with the group's
counts, sums, averages, minimums and maximums. Each write to the table
updates the groups it changes in the same transaction, so a read answers
current totals and costs one pass over the groups, however many rows the
table holds. Use it for totals that pages and reports read often, as SQL
uses a materialized view that each write keeps current.

Declare it with `from`, `groupBy` and `aggregates`, and an optional `where`,
put it in `lent.graph`, and run MIGRATE to fill it from the stored rows:

```lua
local PostsByAuthor = lent.view "PostsByAuthor" {
    from = "Post",
    where = "stars > 0",
    groupBy = { "author", "status" },
    aggregates = {
        posts = { fn = "count" },
        stars = { fn = "sum", field = "stars" },
        mean = { fn = "avg", field = "stars" },
        latest = { fn = "max", field = "at" },
    },
}
local app = lent.graph { User, Post, PostsByAuthor }
local db = lent.open(app)

db.tx(function(c)
    -- each row holds author, status, posts, stars, mean and latest
    return c.PostsByAuthor:query():where("posts >= 3"):order("stars", "desc"):all()
end)
```

| option | required | takes |
|---|---|---|
| `from` | yes | the name of a table in the graph |
| `where` | no | an [expression](#expression-filters) over the row's stored fields, `id` and literal values; rows that fail it stay out of every group |
| `groupBy` | no | a list of the table's stored fields, except `json` fields, and `edge.to` or `edge.from` edges with `:unique()`; an edge groups by the linked row's id. Without `groupBy`, the view has one row for all the rows |
| `aggregates` | yes | a map from each output name to `{ fn, field, scale }` |

`fn` is `count`, `sum`, `avg`, `min` or `max`, and each answers what it
answers in a query's [aggregates](#aggregates), including for a group with
no values. `field` names a stored field of the table; only `count` may omit
it. `scale` works as it does in a query's `sum` or `avg` of a `float` field,
so the stored total stays exact; a stored view's aggregate takes no `value`
function or `distinct`. Each row holds the `groupBy` keys, which are `nil`
for rows without a value or link, and the aggregates by name. A group goes
when its last row leaves it, and a view whose rows all leave answers no
rows.

The view answers the same query methods as a view with a `rows` function,
in memory over its groups. Keep these costs and limits in mind:

- Each create, update, delete, link and unlink that moves a row into or out
  of a group writes that group's key. Writes to rows of one group conflict,
  so an optimistic transaction retries and a pessimistic one waits. A view
  without `groupBy` has one group that every write to the table touches.
- A `min` or `max` stores a count for each distinct value of its field in
  each group, so that a delete finds the next value.
- A `sum` or `avg` of a `float` field without `scale` adds and takes away
  float values, so after many updates its last digits can drift from a sum
  of the current rows. Set `scale` to keep it exact.
- The view counts every row of the table, including rows that the viewer's
  [query rules](schema.md#privacy-policies) hide. Give a view only to viewers who may see its
  totals.

A new stored view, or one whose declaration changes, adds
`drop view Name` and `fill view Name` steps to the migration; a view removed
from the graph adds `drop view Name`. A fill step that rewrites the table's
rows also fills the view again. Writes continue while a view fills, and
reading it raises `view PostsByAuthor is filling; run MIGRATE until it
completes`.

A client opened with a graph whose stored view the catalog lacks, or holds
with a different declaration, raises an error that ends with
`run MIGRATE`. A client opened without the graph still reads the catalog's
stored views as `c.Name`.
