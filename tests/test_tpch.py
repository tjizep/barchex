import datetime
import json
import random
import sqlite3

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# The TPC-H schema in lent, loaded with a small generated dataset. Each test
# runs one TPC-H query twice: as SQL in SQLite, and as lent queries plus the
# Luau that lent has no query form for. Money is in cents and discount and
# tax in percent, so both sides add whole numbers.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local f = lent.field

-- l_extendedprice * (1 - l_discount), in cents times 100
local function revenue(l) return l.extendedprice * (100 - l.discount) end

local app = lent.graph {
    lent.schema "Region" {
        id = "int",
        fields = { f.string "name", f.string "comment" },
        edges = { lent.edge.to "nations" "Nation" },
    },
    lent.schema "Nation" {
        id = "int",
        fields = { f.string "name", f.string "comment" },
        edges = {
            lent.edge.from "region" "Region":ref "nations":unique(),
            lent.edge.to "customers" "Customer",
            lent.edge.to "suppliers" "Supplier",
        },
    },
    lent.schema "Part" {
        id = "int",
        fields = {
            f.string "name", f.string "mfgr", f.string "brand",
            f.string "type", f.int "size", f.string "container", f.int "retailprice",
            f.string "comment",
        },
        indexes = { lent.index("type") },
        edges = {
            -- PARTSUPP: one link per part and supplier, holding its columns
            lent.edge.to "supplies" "Supplier":fields {
                f.int "availqty", f.int "supplycost", f.string "comment",
            },
            lent.edge.to "lines" "Lineitem",
        },
    },
    lent.schema "Supplier" {
        id = "int",
        fields = {
            f.string "name", f.string "address", f.string "phone",
            f.int "acctbal", f.string "comment",
        },
        edges = {
            lent.edge.from "nation" "Nation":ref "suppliers":unique(),
            lent.edge.from "parts" "Part":ref "supplies",
            lent.edge.to "lines" "Lineitem",
        },
    },
    lent.schema "Customer" {
        id = "int",
        fields = {
            f.string "name", f.string "address", f.string "phone",
            f.int "acctbal",
            f.enum "mktsegment":values("AUTOMOBILE", "BUILDING", "FURNITURE",
                                       "HOUSEHOLD", "MACHINERY"),
            f.string "comment",
        },
        edges = {
            lent.edge.from "nation" "Nation":ref "customers":unique(),
            lent.edge.to "orders" "Order",
        },
    },
    lent.schema "Order" {
        id = "int",
        fields = {
            f.enum "orderstatus":values("F", "O", "P"),
            f.int "totalprice", f.time "orderdate", f.string "orderpriority",
            f.string "clerk", f.int "shippriority", f.string "comment",
        },
        indexes = { lent.index("orderdate") },
        edges = {
            lent.edge.from "customer" "Customer":ref "orders":unique(),
            lent.edge.to "lines" "Lineitem",
        },
    },
    lent.schema "Lineitem" {
        id = "int",
        fields = {
            f.int "linenumber", f.int "quantity", f.int "extendedprice",
            f.int "discount", f.int "tax",
            f.enum "returnflag":values("A", "N", "R"), f.enum "linestatus":values("F", "O"),
            f.time "shipdate", f.time "commitdate", f.time "receiptdate",
            f.string "shipinstruct",
            f.enum "shipmode":values("AIR", "FOB", "MAIL", "RAIL", "REG AIR", "SHIP", "TRUCK"),
            f.string "comment",
        },
        indexes = { lent.index("shipdate") },
        edges = {
            lent.edge.from "order" "Order":ref "lines":unique(),
            lent.edge.from "part" "Part":ref "lines":unique(),
            lent.edge.from "supplier" "Supplier":ref "lines":unique(),
            lent.edge.through "customer" "Customer":via "order.customer",
        },
    },
    -- Q15's revenue0 view: each supplier's revenue from the lines shipped
    -- from a to b
    lent.view "Revenue" {
        fields = { f.int "supplier", f.int "revenue" },
        rows = function(c, p)
            return c.Lineitem:query():where("shipdate >= a and shipdate < b", p)
                :groupBy("supplier"):aggregate { revenue = { fn = "sum", value = revenue } }
        end,
    },
}
local db = client.open(app)

-- sorts `list` by the keys `by` names, each "name" or "-name" for descending
local function sort(list, by)
    table.sort(list, function(a, b)
        for _, k in by do
            local desc = string.sub(k, 1, 1) == "-"
            local name = desc and string.sub(k, 2) or k
            if a[name] ~= b[name] then
                if desc then return a[name] > b[name] end
                return a[name] < b[name]
            end
        end
        return false
    end)
    return list
end

local function pick(list, names, limit)
    local out = {}
    for i, r in list do
        if limit and i > limit then break end
        local row = {}
        for j, n in names do row[j] = r[n] end
        out[i] = row
    end
    return out
end

local q = {}

function q.load(c, data)
    -- each row keeps its TPC-H key as its id, so edges name rows by their keys
    local function add(tbl, rows)
        for _, r in rows do
            r.id, r.key = r.key, nil
            c[tbl]:create(r)
        end
    end
    add("Region", data.region)
    add("Nation", data.nation)
    add("Part", data.part)
    add("Supplier", data.supplier)
    for _, ps in data.partsupp do
        c.Part:link("supplies", ps.part, ps.supplier,
                    { availqty = ps.availqty, supplycost = ps.supplycost, comment = ps.comment })
    end
    add("Customer", data.customer)
    add("Order", data.orders)
    c.Lineitem:createMany(data.lineitem)
    return "ok"
end

-- Q1, pricing summary report
function q.q1(c, p)
    local groups = c.Lineitem:query():where("shipdate <= d", p)
        :groupBy("returnflag", "linestatus"):aggregate {
            qty = { fn = "sum", field = "quantity" },
            base = { fn = "sum", field = "extendedprice" },
            disc = { fn = "sum", value = revenue },
            charge = { fn = "sum", value = function(l) return revenue(l) * (100 + l.tax) end },
            avgqty = { fn = "avg", field = "quantity" },
            avgprice = { fn = "avg", field = "extendedprice" },
            avgdisc = { fn = "avg", field = "discount" },
            n = { fn = "count" },
        }
    -- a reply turns a float into an integer, so floats go back as text
    for _, g in groups do
        for _, k in { "avgqty", "avgprice", "avgdisc" } do g[k] = string.format("%.17g", g[k]) end
    end
    return pick(groups, { "returnflag", "linestatus", "qty", "base", "disc", "charge",
                          "avgqty", "avgprice", "avgdisc", "n" })
end

-- Q3, shipping priority
function q.q3(c, p)
    local groups = c.Lineitem:query():where("shipdate > d", p)
        :hasOrderWith(function(o)
            o:where("orderdate < d", p):hasCustomerWith(function(cu)
                cu:where("mktsegment", "=", p.segment)
            end)
        end)
        :groupBy("order", "order.orderdate", "order.shippriority")
        :order("revenue", "desc"):order("order.orderdate"):limit(10)
        :aggregate { revenue = { fn = "sum", value = revenue } }
    return pick(groups, { "order", "revenue", "order.orderdate", "order.shippriority" })
end

-- Q4, order priority checking
function q.q4(c, p)
    local groups = c.Order:query():where("orderdate >= a and orderdate < b", p)
        :hasLinesWith(function(l) l:where("commitdate < receiptdate") end)
        :groupBy("orderpriority"):aggregate { n = { fn = "count" } }
    return pick(groups, { "orderpriority", "n" })
end

-- Q6, forecasting revenue change
function q.q6(c, p)
    local query = c.Lineitem:query():where(
        "shipdate >= a and shipdate < b and discount >= lo and discount <= hi and quantity < qty", p)
    local t = query:aggregate {
        revenue = { fn = "sum", value = function(l) return l.extendedprice * l.discount end },
    }
    return { t.revenue, query:explain() }
end

-- Q10, returned item reporting
function q.q10(c, p)
    local groups = c.Lineitem:query():where("returnflag", "=", "R")
        :hasOrderWith(function(o) o:where("orderdate >= a and orderdate < b", p) end)
        :groupBy("customer", "customer.name", "customer.acctbal", "customer.nation.name")
        :order("revenue", "desc"):limit(20)
        :aggregate { revenue = { fn = "sum", value = revenue } }
    return pick(groups, { "customer", "customer.name", "revenue", "customer.acctbal",
                          "customer.nation.name" })
end

-- Q11, important stock identification
function q.q11(c, p)
    local links = c.Supplier:query()
        :hasNationWith(function(n) n:where("name", "=", p.nation) end)
        :links("parts"):all()
    local value, total = {}, 0
    for _, l in links do
        local v = l.supplycost * l.availqty
        value[l.to] = (value[l.to] or 0) + v
        total += v
    end
    local out = {}
    for part, v in value do
        if v * p.inverse > total then
            out[#out + 1] = { key = part, value = v }
        end
    end
    sort(out, { "-value", "key" })
    return pick(out, { "key", "value" })
end

-- Q12, shipping modes and order priority
function q.q12(c, p)
    local function lines()
        return c.Lineitem:query():where(
            "(shipmode == m1 or shipmode == m2) and commitdate < receiptdate"
            .. " and shipdate < commitdate and receiptdate >= a and receiptdate < b", p)
    end
    local urgent = "orderpriority == '1-URGENT' or orderpriority == '2-HIGH'"
    local high = lines():hasOrderWith(function(o) o:where(urgent) end)
        :groupBy("shipmode"):aggregate { n = { fn = "count" } }
    local low = lines():hasOrderWith(function(o) o:where("not (" .. urgent .. ")") end)
        :groupBy("shipmode"):aggregate { n = { fn = "count" } }
    local modes = {}
    for _, g in high do modes[g.shipmode] = { shipmode = g.shipmode, high = g.n, low = 0 } end
    for _, g in low do
        modes[g.shipmode] = modes[g.shipmode] or { shipmode = g.shipmode, high = 0 }
        modes[g.shipmode].low = g.n
    end
    local out = {}
    for _, r in modes do out[#out + 1] = r end
    return pick(sort(out, { "shipmode" }), { "shipmode", "high", "low" })
end

-- Q13, customer distribution
function q.q13(c, p)
    local customers = c.Customer:query():withOrders(function(o)
        o:where(function(r) return not string.find(r.comment, p.pattern) end)
    end):all()
    local dist = {}
    for _, cu in customers do dist[#cu.orders] = (dist[#cu.orders] or 0) + 1 end
    local out = {}
    for n, d in dist do out[#out + 1] = { count = n, custdist = d } end
    return pick(sort(out, { "-custdist", "-count" }), { "count", "custdist" })
end

-- Q14, promotion effect
function q.q14(c, p)
    local function lines() return c.Lineitem:query():where("shipdate >= a and shipdate < b", p) end
    local promo = lines():hasPartWith(function(pt)
        pt:where("type >= 'PROMO' and type < 'PROMP'")
    end)
    local spec = { revenue = { fn = "sum", value = revenue } }
    return { promo:aggregate(spec).revenue, lines():aggregate(spec).revenue, promo:explain() }
end

-- Q15, top supplier: the suppliers with the most revenue in the view
function q.q15(c, p)
    local top = c.Revenue:query(p):max("revenue")
    local out = {}
    for _, r in c.Revenue:query(p):where("revenue == top", { top = top }):order("supplier"):all() do
        local s = c.Supplier:get(r.supplier)
        out[#out + 1] = { s.id, s.name, s.address, s.phone, r.revenue }
    end
    return out
end

-- Q17, small-quantity-order revenue: a correlated subquery, run as two
-- passes. The first finds each part's average quantity, and the second
-- compares each line with its part's average.
function q.q17(c, p)
    local function lines()
        return c.Lineitem:query():hasPartWith(function(pt)
            pt:where("brand", "=", p.brand):where("container", "=", p.container)
        end)
    end
    local avg = {}
    for _, g in lines():groupBy("part"):aggregate { qty = { fn = "avg", field = "quantity" } } do
        avg[g.part] = g.qty
    end
    local total = 0
    for _, l in lines():withPart():all() do
        if l.quantity < 0.2 * avg[l.part.id] then
            total += l.extendedprice
        end
    end
    return string.format("%.17g", total / 7)
end

function q.q18(c, p)
    local groups = c.Lineitem:query()
        :groupBy("order", "order.orderdate", "order.totalprice", "order.customer",
                 "order.customer.name")
        :having("qty > q", { q = p.qty })
        :order("order.totalprice", "desc"):order("order.orderdate"):limit(100)
        :aggregate { qty = { fn = "sum", field = "quantity" } }
    return pick(groups, { "order.customer.name", "order.customer", "order", "order.orderdate",
                          "order.totalprice", "qty" })
end

-- Q21, suppliers who kept orders waiting: lines of finished orders that a
-- nation's supplier delivered late, where another supplier shipped part of
-- the order and was on time. The lines of one order are compared in Luau.
function q.q21(c, p)
    local suppliers = {}
    for _, s in c.Supplier:query()
        :hasNationWith(function(n) n:where("name", "=", p.nation) end):all() do
        suppliers[s.id] = s
    end
    local late = "receiptdate > commitdate"
    local orders = c.Order:query():where("orderstatus", "=", "F")
        :hasLinesWith(function(l)
            l:where(late):hasSupplierWith(function(s)
                s:hasNationWith(function(n) n:where("name", "=", p.nation) end)
            end)
        end)
        :withLines(function(l) l:withSupplier() end):all()
    local waits = {}
    for _, o in orders do
        for _, l1 in o.lines do
            local s = suppliers[l1.supplier.id]
            if s and l1.receiptdate > l1.commitdate then
                local other, otherLate = false, false
                for _, l2 in o.lines do
                    if l2.supplier.id ~= s.id then
                        other = true
                        otherLate = otherLate or l2.receiptdate > l2.commitdate
                    end
                end
                if other and not otherLate then
                    waits[s.name] = (waits[s.name] or 0) + 1
                end
            end
        end
    end
    local out = {}
    for name, n in waits do out[#out + 1] = { name = name, numwait = n } end
    return pick(sort(out, { "-numwait", "name" }), { "name", "numwait" }, 100)
end

-- Q22, global sales opportunity: customers with an above-average balance
-- and no orders, by the country code in their phone number
function q.q22(c, p)
    local codes = {}
    for _, code in p.codes do codes[code] = true end
    local function inCodes(cu) return codes[string.sub(cu.phone, 1, 2)] == true end
    local avg = c.Customer:query():where("acctbal > 0"):where(inCodes)
        :aggregate({ a = { fn = "avg", field = "acctbal" } }).a
    local groups = {}
    for _, cu in c.Customer:query():where(inCodes):where("acctbal > a", { a = avg })
        :hasNoOrders():all() do
        local code = string.sub(cu.phone, 1, 2)
        local g = groups[code] or { code = code, n = 0, total = 0 }
        g.n += 1
        g.total += cu.acctbal
        groups[code] = g
    end
    local out = {}
    for _, g in groups do out[#out + 1] = g end
    return pick(sort(out, { "code" }), { "code", "n", "total" })
end

function call(step, arg)
    if step == "migrate" then
        return m.migrate(app).done and "done" or "more"
    end
    return db.tx(function(c) return q[step](c, simdjson.parse(arg)) end)
end
"""

SCHEMA = """
create table region (r_regionkey int primary key, r_name text, r_comment text);
create table nation (n_nationkey int primary key, n_name text, n_regionkey int,
                     n_comment text);
create table part (p_partkey int primary key, p_name text, p_mfgr text, p_brand text,
                   p_type text, p_size int, p_container text, p_retailprice int,
                   p_comment text);
create table supplier (s_suppkey int primary key, s_name text, s_address text,
                       s_nationkey int, s_phone text, s_acctbal int, s_comment text);
create table partsupp (ps_partkey int, ps_suppkey int, ps_availqty int, ps_supplycost int,
                       ps_comment text, primary key (ps_partkey, ps_suppkey));
create table customer (c_custkey int primary key, c_name text, c_address text,
                       c_nationkey int, c_phone text, c_acctbal int, c_mktsegment text,
                       c_comment text);
create table orders (o_orderkey int primary key, o_custkey int, o_orderstatus text,
                     o_totalprice int, o_orderdate text, o_orderpriority text, o_clerk text,
                     o_shippriority int, o_comment text);
create table lineitem (l_orderkey int, l_partkey int, l_suppkey int, l_linenumber int,
                       l_quantity int, l_extendedprice int, l_discount int, l_tax int,
                       l_returnflag text, l_linestatus text, l_shipdate text,
                       l_commitdate text, l_receiptdate text, l_shipinstruct text,
                       l_shipmode text, l_comment text,
                       primary key (l_orderkey, l_linenumber));
"""

EPOCH = datetime.date(1970, 1, 1)


def ms(d):
    return (d - EPOCH).days * 86400000


def day(s):
    return datetime.date.fromisoformat(s)


def generate():
    rnd = random.Random(7)
    data = {"region": [], "nation": [], "part": [], "supplier": [], "partsupp": [],
            "customer": [], "orders": [], "lineitem": []}
    for k, name in enumerate(["AMERICA", "EUROPE"], 1):
        data["region"].append({"key": k, "name": name, "comment": "r" + name})
    for k, (name, region) in enumerate(
            [("BRAZIL", 1), ("CANADA", 1), ("FRANCE", 2), ("GERMANY", 2)], 1):
        data["nation"].append({"key": k, "name": name, "region": region, "comment": "n"})
    types = ["PROMO BRUSHED TIN", "STANDARD POLISHED BRASS", "PROMO ANODIZED STEEL",
             "ECONOMY PLATED COPPER", "LARGE BRUSHED BRASS", "PROMO PLATED NICKEL",
             "SMALL BURNISHED TIN", "MEDIUM ANODIZED COPPER"]
    for k, t in enumerate(types, 1):
        data["part"].append({
            "key": k, "name": "part %d" % k, "mfgr": "Manufacturer#%d" % (k % 3 + 1),
            "brand": "Brand#%d" % (k % 5 + 1), "type": t, "size": rnd.randint(1, 50),
            "container": rnd.choice(["SM BOX", "LG CASE", "MED BAG"]),
            "retailprice": rnd.randint(90000, 200000), "comment": "p"})
    for k in range(1, 5):
        data["supplier"].append({
            "key": k, "name": "Supplier#%d" % k, "address": "a%d" % k, "nation": k,
            "phone": "1-%d" % k, "acctbal": rnd.randint(-99999, 999999), "comment": "s"})
    for p in range(1, 9):
        for s in [p % 4 + 1, (p + 1) % 4 + 1]:
            data["partsupp"].append({
                "part": p, "supplier": s, "availqty": rnd.randint(1, 9999),
                "supplycost": rnd.randint(100, 100000), "comment": "ps"})
    for k in range(1, 13):
        data["customer"].append({
            "key": k, "name": "Customer#%d" % k, "address": "c%d" % k,
            "nation": rnd.randint(1, 4), "phone": "2-%d" % k,
            "acctbal": rnd.randint(-99999, 999999),
            "mktsegment": rnd.choice(["AUTOMOBILE", "BUILDING", "MACHINERY"]), "comment": "c"})
    priorities = ["1-URGENT", "2-HIGH", "3-MEDIUM", "4-NOT SPECIFIED", "5-LOW"]
    modes = ["AIR", "FOB", "MAIL", "RAIL", "REG AIR", "SHIP", "TRUCK"]
    cutoff = day("1995-06-17")
    supplies = {}
    for ps in data["partsupp"]:
        supplies.setdefault(ps["part"], []).append(ps["supplier"])
    for k in range(1, 61):
        orderdate = day("1994-01-01") + datetime.timedelta(days=rnd.randint(0, 3 * 365))
        lines = []
        for n in range(1, rnd.randint(1, 7) + 1):
            part = rnd.randint(1, 8)
            qty = rnd.randint(1, 50)
            shipdate = orderdate + datetime.timedelta(days=rnd.randint(1, 120))
            receiptdate = shipdate + datetime.timedelta(days=rnd.randint(1, 30))
            lines.append({
                "order": k, "part": part, "supplier": rnd.choice(supplies[part]),
                "linenumber": n, "quantity": qty,
                "extendedprice": qty * data["part"][part - 1]["retailprice"],
                "discount": rnd.randint(0, 10), "tax": rnd.randint(0, 8),
                "returnflag": rnd.choice("AR") if receiptdate <= cutoff else "N",
                "linestatus": "F" if shipdate <= cutoff else "O",
                "shipdate": shipdate,
                "commitdate": orderdate + datetime.timedelta(days=rnd.randint(30, 90)),
                "receiptdate": receiptdate,
                "shipinstruct": rnd.choice(["DELIVER IN PERSON", "NONE", "TAKE BACK RETURN"]),
                "shipmode": rnd.choice(modes), "comment": "l"})
        data["lineitem"] += lines
        statuses = {l["linestatus"] for l in lines}
        data["orders"].append({
            "key": k, "customer": rnd.randint(1, 10),
            "orderstatus": "F" if statuses == {"F"} else "O" if statuses == {"O"} else "P",
            "totalprice": sum(l["extendedprice"] for l in lines),
            "orderdate": orderdate, "orderpriority": rnd.choice(priorities),
            "clerk": "Clerk#%d" % rnd.randint(1, 5), "shippriority": 0,
            "comment": rnd.choice(["quick special pending requests", "regular deposits",
                                   "furious special accounts requests", "blithely final"])})
    return data


def sqlite_db(data):
    db = sqlite3.connect(":memory:")
    db.executescript(SCHEMA)
    iso = lambda v: v.isoformat() if isinstance(v, datetime.date) else v

    def put(table, rows, cols):
        db.executemany("insert into %s values (%s)" % (table, ",".join("?" * len(cols))),
                       [[iso(r[c]) for c in cols] for r in rows])

    put("region", data["region"], ["key", "name", "comment"])
    put("nation", data["nation"], ["key", "name", "region", "comment"])
    put("part", data["part"], ["key", "name", "mfgr", "brand", "type", "size", "container",
                               "retailprice", "comment"])
    put("supplier", data["supplier"], ["key", "name", "address", "nation", "phone", "acctbal",
                                       "comment"])
    put("partsupp", data["partsupp"], ["part", "supplier", "availqty", "supplycost", "comment"])
    put("customer", data["customer"], ["key", "name", "address", "nation", "phone", "acctbal",
                                       "mktsegment", "comment"])
    put("orders", data["orders"], ["key", "customer", "orderstatus", "totalprice", "orderdate",
                                   "orderpriority", "clerk", "shippriority", "comment"])
    put("lineitem", data["lineitem"], ["order", "part", "supplier", "linenumber", "quantity",
                                       "extendedprice", "discount", "tax", "returnflag",
                                       "linestatus", "shipdate", "commitdate", "receiptdate",
                                       "shipinstruct", "shipmode", "comment"])
    return db


def to_lent(v):
    return ms(v) if isinstance(v, datetime.date) else v


# One load serves every query in this file, so the fixture uses the server
# directly; the client fixture empties the default space for each test.
@pytest.fixture(scope="module")
def tpch(server):
    client = server.client
    data = generate()
    setup(client)
    client.execute_command("USE", "tpch")
    client.execute_command("FLUSHDB")
    client.execute_command("SETF", "TPCH", APP)

    def run(step, arg=None):
        client.execute_command("USE", "tpch")
        return client.execute_command("CALLF", "TPCH", step, json.dumps(arg or {}))

    assert run("migrate") == "done"
    lent_data = {t: [{k: to_lent(v) for k, v in r.items()} for r in rows]
                 for t, rows in data.items()}
    assert run("load", lent_data) == "ok"
    db = sqlite_db(data)
    sql = lambda text, **p: [list(r) for r in db.execute(text, p).fetchall()]
    return run, sql


def dates(rows, *cols):
    # SQLite answers ISO dates; lent answers Unix milliseconds
    for r in rows:
        for c in cols:
            r[c] = ms(day(r[c]))
    return rows


def test_q1_pricing_summary(tpch):
    run, sql = tpch
    want = sql("""
        select l_returnflag, l_linestatus, sum(l_quantity), sum(l_extendedprice),
               sum(l_extendedprice * (100 - l_discount)),
               sum(l_extendedprice * (100 - l_discount) * (100 + l_tax)),
               avg(l_quantity), avg(l_extendedprice), avg(l_discount), count(*)
        from lineitem where l_shipdate <= :d
        group by l_returnflag, l_linestatus order by l_returnflag, l_linestatus""",
               d="1996-06-01")
    want = [r[:6] + ["%.17g" % v for v in r[6:9]] + r[9:] for r in want]
    assert len(want) == 4
    assert run("q1", {"d": ms(day("1996-06-01"))}) == want


def test_q3_shipping_priority(tpch):
    run, sql = tpch
    want = dates(sql("""
        select l_orderkey, sum(l_extendedprice * (100 - l_discount)) as revenue,
               o_orderdate, o_shippriority
        from customer, orders, lineitem
        where c_mktsegment = :segment and c_custkey = o_custkey and l_orderkey = o_orderkey
          and o_orderdate < :d and l_shipdate > :d
        group by l_orderkey, o_orderdate, o_shippriority
        order by revenue desc, o_orderdate, l_orderkey limit 10""",
                     segment="BUILDING", d="1995-03-15"), 2)
    assert want
    assert run("q3", {"segment": "BUILDING", "d": ms(day("1995-03-15"))}) == want


def test_q4_order_priority(tpch):
    run, sql = tpch
    want = sql("""
        select o_orderpriority, count(*) from orders
        where o_orderdate >= :a and o_orderdate < :b and exists (
            select * from lineitem where l_orderkey = o_orderkey
              and l_commitdate < l_receiptdate)
        group by o_orderpriority order by o_orderpriority""",
               a="1995-01-01", b="1996-01-01")
    assert want
    got = run("q4", {"a": ms(day("1995-01-01")), "b": ms(day("1996-01-01"))})
    assert got == want


def test_q6_forecasting_revenue(tpch):
    run, sql = tpch
    [[want]] = sql("""
        select sum(l_extendedprice * l_discount) from lineitem
        where l_shipdate >= :a and l_shipdate < :b
          and l_discount between :lo and :hi and l_quantity < :qty""",
                   a="1994-01-01", b="1995-01-01", lo=5, hi=7, qty=24)
    assert want
    got = run("q6", {"a": ms(day("1994-01-01")), "b": ms(day("1995-01-01")),
                     "lo": 5, "hi": 7, "qty": 24})
    assert got == [want, "by_shipdate range shipdate"]


def test_q10_returned_items(tpch):
    run, sql = tpch
    want = sql("""
        select c_custkey, c_name, sum(l_extendedprice * (100 - l_discount)) as revenue,
               c_acctbal, n_name
        from customer, orders, lineitem, nation
        where c_custkey = o_custkey and l_orderkey = o_orderkey
          and o_orderdate >= :a and o_orderdate < :b and l_returnflag = 'R'
          and c_nationkey = n_nationkey
        group by c_custkey, c_name, c_acctbal, n_name
        order by revenue desc, c_custkey limit 20""", a="1994-01-01", b="1995-01-01")
    assert want
    got = run("q10", {"a": ms(day("1994-01-01")), "b": ms(day("1995-01-01"))})
    assert got == want


def test_q11_important_stock(tpch):
    run, sql = tpch
    want = sql("""
        select ps_partkey, sum(ps_supplycost * ps_availqty) as value
        from partsupp, supplier, nation
        where ps_suppkey = s_suppkey and s_nationkey = n_nationkey and n_name = :nation
        group by ps_partkey having sum(ps_supplycost * ps_availqty) * :inverse > (
            select sum(ps_supplycost * ps_availqty) from partsupp, supplier, nation
            where ps_suppkey = s_suppkey and s_nationkey = n_nationkey and n_name = :nation)
        order by value desc, ps_partkey""", nation="GERMANY", inverse=4)
    assert want
    assert run("q11", {"nation": "GERMANY", "inverse": 4}) == want


def test_q12_shipping_modes(tpch):
    run, sql = tpch
    want = sql("""
        select l_shipmode,
               sum(case when o_orderpriority in ('1-URGENT', '2-HIGH') then 1 else 0 end),
               sum(case when o_orderpriority not in ('1-URGENT', '2-HIGH') then 1 else 0 end)
        from orders, lineitem
        where o_orderkey = l_orderkey and l_shipmode in (:m1, :m2)
          and l_commitdate < l_receiptdate and l_shipdate < l_commitdate
          and l_receiptdate >= :a and l_receiptdate < :b
        group by l_shipmode order by l_shipmode""",
               m1="MAIL", m2="SHIP", a="1994-01-01", b="1997-01-01")
    assert want
    got = run("q12", {"m1": "MAIL", "m2": "SHIP", "a": ms(day("1994-01-01")),
                      "b": ms(day("1997-01-01"))})
    assert got == want


def test_q13_customer_distribution(tpch):
    run, sql = tpch
    want = sql("""
        select c_count, count(*) as custdist from (
            select c_custkey, count(o_orderkey) as c_count
            from customer left outer join orders
              on c_custkey = o_custkey and o_comment not like '%special%requests%'
            group by c_custkey)
        group by c_count order by custdist desc, c_count desc""")
    assert run("q13", {"pattern": "special.*requests"}) == want


def test_q14_promotion_effect(tpch):
    run, sql = tpch
    [[promo, total]] = sql("""
        select sum(case when p_type like 'PROMO%'
                        then l_extendedprice * (100 - l_discount) else 0 end),
               sum(l_extendedprice * (100 - l_discount))
        from lineitem, part
        where l_partkey = p_partkey and l_shipdate >= :a and l_shipdate < :b""",
                               a="1995-01-01", b="1996-01-01")
    assert promo and total
    got = run("q14", {"a": ms(day("1995-01-01")), "b": ms(day("1996-01-01"))})
    assert got == [promo, total,
                   "by_shipdate range shipdate, has part from (by_type range type)"]


def test_q15_top_supplier(tpch):
    run, sql = tpch
    want = sql("""
        with revenue0 as (
            select l_suppkey as supplier_no,
                   sum(l_extendedprice * (100 - l_discount)) as total_revenue
            from lineitem where l_shipdate >= :a and l_shipdate < :b
            group by l_suppkey)
        select s_suppkey, s_name, s_address, s_phone, total_revenue
        from supplier, revenue0
        where s_suppkey = supplier_no
          and total_revenue = (select max(total_revenue) from revenue0)
        order by s_suppkey""", a="1996-01-01", b="1996-04-01")
    assert want
    assert run("q15", {"a": ms(day("1996-01-01")), "b": ms(day("1996-04-01"))}) == want


def test_q17_small_quantity_revenue(tpch):
    run, sql = tpch
    [[want]] = sql("""
        select sum(l_extendedprice) / 7.0 from lineitem, part
        where p_partkey = l_partkey and p_brand = :brand and p_container = :container
          and l_quantity < (select 0.2 * avg(l_quantity) from lineitem
                            where l_partkey = p_partkey)""",
                   brand="Brand#2", container="LG CASE")
    assert want
    assert run("q17", {"brand": "Brand#2", "container": "LG CASE"}) == "%.17g" % want


def test_q18_large_volume_customer(tpch):
    run, sql = tpch
    want = dates(sql("""
        select c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice, sum(l_quantity)
        from customer, orders, lineitem
        where o_orderkey in (select l_orderkey from lineitem group by l_orderkey
                             having sum(l_quantity) > :qty)
          and c_custkey = o_custkey and o_orderkey = l_orderkey
        group by c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice
        order by o_totalprice desc, o_orderdate, o_orderkey limit 100""", qty=150), 3)
    assert want
    assert run("q18", {"qty": 150}) == want


def test_q21_suppliers_kept_orders_waiting(tpch):
    run, sql = tpch
    want = sql("""
        select s_name, count(*) as numwait from supplier, lineitem l1, orders, nation
        where s_suppkey = l1.l_suppkey and o_orderkey = l1.l_orderkey
          and o_orderstatus = 'F' and l1.l_receiptdate > l1.l_commitdate
          and exists (select * from lineitem l2 where l2.l_orderkey = l1.l_orderkey
                        and l2.l_suppkey <> l1.l_suppkey)
          and not exists (select * from lineitem l3 where l3.l_orderkey = l1.l_orderkey
                            and l3.l_suppkey <> l1.l_suppkey
                            and l3.l_receiptdate > l3.l_commitdate)
          and s_nationkey = n_nationkey and n_name = :nation
        group by s_name order by numwait desc, s_name limit 100""", nation="FRANCE")
    assert want
    assert run("q21", {"nation": "FRANCE"}) == want


def test_q22_global_sales_opportunity(tpch):
    run, sql = tpch
    want = sql("""
        select cntrycode, count(*), sum(c_acctbal) from (
            select substr(c_phone, 1, 2) as cntrycode, c_acctbal from customer
            where substr(c_phone, 1, 2) in ('2-')
              and c_acctbal > (select avg(c_acctbal) from customer
                               where c_acctbal > 0 and substr(c_phone, 1, 2) in ('2-'))
              and not exists (select * from orders where o_custkey = c_custkey))
        group by cntrycode order by cntrycode""")
    assert want
    assert run("q22", {"codes": ["2-"]}) == want
