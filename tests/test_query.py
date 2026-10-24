import pytest

from .conftest import install

redis = pytest.importorskip("redis")

# Users and posts in the default space; call(step, mode) answers a list of
# "label value" strings, where value is the ids a query answers and the
# plan it used.
APP = """
local ent = require("ent.SCHEMA")
local m = require("ent.MIGRATE")
local client = require("ent.CLIENT")

local function ids(q)
    return table.concat(q:ids(), ",") .. " " .. q:explain()
end

local steps = {}

function steps.setup(c)
    for _, u in { { "a@b", "ann", 41 }, { "c@d", "bob", 30 }, { "e@f", "cy" },
                  { "g@h", "dee", 30 }, { "i@j", "eve", 52 }, { "k@l", "ann", 25 } } do
        c.User:create { email = u[1], name = u[2], age = u[3] }
    end
    c.Post:create { title = "a", stars = 5, author = 1 }
    c.Post:create { title = "b", stars = 3, author = c.User:get(1) }
    c.Post:create { title = "c", stars = 5, author = 2 }
    c.User:link("friends", 1, 2)
    c.User:link("friends", 1, 5)
    return { "ok" }
end

function steps.query(c)
    local U = c.User
    return {
        ids(U:query():where("name", "=", "ann")),
        ids(U:query():where("name", "=", "ann"):where("age", ">", 30)),
        ids(U:query():where("age", ">=", 30):order("age", "desc"):limit(2)),
        ids(U:query():order("age"):limit(2)),
        ids(U:query():where("age", "<", 31)),
        ids(U:query():where("age", "=", nil)),
        ids(U:query():where("email", "=", "c@d")),
        ids(U:query():where("id", ">", 4)),
        ids(U:query():where(function(r) return #r.name > 2 end):order("id", "desc")),
        ids(U:query():order("name"):offset(1):limit(2)),
        ids(U:query():where("name", "=", "ann"):using("id")),
        tostring(U:query():where("name", "~=", "ann"):count()),
        U:query():order("age", "desc"):first().name,
        tostring(U:query():where("name", "=", "zed"):first()),
    }
end

function steps.edges(c)
    return {
        ids(c.User:query():where("name", "=", "ann"):queryPosts():order("stars")),
        ids(c.Post:query():where("stars", "=", 5):queryAuthor()),
        ids(c.User:query():where("id", "=", 1):follow("friends")),
        tostring(c.User:unlink("friends", 1, 5)) .. " " .. tostring(c.User:unlink("friends", 1, 5)),
    }
end

function steps.delete(c)
    c.User:delete(2)
    return {
        tostring(c.Post:query():where("id", "=", 3):queryAuthor():count()),
        ids(c.User:query():where("id", "=", 1):queryFriends()),
        tostring(c.Post:get(3).title),
    }
end

-- desc reads: the ids, the plan, and how many rows the query read
function steps.desc(c)
    local n = 0
    local function read(q)
        n = 0
        local got = ids(q:where(function() n += 1; return true end))
        return got .. " " .. n
    end
    local U = c.User
    local lay, kc = require("ent.LAYOUT"), require("ent.KEYCODEC")
    local back = {}
    local lo = lay.row(U.t)
    lay.scan_back(lo, kc.after(lo), function(k)
        back[#back + 1] = tostring(kc.decode(k, #k - 16))
        return #back == 5
    end, 2)
    return {
        read(U:query():order("age", "desc"):limit(2)),
        read(U:query():where("age", ">=", 30):order("age", "desc"):limit(3)),
        read(U:query():order("id", "desc"):offset(1):limit(2)),
        read(U:query():where("name", "=", "ann"):order("age", "desc")),
        read(U:query():order("name", "desc"):limit(2)),
        read(U:query():where("id", "=", 1):queryPosts():order("id", "desc"):limit(1)),
        table.concat(back, ","),
    }
end

local errors = {
    field = function(c) c.User:query():where("nick", "=", 1) end,
    op = function(c) c.User:query():where("age", "like", 1) end,
    kind = function(c) c.User:query():where("age", ">", "x") end,
    bool = function(c) c.Post:query():where("draft", "<", true) end,
    unique = function(c) c.User:query():using("by_email"):all() end,
    edge = function(c) c.User:query():follow("likes") end,
    one = function(c) c.Post:create { title = "d", stars = 1, author = { 1, 4 } } end,
    taken = function(c) c.Post:link("author", 1, 4) end,
    missing = function(c) c.Post:create { title = "d", stars = 1, author = 99 } end,
}

function call(step, mode)
    if step == "migrate" then
        local app = ent.graph {
            ent.schema "User" {
                fields = { ent.field.string "email":unique(), ent.field.string "name",
                           ent.field.int "age":optional() },
                indexes = { ent.index("name", "age"), ent.index("age") },
                edges = { ent.edge.to "posts" "Post", ent.edge.to "friends" "User" },
            },
            ent.schema "Post" {
                fields = { ent.field.string "title", ent.field.int "stars",
                           ent.field.bool "draft":default(false) },
                indexes = { ent.index("stars") },
                edges = { ent.edge.from "author" "User":ref "posts":unique() },
            },
        }
        return m.migrate(app).version
    end
    return client.tx(function(c)
        if errors[step] then
            errors[step](c)
            return "no error"
        end
        return steps[step](c)
    end, mode == "pessimistic")
end
"""


def setup(client, space):
    for name, path in [("KEYCODEC", "ent/keycodec.luau"), ("ROWCODEC", "ent/rowcodec.luau"),
                       ("SCHEMA", "ent/schema.luau"), ("LAYOUT", "ent/layout.luau"),
                       ("MIGRATE", "ent/migrate.luau"), ("CLIENT", "ent/client.luau")]:
        install(client, "ent", name, path)
    client.execute_command("USE", space)
    client.execute_command("SETF", "QUERYAPP", APP)
    assert client.execute_command("CALLF", "QUERYAPP", "migrate") == 1
    assert client.execute_command("CALLF", "QUERYAPP", "setup") == ["ok"]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_queries_pick_an_index(client, mode):
    setup(client, "query_" + mode)
    assert client.execute_command("CALLF", "QUERYAPP", "query", mode) == [
        # rows sharing a name come in age order, because the index holds both
        "6,1 by_name_age = name",
        "1 by_name_age = name range age",
        # the index order serves the sort, so the read stops after two rows
        "5,1 by_age range age",
        "3,6 by_age",
        # a row without an age does not match <, though the index holds it
        "6,2,4 by_age range age",
        # = nil reads the whole table
        "3 id",
        "2 by_email = email",
        "5,6 id range id",
        # id order is the table's own, so the read needs no sort
        "6,5,4,2,1 id",
        "6,2 id then sort",
        "1,6 id",
        "4",
        "eve",
        "nil",
    ]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_desc_reads_from_the_end(client, mode):
    setup(client, "query_desc_" + mode)
    assert client.execute_command("CALLF", "QUERYAPP", "desc", mode) == [
        # the ordered reads stop at the limit
        "5,1 by_age 2",
        "5,1,4 by_age range age 3",
        "5,4 id 3",
        "1,6 by_name_age = name 2",
        # a sort has to read every row first
        "5,4 id then sort 6",
        "2 edge user_posts 1",
        # pages of two from the end, stopped after five keys
        "6,5,4,3,2",
    ]


def test_edges_link_follow_and_delete(client):
    setup(client, "query_edges")
    run = lambda step: client.execute_command("CALLF", "QUERYAPP", step)
    assert run("edges") == [
        "2,1 edge user_posts then sort",
        "1,2 edge user_posts",
        "2,5 edge user_friends",
        "true false",
    ]
    # deleting bob removes his posts' author edge and ann's friend edge to him
    assert run("delete") == ["0", " edge user_friends", "c"]


@pytest.mark.parametrize("step, error", [
    ("field", "ENT table User has no field nick"),
    ("op", "ENT table User query has no operator like"),
    ("kind", "ENT table User field age is int, got x"),
    ("bool", "ENT table Post field draft is bool, which has no order"),
    ("unique", "ENT table User index by_email is unique, so a query using it needs = on each"),
    ("edge", "ENT table User has no edge likes"),
    ("one", "ENT table Post edge author links one row, got 2"),
    ("taken", "ENT edge user_posts allows one User per Post, and Post row 1 has one"),
    ("missing", "ENT table User has no row 99"),
])
def test_query_and_edge_errors(client, step, error):
    setup(client, "query_errors_" + step)
    with pytest.raises(redis.ResponseError, match=error):
        client.execute_command("CALLF", "QUERYAPP", step)
