import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Decimal fields: values round to the field's scale when written, sums add
# whole units of the scale, and indexes and filters read them as numbers.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local f = lent.field

local function graph(stage)
    local price = f.decimal "price":scale(2):min(0)
    if stage == "rescale" then price = f.decimal "price":scale(3):min(0) end
    if stage == "float" then price = f.float "price":min(0) end
    return lent.graph {
        lent.schema "Product" {
            format = FORMAT,
            id = "int",
            fields = {
                f.string "name", price,
                f.decimal "fee":scale(1):default(0.25),
                f.decimal "rate":scale(4):optional(),
                f.decimal "gross":scale(2):computed(function(r) return r.price * 1.15 end),
            },
            indexes = { lent.index("price") },
            edges = {
                lent.edge.to "offers" "Shop":fields { f.decimal "cost":scale(2) },
            },
        },
        lent.schema "Shop" {
            id = "int",
            fields = { f.string "name" },
            edges = { lent.edge.from "products" "Product":ref "offers" },
        },
    }
end

local app = graph()
local db = client.open(app)

local function err(fn)
    local ok, e = pcall(fn)
    return ok and "no error" or tostring(e)
end

local steps = {}

-- each value rounds half away from zero, as its shortest text reads
function steps.round(c)
    local out = {}
    for i, p in { 2.675, 1.005, 10, 0.1 + 0.2, -0.004 + 0.004, 0.004 } do
        local r = c.Product:create { name = "p" .. i, price = p }
        local got = c.Product:get(r.id)
        out[i] = { got.price, got.fee, got.gross }
    end
    return out
end

-- ten prices of 0.1 add up to 1; a float sum gives 0.9999999999999999
function steps.sum(c)
    for i = 1, 10 do
        c.Product:create { name = i % 2 == 0 and "even" or "odd", price = 0.1, rate = 0.0001 }
    end
    local groups = c.Product:query():groupBy("name"):aggregate {
        total = { fn = "sum", field = "price" }, n = { fn = "count" },
    }
    local q = c.Product:query()
    return {
        tostring(q:sum("price")), tostring(q:sum("rate")), tostring(q:sum("gross")),
        tostring(q:max("price")),
        groups[1].name, tostring(groups[1].total), groups[2].name, tostring(groups[2].total),
    }
end

function steps.filter(c)
    for i, p in { 0.3, 2.68, 1.01, 10 } do
        c.Product:create { name = "p" .. i, price = p }
    end
    local function names(q)
        local out = {}
        for _, r in q:all() do out[#out + 1] = r.name end
        table.sort(out)
        return table.concat(out, " ")
    end
    local range = c.Product:query():where("price", ">=", 1.01)
    return {
        names(range), range:explain(),
        names(c.Product:query():where("price", "=", 0.3)),
        -- filters compare the value as given; 0.1 + 0.2 is 0.30000000000000004
        names(c.Product:query():where("price", "=", 0.1 + 0.2)),
        names(c.Product:query():where("price < 2 and gross > 1")),
    }
end

function steps.update(c)
    local r = c.Product:create { name = "a", price = 1 }
    local a = c.Product:update(r.id, { price = 3.14159 })
    local b = c.Product:update(r.id, { name = "b" })
    return { a.price, b.price, b.name }
end

function steps.link(c)
    local p = c.Product:create { name = "a", price = 1 }
    local s = c.Shop:create { name = "s" }
    c.Product:link("offers", p.id, s.id, { cost = 1.239 })
    local l = c.Product:query():links("offers"):all()[1]
    return { l.cost, tostring(c.Product:query():links("offers"):sum("cost")) }
end

function steps.errors(c)
    return {
        err(function() c.Product:create { name = "x", price = 1e13 } end),
        err(function() c.Product:create { name = "x", price = "1.5" } end),
        err(function() c.Product:create { name = "x", price = math.huge } end),
        err(function() c.Product:create { name = "x", price = -1 } end),
        err(function() c.Product:create { name = "x", price = 1, rate = 1e12 } end),
        err(function() c.Product:query():where("price", ">", "1") end),
        err(function() c.Product:query():aggregate { s = { fn = "sum", field = "name" } } end),
        c.Product:query():count(),
    }
end

function steps.schema(_, kind)
    local fields = {
        none = { f.decimal "price" },
        big = { f.decimal "price":scale(16) },
        part = { f.decimal "price":scale(1.5) },
        int = { f.int "price":scale(2) },
        computed = { f.decimal "price":computed(function() return 1 end) },
        default = { f.decimal "price":scale(2):default(1e14) },
        plain = { { kind = "decimal", name = "price", scale = 2, default = 1.005 } },
    }
    local ok, e = pcall(lent.schema "T", { fields = fields[kind] })
    if ok then return "default " .. tostring(e.fields[1].default) end
    return tostring(e)
end

function steps.read(c)
    local out = {}
    for _, r in c.Product:query():all() do out[#out + 1] = r.price end
    return out
end

function call(step, arg)
    if step == "migrate" then
        local plan = m.migrate(arg == "" and app or graph(arg))
        return plan.done and "done" or "more"
    end
    if step == "remigrate" then
        return err(function() m.migrate(graph(arg)) end)
    end
    return db.tx(function(c) return steps[step](c, arg) end)
end
"""


@pytest.fixture(params=["binary", "text", "json"])
def run(client, request):
    setup(client)
    client.execute_command("USE", re.sub(r"\W", "_", "decimal_" + request.node.name))
    client.execute_command("SETF", "DECIMALAPP", APP.replace("FORMAT", '"%s"' % request.param))
    run = lambda step, arg="": client.execute_command("CALLF", "DECIMALAPP", step, arg)
    assert run("migrate") == "done"
    return run


def test_values_round_to_the_scale(run):
    assert run("round") == [
        ["2.68", "0.3", "3.08"],
        ["1.01", "0.3", "1.16"],
        [10, "0.3", "11.5"],
        ["0.3", "0.3", "0.35"],
        [0, "0.3", 0],
        [0, "0.3", 0],
    ]


def test_sums_are_exact(run):
    assert run("sum") == ["1", "0.001", "1.1", "0.1", "even", "0.5", "odd", "0.5"]


def test_filters_and_indexes_read_decimals(run):
    assert run("filter") == ["p2 p3 p4", "by_price range price", "p1", "", "p3"]


def test_update_rounds_the_new_value(run):
    assert run("update") == ["3.14", "3.14", "b"]


def test_link_fields_round(run):
    assert run("link") == ["1.24", "1.24"]


def test_errors(run):
    assert run("errors") == [
        "LENT table Product field price wants a decimal of at most 15 digits with 2 after"
        " the point, got 10000000000000",
        "LENT table Product field price wants a decimal of at most 15 digits with 2 after"
        " the point, got 1.5",
        "LENT table Product field price wants a decimal of at most 15 digits with 2 after"
        " the point, got inf",
        "LENT table Product field price wants at least 0, got -1",
        "LENT table Product field rate wants a decimal of at most 15 digits with 4 after"
        " the point, got 1000000000000",
        "LENT table Product field price is decimal, got 1",
        "LENT table Product field name is string, so sum needs int, float or decimal",
        0,
    ]


@pytest.mark.parametrize("kind, error", [
    ("none", "SCHEMA table T field price is a decimal field, which needs :scale(n) with n"
             " from 0 to 15, got nil"),
    ("big", "SCHEMA table T field price is a decimal field, which needs :scale(n) with n"
            " from 0 to 15, got 16"),
    ("part", "SCHEMA table T field price is a decimal field, which needs :scale(n) with n"
             " from 0 to 15, got 1.5"),
    ("int", "SCHEMA table T field price is a int field, which takes no scale"),
    ("computed", "SCHEMA table T field price is a decimal field, which needs :scale(n) with n"
                 " from 0 to 15, got nil"),
    ("default", "SCHEMA table T field price default wants a decimal of at most 15 digits"
                " with 2 after the point, got 100000000000000"),
    ("plain", "default 1.01"),
])
def test_schema_checks_the_scale(run, kind, error):
    assert run("schema", kind) == error


def test_migrate_keeps_the_scale(run):
    run("filter")
    assert run("remigrate", "rescale") == \
        "MIGRATE table Product field price changes scale from 2 to 3"
    assert run("migrate", "float") == "done"
    assert run("read") == ["0.3", "2.68", "1.01", 10]
