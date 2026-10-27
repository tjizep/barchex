import re

import pytest

from .conftest import install
from .test_client import setup

redis = pytest.importorskip("redis")

# Employees with an optional age, a salary, a computed `senior` flag and
# optional JSON tags. `knows` links employees with the years they have known
# each other. Queries filter them with expression strings.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

local app = lent.graph {
    lent.schema "Emp" {
        id = "int",
        fields = {
            lent.field.string "name":unique(),
            lent.field.int "age":optional(),
            lent.field.float "salary":default(0),
            lent.field.bool "active":default(true),
            lent.field.json "tags":optional(),
            lent.field.bool "senior":computed(function(r) return (r.age or 0) >= 40 end),
        },
        indexes = { lent.index("age") },
        edges = { lent.edge.to "knows" "Emp":fields { lent.field.int "years":default(1) } },
    },
}
local db = client.open(app)

local function names(q)
    local out = {}
    for _, r in q:order("id"):all() do out[#out + 1] = r.name end
    return table.concat(out, ",")
end

local function err(fn)
    local ok, e = pcall(fn)
    return ok and "no error" or tostring(e)
end

local steps = {}

function steps.seed(c)
    c.Emp:create { name = "ann", age = 30, salary = 500, tags = { "x" } }
    c.Emp:create { name = "bob", age = 45, salary = 1500, active = false }
    c.Emp:create { name = "cy", salary = 800 }
    c.Emp:create { name = "dee", age = 12, salary = 100, tags = { "y" } }
    c.Emp:create { name = "eve", age = 101, salary = 900 }
    c.Emp:link("knows", 1, 2, { years = 3 })
    c.Emp:link("knows", 1, 3)
    c.Emp:link("knows", 2, 4, { years = 7 })
    return "ok"
end

function steps.reads(c)
    local function q(...) return c.Emp:query():where(...) end
    return {
        names(q("age > 10 and age <= 100 and salary < 1000")),
        q("age > 10 and age <= 100 and salary < 1000"):explain(),
        -- a value on the left compares the same way
        q("100 >= age and salary < 1000"):explain(),
        names(q("salary >= lo and name ~= skip", { lo = 800, skip = "bob" })),
        -- cy has no age: a range comparison with it is false, so `not` keeps it
        names(q("not (age > 20)")),
        names(q("age == nil")),
        names(q("(age or 0) * 2 > salary / 10")),
        names(q("active and senior")),
        names(q("not active")),
        names(q("tags == want", { want = { "x" } })),
        names(q("name == 'ann' or age > 100")),
        names(q("#name == 2 or name .. '!' == 'eve!'")),
        names(c.Emp:query():where("salary < 1000"):where("age", ">", 10)),
        tostring(q("id >= 3"):count()),
        names(q("age + 1 > lo + 1", { lo = 40 })),
        -- an `or` reads every row, then filters them
        q("age < 20 or age > 100"):explain(),
    }
end

function steps.edges(c)
    local ann = c.Emp:query():where("name == 'ann'")
    local knows = {}
    for _, l in c.Emp:query():links("knows"):where("years > 2"):order("years"):all() do
        knows[#knows + 1] = l.from .. ">" .. l.to
    end
    return {
        table.concat(knows, ","),
        names(ann:queryKnows():whereEdge("years >= n", { n = 3 })),
        names(c.Emp:query():hasKnowsWith(function(q) q:where("age > 40") end)),
    }
end

function steps.writes(c)
    local n = c.Emp:query():where("age < 18 or age == nil"):update { salary = 0 }
    return { n, names(c.Emp:query():where("salary == 0")) }
end

function steps.errors(c)
    local function q(...) return c.Emp:query():where(...) end
    return {
        err(function() q("age >") end),
        err(function() q("nope > 1") end),
        err(function() q("age > 3", { age = 1 }) end),
        err(function() q("active < true") end),
        err(function() q("tags < 3") end),
        err(function() q("age > 'ten'") end),
        err(function() q("age > lo", { lo = print }) end),
        -- cy has no age, so the `or` gives a string there
        err(function() q("(age or 'none') > 3"):all() end),
        err(function() c.Emp:query():links("knows"):where("id > 1") end),
    }
end

function call(step, mode)
    if step == "migrate" then
        return m.migrate(app).done and "done" or "more"
    end
    return db.tx(function(c) return steps[step](c) end, mode == "pessimistic")
end
"""


@pytest.fixture(params=["optimistic", "pessimistic"])
def run(client, request):
    setup(client)
    client.execute_command("USE", re.sub(r"\W", "_", "where_expr_" + request.node.name))
    client.execute_command("SETF", "WHEREEXPR", APP)
    mode = request.param
    run = lambda step: client.execute_command("CALLF", "WHEREEXPR", step, mode)
    assert run("migrate") == "done"
    assert run("seed") == "ok"
    return run


def test_expr_selftest(client):
    install(client, "lent", "VALUES", "lent/values.luau")
    install(client, "lent", "EXPR", "lent/expr.luau")
    client.execute_command("USE", "lent")
    assert client.execute_command("CALLF", "EXPR") == "ok"


def test_expressions_filter_rows(run):
    assert run("reads") == [
        "ann,dee",
        "by_age range age",
        "by_age range age",
        "cy,eve",
        "cy,dee",
        "cy",
        "ann,dee,eve",
        "eve",
        "bob",
        "ann",
        "ann,eve",
        "cy,eve",
        "ann,dee,eve",
        "3",
        "bob,eve",
        "id",
    ]


def test_expressions_filter_links(run):
    assert run("edges") == ["1>2,2>4", "bob", "ann"]


def test_expressions_select_rows_to_write(run):
    assert run("writes") == [2, "cy,dee"]


def test_expression_errors(run):
    where = 'LENT table Emp query where '
    assert run("errors") == [
        where + '"age >": ends where a value should come',
        where + '"nope > 1" at column 1: has no field or parameter nope',
        where + '"age > 3" at column 1: age names both a field and a parameter',
        where + '"active < true" at column 8: field active (bool) has no order',
        where + '"tags < 3" at column 6: field tags (json) has no order',
        where + '"age > \'ten\'" at column 5: > compares field age (int) with "ten"',
        where + '"age > lo": parameter lo is a function; parameters are numbers, strings,'
                ' booleans or JSON tables',
        where + '"(age or \'none\') > 3": > compares string with number',
        'LENT table Emp links knows query where "id > 1" at column 1: has no field or'
        ' parameter id',
    ]
