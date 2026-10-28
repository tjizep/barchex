import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Luau integers, which simdjson.parse answers for whole numbers beyond 32
# bits: lent takes one wherever it takes a number, when it lies from -2^53 to
# 2^53, and refuses a larger one with the field's usual error.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local f = lent.field

-- I(5) is the Luau integer 5; I("9007199254740993") reads a larger one
local function I(v)
    if type(v) == "string" then return simdjson.parse(v) end
    return integer.create(v)
end

local app = lent.graph {
    lent.schema "Trip" {
        id = "int",
        fields = {
            f.int "n":min(I(0)), f.float "km", f.decimal "fare":scale(2),
            f.time "at", f.int "seen":default(function() return I(7) end),
            f.int "twice":computed(function(r) return I(2 * r.n) end),
            f.string "code":optional():unique(),
        },
        indexes = { lent.index("at") },
        edges = { lent.edge.to "stops" "Stop":fields { f.time "at":optional() } },
    },
    lent.schema "Stop" {
        id = "int",
        fields = { f.string "name" },
        edges = { lent.edge.from "trips" "Trip":ref "stops" },
    },
}
local db = client.open(app)

local function err(fn)
    local ok, e = pcall(fn)
    return ok and "no error" or tostring(e)
end

local AT = "805075200000"

local steps = {}

function steps.write(c)
    local stop = c.Stop:create { id = I(3), name = "a" }
    local r = c.Trip:create { id = I(10), n = I(4), km = I(5), fare = I(6), at = I(AT),
                              stops = I(3), code = "x" }
    local u = c.Trip:update(I(10), { n = I(8) })
    local l = c.Trip:link("stops", I(10), I(3), { at = I(AT) })
    local g = c.Trip:get(I(10))
    return {
        r.id, r.n, r.km, r.fare, r.at, r.seen, r.twice, u.n, u.twice, l.at, stop.id,
        type(g.at), c.Trip:edge("stops", I(10), I(3)).at, c.Trip:by("code", "x").id,
        lent.year(g.at), c.Trip:unlink("stops", I(10), I(3)), c.Trip:delete(I(10)),
    }
end

function steps.upsert(c)
    local a, made = c.Trip:upsert("id", { id = I(20), n = I(1), km = 1, fare = 1, at = I(AT) })
    local b, again = c.Trip:upsert("id", { id = I(20), n = I(2), km = 1, fare = 1, at = I(AT) })
    return { a.id, made, b.n, again }
end

function steps.query(c)
    for i = 1, 4 do
        c.Trip:create { n = i, km = i, fare = i, at = 805075200000 + i }
    end
    local function ids(q)
        local out = {}
        for _, r in q:all() do out[#out + 1] = r.id end
        return out
    end
    local after = c.Trip:query():where("at", ">", I("805075200002"))
    return {
        ids(after), after:explain(),
        ids(c.Trip:query():where("n", "=", I(3))),
        ids(c.Trip:query():where("at <= t", { t = I("805075200001") })),
        ids(c.Trip:query():order("id"):limit(I(2)):offset(I(1))),
    }
end

-- 2^53 + 1 does not fit in a number, so lent refuses it
function steps.errors(c)
    local big = I("9007199254740993")
    return {
        err(function() c.Trip:create { n = big, km = 1, fare = 1, at = I(AT) } end),
        err(function() c.Trip:create { n = 1, km = 1, fare = 1, at = big } end),
        err(function() c.Trip:create { n = 1, km = big, fare = 1, at = I(AT) } end),
        err(function() c.Trip:get(big) end),
        err(function() c.Trip:query():where("n", "=", big) end),
        err(function() c.Trip:query():where("n == v", { v = big }) end),
        err(function() c.Trip:create { n = I(-1), km = 1, fare = 1, at = I(AT) } end),
    }
end

function steps.edge()
    local nine = I("9007199254740992")
    return {
        type(lent.parseJson("9007199254740992")), type(lent.parseJson("9007199254740993")),
        type(lent.parseJson("-9007199254740993")), lent.year(nine) ~= nil,
    }
end

function call(step, arg)
    if step == "migrate" then
        return m.migrate(app).done and "done" or "more"
    end
    return db.tx(function(c) return steps[step](c, arg) end)
end
"""


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", re.sub(r"\W", "_", "integers_" + request.node.name))
    client.execute_command("SETF", "INTEGERSAPP", APP)
    run = lambda step, arg="": client.execute_command("CALLF", "INTEGERSAPP", step, arg)
    assert run("migrate") == "done"
    return run


def test_writes_take_integers(run):
    assert run("write") == [
        10, 4, 5, 6, 805075200000, 7, 8, 8, 16, 805075200000, 3,
        "number", 805075200000, 10, 1995, 1, 1,
    ]


def test_upsert_takes_integers(run):
    assert run("upsert") == [20, 1, 2, None]


def test_queries_take_integers(run):
    assert run("query") == [[3, 4], "by_at range at", [3], [1], [2, 3]]


def test_integers_beyond_2_53_are_refused(run):
    big = "9007199254740993"
    # kind errors come from ROWCODEC, after the script position
    assert [re.sub(r"^lent:\d+: ", "", e) for e in run("errors")] == [
        "ROWCODEC field n wants int, got " + big,
        "LENT table Trip field at wants a time in Unix milliseconds, got " + big,
        "ROWCODEC field km wants float, got " + big,
        "LENT table Trip wants an integer id, got " + big,
        "LENT table Trip field n is int, got " + big,
        'LENT table Trip query where "n == v": parameter v wants a whole number from -2^53'
        " to 2^53, got " + big,
        "LENT table Trip field n wants at least 0, got -1",
    ]


def test_parse_json_keeps_large_integers(run):
    assert run("edge") == ["number", "integer", "integer", 1]
