import pytest

from .conftest import install

redis = pytest.importorskip("redis")

# Users and posts in the default space; call(step, mode) answers a list of
# "label value" strings, where value is the ids a query answers and the
# plan it used.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

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

-- has() filters and with() eager loads
function steps.joins(c)
    local U, P = c.User, c.Post
    local function titles(list)
        local out = {}
        for i, p in list do
            out[i] = p.title
        end
        return table.concat(out, ",")
    end
    local anns = {}
    for i, u in U:query():where("name", "=", "ann"):withPosts(function(p)
        return p:order("stars", "desc")
    end):all() do
        anns[i] = u.id .. ":" .. titles(u.posts)
    end
    local authors = {}
    for i, p in P:query():withAuthor():all() do
        authors[i] = p.title .. "=" .. p.author.name
    end
    local top = U:query():where("id", "=", 1):withFriends(function(f)
        f:order("id", "desc"):limit(1)
    end):first()
    return {
        ids(U:query():hasPosts()),
        ids(U:query():hasPostsWith(function(p) p:where("stars", "=", 5) end)),
        ids(U:query():hasPostsWith(function(p) p:where("title", "=", "b") end)),
        ids(U:query():where("name", "=", "ann"):hasPostsWith(function(p)
            p:where("stars", "<", 4)
        end)),
        ids(P:query():hasAuthorWith(function(u) u:where("age", ">", 35) end):order("stars")),
        ids(U:query():hasFriendsWith(function(f) f:hasPosts() end)),
        ids(U:query():hasFriendsWith(function(f) f:hasPostsWith(function(p)
            p:where("stars", ">", 4)
        end) end)),
        tostring(U:query():hasPosts():count()),
        table.concat(anns, " "),
        table.concat(authors, " "),
        top.friends[1].name .. " " .. #top.friends,
    }
end

-- hasNo() keeps the rows without a matching link
function steps.anti(c)
    local U, P = c.User, c.Post
    c.User:link("noFly", 3, 4)
    return {
        ids(U:query():hasNoPosts()),
        ids(U:query():hasNoPostsWith(function(p) p:where("stars", "=", 5) end)),
        ids(U:query():hasNoPostsWith(function(p) p:where("stars", "<", 4) end)),
        ids(U:query():where("name", "=", "ann"):hasNoPosts()),
        ids(P:query():hasNoAuthorWith(function(u) u:where("age", ">", 35) end)),
        ids(U:query():hasPosts():hasNoFriends()),
        ids(U:query():hasNoFriends():hasPostsWith(function(p) p:where("stars", "=", 5) end)),
        ids(U:query():hasNoFriendsWith(function(f) f:hasPosts() end)),
        ids(U:query():hasFriendsWith(function(f) f:hasNoPosts() end)),
        ids(U:query():hasNo("posts")),
        tostring(U:query():hasNoPosts():count()),
        ids(U:query():hasNoFly()),
        ids(U:query():hasNoNoFly()),
    }
end

-- cursor pages: each walk answers its plan, then each page's ids
function steps.pages(c)
    local U = c.User
    local out = {}
    local function walk(make, n)
        local pages, cur, plan = {}, nil, nil
        repeat
            local q = make():limit(n)
            if cur then
                q:after(cur)
                plan = q:explain()
            end
            local rs = q:all()
            local ids = {}
            for i, r in rs do
                ids[i] = r.id
            end
            pages[#pages + 1] = table.concat(ids, ",")
            cur = rs[1] and q:cursor(rs[#rs])
        until #rs < n
        out[#out + 1] = plan .. ": " .. table.concat(pages, " ")
    end
    walk(function() return U:query():order("age") end, 2)
    walk(function() return U:query():order("age", "desc") end, 2)
    walk(function() return U:query() end, 2)
    walk(function() return U:query():order("id", "desc") end, 4)
    walk(function() return U:query():where("name", "=", "ann"):order("age", "desc") end, 1)
    walk(function() return U:query():order("name") end, 4)
    walk(function() return U:query():where("id", "=", 1):queryFriends() end, 1)
    walk(function() return U:query():where("email", "=", "c@d") end, 1)
    return out
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
    local lay, kc = require("lent.LAYOUT"), require("lent.KEYCODEC")
    local back = {}
    local lo = lay.row(U.t)
    lay.scan_back(lo, kc.after(lo), function(k)
        back[#back + 1] = tostring(lay.row_pk(U.t, k))
        return #back == 5
    end, 2)
    -- the values variants give each key with its stored value
    local function values(scan, first, stop)
        local got = {}
        scan(lo, kc.after(lo), function(k, v)
            local same = v == barch.store.get(k) and "" or "?"
            got[#got + 1] = tostring(lay.row_pk(U.t, k)) .. same
            return #got == stop
        end, first)
        return table.concat(got, ",")
    end
    return {
        read(U:query():order("age", "desc"):limit(2)),
        read(U:query():where("age", ">=", 30):order("age", "desc"):limit(3)),
        read(U:query():order("id", "desc"):offset(1):limit(2)),
        read(U:query():where("name", "=", "ann"):order("age", "desc")),
        read(U:query():order("name", "desc"):limit(2)),
        read(U:query():where("id", "=", 1):queryPosts():order("id", "desc"):limit(1)),
        table.concat(back, ","),
        values(lay.scan_values, 1),
        values(lay.scan_values, 2, 3),
        values(lay.scan_back_values, 2),
        values(lay.scan_back_values, nil, 2),
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
    hasorder = function(c) c.User:query():hasPostsWith(function(p) p:order("stars") end) end,
    hasfn = function(c) c.User:query():hasPostsWith() end,
    hasedge = function(c) c.User:query():hasLikes() end,
    hasnofn = function(c) c.User:query():hasNoPostsWith() end,
    hasnoorder = function(c)
        c.User:query():hasNoPostsWith(function(p) p:limit(1) end)
    end,
    hasnoedge = function(c) c.User:query():hasNoLikes() end,
    withfn = function(c) c.User:query():withPosts(3) end,
    cursor = function(c) c.User:query():after("zz"):all() end,
    cursororder = function(c)
        local q = c.User:query():order("age")
        local cur = q:cursor(q:first())
        c.User:query():order("name"):after(cur):all()
    end,
    cursorrow = function(c) c.User:query():cursor(3) end,
    hasafter = function(c)
        local q = c.Post:query()
        local cur = q:cursor(q:first())
        c.User:query():hasPostsWith(function(p) p:after(cur) end)
    end,
}

function call(step, mode)
    if step == "migrate" then
        local app = lent.graph {
            lent.schema "User" {
                id = "int",
                fields = { lent.field.string "email":unique(), lent.field.string "name",
                           lent.field.int "age":optional() },
                indexes = { lent.index("name", "age"), lent.index("age") },
                edges = { lent.edge.to "posts" "Post", lent.edge.to "friends" "User",
                          lent.edge.to "noFly" "User" },
            },
            lent.schema "Post" {
                id = "int",
                fields = { lent.field.string "title", lent.field.int "stars",
                           lent.field.bool "draft":default(false) },
                indexes = { lent.index("stars") },
                edges = { lent.edge.from "author" "User":ref "posts":unique() },
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
    for name, path in [("VALUES", "lent/values.luau"),
                       ("KEYCODEC", "lent/keycodec.luau"), ("ROWCODEC", "lent/rowcodec.luau"),
                       ("SCHEMA", "lent/schema.luau"), ("LAYOUT", "lent/layout.luau"),
                       ("MIGRATE", "lent/migrate.luau"), ("EXPR", "lent/expr.luau"),
                       ("CLIENT", "lent/client.luau")]:
        install(client, "lent", name, path)
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
        # pages of one, two and four keys, then stops
        "1,2,3,4,5,6",
        "1,2,3",
        "6,5,4,3,2,1",
        "6,5",
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


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_has_filters_and_with_loads(client, mode):
    setup(client, "query_joins_" + mode)
    assert client.execute_command("CALLF", "QUERYAPP", "joins", mode) == [
        # without a filter, has checks each row's edges
        "1,2 id, has posts",
        # a filter that reads part of Post supplies the users through the
        # reverse edges
        "1,2 has posts from (by_stars = stars)",
        "1 id, has posts",
        "1 by_name_age = name, has posts from (by_stars range stars)",
        "2,1 has author from (by_age range age) then sort",
        "1 id, has friends",
        # nested filters drive too: posts with 5 stars, their authors, then
        # the users who befriend them
        "1 has friends from (has posts from (by_stars range stars))",
        "2",
        # ann 6 has no posts; ann 1's come by stars, highest first
        "6: 1:a,b",
        "a=ann b=ann c=bob",
        "eve 1",
    ]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_has_no_keeps_rows_without_links(client, mode):
    setup(client, "query_anti_" + mode)
    assert client.execute_command("CALLF", "QUERYAPP", "anti", mode) == [
        "3,4,5,6 id, has no posts",
        # a filter that reads part of Post finds the users to leave out
        "3,4,5,6 id, has no posts from (by_stars = stars)",
        "2,3,4,5,6 id, has no posts from (by_stars range stars)",
        "6 by_name_age = name, has no posts",
        "3 id, has no author from (by_age range age)",
        "2 id, has posts, has no friends",
        # only a has check supplies rows; hasNo filters them
        "2 has posts from (by_stars = stars), has no friends",
        "2,3,4,5,6 id, has no friends",
        "1 id, has friends",
        "3,4,5,6 id, has no posts",
        "4",
        # an edge named noFly keeps hasNoFly as its has method
        "3 id, has noFly",
        "1,2,4,5,6 id, has no noFly",
    ]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_cursor_pages(client, mode):
    setup(client, "query_pages_" + mode)
    assert client.execute_command("CALLF", "QUERYAPP", "pages", mode) == [
        # an index that serves the order starts each page at the cursor
        "by_age from cursor: 3,6 2,4 1,5 ",
        "by_age from cursor: 5,1 4,2 6,3 ",
        "id from cursor: 1,2 3,4 5,6 ",
        "id from cursor: 6,5,4,3 2,1",
        "by_name_age = name from cursor: 1 6 ",
        # a sorted read checks the cursor on each row
        "id then sort, after cursor: 1,6,2,3 4,5",
        "edge user_friends, after cursor: 2 5 ",
        "by_email = email, after cursor: 2 ",
    ]


@pytest.mark.parametrize("step, error", [
    ("field", "LENT table User has no field nick"),
    ("op", "LENT table User query has no operator like"),
    ("kind", "LENT table User field age is int, got x"),
    ("bool", "LENT table Post field draft is bool, which has no order"),
    ("unique", "LENT table User index by_email is unique, so a query using it needs = on each"),
    ("edge", "LENT table User has no edge likes"),
    ("one", "LENT table Post edge author links one row, got 2"),
    ("taken", "LENT edge user_posts allows one User per Post, and Post row 1 has one"),
    ("missing", "LENT table User has no row 99"),
    ("hasorder", "LENT table User query has posts filters rows with where, has and using"),
    ("hasfn", "LENT table User query hasPostsWith takes a function, got nil"),
    ("hasedge", "LENT table User has no edge likes"),
    ("hasnofn", "LENT table User query hasNoPostsWith takes a function, got nil"),
    ("hasnoorder", "LENT table User query hasNo posts filters rows with where, has and using"),
    ("hasnoedge", "LENT table User has no edge likes"),
    ("withfn", "LENT table User query with takes a function, got 3"),
    ("cursor", "LENT table User query after takes a cursor from cursor\\(\\), got zz"),
    ("cursororder", "LENT table User query cursor follows order age asc, and the query orders by name asc"),
    ("cursorrow", "LENT table User query cursor takes a row, got 3"),
    ("hasafter", "LENT table User query has posts filters rows with where, has and using; order, limit, offset, after"),
])
def test_query_and_edge_errors(client, step, error):
    setup(client, "query_errors_" + step)
    with pytest.raises(redis.ResponseError, match=error):
        client.execute_command("CALLF", "QUERYAPP", step)
