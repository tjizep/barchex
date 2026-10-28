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

function steps.values(c)
    local q = c.Post:query()
    local t = q:aggregate {
        -- stars plus a bonus for news; titles longer than one letter
        weighted = { fn = "sum", value = function(p)
            return p.stars + (p.kind == "news" and 10 or 0)
        end },
        long = { fn = "count", value = function(p)
            if #p.title > 1 then return true end
            return nil
        end },
        lowscore = { fn = "min", value = function(p) return p.score and -p.score end },
        tag = { fn = "max", value = function(p) return p.kind .. "/" .. p.title end },
    }
    local out = { rows({ t }, { "weighted", "long", "lowscore", "tag" })[1] }
    for _, line in rows(q:groupBy("author"):aggregate {
        half = { fn = "sum", value = function(p) return p.stars / 2 end },
    }, { "author", "half" }) do
        out[#out + 1] = line
    end
    local none = c.Post:query():where("stars", ">", 9):aggregate {
        s = { fn = "sum", value = function(p) return p.stars end },
        m = { fn = "max", value = function(p) return p.stars end },
    }
    out[#out + 1] = show(none.s) .. " " .. show(none.m)
    return out
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

function steps.more(c)
    local q = c.Post:query()
    local t = q:aggregate {
        stars = { fn = "avg", field = "stars" }, score = { fn = "avg", field = "score" },
        double = { fn = "avg", value = function(p) return p.stars * 2 end },
        kinds = { fn = "count", field = "kind", distinct = true },
        scores = { fn = "count", field = "score", distinct = true },
        -- 1, 2, 1, 2 hold two distinct values
        ones = { fn = "sum", value = function(p) return p.stars > 2 and 1 or 2 end, distinct = true },
        len = { fn = "avg", value = function(p) return #p.kind end, distinct = true },
        tables = { fn = "count", value = function(p) return { k = p.kind } end, distinct = true },
    }
    local out = { rows({ t }, { "stars", "score", "double", "kinds", "scores", "ones", "len",
                                "tables" })[1] }
    local none = c.Post:query():where("stars", ">", 9):aggregate { a = { fn = "avg", field = "stars" } }
    out[#out + 1] = show(none.a)
    local spec = { n = { fn = "count" }, stars = { fn = "sum", field = "stars" },
                   score = { fn = "avg", field = "score" } }
    local names = { "author", "n", "stars", "score" }
    local function add(label, groups)
        out[#out + 1] = label .. ": " .. table.concat(rows(groups, names), ", ")
    end
    local function by() return c.Post:query():groupBy("author") end
    add("n > 1", by():having("n > 1"):aggregate(spec))
    add("stars >= s", by():having("stars >= s", { s = 3 }):aggregate(spec))
    add("fn", by():having(function(g) return g.author ~= nil end):aggregate(spec))
    add("two", by():having("stars > 2"):having("n == 1"):aggregate(spec))
    -- a group whose avg has no values fails a range test
    add("score > 1", by():having("score > 1"):aggregate(spec))
    add("stars desc", by():order("stars", "desc"):aggregate(spec))
    add("n desc, stars", by():order("n", "desc"):order("stars"):aggregate(spec))
    add("score desc", by():order("score", "desc"):aggregate(spec))
    add("page", by():order("stars", "desc"):offset(1):limit(1):aggregate(spec))
    add("past", by():offset(5):aggregate(spec))
    add("key", by():order("author", "desc"):limit(2):aggregate(spec))
    return out
end

local bad = {
    spec = function(c) c.Post:query():aggregate(5) end,
    entry = function(c) c.Post:query():aggregate { n = "count" } end,
    option = function(c) c.Post:query():aggregate { n = { fn = "count", as = 1 } } end,
    fn = function(c) c.Post:query():aggregate { n = { fn = "median", field = "stars" } } end,
    avgkind = function(c) c.Post:query():aggregate { n = { fn = "avg", field = "title" } } end,
    avgvalue = function(c)
        c.Post:query():aggregate { n = { fn = "avg", value = function(p) return p.title end } }
    end,
    distinctmax = function(c)
        c.Post:query():aggregate { n = { fn = "max", field = "stars", distinct = true } }
    end,
    distinctflag = function(c)
        c.Post:query():aggregate { n = { fn = "count", field = "stars", distinct = 1 } }
    end,
    distinctrows = function(c) c.Post:query():aggregate { n = { fn = "count", distinct = true } } end,
    having = function(c) c.Post:query():groupBy("kind"):having(5) end,
    havingparams = function(c) c.Post:query():groupBy("kind"):having(function() end, {}) end,
    havingname = function(c) c.Post:query():groupBy("kind"):having("stars > 1"):aggregate {} end,
    ordername = function(c) c.Post:query():groupBy("kind"):order("n"):aggregate {} end,
    orderdir = function(c) c.Post:query():groupBy("kind"):order("kind", "up") end,
    grouplimit = function(c) c.Post:query():groupBy("kind"):limit(-1) end,
    nofield = function(c) c.Post:query():aggregate { n = { fn = "sum" } } end,
    field = function(c) c.Post:query():sum("missing") end,
    sumkind = function(c) c.Post:query():sum("title") end,
    sumtime = function(c) c.Post:query():sum("at") end,
    jsonmax = function(c) c.Post:query():max("meta") end,
    groupnone = function(c) c.Post:query():groupBy() end,
    groupname = function(c) c.Post:query():groupBy("nothing") end,
    groupjson = function(c) c.Post:query():groupBy("meta") end,
    groupmany = function(c) c.User:query():groupBy("posts") end,
    both = function(c)
        c.Post:query():aggregate { n = { fn = "sum", field = "stars", value = function() return 1 end } }
    end,
    valuefn = function(c) c.Post:query():aggregate { n = { fn = "sum", value = 1 } } end,
    sumvalue = function(c)
        c.Post:query():aggregate { n = { fn = "sum", value = function(p) return p.title end } }
    end,
    novalueorder = function(c)
        c.Post:query():aggregate { n = { fn = "max", value = function(p) return {} end } }
    end,
    mixed = function(c)
        c.Post:query():aggregate { n = { fn = "min", value = function(p)
            if p.stars > 2 then return p.stars end
            return p.title
        end } }
    end,
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


def test_aggregate_values(run):
    assert run("values") == [
        # a and c are news: 5+10 + 1 + 3+10 + 2
        "weighted=31 long=0 lowscore=-2.25 tag=note/d",
        "author=nil half=1",
        "author=1 half=3",
        "author=2 half=1.5",
        "0 nil",
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


def test_avg_distinct_having_and_group_order(run):
    a1 = "author=1 n=2 stars=6 score=1.5"
    a2 = "author=2 n=1 stars=3 score=2.25"
    none = "author=nil n=1 stars=2 score=nil"
    assert run("more") == [
        "stars=2.75 score=1.875 double=5.5 kinds=2 scores=2 ones=3 len=4 tables=2",
        "nil",
        "n > 1: " + a1,
        "stars >= s: " + a1 + ", " + a2,
        "fn: " + a1 + ", " + a2,
        "two: " + a2,
        "score > 1: " + a1 + ", " + a2,
        "stars desc: " + a1 + ", " + a2 + ", " + none,
        # ties on n keep the order of the next sort key
        "n desc, stars: " + a1 + ", " + none + ", " + a2,
        # a missing value sorts first, so last in descending order
        "score desc: " + a2 + ", " + a1 + ", " + none,
        "page: " + a2,
        "past: ",
        "key: " + a2 + ", " + a1,
    ]


ERRORS = {
    "spec": "LENT table Post query aggregate takes a table of name = { fn = ..., field = ... }",
    "entry": "LENT table Post query aggregate takes a table of name = { fn = ..., field = ... }",
    "option": "LENT table Post query aggregate n has no option as",
    "fn": "LENT table Post query aggregate n has no function median; use count, sum, avg, min"
          " or max",
    "avgkind": "LENT table Post field title is string, so avg needs int, float or decimal",
    "avgvalue": "LENT table Post query aggregate n value answered a, so avg needs a number",
    "distinctmax": "LENT table Post query aggregate n is max, which takes no distinct; use it"
                   " with count, sum or avg",
    "distinctflag": "LENT table Post query aggregate n distinct must be true or false, got 1",
    "distinctrows": "LENT table Post query aggregate n counts distinct values, so it needs a"
                    " field or value",
    "having": "LENT table Post query groupBy having takes a function or an expression string,"
              " got 5",
    "havingparams": "LENT table Post query groupBy having takes parameters with an expression"
                    " string only",
    "havingname": 'LENT table Post query groupBy having "stars > 1" at column 1: has no field or'
                  " parameter stars",
    "ordername": "LENT table Post query groupBy order has no group key or aggregate n",
    "orderdir": "LENT table Post query groupBy order direction must be asc or desc, got up",
    "grouplimit": "LENT table Post query groupBy limit takes a whole number, got -1",
    "nofield": "LENT table Post query aggregate n needs a field or value for sum",
    "field": "LENT table Post has no field missing",
    "sumkind": "LENT table Post field title is string, so sum needs int, float or decimal",
    "sumtime": "LENT table Post field at is time, so sum needs int, float or decimal",
    "jsonmax": "LENT table Post field meta is json, which has no order",
    "groupnone": "LENT table Post query groupBy takes at least one field or edge",
    "groupname": "LENT table Post has no field or edge nothing",
    "groupjson": "LENT table Post field meta is json, so groupBy cannot use it",
    "groupmany": "LENT table User edge posts can link a row to many rows, so groupBy cannot use it",
    "both": "LENT table Post query aggregate n has both field and value; give one",
    "valuefn": "LENT table Post query aggregate n value must be a function, got 1",
    "sumvalue": "LENT table Post query aggregate n value answered a, so sum needs a number",
    "novalueorder": "LENT table Post query aggregate n value answered a table, which has no order",
    "mixed": "LENT table Post query aggregate n value answered a string after a number",
    "clash": "LENT table Post query aggregate kind has the name of a groupBy key",
}


def test_aggregate_errors(run):
    for which, message in ERRORS.items():
        with pytest.raises(redis.ResponseError) as err:
            run("bad", which)
        assert message in str(err.value), which
