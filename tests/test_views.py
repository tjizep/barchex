import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Customers in cities rent films for an amount; a customer list view and a
# view of rentals since a time read them, and queries filter, order, page
# and group the view rows as they do table rows.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local f = lent.field

local tables = {
    lent.schema "City" {
        id = "int",
        fields = { f.string "name" },
        edges = { lent.edge.to "customers" "Customer" },
    },
    lent.schema "Customer" {
        id = "int",
        fields = { f.string "name", f.bool "active":default(true) },
        edges = {
            lent.edge.from "city" "City":ref "customers":unique(),
            lent.edge.to "rentals" "Rental",
        },
    },
    lent.schema "Rental" {
        id = "int",
        fields = { f.time "at", f.decimal "amount":scale(2) },
        edges = { lent.edge.from "customer" "Customer":ref "rentals":unique() },
    },
}

local views = {
    -- one row per customer, as Sakila's customer_list
    lent.view "CustomerList" {
        fields = {
            f.int "id", f.string "name", f.string "city":optional(), f.int "rentals",
            f.decimal "paid":scale(2), f.enum "status":values("active", "inactive"),
        },
        rows = function(c)
            local totals = {}
            for _, g in c.Rental:query():groupBy("customer"):aggregate {
                n = { fn = "count" }, paid = { fn = "sum", field = "amount" },
            } do
                totals[g.customer] = g
            end
            local out = {}
            for _, cu in c.Customer:query():with("city"):all() do
                local t = totals[cu.id]
                out[#out + 1] = {
                    id = cu.id, name = cu.name, city = cu.city and cu.city.name,
                    rentals = t and t.n or 0, paid = t and t.paid or 0,
                    status = cu.active and "active" or "inactive",
                }
            end
            return out
        end,
    },
    -- table rows as they are; the view keeps its own fields
    lent.view "RentalsSince" {
        fields = { f.time "at", f.decimal "amount":scale(2) },
        rows = function(c, p)
            return c.Rental:query():where("at >= since", p):all()
        end,
    },
    -- answers the rows its parameters hold
    lent.view "Echo" {
        fields = { f.int "n", f.enum "e":values("x"):optional() },
        rows = function(c, p) return p.answer end,
    },
}

local function app()
    local list = table.clone(tables)
    for _, v in views do list[#list + 1] = v end
    return lent.graph(list)
end
local db = client.open(app())

-- a value as text, so nil and decimals compare in Python
local function show(v)
    if v == nil then return "nil" end
    return tostring(v)
end

local function rows(list, names)
    local out = {}
    for _, r in list do
        local parts = {}
        for _, n in names do parts[#parts + 1] = n .. "=" .. show(r[n]) end
        out[#out + 1] = table.concat(parts, " ")
    end
    return out
end

local LIST = { "id", "name", "city", "rentals", "paid", "status" }

local steps = {}

function steps.seed(c)
    local oslo = c.City:create { name = "oslo" }
    local rome = c.City:create { name = "rome" }
    local ann = c.Customer:create { name = "ann", city = oslo }
    local bob = c.Customer:create { name = "bob", city = rome }
    c.Customer:create { name = "cy", active = false }
    local dee = c.Customer:create { name = "dee", city = oslo }
    c.Rental:create { at = 10, amount = 2.5, customer = ann }
    c.Rental:create { at = 30, amount = 4.99, customer = ann }
    c.Rental:create { at = 20, amount = 1, customer = bob }
    c.Rental:create { at = 40, amount = 3, customer = dee }
    return "ok"
end

function steps.list(c)
    return rows(c.CustomerList:query():all(), LIST)
end

function steps.query(c)
    local v = c.CustomerList
    local out = {}
    local function add(label, list)
        local names = {}
        for i, r in list do names[i] = r.name end
        out[#out + 1] = label .. ": " .. table.concat(names, ", ")
    end
    add("renters", v:query():where("rentals >= n", { n = 1 }):all())
    add("paid desc", v:query():order("paid", "desc"):all())
    -- ties keep the order the function answered
    add("rentals", v:query():order("rentals"):all())
    add("rentals desc", v:query():order("rentals", "desc"):all())
    add("no city", v:query():where("city", "=", nil):all())
    add("oslo", v:query():where(function(r) return r.city == "oslo" end):all())
    add("page", v:query():order("name", "desc"):offset(1):limit(2):all())
    add("first", { v:query():where("status == 'active'"):order("paid"):first() })
    out[#out + 1] = "count " .. v:query():where("paid > 2"):count()
    out[#out + 1] = "explain " .. v:query():where("rentals > 0"):explain()
    return out
end

function steps.groups(c)
    local out = {}
    local spec = { n = { fn = "count" }, paid = { fn = "sum", field = "paid" },
                   avg = { fn = "avg", field = "rentals" } }
    for _, line in rows(c.CustomerList:query():groupBy("city"):aggregate(spec),
                        { "city", "n", "paid", "avg" }) do
        out[#out + 1] = line
    end
    for _, line in rows(c.CustomerList:query():groupBy("status"):having("n > 1")
                        :aggregate { n = { fn = "count" } }, { "status", "n" }) do
        out[#out + 1] = line
    end
    out[#out + 1] = "max " .. show(c.CustomerList:query():max("paid"))
    out[#out + 1] = "sum " .. show(c.CustomerList:query():where("city ~= nil"):sum("rentals"))
    return out
end

function steps.params(c)
    local q = c.RentalsSince:query({ since = 20 }):order("at", "desc")
    local out = rows(q:all(), { "at", "amount", "id" })
    out[#out + 1] = "count " .. c.RentalsSince:query({ since = 35 }):count()
    return out
end

local bad = {
    notable = function(c) return c.Nothing end,
    answer = function(c) c.Echo:query({ answer = 5 }):all() end,
    row = function(c) c.Echo:query({ answer = { 5 } }):all() end,
    missing = function(c) c.Echo:query({ answer = { { n = 1 }, {} } }):all() end,
    kind = function(c) c.Echo:query({ answer = { { n = "x" } } }):count() end,
    float = function(c) c.Echo:query({ answer = { { n = 1.5 } } }):first() end,
    enum = function(c) c.Echo:query({ answer = { { n = 1, e = "y" } } }):all() end,
    field = function(c) c.Echo:query():where("zzz", "=", 1) end,
    ids = function(c) c.Echo:query():ids() end,
    update = function(c) c.Echo:query():update { n = 2 } end,
    links = function(c) c.Echo:query():links("n") end,
    edge = function(c) c.CustomerList:query():groupBy("city.name") end,
}

-- each declaration that lent.view or lent.graph refuses, with its error
function steps.schema()
    local cases = {
        function() lent.view "V" { fields = { f.int "n" }, rows = 5 } end,
        function() lent.view "V" { fields = { f.int "n" }, rows = print, where = 1 } end,
        function() lent.view "V" { fields = {}, rows = print } end,
        function() lent.view "V" { fields = { f.int "n", f.int "n" }, rows = print } end,
        function() lent.view "V" { fields = { f.int "n":unique() }, rows = print } end,
        function() lent.view "V" { fields = { f.int "n":default(1) }, rows = print } end,
        function() lent.view "V" { fields = { f.decimal "n" }, rows = print } end,
        function() lent.view "V" { fields = { f.int "n":values("a") }, rows = print } end,
        function() lent.view "V" { fields = { { kind = "int", name = "n", min = 1 } },
                                   rows = print } end,
        function() lent.view "2V" end,
        function()
            local v = lent.view "V" { fields = { f.int "n" }, rows = print }
            lent.graph { v, v }
        end,
        function()
            lent.graph { lent.schema "V" { fields = { f.int "n" } },
                         lent.view "V" { fields = { f.int "n" }, rows = print } }
        end,
    }
    local out = {}
    for _, fn in cases do
        local ok, err = pcall(fn)
        out[#out + 1] = ok and "no error" or tostring(err)
    end
    return out
end

function call(step, which)
    if step == "migrate" then
        return m.migrate(app()).version
    end
    if step == "schema" then
        return steps.schema()
    end
    return db.tx(function(c)
        if step == "bad" then
            bad[which](c)
            return "no error"
        end
        return steps[step](c)
    end)
end
"""


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", re.sub(r"\W", "_", "views_" + request.node.name))
    client.execute_command("SETF", "VIEWS", APP)
    assert client.execute_command("CALLF", "VIEWS", "migrate") == 1
    assert client.execute_command("CALLF", "VIEWS", "seed") == "ok"
    return lambda *a: client.execute_command("CALLF", "VIEWS", *a)


def test_view_rows(run):
    assert run("list") == [
        "id=1 name=ann city=oslo rentals=2 paid=7.49 status=active",
        "id=2 name=bob city=rome rentals=1 paid=1 status=active",
        "id=3 name=cy city=nil rentals=0 paid=0 status=inactive",
        "id=4 name=dee city=oslo rentals=1 paid=3 status=active",
    ]


def test_view_query(run):
    assert run("query") == [
        "renters: ann, bob, dee",
        "paid desc: ann, dee, bob, cy",
        "rentals: cy, bob, dee, ann",
        "rentals desc: ann, bob, dee, cy",
        "no city: cy",
        "oslo: ann, dee",
        "page: cy, bob",
        "first: bob",
        "count 2",
        "explain view CustomerList rows, then filter in memory",
    ]


def test_view_groups_and_aggregates(run):
    assert run("groups") == [
        "city=nil n=1 paid=0 avg=0",
        "city=oslo n=2 paid=10.49 avg=1.5",
        "city=rome n=1 paid=1 avg=1",
        "status=active n=3",
        "max 7.49",
        "sum 4",
    ]


def test_view_params(run):
    # the view keeps its declared fields, so the rental id is gone
    assert run("params") == [
        "at=40 amount=3 id=nil",
        "at=30 amount=4.99 id=nil",
        "at=20 amount=1 id=nil",
        "count 1",
    ]


REFUSED = ("reads table rows; a view query takes where, order, limit, offset, groupBy and"
           " aggregates")
ERRORS = {
    "notable": "LENT this space's schema has no table or view Nothing",
    "answer": "LENT view Echo rows function answered 5; it answers a list of rows",
    "row": "LENT view Echo row 1 is 5; a row is a table",
    "missing": "LENT view Echo row 2 has no n, and the field is not optional",
    "kind": "LENT view Echo row 1 field n is int, got x",
    "float": "LENT view Echo row 1 field n is int, got 1.5",
    "enum": 'LENT view Echo row 1 field e wants one of ["x"], got "y"',
    "field": "LENT view Echo has no field zzz",
    "ids": "LENT view Echo query ids " + REFUSED,
    "update": "LENT view Echo query update " + REFUSED,
    "links": "LENT view Echo query links " + REFUSED,
    "edge": "LENT view CustomerList has no edge city",
}


@pytest.mark.parametrize("which", sorted(ERRORS))
def test_view_errors(run, which):
    with pytest.raises(redis.ResponseError) as err:
        run("bad", which)
    assert str(err.value).startswith(ERRORS[which])


def test_view_declarations(run):
    assert run("schema") == [
        "SCHEMA view V rows takes a function, got number",
        "SCHEMA view V has no option where; it takes fields and rows",
        "SCHEMA view V needs at least one field",
        "SCHEMA view V field n is declared twice",
        "SCHEMA view V field n is a view field, which takes no unique",
        "SCHEMA view V field n is a view field, which takes no default",
        "SCHEMA view V field n is a decimal field, which needs :scale(n) with n from 0 to 15,"
        " got nil",
        "SCHEMA view V field n is a int field, which takes no values",
        "SCHEMA view V field n is a view field, which takes no min",
        "SCHEMA view needs a name of letters, digits and _, got 2V",
        "SCHEMA view V is declared twice",
        "SCHEMA view V has the name of a table",
    ]
