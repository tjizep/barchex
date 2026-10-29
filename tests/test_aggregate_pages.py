import json

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Shops sell in regions; aggregates over the sales run in pages, each page
# in its own call, and must answer what one aggregate call answers.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local f = lent.field

local app = lent.graph {
    lent.schema "Shop" {
        id = "int",
        fields = { f.string "name", f.string "city" },
        indexes = { lent.index("name") },
        edges = { lent.edge.to "sales" "Sale" },
    },
    lent.schema "Sale" {
        fields = {
            f.string "region", f.decimal "amount":scale(2), f.int "qty",
            f.float "score":optional(), f.string "tag":optional(),
        },
        indexes = { lent.index("region"), lent.index("qty") },
        edges = { lent.edge.from "shop" "Shop":ref "sales":unique() },
    },
}
local db = client.open(app)

local function show(v)
    if v == nil then return "nil" end
    return tostring(v)
end

-- rows as sorted name=value text, so Python compares them whole
local function text(list)
    local out = {}
    for i, r in list do
        local names = {}
        for k in r do names[#names + 1] = k end
        table.sort(names)
        local parts = {}
        for _, n in names do parts[#parts + 1] = n .. "=" .. show(r[n]) end
        out[i] = table.concat(parts, " ")
    end
    return out
end

local SPEC = {
    n = { fn = "count" }, scored = { fn = "count", field = "score" },
    amount = { fn = "sum", field = "amount" }, qty = { fn = "sum", field = "qty" },
    avgScore = { fn = "avg", field = "score" }, avgAmount = { fn = "avg", field = "amount" },
    lowTag = { fn = "min", field = "tag" }, highScore = { fn = "max", field = "score" },
    tags = { fn = "count", field = "tag", distinct = true },
    qtys = { fn = "sum", field = "qty", distinct = true },
    double = { fn = "sum", value = function(s) return s.qty * 2 end },
    lowRegion = { fn = "min", value = function(s) return s.region .. s.qty end },
}

-- each case answers a query or groupBy and its aggregate spec
local cases = {}
function cases.totals(c) return c.Sale:query(), SPEC end
function cases.ordered(c) return c.Sale:query():order("qty", "desc"), SPEC end
function cases.regions(c)
    return c.Sale:query():groupBy("region"), SPEC
end
function cases.shaped(c)
    return c.Sale:query():groupBy("region", "qty"):having("n > 1")
        :order("amount", "desc"):limit(4), { n = SPEC.n, amount = SPEC.amount }
end
function cases.range(c)
    return c.Sale:query():where("qty", ">=", 3):groupBy("region"), SPEC
end
function cases.spans(c)
    return c.Sale:query():where("qty < 2 or qty > 5"), SPEC
end
function cases.equal(c)
    return c.Sale:query():where("region", "=", "s"), SPEC
end
function cases.path(c)
    return c.Sale:query():groupBy("shop.city"), { n = SPEC.n, tags = SPEC.tags }
end
function cases.follow(c)
    return c.Shop:query():where("city", "=", "oslo"):follow("sales"):groupBy("region"), SPEC
end
function cases.has(c)
    return c.Sale:query():has("shop", function(q) return q:where("name", "=", "b") end), SPEC
end
function cases.none(c)
    return c.Sale:query():where("qty", ">", 100), SPEC
end
function cases.keys(c)
    return c.Sale:query():groupBy("tag"), nil
end

local function answer(r)
    if r == nil then return {} end
    if r[1] ~= nil or next(r) == nil then return text(r) end
    return text({ r })
end

local steps = {}

function steps.seed(c)
    local shops = {
        c.Shop:create { name = "a", city = "oslo" }, c.Shop:create { name = "b", city = "rome" },
        c.Shop:create { name = "c", city = "oslo" }, c.Shop:create { name = "d", city = "kyiv" },
    }
    for i = 1, 40 do
        c.Sale:create {
            region = ({ "n", "s", "e" })[i % 3 + 1], amount = (i * 37 % 100) / 4,
            -- quarters add exactly in any order
            qty = i % 7, score = if i % 5 == 0 then nil else (i % 9) / 4,
            tag = if i % 4 == 0 then nil else "t" .. i % 6,
            shop = shops[i % 4 + 1],
        }
    end
    return "ok"
end

-- the answer of one aggregate call
function steps.whole(c, name)
    local q, spec = cases[name](c)
    return answer(q:aggregate(spec))
end

-- one page, as JSON: done, processed, state and the answer
function steps.page(c, name, state, size)
    local q, spec = cases[name](c)
    local r = q:aggregatePage(spec, if state == "" then nil else state, tonumber(size))
    return simdjson.encode({ done = r.done, processed = r.processed, state = r.state or "",
                             result = if r.done then answer(r.result) else {} })
end

function steps.change(c)
    c.Sale:delete(c.Sale:query():first().id)
    c.Sale:create { region = "n", amount = 1, qty = 1 }
    return "ok"
end

local function err(fn)
    local ok, e = pcall(fn)
    if ok then return "no error" end
    return tostring(e)
end

function steps.errors(c, state)
    local q = function() return c.Sale:query() end
    local cur = q():order("qty"):cursor(q():first())
    return {
        err(function() q():limit(3):aggregatePage(SPEC) end),
        err(function() q():offset(1):aggregatePage(SPEC) end),
        err(function() q():order("qty"):after(cur):aggregatePage(SPEC) end),
        err(function() c.Shop:query():links("sales"):aggregatePage(SPEC) end),
        err(function() q():aggregatePage(SPEC, nil, 0) end),
        err(function() q():aggregatePage(SPEC, nil, 1.5) end),
        err(function() q():aggregatePage(SPEC, nil, 1000001) end),
        err(function() q():aggregatePage(SPEC, "zz") end),
        err(function() q():aggregatePage(SPEC, "abcd") end),
        -- the state of where qty >= 3 by region
        err(function() q():aggregatePage(SPEC, state) end),
        err(function() q():where("qty", ">=", 4):groupBy("region"):aggregatePage(SPEC, state) end),
        err(function() q():where("qty", ">=", 3):groupBy("region")
            :aggregatePage({ n = SPEC.n }, state) end),
        err(function() q():aggregatePage({ n = { fn = "median" } }) end),
    }
end

function call(step, ...)
    if step == "migrate" then
        return m.migrate(app).version
    end
    local args = { ... }
    return db.tx(function(c) return steps[step](c, table.unpack(args)) end)
end
"""


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", "aggp_" + request.node.name.replace("[", "_").rstrip("]"))
    client.execute_command("SETF", "AGGP", APP)
    assert client.execute_command("CALLF", "AGGP", "migrate") == 1
    assert client.execute_command("CALLF", "AGGP", "seed") == "ok"
    return lambda *a: client.execute_command("CALLF", "AGGP", *a)


def pages(run, case, size, state=""):
    """Calls aggregatePage until it is done; answers the result and the
    processed count of each call."""
    processed = []
    while True:
        r = json.loads(run("page", case, state, str(size)))
        processed.append(r["processed"])
        if r["done"]:
            assert r["state"] == ""
            return r["result"], processed
        assert r["state"] != ""
        state = r["state"]


CASES = ["totals", "ordered", "regions", "shaped", "range", "spans", "equal", "path",
         "follow", "has", "none", "keys"]


@pytest.mark.parametrize("size", [1, 3, 8, 100])
def test_pages_answer_what_one_call_answers(run, size):
    for case in CASES:
        whole = run("whole", case)
        assert whole, case
        got, _ = pages(run, case, size)
        assert got == whole, case


def test_pages_read_page_size_rows(run):
    # 40 rows: pages of 7 read 7 each and 5 last; pages of 8 end on the
    # fifth call, which finds no row after its eighth
    assert pages(run, "totals", 7)[1] == [7, 7, 7, 7, 7, 5]
    assert pages(run, "totals", 8)[1] == [8, 8, 8, 8, 8]
    assert pages(run, "none", 5)[1] == [0]
    # the default page reads all 40 in one call
    r = json.loads(run("page", "totals", "", ""))
    assert r["done"] and r["processed"] == 40


def test_pages_see_writes_after_their_position(run):
    first = json.loads(run("page", "totals", "", "10"))
    assert not first["done"]
    # the first row was read before the delete, and the new row lies ahead
    assert run("change") == "ok"
    got, _ = pages(run, "totals", 10, first["state"])
    assert [p for p in got[0].split() if p.startswith("n=")] == ["n=41"]


def test_page_errors(run):
    state = json.loads(run("page", "range", "", "2"))["state"]
    at = "LENT table Sale query aggregatePage"
    other = (at + " state comes from another query, aggregate or schema version; start"
             " again without a state")
    size = at + " page size must be a whole number from 1 to 1000000, got "
    bad = at + " takes a state that an earlier aggregatePage answered, or nil to start"
    assert run("errors", state) == [
        at + " reads every matching row, so the query takes no limit, offset or after",
        at + " reads every matching row, so the query takes no limit, offset or after",
        at + " reads every matching row, so the query takes no limit, offset or after",
        "LENT table Shop links sales query aggregatePage reads table rows; a links query"
        " takes where,"
        " order, limit, offset, groupBy and aggregates",
        size + "0", size + "1.5", size + "1000001",
        bad, bad,
        other, other, other,
        "LENT table Sale query aggregate n has no function median; use count, sum,"
        " avg, min or max",
    ]
