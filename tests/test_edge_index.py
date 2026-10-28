import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Orders hold numbered lines, and each line may name a part. A unique index
# over a line's number and its order keeps one line per number in each
# order; a second one over quantity, order and part reads the edge.to side;
# a plain index over quantity and order keeps every line.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local lay = require("lent.LAYOUT")
local kc = require("lent.KEYCODEC")
local f = lent.field

local function tables(indexes)
    return {
        lent.schema "Order" {
            id = "int",
            fields = { f.string "status" },
            edges = { lent.edge.to "lines" "Line" },
        },
        lent.schema "Line" {
            id = "int",
            fields = { f.int "n", f.int "qty":default(1) },
            edges = {
                lent.edge.from "order" "Order":ref "lines":unique(),
                lent.edge.to "part" "Part":unique(),
            },
            indexes = indexes,
        },
        lent.schema "Part" { id = "int", fields = { f.string "name" } },
    }
end

local FULL = {
    lent.index("n"):edges("order"):unique(),
    lent.index("qty"):edges("order", "part"):unique():name("one_part"),
    { on = { "qty" }, edges = { "order" } },
}

local function app(indexes)
    return lent.graph(tables(indexes or FULL))
end
local db = client.open(app())

-- each entry of index `name` of table `tname`: its values, then the pk
local function entries(c, tname, name)
    local t = c[tname].t
    local ix
    for _, i in t.indexes do
        if i.name == name then ix = i end
    end
    local prefix = lay.index(t, ix)
    local w = #ix.on + #ix.links
    local out = {}
    lay.walk(prefix, function(k)
        local values = kc.unpack(k, ix.unique and w or w + 1, #prefix + 1)
        local parts = {}
        for i = 1, w do parts[i] = tostring(values[i]) end
        local pk = ix.unique and barch.store.get(k) or tostring(values[w + 1])
        out[#out + 1] = table.concat(parts, ",") .. " -> " .. pk
    end)
    return out
end

local function report(c)
    local out = {}
    for _, name in { "by_n_order", "one_part", "by_qty_order" } do
        out[#out + 1] = name .. ": " .. table.concat(entries(c, "Line", name), "; ")
    end
    return out
end

-- runs fn and answers its error, or "no error"
local function try(fn)
    local ok, err = pcall(fn)
    return ok and "no error" or tostring(err)
end

local steps = {}

function steps.seed(c)
    local o1 = c.Order:create { status = "open" }
    local o2 = c.Order:create { status = "open" }
    local p = c.Part:create { name = "bolt" }
    c.Line:create { n = 1, order = o1, part = p }
    c.Line:create { n = 2, order = o1, qty = 3 }
    c.Line:create { n = 1, order = o2 }
    c.Line:create { n = 1 }
    return "ok"
end

function steps.entries(c)
    return report(c)
end

function steps.create(c)
    local out = {}
    out[#out + 1] = try(function() c.Line:create { n = 1, order = 1 } end)
    -- unlinked lines take any number
    out[#out + 1] = try(function() c.Line:create { n = 1 } end)
    -- one order taking two lines with one number
    local a = c.Line:create { n = 7 }
    local b = c.Line:create { n = 7 }
    out[#out + 1] = try(function() c.Order:create { status = "x", lines = { a, b } } end)
    out[#out + 1] = "orders " .. c.Order:query():count()
    for _, line in report(c) do out[#out + 1] = line end
    return out
end

function steps.link(c)
    local out = {}
    -- line 4 has number 1, as line 1 of order 1 has
    out[#out + 1] = try(function() c.Line:link("order", 4, 1) end)
    out[#out + 1] = try(function() c.Order:link("lines", 1, 4) end)
    local o3 = c.Order:create { status = "new" }
    c.Line:link("order", 4, o3.id)
    -- the edge.to side: line 3 takes the part line 1 has, with qty 1 in
    -- order 2, then moves to order 1 under a free number
    c.Line:link("part", 3, 1)
    c.Line:unlink("order", 3, 2)
    c.Line:update(3, { n = 9 })
    out[#out + 1] = try(function() c.Line:link("order", 3, 1) end)
    for _, line in report(c) do out[#out + 1] = line end
    return out
end

function steps.unlink(c)
    c.Order:unlink("lines", 1, 1)
    c.Line:create { n = 1, order = 1 }
    return report(c)
end

function steps.by(c)
    local function show(r) return r and tostring(r.id) or "nil" end
    local o1 = c.Order:get(1)
    local out = {
        show(c.Line:by("by_n_order", 1, 1)),
        show(c.Line:by("by_n_order", 2, o1)),
        show(c.Line:by("by_n_order", 2, 2)),
        show(c.Line:by("one_part", 1, 1, 1)),
        try(function() c.Line:by("by_n_order", 1) end),
        try(function() c.Line:by("by_qty_order", 1, 1) end),
        c.Line:query():where("n", "=", 1):explain(),
        c.Line:query():where("qty", "=", 1):explain(),
    }
    return out
end

function steps.update(c)
    local out = {}
    out[#out + 1] = try(function() c.Line:update(2, { n = 1 }) end)
    c.Line:update(2, { n = 5, qty = 4 })
    for _, line in report(c) do out[#out + 1] = line end
    return out
end

function steps.upsert(c)
    local out = {}
    local r, created = c.Line:upsert("by_n_order", { n = 2, order = 1, qty = 8 })
    out[#out + 1] = r.id .. " " .. tostring(created) .. " qty " .. r.qty
    r, created = c.Line:upsert("by_n_order", { n = 3, order = c.Order:get(1), qty = 6 })
    out[#out + 1] = r.id .. " " .. tostring(created) .. " qty " .. r.qty
    out[#out + 1] = try(function() c.Line:upsert("by_n_order", { n = 2 }) end)
    out[#out + 1] = try(function() c.Line:upsert("by_n_order", { n = 2, order = { 1, 2 } }) end)
    for _, line in report(c) do out[#out + 1] = line end
    return out
end

function steps.delete(c)
    -- deleting an order unlinks its lines, deleting a part unlinks line 1,
    -- and deleting line 2 removes its entries
    c.Order:delete(2)
    c.Part:delete(1)
    c.Line:delete(2)
    return report(c)
end

-- a second line 2 in order 1, while no index stops it
function steps.dupe(c)
    c.Line:create { n = 2, order = 1 }
    return "ok"
end

-- each declaration that lent.schema refuses, with its error
function steps.schema()
    local function line(index, edges)
        return function()
            lent.schema "L" {
                fields = { f.int "n" },
                edges = edges or {
                    lent.edge.from "order" "Order":ref "lines":unique(),
                    lent.edge.to "tags" "Tag",
                    lent.edge.through "shop" "Shop":via "order.shop",
                },
                indexes = { index },
            }
        end
    end
    local cases = {
        line(lent.index("n"):edges("nope")),
        line(lent.index("n"):edges("tags")),
        line(lent.index("n"):edges("shop")),
        line(lent.index("n"):edges("order", "order")),
        line({ on = { "n" }, edges = "order" }),
        function() lent.index("n"):edges() end,
        function() lent.index("n"):edges("2x") end,
    }
    local out = {}
    for _, fn in cases do
        out[#out + 1] = try(fn)
    end
    return out
end

function call(step, which)
    if step == "migrate" then
        return m.migrate(app()).version
    end
    if step == "migrate_without" then
        return m.migrate(app({ lent.index("qty") })).version
    end
    if step == "migrate_with" then
        local ok, err = pcall(m.migrate, app())
        if not ok then return tostring(err) end
        return db.tx(report)
    end
    if step == "schema" then
        return steps.schema()
    end
    return db.tx(function(c)
        return steps[step](c)
    end)
end
"""


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", re.sub(r"\W", "_", "edge_index_" + request.node.name))
    client.execute_command("SETF", "EDGEIX", APP)
    assert client.execute_command("CALLF", "EDGEIX", "migrate") == 1
    assert client.execute_command("CALLF", "EDGEIX", "seed") == "ok"
    return lambda *a: client.execute_command("CALLF", "EDGEIX", *a)


SEEDED = [
    "by_n_order: 1,1 -> 1; 1,2 -> 3; 2,1 -> 2",
    "one_part: 1,1,1 -> 1",
    "by_qty_order: 1,nil -> 4; 1,1 -> 1; 1,2 -> 3; 3,1 -> 2",
]


def test_entries_hold_linked_ids(run):
    assert run("entries") == SEEDED


DUPLICATE = "LENT table Line index by_n_order is unique, and row "


def test_create_checks_linked_index(run):
    out = run("create")
    assert out[0].startswith(DUPLICATE + "1 already has n=1 order=1")
    assert out[1] == "no error"
    # the second line of the new order breaks the index, and the order goes
    assert out[2].startswith("LENT table Line index by_n_order is unique, and row 6"
                             " already has n=7 order=3")
    assert out[3:] == [
        "orders 2",
        "by_n_order: 1,1 -> 1; 1,2 -> 3; 2,1 -> 2",
        "one_part: 1,1,1 -> 1",
        "by_qty_order: 1,nil -> 4; 1,nil -> 5; 1,nil -> 6; 1,nil -> 7; 1,1 -> 1; 1,2 -> 3;"
        " 3,1 -> 2",
    ]


def test_link_moves_entries(run):
    out = run("link")
    assert out[0].startswith(DUPLICATE + "1 already has n=1 order=1")
    assert out[1].startswith(DUPLICATE + "1 already has n=1 order=1")
    assert out[2].startswith("LENT table Line index one_part is unique, and row 1"
                             " already has qty=1 order=1 part=1")
    assert out[3:] == [
        "by_n_order: 1,1 -> 1; 1,3 -> 4; 2,1 -> 2",
        "one_part: 1,1,1 -> 1",
        "by_qty_order: 1,nil -> 3; 1,1 -> 1; 1,3 -> 4; 3,1 -> 2",
    ]


def test_link_moves_entries(run):
    out = run("link")
    assert out[0].startswith(DUPLICATE + "1 already has n=1 order=1")
    assert out[1].startswith(DUPLICATE + "1 already has n=1 order=1")
    assert out[2].startswith("LENT table Line index one_part is unique, and row 1"
                             " already has qty=1 order=1 part=1")
    assert out[3:] == [
        "by_n_order: 1,1 -> 1; 1,3 -> 4; 2,1 -> 2",
        "one_part: 1,1,1 -> 1",
        "by_qty_order: 1,nil -> 3; 1,1 -> 1; 1,3 -> 4; 3,1 -> 2",
    ]


def test_unlink_frees_key(run):
    # line 1 leaves order 1, so line 5 can take number 1 there
    assert run("unlink") == [
        "by_n_order: 1,1 -> 5; 1,2 -> 3; 2,1 -> 2",
        "one_part: ",
        "by_qty_order: 1,nil -> 1; 1,nil -> 4; 1,1 -> 5; 1,2 -> 3; 3,1 -> 2",
    ]


def test_by_and_planner(run):
    assert run("by") == [
        "1",
        "2",
        "nil",
        "1",
        "LENT table Line index by_n_order takes 2 values, got 1",
        "LENT table Line has no unique index by_qty_order",
        # a unique index with an edge needs the edge's id, which where
        # cannot give
        "id",
        "by_qty_order = qty",
    ]


def test_update_checks_linked_index(run):
    out = run("update")
    assert out[0].startswith(DUPLICATE + "1 already has n=1 order=1")
    assert out[1:] == [
        "by_n_order: 1,1 -> 1; 1,2 -> 3; 5,1 -> 2",
        "one_part: 1,1,1 -> 1",
        "by_qty_order: 1,nil -> 4; 1,1 -> 1; 1,2 -> 3; 4,1 -> 2",
    ]


def test_upsert_by_linked_index(run):
    needs = "LENT table Line upsert index by_n_order needs one row or id for edge order"
    out = run("upsert")
    assert out[:2] == ["2 false qty 8", "5 true qty 6"]
    assert out[2].startswith(needs)
    assert out[3].startswith(needs)
    assert out[4:] == [
        "by_n_order: 1,1 -> 1; 1,2 -> 3; 2,1 -> 2; 3,1 -> 5",
        "one_part: 1,1,1 -> 1",
        "by_qty_order: 1,nil -> 4; 1,1 -> 1; 1,2 -> 3; 6,1 -> 5; 8,1 -> 2",
    ]


def test_delete_removes_entries(run):
    assert run("delete") == [
        "by_n_order: 1,1 -> 1",
        "one_part: ",
        "by_qty_order: 1,nil -> 3; 1,nil -> 4; 1,1 -> 1",
    ]


def test_migrate_builds_linked_index(run):
    assert run("migrate_without") == 2
    assert run("migrate_with") == SEEDED


def test_migrate_refuses_linked_duplicates(run):
    assert run("migrate_without") == 2
    assert run("dupe") == "ok"
    assert run("migrate_with").startswith(
        "MIGRATE table Line index by_n_order is unique, but rows 2 and 5 hold the same values")


def test_index_declarations(run):
    assert run("schema") == [
        "SCHEMA table L index by_n_nope edge nope is not an edge of the table",
        "SCHEMA table L index by_n_tags edge tags links many rows; an index takes an edge"
        " with :unique()",
        "SCHEMA table L index by_n_shop edge shop is an edge.through; an index takes an"
        " edge.to or edge.from",
        "SCHEMA table L index by_n_order_order names edge order twice",
        "SCHEMA table L index nil option edges takes a table, got order",
        "SCHEMA index edges takes at least one edge name",
        "SCHEMA index edge needs a name of letters, digits and _, got 2x",
    ]
