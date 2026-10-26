import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Users like posts with a weight and an optional note, and follow users
# without fields. Links queries read the links themselves, and whereEdge
# after follow filters the links of the last edge.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

local app = lent.graph {
    lent.schema "User" {
        id = "int",
        fields = { lent.field.string "name" },
        edges = {
            lent.edge.to "likes" "Post":fields {
                lent.field.int "weight":default(1),
                lent.field.string "note":optional(),
            },
            lent.edge.to "follows" "User",
            lent.edge.through "friendLikes" "Post":via "follows.likes",
        },
    },
    lent.schema "Post" {
        id = "int",
        fields = { lent.field.string "title" },
        edges = { lent.edge.from "likers" "User":ref "likes" },
    },
}

local function show(r)
    local keys = {}
    for k in r do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in keys do parts[#parts + 1] = k .. "=" .. tostring(r[k]) end
    return table.concat(parts, " ")
end

local function shows(list)
    local out = {}
    for _, r in list do out[#out + 1] = show(r) end
    return table.concat(out, "; ")
end

local function titles(list)
    local out = {}
    for _, p in list do out[#out + 1] = p.title end
    return table.concat(out, ",")
end

local function err(fn)
    local ok, e = pcall(fn)
    return ok and "no error" or string.match(tostring(e), "LENT.*$")
end

local steps = {}

function steps.seed(c)
    local ann = c.User:create { name = "ann" }
    local bob = c.User:create { name = "bob" }
    local cy = c.User:create { name = "cy" }
    local a = c.Post:create { title = "a" }
    local b = c.Post:create { title = "b" }
    local d = c.Post:create { title = "d" }
    c.User:link("likes", ann.id, a.id, { weight = 3, note = "good" })
    c.User:link("likes", ann.id, b.id)
    c.User:link("likes", bob.id, a.id, { weight = 2 })
    c.User:link("likes", bob.id, d.id, { weight = 5 })
    c.User:link("likes", cy.id, b.id, { weight = 4 })
    c.User:link("follows", cy.id, ann.id)
    c.User:link("follows", cy.id, bob.id)
    c.User:link("follows", bob.id, ann.id)
    return "ok"
end

function steps.links(c)
    local function user(name) return c.User:query():where("name", "=", name) end
    local all = c.User:query():links("likes")
    return {
        shows(user("ann"):links("likes"):all()),
        shows(all:where("weight", ">=", 3):order("weight", "desc"):all()),
        shows(c.User:query():links("likes"):order("weight"):offset(1):limit(2):all()),
        -- without an order, links come in from then to order
        shows(c.User:query():links("likes"):limit(3):all()),
        tostring(c.User:query():links("likes"):where("note", "=", nil):count()),
        tostring(c.User:query():links("likes"):sum("weight")),
        shows(c.User:query():links("likes"):groupBy("to"):aggregate {
            likers = { fn = "count" }, weight = { fn = "sum", field = "weight" },
            top = { fn = "max", value = function(l) return l.weight * 10 end },
        }),
        -- from the edge.from, `from` is the post and `to` the user
        shows(c.Post:query():where("title", "=", "a"):links("likers"):all()),
        -- an edge without fields gives each link's ends
        shows(c.User:query():links("follows"):groupBy("to"):aggregate { n = { fn = "count" } }),
        shows(c.User:query():links("likes"):where(function(l) return l.from == l.to end):all()),
        c.User:query():where("name", "=", "ann"):links("likes"):explain(),
    }
end

function steps.follow(c)
    local function user(name) return c.User:query():where("name", "=", name) end
    local everyone = c.User:query()
    return {
        titles(user("ann"):queryLikes():whereEdge("weight", ">=", 3):all()),
        -- a post stays when one of the links that reach it matches
        titles(everyone:queryLikes():whereEdge("weight", ">=", 3):all()),
        titles(c.User:query():queryLikes():whereEdge("weight", "=", 1):all()),
        titles(c.User:query():queryLikes():whereEdge(function(v) return v.note ~= nil end):all()),
        -- the filter applies to the last edge followed
        titles(user("cy"):follow("follows", "likes"):whereEdge("weight", ">", 2)
            :order("title", "desc"):all()),
        tostring(user("bob"):queryLikes():whereEdge("weight", "<", 5):count()),
        titles(c.Post:query():where("title", "=", "a"):queryLikers():queryLikes()
            :whereEdge("weight", "=", 5):all()),
    }
end

function steps.errors(c)
    local q = c.User:query()
    return {
        err(function() q:links("friendLikes") end),
        err(function() q:links("nope") end),
        err(function() q:links("likes"):where("id", "=", 1) end),
        err(function() q:links("likes"):where("from", "=", "x") end),
        err(function() q:links("likes"):groupBy("id") end),
        err(function() q:links("likes"):has("likes") end),
        err(function() q:links("likes"):ids() end),
        err(function() q:links("likes"):links("likes") end),
        err(function() q:links("likes"):queryLikes() end),
        err(function() q:links("likes"):delete() end),
        err(function() q:queryFollows():whereEdge("weight", "=", 1) end),
        err(function() q:queryFriendLikes():whereEdge("weight", "=", 1) end),
        err(function() q:whereEdge("weight", "=", 1) end),
    }
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
    client.execute_command("USE", "links_" + request.node.name)
    client.execute_command("SETF", "LINKS", APP)
    run = lambda *a: client.execute_command("CALLF", "LINKS", *a)
    assert run("migrate") == "done"
    assert run("seed") == "ok"
    return run


def test_links_queries(run):
    assert run("links") == [
        "from=1 note=good to=1 weight=3; from=1 to=2 weight=1",
        "from=2 to=3 weight=5; from=3 to=2 weight=4; from=1 note=good to=1 weight=3",
        "from=2 to=1 weight=2; from=1 note=good to=1 weight=3",
        "from=1 note=good to=1 weight=3; from=1 to=2 weight=1; from=2 to=1 weight=2",
        "4",
        "15",
        "likers=2 to=1 top=30 weight=5; likers=2 to=2 top=40 weight=5; likers=1 to=3 top=50 weight=5",
        "from=1 note=good to=1 weight=3; from=1 to=2 weight=2",
        "n=2 to=1; n=1 to=2",
        "from=1 note=good to=1 weight=3",
        "links user_likes from (id)",
    ]


def test_where_edge_after_follow(run):
    assert run("follow") == [
        "a",
        "a,b,d",
        "b",
        "a",
        "d,a",
        "1",
        "d",
    ]


def test_links_errors(run):
    got = run("errors")
    assert got[0].endswith("User edge friendLikes is an edge.through; links reads the links of"
                           " an edge.to or edge.from")
    assert got[1].endswith("User has no edge nope")
    assert got[2].endswith("User links likes has no field id")
    assert got[3].endswith("User links likes field from is int, got x")
    assert got[4].endswith("User links likes has no field or edge id")
    for i, what in [(5, "has"), (6, "ids"), (7, "links"), (8, "follow"), (9, "delete")]:
        assert got[i].endswith("User links likes query " + what + " reads table rows; a links"
                               " query takes where, order, limit, offset, groupBy and aggregates")
    assert got[10].endswith("User edge follows has no fields")
    assert got[11].endswith("User edge friendLikes has no fields")
    assert got[12].endswith("User query whereEdge works inside the function given to has or"
                            " with, and after follow")
