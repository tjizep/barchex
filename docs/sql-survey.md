# SQL workload survey

This page checks how well lent stores public SQL example workloads and
answers their queries, and lists the features lent needs to cover them. It
covers TPC-H, the New York taxi trip data and the Sakila sample database.

Two test files back the survey. Each loads one small generated dataset into
SQLite and into lent, runs every translated query both ways, and compares
the answers:

| file | workload | queries checked |
|---|---|---|
| `tests/test_tpch.py` | TPC-H, 8 tables, 220 line items | Q1, Q3, Q4, Q6, Q10, Q11, Q12, Q13, Q14, Q18 |
| `tests/test_nyc_taxi.py` | yellow taxi trips and zones, 300 trips | the four benchmark queries and a group by pickup borough |

Run them with the rest of the suite, or alone:

```bash
BARCHD=/path/to/barchd pytest -q tests/test_tpch.py tests/test_nyc_taxi.py
```

## Summary

lent stores all three schemas. Tables map to `lent.schema`, foreign keys to
an `edge.from` with its `edge.to`, and a join table with extra columns to an
edge with `:fields`. Single-table filters and group-by queries translate
directly. Queries that join several tables translate to `has` filters and
`groupBy` over a unique edge or path edge, with `having`, `order` and
`limit` on the groups, followed by a little Luau for loading the joined
rows.

The main limits, in order of impact:

1. **Size.** An aggregate reads about 60,000 rows per second, and a
   function call runs for 1 s by default and at most 30 s. A TPC-H
   scale-factor-1 `lineitem` table has 6 million rows and one month of
   taxi trips has about 3 million, so neither fits in one call.
2. **Missing query forms.** Grouping by a field of a linked row,
   anti-joins (`NOT EXISTS`), correlated subqueries and views all take
   Luau code.

[Gaps](#gaps) lists each missing feature with the queries that need it.

## TPC-H

TPC-H is a decision-support benchmark of eight tables around orders and
their line items, with 22 queries.

### Schema

| SQL | lent |
|---|---|
| `REGION`, `NATION`, `PART`, `SUPPLIER`, `CUSTOMER`, `ORDERS`, `LINEITEM` | one `lent.schema` each, with `id = "int"` |
| primary keys such as `O_ORDERKEY` | the row's `id`, given to `create` |
| foreign keys such as `O_CUSTKEY` | `edge.from "customer" "Customer":ref "orders":unique()` |
| `PARTSUPP`, keyed by part and supplier | `edge.to "supplies" "Supplier"` on `Part`, with `:fields` for `PS_AVAILQTY`, `PS_SUPPLYCOST` and `PS_COMMENT` |
| `LINEITEM` key `(L_ORDERKEY, L_LINENUMBER)` | a `linenumber` field and the `order` edge; lent does not enforce the pair as unique |
| `DECIMAL(15,2)` | `decimal` with `:scale(2)`; the test keeps `int` cents and percent so revenue products stay exact |
| `DATE` | `time` at midnight UTC; `lent.date("1995-03-15")` and `date('1995-03-15')` in an expression |
| `CHAR(1)` flags and fixed lists | `enum` |
| line item to customer, used for grouping | `edge.through "customer" "Customer":via "order.customer"` |

The loader gives each row its TPC-H key as its `id`, so foreign key values
name the linked rows directly.

### Queries

"Verified" queries are in `tests/test_tpch.py`. The others are described
from the query text.

| query | status | how lent answers it, or what it lacks |
|---|---|---|
| Q1 pricing summary | verified | `where` on `shipdate`, `groupBy("returnflag", "linestatus")`, sums with `value` functions, and `avg` |
| Q2 minimum cost supplier | Luau | `links("parts")` from suppliers in a region, then the minimum cost per part in Luau; `LIKE '%BRASS'` needs a `where` function |
| Q3 shipping priority | verified | nested `hasOrderWith` and `hasCustomerWith`, `groupBy("order")`, then sort by revenue and order date and limit in Luau, since the order date is not a group key |
| Q4 order priority checking | verified | `hasLinesWith` with the expression `commitdate < receiptdate` for `EXISTS` |
| Q5 local supplier volume | Luau | needs the customer's nation to equal the supplier's nation, a condition across two paths; load both with `with` and compare in Luau |
| Q6 forecasting revenue change | verified | one expression filter read through `by_shipdate` |
| Q7 volume shipping | Luau | nation pairs as in Q5, and the year of `shipdate` |
| Q8 national market share | Luau | eight-table join, the year of `orderdate`, and a `CASE` share |
| Q9 product type profit | Luau | `LIKE '%green%'`, the `PARTSUPP` cost per line through `c.Part:edge("supplies", part, supplier)`, and the year |
| Q10 returned item reporting | verified | `groupBy("customer")` over the path edge with `order("revenue", "desc"):limit(20)`, then each customer `withNation` |
| Q11 important stock | verified | `links("parts")` reads the `PARTSUPP` values; `HAVING` against a total in Luau |
| Q12 shipping modes | verified | `IN` as an `or` of `==`; each `CASE` sum is a separate `hasOrderWith` query |
| Q13 customer distribution | verified | `withOrders` keeps customers without orders, as `LEFT OUTER JOIN` does; `NOT LIKE` as a `where` function |
| Q14 promotion effect | verified | `LIKE 'PROMO%'` as the range `type >= 'PROMO' and type < 'PROMP'`, read through `by_type` |
| Q15 top supplier | Luau | uses a view; `groupBy("supplier")` with `order("revenue", "desc")` finds the maximum |
| Q16 parts/supplier relationship | Luau | `NOT IN` a subquery; `count` with `distinct = true` counts the suppliers |
| Q17 small-quantity-order revenue | Luau | a correlated `avg` per part: one `groupBy("part")` pass, then a second pass |
| Q18 large volume customer | verified | `groupBy("order")` with `having("qty > q", { q = 300 })`, then each order `withCustomer` |
| Q19 discounted revenue | Luau | three `OR` branches over line and part fields; the branches select different brands, so three `hasPartWith` queries add up |
| Q20 potential part promotion | Luau | nested `IN` subqueries and a correlated sum |
| Q21 suppliers who kept orders waiting | Luau | `EXISTS` and `NOT EXISTS` over other lines of the same order |
| Q22 global sales opportunity | Luau | `SUBSTRING` of the phone number, `avg` of a subquery, and `NOT EXISTS` orders |

## New York taxi trips

The New York City Taxi and Limousine Commission publishes every yellow taxi
trip: about 3 million rows a month, with 19 columns of times, distances,
codes and money amounts, and a lookup table of 265 zones.

| SQL column | lent |
|---|---|
| `tpep_pickup_datetime`, `tpep_dropoff_datetime` | `time` |
| `passenger_count`, nullable | `int` with `:optional()` |
| `trip_distance` and the money columns | `float`; `decimal` with `:scale(2)` keeps sums of cents exact |
| `VendorID`, `RatecodeID`, `payment_type` | `int` codes; an `enum` needs string labels |
| `store_and_fwd_flag` | `bool` |
| `LocationID` of the zone table | the zone's `id`, given to `create` |
| `PULocationID`, `DOLocationID` | `edge.from` to `Zone`, named `origin` and `destination` |

The common taxi benchmark runs four queries over the whole table:

| query | lent |
|---|---|
| count per vendor | `groupBy("vendor")` |
| average total per passenger count | `groupBy("passengers")` with `avg` |
| count per passenger count and pickup year | `groupBy("passengers", "year")`, where `year` is a computed field |
| count per passenger count, year and rounded distance, ordered by year and count | as above with a computed `miles` field, and `order("year"):order("n", "desc")` |

All four are verified in `tests/test_nyc_taxi.py`. The `year` computed
field is `lent.year(r.pickup)`.

These queries read every row, so they show the size limit most clearly. In
a run on one machine, `count()`, `sum` and each benchmark query took about
0.5 s for 30,000 trips, and all of them ended with `FUNCTION timeout` at
100,000 trips under the default 1 s deadline. Loading ran at about 15,000
trips per second.

## Sakila

Sakila is MySQL's sample database for a DVD rental store: 16 tables with
views, triggers and stored routines. It is an online transaction workload,
so it shows which schema features lent lacks more than query speed. This
section is based on the schema text and has no test.

| Sakila feature | lent |
|---|---|
| `SMALLINT UNSIGNED AUTO_INCREMENT` keys | `id = "int"`; a load gives each row its key as `id` |
| `film_actor` and `film_category`, keyed by two foreign keys plus `last_update` | an edge with a `time` field |
| `last_update ... ON UPDATE CURRENT_TIMESTAMP` | `:default(lent.now):updateDefault(lent.now)` |
| `rating ENUM(...)` | `enum` |
| `special_features SET(...)` | a `json` list, or one `bool` field per choice |
| `release_year YEAR` | `int` with `:min` and `:max` |
| `rental_rate DECIMAL(4,2)`, `amount DECIMAL(5,2)` | `decimal` with `:scale(2)` |
| `staff.picture BLOB` | `bytes` |
| `address.location GEOMETRY` with a spatial index | `bytes` or `json`; lent has no spatial index |
| `film_text` with a `FULLTEXT` index | lent has no text search |
| triggers that fill `create_date` and copy films to `film_text` | `:default` and `create`, `update` and `delete` hooks |
| foreign keys `ON DELETE RESTRICT ON UPDATE CASCADE` | `delete` removes the row's links; a `delete` hook can refuse or cascade |
| seven views, such as `customer_list` and `sales_by_store` | a Luau function that builds the query |
| stored functions such as `inventory_in_stock` | Luau functions |

## Gaps

Each entry names the feature, the workloads that need it, and the TODO
item it belongs to.

1. **Aggregates over large tables.** Every taxi query and most TPC-H
   queries read more rows than one call allows. Aggregates need partial
   results that continue across calls, as paged migrations do. This is the
   analytics item; column formats reduce the cost per row.
2. **`count()` reads rows.** An unfiltered `count()` decodes every row,
   at the same speed as a sum. A key count over the table or an index range
   would answer it without decoding.
3. **Natural keys.** Done: `create` takes an `id`, so a table keyed by one
   positive integer or a uuid keeps its keys, and edges name rows by them.
   String and composite keys still need a unique field and a key-to-id map
   when loading.
4. **Decimal values.** Done: a `decimal` field rounds each value to its
   scale and sums it exactly. A `sum` with a `value` function, such as
   TPC-H revenue `l_extendedprice * (1 - l_discount)`, still adds floats.
5. **Dates and their parts.** Done: `lent.date("1995-03-15")`,
   `lent.year`, `lent.month`, `lent.day` and `lent.addMonths` cover `DATE`
   literals, `EXTRACT` and `INTERVAL` months in computed fields, and
   expressions call `date`, `year`, `month` and `day`. A filter such as
   `year(shipdate) = 1995` checks each row; compare with date bounds to read
   an index.
6. **More aggregates and group forms.** Done: `avg`, `distinct` on
   `count`, `sum` and `avg`, and `having`, `order`, `limit` and `offset` on
   `groupBy` cover Q1, Q10, Q16's count, Q18 and the taxi benchmark. Q3
   orders its groups by a column outside the group, and Q11 compares each
   group with a total from a second query, so both still sort or filter in
   Luau.
7. **Grouping by a linked row's field.** `groupBy` takes an edge and
   groups by the linked row's id. TPC-H groups by nation name (Q5, Q7, Q8)
   and the taxi data by borough, which takes a second pass in Luau.
8. **Views.** TPC-H Q15 and seven Sakila views are named queries. A view
   could be a named query declared in the graph and read like a table, and
   a stored view could keep its rows current on each write, as stored path
   edges do.
9. **Anti-joins and subqueries.** `NOT EXISTS` (Q21, Q22) needs a negated
   `has`. Correlated subqueries (Q2, Q17, Q20) run as two passes in Luau.
10. **Composite keys that include an edge.** A unique index takes fields
    only, so `(L_ORDERKEY, L_LINENUMBER)` cannot be unique.
11. **String patterns.** A `LIKE` prefix works as a range on an index. A
    pattern elsewhere in the string needs a `where` function, because
    expressions call only the date functions.
12. **Luau integers.** Done: lent takes the Luau `integer` values that
    `simdjson.parse` answers for whole numbers beyond 32 bits, such as
    millisecond times, wherever it takes a number, and the tests pass
    parsed arguments straight to lent.
13. **Sakila types.** `SET`, spatial values and full-text search have no
    lent form. A `SET` fits a `json` list today.
