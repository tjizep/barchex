import json
import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Orders with two indexes that one filter each can serve. Most orders are
# open and customer 1 has most of the rest, so which index is narrower
# depends on the values.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local f = lent.field

local app = lent.graph {
    lent.schema "Shop" {
        id = "int",
        fields = { f.string "name" },
        edges = { lent.edge.to "orders" "Order" },
    },
    lent.schema "Order" {
        id = "int",
        fields = {
            f.string "status", f.int "customer", f.int "size", f.int "weight",
            f.string "code":unique(), f.string "note":optional(),
        },
        indexes = { lent.index("status"), lent.index("customer"), lent.index("size"),
                    lent.index("weight") },
        edges = { lent.edge.from "shop" "Shop":ref "orders":unique() },
    },
}
local db = client.open(app)

local function ids(q)
    local out = {}
    for _, r in q:all() do out[#out + 1] = r.id end
    table.sort(out)
    return out
end

local cases = {}
function cases.eitherIndex(c, q) return q:where("status", "=", "open"):where("customer", "=", 7) end
function cases.firstIsNarrower(c, q) return q:where("status", "=", "rare"):where("customer", "=", 1) end
function cases.equalCounts(c, q) return q:where("status", "=", "rare"):where("customer", "=", 7) end
function cases.expression(c, q) return q:where("status == 'open' and customer == 7") end
function cases.ranges(c, q) return q:where("size > 2 and weight > 37") end
function cases.spans(c, q) return q:where("(size == 1 or size == 5) and weight > 5") end
function cases.none(c, q) return q:where("status", "=", "open"):where("customer", "=", 12345) end
function cases.sorted(c, q)
    return q:where("status", "=", "open"):where("customer", "=", 7):order("note")
end
function cases.oneIndex(c, q) return q:where("customer", "=", 7) end
function cases.fullRead(c, q) return q:where("note", "=", "x") end
function cases.point(c, q) return q:where("code", "=", "c7"):where("status", "=", "open") end
function cases.named(c, q)
    return q:where("status", "=", "open"):where("customer", "=", 7):using("by_status")
end
function cases.rangeOnly(c, q) return q:where("size", ">", 2) end
function cases.paged(c, q) return q:where("status", "=", "open"):where("customer", "=", 1) end

local steps = {}

function steps.seed(c)
    local shops = { c.Shop:create { name = "a" }, c.Shop:create { name = "b" },
                     c.Shop:create { name = "c" } }
    for i = 1, 40 do
        c.Order:create {
            status = if i == 7 then "rare" elseif i == 8 then "rare" else "open",
            customer = if i == 7 or i == 9 then 7 elseif i == 8 then 9 else 1,
            size = i, weight = i, code = "c" .. i,
            note = if i % 2 == 0 then "x" else nil, shop = shops[i % 3 + 1],
        }
    end
    return "ok"
end

function steps.explain(c, name)
    return cases[name](c, c.Order:query()):explain()
end

function steps.rows(c, name)
    return ids(cases[name](c, c.Order:query()))
end

-- The rows through each index, which must not depend on the plan.
function steps.through(c, name, index)
    return ids(cases[name](c, c.Order:query()):using(index))
end

function steps.count(c, name)
    return cases[name](c, c.Order:query()):count()
end

function steps.update(c)
    return c.Order:query():where("status", "=", "open"):where("customer", "=", 7)
        :update { note = "changed" }
end

function steps.withOrders(c)
    local q = c.Shop:query():with("orders", function(o)
        return o:where("status", "=", "open"):where("customer", "=", 7)
    end)
    local n = 0
    for _, s in q:all() do n += #s.orders end
    return n
end

function steps.followExplain(c)
    return c.Shop:query():follow("orders"):where("status", "=", "open")
        :where("customer", "=", 7):explain()
end

-- Closes orders behind a paged read's position. Status open then holds fewer
-- keys than customer 1, which held fewer before.
function steps.closeSome(c)
    for _, i in { 9, 10, 11 } do c.Order:update(i, { status = "closed" }) end
    return "ok"
end

-- Status past "p" then holds more keys than customer past 1, which held more.
function steps.widen(c)
    for i = 20, 30 do c.Order:update(i, { status = "rare" }) end
    return "ok"
end

local PAGED = {
    plain = function(c) return c.Order:query():where("status", "=", "open"):where("customer", "=", 1) end,
    filtered = function(c)
        return c.Shop:query():has("orders", function(o)
            return o:where("status", "=", "open"):where("customer", "=", 1)
        end)
    end,
}

function steps.page(c, name, state, size)
    local q = PAGED[name](c)
    local r = q:aggregatePage({ n = { fn = "count" } },
                              if state == "" then nil else state, tonumber(size))
    return simdjson.encode({ plan = q:explain(), state = r.state or "",
                             n = if r.done then r.result.n else -1 })
end

function steps.cursorPage(c, cursor)
    local q = c.Order:query():where("status", ">=", "p"):where("customer", ">=", 2)
        :order("id"):limit(1)
    if cursor ~= "" then q:after(cursor) end
    local list = q:all()
    local out = { q:explain(), #list > 0 and q:cursor(list[#list]) or "" }
    for _, r in list do out[#out + 1] = r.id end
    return out
end

function call(step, mode, ...)
    if step == "migrate" then
        return m.migrate(app).version
    end
    local args = { ... }
    return db.tx(function(c) return steps[step](c, table.unpack(args)) end, mode == "pessimistic")
end
"""


@pytest.fixture(params=["optimistic", "pessimistic"])
def run(client, request):
    setup(client)
    client.execute_command("USE", "plan_" + re.sub(r"\W", "_", request.node.name))
    client.execute_command("SETF", "PLANNER", APP)
    mode = request.param
    run = lambda step, *a: client.execute_command("CALLF", "PLANNER", step, mode, *a)
    assert run("migrate") == 1
    assert run("seed") == "ok"
    return run


def test_ties_read_the_index_with_fewer_keys(run):
    assert run("explain", "eitherIndex") == "by_customer = customer [2 keys over by_status 38]"
    assert run("explain", "expression") == "by_customer = customer [2 keys over by_status 38]"
    assert run("explain", "firstIsNarrower") == "by_status = status [2 keys over by_customer 37]"
    assert run("explain", "none") == "by_customer = customer [0 keys over by_status 38]"
    assert run("explain", "sorted") == ("by_customer = customer then sort"
                                        " [2 keys over by_status 38]")


def test_ties_compare_range_widths(run):
    # a range on an int field also reads the keys at its bound
    assert run("explain", "ranges") == "by_weight range weight [4 keys over by_size 39]"
    assert run("explain", "spans") == "by_size 2 ranges size [2 keys over by_weight 36]"


def test_equal_counts_keep_the_first_index(run):
    assert run("explain", "equalCounts") == "by_status = status [2 keys over by_customer 2]"


@pytest.mark.parametrize("case, name", [
    ("oneIndex", "by_customer = customer"),
    ("fullRead", "id"),
    ("point", "by_code = code"),
    ("named", "by_status = status"),
    ("rangeOnly", "by_size range size"),
])
def test_plans_without_a_tie_count_nothing(run, case, name):
    assert run("explain", case) == name


@pytest.mark.parametrize("case, want", [
    ("eitherIndex", [9]), ("firstIsNarrower", []), ("equalCounts", [7]),
    ("none", []), ("ranges", [38, 39, 40]), ("spans", []),
])
def test_rows_do_not_depend_on_the_index_read(run, case, want):
    assert run("rows", case) == want
    assert run("count", case) == len(want)
    assert run("through", case, "id") == want


def test_query_writes_use_the_same_plan(run):
    assert run("update") == 1


def test_queries_from_linked_rows_count_nothing(run):
    assert run("withOrders") == 1
    assert "keys over" not in run("followExplain")


@pytest.mark.parametrize("name, size, want", [("plain", 10, 37), ("filtered", 1, 3)])
def test_paged_plans_stay_the_same_across_pages(run, name, size, want):
    if name == "plain":
        assert run("explain", "paged") == "by_customer = customer [37 keys over by_status 38]"
    first = json.loads(run("page", name, "", str(size)))
    assert first["state"] != ""
    assert run("closeSome") == "ok"
    if name == "plain":
        assert run("explain", "paged") == "by_status = status [35 keys over by_customer 37]"
    state, n = first["state"], first["n"]
    while state:
        page = json.loads(run("page", name, state, str(size)))
        state, n = page["state"], page["n"]
    assert n == want


def test_cursor_pages_survive_a_tie_changing(run):
    plan, cursor, *rows = run("cursorPage", "")
    assert plan == "by_status range status then sort [2 keys over by_customer 3]"
    assert rows == [7]
    assert run("widen") == "ok"
    plan, cursor, *rows = run("cursorPage", cursor)
    assert plan == "by_customer range customer then sort [3 keys over by_status 13], after cursor"
    assert rows == [8]
    assert run("cursorPage", cursor)[2:] == []
