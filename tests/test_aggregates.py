import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Users write posts with stars, a kind and an optional score; aggregates run
# over posts, with and without groups.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

local function app()
    return lent.graph {
        lent.schema "User" {
            id = "int",
            fields = { lent.field.string "name":unique() },
            edges = { lent.edge.to "posts" "Post", lent.edge.to "likes" "Post" },
        },
        lent.schema "Post" {
            id = "int",
            fields = {
                lent.field.string "title",
                lent.field.int "stars":default(0),
                lent.field.float "score":optional(),
                lent.field.enum "kind":values("news", "note"):default("note"),
                lent.field.bool "draft":default(false),
                lent.field.time "at":default(0),
                lent.field.json "meta":optional(),
            },
            indexes = { lent.index("stars") },
            edges = { lent.edge.from "author" "User":ref "posts":unique() },
        },
    }
end

-- a value as text, so nil, booleans and floats compare in Python
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

local steps = {}

function steps.seed(c)
    local ann = c.User:create { name = "ann" }
    local bob = c.User:create { name = "bob" }
    c.User:create { name = "cy" }
    c.Post:create { title = "a", stars = 5, score = 1.5, kind = "news", author = ann, at = 30 }
    c.Post:create { title = "b", stars = 1, author = ann, at = 10 }
    c.Post:create { title = "c", stars = 3, score = 2.25, kind = "news", author = bob, at = 20 }
    c.Post:create { title = "d", stars = 2, draft = true, at = 40 }
    c.User:link("likes", bob.id, 1)
    return "ok"
end

function steps.totals(c)
    local q = c.Post:query()
    local all = q:aggregate {
        n = { fn = "count" }, scored = { fn = "count", field = "score" },
        stars = { fn = "sum", field = "stars" }, score = { fn = "sum", field = "score" },
        low = { fn = "min", field = "stars" }, high = { fn = "max", field = "stars" },
        first = { fn = "min", field = "title" }, last = { fn = "max", field = "at" },
        anydraft = { fn = "max", field = "draft" },
    }
    local none = c.Post:query():where("stars", ">", 9)
    return {
        rows({ all }, { "n", "scored", "stars", "score", "low", "high", "first", "last",
                        "anydraft" })[1],
        show(q:sum("stars")) .. " " .. show(q:min("score")) .. " " .. show(q:max("kind")),
        -- the filters, order and limit pick the rows aggregated
        show(c.Post:query():where("stars", ">=", 2):sum("stars")) .. " "
            .. show(c.Post:query():order("stars", "desc"):limit(2):sum("stars")) .. " "
            .. show(c.User:query():where("name", "=", "ann"):queryPosts():max("stars")),
        show(none:sum("stars")) .. " " .. show(none:min("stars")) .. " "
            .. show(none:aggregate({ n = { fn = "count" } }).n),
    }
end

function steps.groups(c)
    local out = {}
    local spec = { n = { fn = "count" }, stars = { fn = "sum", field = "stars" },
                   best = { fn = "max", field = "title" } }
    for _, line in rows(c.Post:query():groupBy("kind"):aggregate(spec), { "kind", "n", "stars", "best" }) do
        out[#out + 1] = line
    end
    -- grouping by an edge with one row at its far end groups by that row's id
    for _, line in rows(c.Post:query():groupBy("author"):aggregate(spec), { "author", "n", "stars" }) do
        out[#out + 1] = line
    end
    for _, line in rows(c.Post:query():groupBy("draft", "kind"):aggregate { n = { fn = "count" } },
                        { "draft", "kind", "n" }) do
        out[#out + 1] = line
    end
    -- groups without aggregates list the distinct values
    for _, line in rows(c.Post:query():where("stars", ">", 1):groupBy("score"):aggregate(),
                        { "score" }) do
        out[#out + 1] = line
    end
    out[#out + 1] = show(#c.Post:query():where("stars", ">", 9):groupBy("kind"):aggregate {})
    return out
end

local bad = {
    spec = function(c) c.Post:query():aggregate(5) end,
    entry = function(c) c.Post:query():aggregate { n = "count" } end,
    option = function(c) c.Post:query():aggregate { n = { fn = "count", as = 1 } } end,
    fn = function(c) c.Post:query():aggregate { n = { fn = "avg", field = "stars" } } end,
    nofield = function(c) c.Post:query():aggregate { n = { fn = "sum" } } end,
    field = function(c) c.Post:query():sum("missing") end,
    sumkind = function(c) c.Post:query():sum("title") end,
    sumtime = function(c) c.Post:query():sum("at") end,
    jsonmax = function(c) c.Post:query():max("meta") end,
    groupnone = function(c) c.Post:query():groupBy() end,
    groupname = function(c) c.Post:query():groupBy("nothing") end,
    groupjson = function(c) c.Post:query():groupBy("meta") end,
    groupmany = function(c) c.User:query():groupBy("posts") end,
    clash = function(c) c.Post:query():groupBy("kind"):aggregate { kind = { fn = "count" } } end,
}

function call(step, which)
    if step == "migrate" then
        return m.migrate(app()).version
    end
    return client.tx(function(c)
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
    client.execute_command("USE", "agg_" + request.node.name)
    client.execute_command("SETF", "AGG", APP)
    assert client.execute_command("CALLF", "AGG", "migrate") == 1
    assert client.execute_command("CALLF", "AGG", "seed") == "ok"
    return lambda *a: client.execute_command("CALLF", "AGG", *a)


def test_aggregates(run):
    assert run("totals") == [
        "n=4 scored=2 stars=11 score=3.75 low=1 high=5 first=a last=40 anydraft=true",
        "11 1.5 note",
        "10 8 5",
        # an empty selection sums to 0 and has no min or max
        "0 nil 0",
    ]


def test_group_by(run):
    assert run("groups") == [
        "kind=news n=2 stars=8 best=c",
        "kind=note n=2 stars=3 best=d",
        # a post without an author forms the nil group, which sorts first
        "author=nil n=1 stars=2",
        "author=1 n=2 stars=6",
        "author=2 n=1 stars=3",
        "draft=false kind=news n=2",
        "draft=false kind=note n=1",
        "draft=true kind=note n=1",
        "score=nil",
        "score=1.5",
        "score=2.25",
        "0",
    ]


ERRORS = {
    "spec": "LENT table Post query aggregate takes a table of name = { fn = ..., field = ... }",
    "entry": "LENT table Post query aggregate takes a table of name = { fn = ..., field = ... }",
    "option": "LENT table Post query aggregate n has no option as",
    "fn": "LENT table Post query aggregate n has no function avg; use count, sum, min or max",
    "nofield": "LENT table Post query aggregate n needs a field for sum",
    "field": "LENT table Post has no field missing",
    "sumkind": "LENT table Post field title is string, so sum needs int or float",
    "sumtime": "LENT table Post field at is time, so sum needs int or float",
    "jsonmax": "LENT table Post field meta is json, which has no order",
    "groupnone": "LENT table Post query groupBy takes at least one field or edge",
    "groupname": "LENT table Post has no field or edge nothing",
    "groupjson": "LENT table Post field meta is json, so groupBy cannot use it",
    "groupmany": "LENT table User edge posts can link a row to many rows, so groupBy cannot use it",
    "clash": "LENT table Post query aggregate kind has the name of a groupBy key",
}


def test_aggregate_errors(run):
    for which, message in ERRORS.items():
        with pytest.raises(redis.ResponseError) as err:
            run("bad", which)
        assert message in str(err.value), which
