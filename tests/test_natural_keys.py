import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Rows created with ids of their own: a Country table keyed by a number, a
# City table that links to countries by those numbers, and a Tag table with
# uuid ids.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

local app = lent.graph {
    lent.schema "Country" {
        id = "int",
        fields = { lent.field.string "name" },
        edges = { lent.edge.to "cities" "City" },
    },
    lent.schema "City" {
        id = "int",
        fields = { lent.field.string "name", lent.field.int "pop":default(0) },
        edges = { lent.edge.from "country" "Country":ref "cities":unique() },
    },
    lent.schema "Tag" {
        fields = { lent.field.string "name" },
    },
}
local db = client.open(app)

local UUID = "019a1f3c-7d2e-7a41-9b3c-5e6f7a8b9c0d"

local function err(fn)
    local ok, e = pcall(fn)
    return ok and "no error" or tostring(e)
end

local steps = {}

-- given ids keep their value, and edges name rows by them
function steps.given(c)
    c.Country:createMany { { id = 44, name = "uk" }, { id = 27, name = "za" } }
    c.City:create { id = 7, name = "london", country = 44 }
    c.City:create { id = 3, name = "durban", country = 27 }
    local out = {}
    for _, city in c.City:query():withCountry():all() do
        out[#out + 1] = city.id .. " " .. city.name .. " " .. city.country.id
    end
    return out
end

-- automatic ids continue above the greatest given id; a smaller given id
-- leaves the counter alone
function steps.counter(c)
    local a = c.City:create { name = "a" }
    c.City:create { id = 10, name = "b" }
    c.City:create { id = 4, name = "c" }
    local d = c.City:create { name = "d" }
    return { a.id, d.id, c.City:query():count() }
end

function steps.errors(c)
    c.City:create { id = 5, name = "x" }
    return {
        err(function() c.City:create { id = 5, name = "y" } end),
        err(function() c.City:create { id = 0, name = "y" } end),
        err(function() c.City:create { id = 2.5, name = "y" } end),
        err(function() c.City:create { id = "6", name = "y" } end),
        err(function() c.City:create { id = 2 ^ 53 + 2, name = "y" } end),
        err(function() c.Tag:create { id = 6, name = "y" } end),
        err(function() c.City:update(5, { id = 6 }) end),
        err(function() c.City:query():update { id = 6 } end),
        c.City:query():count(),
    }
end

-- a refused create leaves the counter as it was
function steps.refused(c)
    err(function() c.City:create { id = 50, name = 1 } end)
    return c.City:create { name = "next" }.id
end

function steps.uuid(c)
    local t = c.Tag:create { id = UUID, name = "given" }
    return { t.id, c.Tag:get(UUID).name, err(function() c.Tag:create { id = UUID, name = "again" } end) }
end

function steps.upsert(c)
    local a, made = c.City:upsert("id", { id = 9, name = "nine", pop = 1 })
    local b, again = c.City:upsert("id", { id = 9, name = "nein" })
    return {
        a.id, tostring(made), b.id, tostring(again), b.name, b.pop,
        c.City:query():count(),
        err(function() c.City:upsert("id", { name = "none" }) end),
        err(function() c.City:upsert("id", { id = -1, name = "none" }) end),
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
    client.execute_command("USE", re.sub(r"\W", "_", "natural_keys_" + request.node.name))
    client.execute_command("SETF", "NATURALKEYS", APP)
    mode = request.param
    run = lambda step: client.execute_command("CALLF", "NATURALKEYS", step, mode)
    assert run("migrate") == "done"
    return run


def test_create_keeps_given_ids(run):
    assert run("given") == ["3 durban 27", "7 london 44"]


def test_automatic_ids_continue_above_given_ids(run):
    assert run("counter") == [1, 11, 4]


def test_given_id_errors(run):
    assert run("errors") == [
        "LENT table City already has a row 5",
        "LENT table City wants an integer id, got 0",
        "LENT table City wants an integer id, got 2.5",
        "LENT table City wants an integer id, got 6",
        "LENT table City wants an integer id, got 9007199254740994",
        "LENT table Tag wants a uuid id, got 6",
        "LENT table City keeps each row's id; only create takes an id",
        "LENT table City keeps each row's id; only create takes an id",
        1,
    ]


def test_refused_create_keeps_the_counter(run):
    assert run("refused") == 1


def test_uuid_table_takes_a_given_uuid(run):
    assert run("uuid") == [
        "019a1f3c-7d2e-7a41-9b3c-5e6f7a8b9c0d",
        "given",
        "LENT table Tag already has a row 019a1f3c-7d2e-7a41-9b3c-5e6f7a8b9c0d",
    ]


def test_upsert_by_id(run):
    assert run("upsert") == [
        9, "true", 9, "false", "nein", 1, 1,
        "LENT table City upsert by id needs a value for id",
        "LENT table City wants an integer id, got -1",
    ]
