import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Customers like products. A follow with filters on the products reads the
# linked rows through a product index when the index range is no larger
# than the set of linked rows, and reads every linked row otherwise.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local lay = require("lent.LAYOUT")

local app = lent.graph {
    lent.schema "Customer" {
        id = "int",
        fields = { lent.field.string "name" },
        edges = { lent.edge.to "likes" "Product" },
    },
    lent.schema "Product" {
        id = "int",
        fields = { lent.field.string "name":unique(), lent.field.string "color",
                   lent.field.int "rank" },
        indexes = { lent.index("color"), lent.index("rank") },
    },
}

local COLORS = { [0] = "red", "green", "blue" }

local function names(list)
    local out = {}
    for _, r in list do out[#out + 1] = r.name end
    return table.concat(out, ",")
end

-- Runs q's read with every product row outside `keep` (a list of product
-- numbers) made unreadable, so reading one raises an error, and answers
-- "names | explain".
local function reading(c, keep, q, read)
    local t, saved = c.Product.t, {}
    for i = 1, 60 do
        if not table.find(keep, i) then
            saved[i] = barch.store.get(lay.row(t, i))
            barch.store.set(lay.row(t, i), "not a row")
        end
    end
    local ok, got = pcall(read or q.all, q)
    for i, v in saved do
        barch.store.set(lay.row(t, i), v)
    end
    if not ok then return "read a row outside keep" end
    local shown = type(got) == "number" and tostring(got) or names(got)
    return shown .. " | " .. q:explain()
end

local function range(lo, hi, step)
    local out = {}
    for i = lo, hi, step or 1 do out[#out + 1] = i end
    return out
end

local steps = {}

function steps.seed(c)
    local ann = c.Customer:create { name = "ann" }
    local bob = c.Customer:create { name = "bob" }
    for i = 1, 60 do
        local p = c.Product:create { name = string.format("p%02d", i), color = COLORS[i % 3],
                                     rank = 61 - i }
        -- ann likes the 30 odd products, bob products 1 and 2
        if i % 2 == 1 then c.Customer:link("likes", ann.id, p.id) end
        if i <= 2 then c.Customer:link("likes", bob.id, p.id) end
    end
    return "ok"
end

function steps.reads(c)
    local function likes(name)
        return c.Customer:query():where("name", "=", name):queryLikes()
    end
    local function red(q) return q:where("color", "=", "red") end
    local first = likes("ann"):order("rank"):limit(2)
    local page = first:all()
    local odd, redOdd = range(1, 59, 2), range(3, 57, 6)
    return {
        -- the unique name finds the one row
        reading(c, { 7 }, likes("ann"):where("name", "=", "p07")),
        -- 20 red keys, 10 of them liked
        reading(c, redOdd, red(likes("ann"))),
        reading(c, redOdd, red(likes("ann")), likes("ann").count),
        -- bob likes 2 products, fewer than the red keys: read those two
        reading(c, { 1, 2 }, red(likes("bob"))),
        -- with using(), the index is read however many keys it holds
        reading(c, {}, red(likes("bob")):using("by_color")),
        -- rank order stops at the limit
        reading(c, { 59, 57, 55 }, likes("ann"):order("rank"):limit(3)),
        -- bob's products come after more rank keys than he has links
        reading(c, { 1, 2 }, likes("bob"):order("rank"):limit(1)),
        reading(c, odd, likes("ann"):order("rank", "desc"):limit(3)),
        -- the index bound starts at rank 50, so p11 is read and filtered out
        reading(c, range(1, 11, 2), likes("ann"):where("rank", ">", 50)),
        -- a read that leaves the index's rows out of keep fails
        reading(c, { 1 }, red(likes("ann"))),
        names(page) .. " " .. names(likes("ann"):order("rank"):limit(2)
            :after(first:cursor(page[#page])):all()),
    }
end

function steps.with(c)
    local out = {}
    local q = c.Customer:query():withLikes(function(l) l:where("name", "=", "p01") end)
    for _, r in q:all() do
        out[#out + 1] = r.name .. "=" .. names(r.likes)
    end
    return out
end

function call(step)
    if step == "migrate" then
        local r = m.migrate(app)
        return r.done and "done" or "more"
    end
    return client.tx(function(c) return steps[step](c) end)
end
"""


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", "follow_" + request.node.name)
    client.execute_command("SETF", "LIKES", APP)
    run = lambda *a: client.execute_command("CALLF", "LIKES", *a)
    assert run("migrate") == "done"
    assert run("seed") == "ok"
    return run


def test_follow_reads_through_an_index(run):
    assert run("reads") == [
        "p07 | edge customer_likes in (by_name = name)",
        "p03,p09,p15,p21,p27,p33,p39,p45,p51,p57 | edge customer_likes in (by_color = color)",
        "10 | edge customer_likes in (by_color = color)",
        " | edge customer_likes in (by_color = color)",
        " | edge customer_likes in (by_color = color)",
        "p59,p57,p55 | edge customer_likes in (by_rank)",
        "p02 | edge customer_likes in (by_rank)",
        "p01,p03,p05 | edge customer_likes then sort",
        "p09,p07,p05,p03,p01 | edge customer_likes in (by_rank range rank)",
        "read a row outside keep",
        "p59,p57 p55,p53",
    ]


def test_follow_index_in_with(run):
    assert run("with") == ["ann=p01", "bob=p01"]
