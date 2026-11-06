import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Authors write posts. PostsByAuthor groups every post by its author edge;
# LongByStatus groups the posts with 10 or more words by status and author.
# check() reads each stored view and the groupBy query over Post that it
# keeps, and answers both as text, so each step shows the view stays equal
# to the query after the writes that step made.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local f = lent.field

local STAGE = "STAGEVALUE"

local function specs(stage)
    if stage == "none" then return {} end
    local out = {
        PostsByAuthor = { from = "Post", groupBy = { "author" }, aggregates = {
            n = { fn = "count" },
            words = { fn = "sum", field = "words" },
            avgWords = { fn = "avg", field = "words" },
            first = { fn = "min", field = "title" },
            last = { fn = "max", field = "title" },
            price = { fn = "sum", field = "price" },
            score = { fn = "sum", field = "score", scale = 2 },
        } },
        LongByStatus = { from = "Post", where = "words >= 10", groupBy = { "status", "author" },
            aggregates = {
                n = { fn = "count" },
                top = { fn = "max", field = "words" },
                low = { fn = "min", field = "price" },
            } },
        -- no groupBy: one row for the whole table
        Totals = { from = "Post", aggregates = {
            n = { fn = "count" }, scored = { fn = "count", field = "score" },
            price = { fn = "avg", field = "price" },
        } },
    }
    if stage == "v2" then
        out.PostsByAuthor.aggregates.most = { fn = "max", field = "words" }
        out.LongByStatus = nil
    end
    return out
end

local function tables()
    return {
        lent.schema "Author" {
            id = "int", fields = { f.string "name" },
            edges = { lent.edge.to "posts" "Post" },
        },
        lent.schema "Post" {
            id = "int", FORMAT
            fields = {
                f.string "title", f.int "words", f.decimal "price":scale(2),
                f.float "score":optional(), f.enum "status":values("draft", "live"),
            },
            edges = { lent.edge.from "author" "Author":ref "posts":unique() },
        },
    }
end

local function graph(stage)
    local list = tables()
    for name, spec in specs(stage) do
        list[#list + 1] = lent.view(name)(spec)
    end
    return lent.graph(list)
end

local app = graph(STAGE)
local db = client.open(app)

local function fmt(x)
    if type(x) == "number" then return string.format("%.10g", x) end
    return tostring(x)
end

local function render(list, spec)
    local names = {}
    for n in spec.aggregates do names[#names + 1] = n end
    table.sort(names)
    local out = {}
    for _, r in list do
        local keys, aggs = {}, {}
        for _, k in spec.groupBy or {} do keys[#keys + 1] = fmt(r[k]) end
        for _, n in names do aggs[#aggs + 1] = n .. "=" .. fmt(r[n]) end
        out[#out + 1] = table.concat(keys, "/") .. ":" .. table.concat(aggs, ",")
    end
    table.sort(out)
    return table.concat(out, " ")
end

local function check(c)
    local out = {}
    local list = specs(STAGE)
    local names = {}
    for name in list do names[#names + 1] = name end
    table.sort(names)
    for _, name in names do
        local spec = list[name]
        local q = c.Post:query()
        if spec.where then q = q:where(spec.where) end
        local groupBy = spec.groupBy or {}
        local want = render(if #groupBy == 0 then { q:aggregate(spec.aggregates) }
            else q:groupBy(table.unpack(groupBy)):aggregate(spec.aggregates), spec)
        local got = render(c[name]:query():all(), spec)
        out[#out + 1] = name .. " " .. got
        if got ~= want then out[#out + 1] = name .. " query " .. want end
    end
    return out
end

local function post(c, title, words, price, score, status, author)
    return c.Post:create { title = title, words = words, price = price, score = score,
                           status = status, author = author }
end

local steps = {}

function steps.seed(c)
    for _, n in { "a1", "a2", "a3" } do c.Author:create { name = n } end
    post(c, "b", 12, 1.10, 0.1, "draft", 1)
    post(c, "a", 5, 2.25, 0.2, "live", 1)
    post(c, "d", 20, 3.00, 0.3, "live", 2)
    post(c, "c", 15, 0.05, 0.7, "live", nil)
    return check(c)
end

function steps.update(c)
    c.Post:update(2, { title = "z", words = 30 })
    c.Post:update(4, nil, { "score" })
    return check(c)
end

function steps.relink(c)
    c.Post:unlink("author", 1, 1)
    c.Author:link("posts", 3, 1)
    c.Post:link("author", 4, 2)
    return check(c)
end

function steps.delete(c)
    c.Post:delete(3)
    c.Post:delete(2)
    return check(c)
end

function steps.more(c)
    post(c, "e", 40, 9.99, 0.15, "live", 3)
    -- deleting an author unlinks its posts, which move to the nil group
    c.Author:delete(3)
    return check(c)
end

function steps.check(c)
    return check(c)
end

function steps.read(c)
    local ok, e = pcall(function() return c.PostsByAuthor:query():all() end)
    return ok and "read" or tostring(e)
end

function steps.mixed(c)
    -- rows before and after the fill's cursor
    c.Post:update(1, { words = 7 })
    c.Post:update(4, { words = 11 })
    post(c, "f", 3, 0.01, nil, "draft", 2)
    c.Post:delete(2)
    c.Post:link("author", 4, 3)
    return "ok"
end

function steps.errors(c)
    local function err(spec)
        local ok, e = pcall(function()
            local list = tables()
            list[#list + 1] = lent.view "V" (spec)
            return lent.graph(list)
        end)
        return ok and "no error" or tostring(e)
    end
    local count = { n = { fn = "count" } }
    return {
        err({ from = "Post", groupBy = { "nope" }, aggregates = count }),
        err({ from = "Author", groupBy = { "posts" }, aggregates = count }),
        err({ from = "Nope", aggregates = count }),
        err({ from = "Post", aggregates = { s = { fn = "sum", field = "title" } } }),
        err({ from = "Post", aggregates = { s = { fn = "sum", field = "words", scale = 2 } } }),
        err({ from = "Post", order = "n", aggregates = count }),
        err({ from = "Post", where = "nope > 1", aggregates = count }),
    }
end

function call(step, mode, arg)
    if step == "migrate" then
        local r = m.migrate(app, tonumber(arg) or 1000)
        return { r.done and "done" or "more", table.concat(r.steps or {}, ";") }
    end
    return db.tx(function(c) return steps[step](c) end, mode == "pessimistic")
end
"""

FORMATS = {"binary": "", "column": 'format = "column",'}
STAGES = ["none", "v1", "v2"]


@pytest.fixture(params=[(f, m) for f in FORMATS for m in ["optimistic", "pessimistic"]],
                ids=lambda p: "-".join(p))
def run(client, request):
    setup(client)
    fmt, mode = request.param
    client.execute_command("USE", re.sub(r"\W", "_", "stored_views_" + request.node.name))
    for stage in STAGES:
        source = APP.replace("FORMAT", FORMATS[fmt]).replace("STAGEVALUE", stage)
        client.execute_command("SETF", f"STOREDVIEWS{fmt.upper()}{stage.upper()}", source)

    def run(stage, step, *args):
        name = f"STOREDVIEWS{fmt.upper()}{stage.upper()}"
        return client.execute_command("CALLF", name, step, mode, *args)
    return run


def migrate(run, stage, page=1000):
    while True:
        done, steps = run(stage, "migrate", page)
        if done == "done":
            return steps


def same(lines):
    # check() adds a "query" line only when a view differs from its query
    assert not [line for line in lines if " query " in line], lines
    return lines


def test_writes_keep_views_current(run):
    migrate(run, "v1")
    assert same(run("v1", "seed")) == [
        "LongByStatus draft/1:low=1.1,n=1,top=12 live/2:low=3,n=1,top=20"
        " live/nil:low=0.05,n=1,top=15",
        "PostsByAuthor 1:avgWords=8.5,first=a,last=b,n=2,price=3.35,score=0.3,words=17"
        " 2:avgWords=20,first=d,last=d,n=1,price=3,score=0.3,words=20"
        " nil:avgWords=15,first=c,last=c,n=1,price=0.05,score=0.7,words=15",
        "Totals :n=4,price=1.6,scored=4",
    ]
    assert same(run("v1", "update"))[1] == (
        "PostsByAuthor 1:avgWords=21,first=b,last=z,n=2,price=3.35,score=0.3,words=42"
        " 2:avgWords=20,first=d,last=d,n=1,price=3,score=0.3,words=20"
        " nil:avgWords=15,first=c,last=c,n=1,price=0.05,score=0,words=15")
    assert same(run("v1", "relink"))[1] == (
        "PostsByAuthor 1:avgWords=30,first=z,last=z,n=1,price=2.25,score=0.2,words=30"
        " 2:avgWords=17.5,first=c,last=d,n=2,price=3.05,score=0.3,words=35"
        " 3:avgWords=12,first=b,last=b,n=1,price=1.1,score=0.1,words=12")
    # min and max move to the remaining values after deletes
    assert same(run("v1", "delete")) == [
        "LongByStatus draft/3:low=1.1,n=1,top=12 live/2:low=0.05,n=1,top=15",
        "PostsByAuthor 2:avgWords=15,first=c,last=c,n=1,price=0.05,score=0,words=15"
        " 3:avgWords=12,first=b,last=b,n=1,price=1.1,score=0.1,words=12",
        "Totals :n=2,price=0.575,scored=1",
    ]
    assert same(run("v1", "more")) == [
        "LongByStatus draft/nil:low=1.1,n=1,top=12 live/2:low=0.05,n=1,top=15"
        " live/nil:low=9.99,n=1,top=40",
        "PostsByAuthor 2:avgWords=15,first=c,last=c,n=1,price=0.05,score=0,words=15"
        " nil:avgWords=26,first=b,last=e,n=2,price=11.09,score=0.25,words=52",
        "Totals :n=3,price=3.713333333,scored=2",
    ]


def test_migrate_fills_views_from_stored_rows(run):
    migrate(run, "none")
    run("none", "seed")
    with pytest.raises(redis.ResponseError, match="view (PostsByAuthor|LongByStatus) is declared,"
                       " and this space's catalog lacks it; run MIGRATE"):
        run("v1", "check")
    assert run("v1", "migrate", 2) == [
        "more",
        "drop view LongByStatus;drop view PostsByAuthor;drop view Totals;"
        "fill view LongByStatus;fill view PostsByAuthor;fill view Totals",
    ]
    assert run("v1", "read") == "LENT view PostsByAuthor is filling; run MIGRATE until it completes"
    # writes during the fill reach the view, whether the fill has read the row yet or not
    assert run("v1", "mixed") == "ok"
    migrate(run, "v1", 2)
    lines = same(run("v1", "check"))
    assert lines[1] == (
        "PostsByAuthor 1:avgWords=7,first=b,last=b,n=1,price=1.1,score=0.1,words=7"
        " 2:avgWords=11.5,first=d,last=f,n=2,price=3.01,score=0.3,words=23"
        " 3:avgWords=11,first=c,last=c,n=1,price=0.05,score=0.7,words=11")
    assert run("v1", "migrate") == ["done", ""]


def test_changed_view_refills_and_removed_view_drops(run):
    migrate(run, "v1")
    run("v1", "seed")
    with pytest.raises(redis.ResponseError, match="view PostsByAuthor is declared with another"
                       " from, where, groupBy or aggregates than this space's catalog holds;"
                       " run MIGRATE"):
        run("v2", "check")
    # the drops of changed views come before those of removed ones
    assert migrate(run, "v2") == (
        "drop view PostsByAuthor;drop view LongByStatus;fill view PostsByAuthor")
    assert same(run("v2", "check")) == [
        "PostsByAuthor 1:avgWords=8.5,first=a,last=b,most=12,n=2,price=3.35,score=0.3,words=17"
        " 2:avgWords=20,first=d,last=d,most=20,n=1,price=3,score=0.3,words=20"
        " nil:avgWords=15,first=c,last=c,most=15,n=1,price=0.05,score=0.7,words=15",
        "Totals :n=4,price=1.6,scored=4",
    ]
    # the removed view's groups are gone, so declaring it again fills it
    # anew; Totals stays as it is
    assert migrate(run, "v1") == (
        "drop view LongByStatus;drop view PostsByAuthor;fill view LongByStatus;"
        "fill view PostsByAuthor")
    same(run("v1", "check"))


def test_view_declaration_errors(run):
    migrate(run, "none")
    assert run("none", "errors") == [
        "SCHEMA view V groupBy names nope, which table Post has no stored field or edge of",
        "SCHEMA view V groupBy posts links many rows; group by an edge with :unique()",
        "SCHEMA view V reads table Nope, which is not declared",
        "SCHEMA view V aggregate s is sum of a string field; use an int, float or decimal field",
        "SCHEMA view V aggregate s sets a scale, which takes a sum or avg of a float field",
        "SCHEMA view V has no option order; a stored view takes from, where, groupBy and"
        " aggregates",
        """SCHEMA view V where "nope > 1" at column 1: has no field or parameter nope""",
    ]
