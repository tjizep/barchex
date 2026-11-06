import json
import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# A small TPC-H shape: customers and suppliers each have a nation, orders
# have a customer, and lines have an order, a supplier and a price. Line's
# `customer` edge goes through its order. Expression filters on lines read
# the linked rows through dotted names such as `supplier.nation.name`.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local f = lent.field

local app = lent.graph {
    lent.schema "Nation" {
        id = "int", fields = { f.string "name" },
        edges = { lent.edge.to "customers" "Customer", lent.edge.to "suppliers" "Supplier" },
    },
    lent.schema "Customer" {
        id = "int", fields = { f.string "name" },
        edges = {
            lent.edge.from "nation" "Nation":ref "customers":unique(),
            lent.edge.to "orders" "Order",
        },
    },
    lent.schema "Supplier" {
        id = "int", fields = { f.string "name" },
        edges = {
            lent.edge.from "nation" "Nation":ref "suppliers":unique(),
            lent.edge.to "lines" "Line",
        },
    },
    lent.schema "Order" {
        id = "int", fields = { f.string "note" },
        edges = {
            lent.edge.from "customer" "Customer":ref "orders":unique(),
            lent.edge.to "lines" "Line",
        },
    },
    lent.schema "Line" {
        id = "int", FORMAT
        fields = { f.int "price" },
        indexes = { lent.index("price") },
        edges = {
            lent.edge.from "order" "Order":ref "lines":unique(),
            lent.edge.from "supplier" "Supplier":ref "lines":unique(),
            lent.edge.through "customer" "Customer":via "order.customer",
        },
    },
}
local db = client.open(app)

local function ids(q)
    local out = {}
    for _, r in q:order("id"):all() do out[#out + 1] = tostring(r.id) end
    return table.concat(out, ",")
end

local function err(fn)
    local ok, e = pcall(fn)
    return ok and "no error" or tostring(e)
end

local function groups(list)
    local out = {}
    for _, g in list do
        out[#out + 1] = tostring(g["customer.nation.name"]) .. "=" .. tostring(g.total)
    end
    return table.concat(out, ",")
end

local steps = {}

function steps.seed(c)
    for _, n in { "FRANCE", "GERMANY", "BRAZIL" } do c.Nation:create { name = n } end
    -- customer 3 and supplier 3 have no nation
    for i, n in { 1, 2, 0 } do
        c.Customer:create { name = "c" .. i, nation = if n > 0 then n else nil }
        c.Supplier:create { name = "s" .. i, nation = if n > 0 then n else nil }
    end
    for i = 1, 3 do c.Order:create { note = "o" .. i, customer = i } end
    -- line 7 has no supplier, and its customer has no nation
    for _, l in {
        { 1, 1, 10 }, { 1, 2, 20 }, { 2, 2, 30 }, { 2, 1, 40 },
        { 3, 1, 50 }, { 1, 0, 60 }, { 3, 0, 70 },
    } do
        c.Line:create { order = l[1], supplier = if l[2] > 0 then l[2] else nil, price = l[3] }
    end
    return "ok"
end

function steps.reads(c)
    local function q(...) return c.Line:query():where(...) end
    local same = "customer.nation == supplier.nation"
    return {
        ids(q(same)),
        ids(q(same .. " and customer.nation ~= nil")),
        ids(q("supplier.nation.name == 'FRANCE'")),
        ids(q("supplier.nation.name == ? and price > ?", "FRANCE", 15)),
        ids(q("customer.nation.name == want or price >= 60", { want = "GERMANY" })),
        ids(q("customer.nation.name ~= supplier.nation.name")),
        ids(q("supplier.nation == nil")),
        ids(q("supplier == 2 and customer.name == 'c1'")),
        ids(q(same):where("price", ">", 20)),
        tostring(q(same):count()),
        q("price >= 20 and supplier.nation.name == 'GERMANY'"):explain(),
        ids(q("price >= 20 and supplier.nation.name == 'GERMANY'")),
        groups(q(same .. " and customer.nation ~= nil"):groupBy("customer.nation.name")
            :aggregate { total = { fn = "sum", field = "price" } }),
        tostring(q(same):aggregate({ total = { fn = "sum", field = "price" } }).total),
    }
end

function steps.page(c, state)
    local r = c.Line:query():where("customer.nation == supplier.nation and customer.nation ~= nil")
        :groupBy("customer.nation.name")
        :aggregatePage({ total = { fn = "sum", field = "price" } },
                       if state == "" then nil else state, 2)
    return simdjson.encode({ done = r.done, state = r.state or "",
                             result = if r.result then groups(r.result) else "" })
end

function steps.errors(c)
    local function q(...) return c.Line:query():where(...) end
    return {
        err(function() q("supplier.nope == 1") end),
        err(function() q("supplier.lines.price > 1") end),
        err(function() q("supplier..name == 'x'") end),
        err(function() q("supplier.nation.name > ?", 1) end),
        err(function() q("supplier == supplier", { supplier = 1 }) end),
    }
end

function call(step, mode, arg)
    if step == "migrate" then
        return m.migrate(app).done and "done" or "more"
    end
    return db.tx(function(c) return steps[step](c, arg) end, mode == "pessimistic")
end
"""

FORMATS = {"binary": "", "column": 'format = "column",'}


@pytest.fixture(params=[(f, m) for f in FORMATS for m in ["optimistic", "pessimistic"]],
                ids=lambda p: "-".join(p))
def run(client, request):
    setup(client)
    fmt, mode = request.param
    client.execute_command("USE", re.sub(r"\W", "_", "where_paths_" + request.node.name))
    name = "WHEREPATHS" + fmt.upper()
    client.execute_command("SETF", name, APP.replace("FORMAT", FORMATS[fmt]))
    run = lambda step, *args: client.execute_command("CALLF", name, step, mode, *args)
    assert run("migrate") == "done"
    assert run("seed") == "ok"
    return run


def test_dotted_names_read_linked_rows(run):
    assert run("reads") == [
        # line 7 has no supplier and its customer has no nation: nil == nil
        "1,3,7",
        "1,3",
        "1,4,5",
        "4,5",
        "3,4,6,7",
        # a missing link reads nil, and nil differs from a name
        "2,4,5,6",
        "6,7",
        "2",
        "3,7",
        "3",
        # the price index still narrows the rows the path test reads
        "by_price range price",
        "2,3",
        "FRANCE=10,GERMANY=30",
        "110",
    ]


def test_paged_aggregates_read_linked_rows(run):
    state, pages = "", 0
    while True:
        r = json.loads(run("page", state))
        pages += 1
        if r["done"]:
            break
        state = r["state"]
    assert pages > 1
    assert r["result"] == "FRANCE=10,GERMANY=30"


def test_dotted_name_errors(run):
    assert run("errors") == [
        "LENT table Supplier has no field or edge nope",
        "LENT table Supplier edge lines can link a row to many rows, so where cannot use it",
        # `..` joins text, so this reads supplier .. name
        """LENT table Line query where "supplier..name == 'x'" at column 11: has no field or"""
        " parameter name",
        """LENT table Line query where "supplier.nation.name > ?" at column 22: > compares"""
        " field supplier.nation.name (string) with 1",
        """LENT table Line query where "supplier == supplier" at column 1: supplier names both"""
        " a field and a parameter",
    ]
