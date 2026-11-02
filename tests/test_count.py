import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Items with optional indexed fields, some nil, so counts that read keys
# must leave those out. A computed field counts the rows each call reads.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local f = lent.field

local reads = 0

local app = lent.graph {
    lent.schema "Shelf" {
        id = "int",
        fields = { f.string "name" },
        edges = { lent.edge.to "items" "Item" },
    },
    lent.schema "Item" {
        id = "int",
        fields = {
            f.string "kind", f.int "size":optional(), f.float "price":optional(),
            f.decimal "cost":scale(2), f.string "tag":optional(),
            f.string "code":optional():unique(), f.string "note":optional(),
            f.bool "read":computed(function()
                reads += 1
                return true
            end),
        },
        indexes = {
            lent.index("kind", "size"), lent.index("size"), lent.index("price"),
            lent.index("cost"), lent.index("tag"),
        },
        edges = { lent.edge.from "shelf" "Shelf":ref "items":unique() },
    },
    lent.schema "Doc" {
        fields = { f.int "n" },
        indexes = { lent.index("n") },
        policy = {
            query = { function(_, viewer, q) q:where("n", ">=", viewer) end },
        },
    },
}
local db = client.open(app)

local function item(c) return c.Item:query() end

-- each case answers a query; every one counts as #all() does
local cases = {
    -- whole tables and orders
    table = item,
    ordered = function(c) return item(c):order("size") end,
    paged = function(c) return item(c):order("size", "desc"):limit(5):offset(2) end,
    limited = function(c) return item(c):limit(4) end,
    noLimit = function(c) return item(c):limit(0) end,
    past = function(c) return item(c):offset(1000) end,
    tailPage = function(c) return item(c):offset(28):limit(10) end,
    -- ids
    id = function(c) return item(c):where("id", "=", 3) end,
    noId = function(c) return item(c):where("id", "=", 999) end,
    idsOver = function(c) return item(c):where("id", ">", 10) end,
    idSpan = function(c) return item(c):where("id", ">", 2):where("id", "<=", 5) end,
    -- equal filters
    tag = function(c) return item(c):where("tag", "=", "a") end,
    spaced = function(c) return item(c):where("tag", "=", "a b") end,
    kind = function(c) return item(c):where("kind", "=", "x") end,
    both = function(c) return item(c):where("size", "=", 2):where("kind", "=", "x") end,
    code = function(c) return item(c):where("code", "=", "c7") end,
    noCode = function(c) return item(c):where("code", "=", "nope") end,
    cost = function(c) return item(c):where("cost", "=", 1.5) end,
    sameTwice = function(c) return item(c):where("kind", "=", "x"):where("kind", "=", "x") end,
    -- ranges, whose ends and nils must stay out
    below = function(c) return item(c):where("size", "<", 3) end,
    upTo = function(c) return item(c):where("size", "<=", 3) end,
    above = function(c) return item(c):where("size", ">", 3) end,
    from = function(c) return item(c):where("size", ">=", 3) end,
    between = function(c) return item(c):where("size", ">", 1):where("size", "<", 4) end,
    empty = function(c) return item(c):where("size", ">", 4):where("size", "<", 1) end,
    afterKind = function(c) return item(c):where("kind", "=", "x"):where("size", "<", 3) end,
    priceOver = function(c) return item(c):where("price", ">", 1.5) end,
    priceUnder = function(c) return item(c):where("price", "<", 1.5) end,
    words = function(c) return item(c):where("tag", ">", "a") end,
    codes = function(c) return item(c):where("code", ">=", "c2") end,
    cheap = function(c) return item(c):where("cost", "<", 2) end,
    fractionOver = function(c) return item(c):where("size", ">", 2.5) end,
    fractionUnder = function(c) return item(c):where("size", "<=", 2.5) end,
    expr = function(c) return item(c):where("size >= 3") end,
    params = function(c) return item(c):where("kind == k and size < n", { k = "y", n = 3 }) end,
    named = function(c) return item(c):using("by_tag") end,
    namedLimit = function(c) return item(c):using("by_tag"):limit(3) end,
}

-- and these need the rows
local reading = {
    other = function(c) return item(c):where("note", "=", "n") end,
    differs = function(c) return item(c):where("kind", "~=", "x") end,
    missing = function(c) return item(c):where("size", "=", nil) end,
    fn = function(c) return item(c):where(function(r) return r.id > 3 end) end,
    orExpr = function(c) return item(c):where("size < 2 or size > 3") end,
    twoValues = function(c) return item(c):where("kind", "=", "x"):where("kind", "=", "y") end,
    twoFields = function(c) return item(c):where("size", ">", 1):where("price", ">", 1) end,
    equalAndRange = function(c) return item(c):where("size", "=", 2):where("size", ">", 1) end,
    fractionEqual = function(c) return item(c):where("size", "=", 2.5) end,
    infinite = function(c) return item(c):where("price", "<", math.huge) end,
    allFinite = function(c) return item(c):where("price", ">", -math.huge) end,
    top = function(c) return item(c):where("price", ">=", math.huge) end,
    computed = function(c) return item(c):where("read", "=", true) end,
    has = function(c) return item(c):has("shelf") end,
    hasNo = function(c) return item(c):hasNo("shelf") end,
    follow = function(c) return c.Shelf:query():follow("items") end,
    cursor = function(c)
        local q = item(c):order("id")
        return item(c):order("id"):after(q:cursor(q:first()))
    end,
}

local steps = {}

function steps.seed(c)
    local shelf = c.Shelf:create { name = "s" }
    for i = 1, 30 do
        c.Item:create {
            kind = if i % 2 == 0 then "x" else "y",
            size = if i % 5 == 0 then nil else i % 5,
            price = if i % 4 == 0 then nil elseif i == 1 then math.huge
                elseif i == 2 then -math.huge else (i % 3) * 0.75,
            cost = (i % 4) / 2,
            tag = if i % 3 == 0 then nil else ({ "a", "ab", "a b", "b" })[i % 4 + 1],
            code = if i % 6 == 0 then nil else "c" .. i,
            note = if i % 2 == 0 then "n" else nil,
            shelf = if i % 3 == 0 then shelf else nil,
        }
    end
    return "ok"
end

-- how many rows it counted, how many all() answers and how many rows each read
local function check(c, q)
    local before = reads
    local n = q(c):count()
    local read = reads - before
    return { n, #q(c):all(), read }
end

function steps.keys(c, name) return check(c, cases[name]) end
function steps.rows(c, name) return check(c, reading[name]) end

function steps.writes(c)
    local out = { item(c):where("kind", "=", "x"):count() }
    local a = c.Item:create { kind = "x", cost = 1 }
    out[2] = item(c):where("kind", "=", "x"):count()
    c.Item:update(a.id, { kind = "y" })
    out[3] = item(c):where("kind", "=", "x"):count()
    c.Item:delete(a.id)
    out[4] = item(c):count()
    return out
end

function steps.policy(viewer)
    return db.tx(function(c)
        for n = 1, 6 do c.Doc:create { n = n } end
        return { c.Doc:query():count(), c.Doc:query():where("n", "<", 5):count() }
    end, false, tonumber(viewer))
end

function call(step, ...)
    if step == "migrate" then
        return m.migrate(app).version
    elseif step == "policy" then
        return steps.policy(...)
    end
    local args = { ... }
    return db.tx(function(c) return steps[step](c, table.unpack(args)) end)
end
"""

KEYS = [
    "table", "ordered", "paged", "limited", "noLimit", "past", "tailPage", "id", "noId",
    "idsOver", "idSpan", "tag", "spaced", "kind", "both", "code", "noCode", "cost", "sameTwice",
    "below", "upTo", "above", "from", "between", "empty", "afterKind", "priceOver", "priceUnder",
    "words", "codes", "cheap", "fractionOver", "fractionUnder", "expr", "params", "named", "namedLimit",
]
ROWS = [
    "other", "differs", "missing", "fn", "orExpr", "twoValues", "twoFields", "equalAndRange",
    "fractionEqual", "infinite", "allFinite", "top", "computed", "has",
    "hasNo", "follow", "cursor",
]


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", "cnt_" + request.node.name)
    client.execute_command("SETF", "CNT", APP)
    assert client.execute_command("CALLF", "CNT", "migrate") == 1
    assert client.execute_command("CALLF", "CNT", "seed") == "ok"
    return lambda *a: client.execute_command("CALLF", "CNT", *a)


def test_count_reads_no_row_when_the_keys_are_the_answer(run):
    for case in KEYS:
        n, every, read = run("keys", case)
        assert n == every, case
        assert read == 0, case


def test_count_reads_rows_for_other_filters(run):
    for case in ROWS:
        n, every, read = run("rows", case)
        assert n == every, case
        assert read > 0 or case in ("twoValues",), case


def test_count_sees_the_transactions_writes(run):
    assert run("writes") == [15, 16, 15, 30]


def test_count_keeps_the_policys_filter(run):
    assert run("policy", "3") == [4, 2]
