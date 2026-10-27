import re

import pytest

from .conftest import install

redis = pytest.importorskip("redis")

# Users own posts, and posts have comments. Post's policy lets an admin do
# anything, shows a signed-out viewer the public posts and a member the
# public posts and their own, and lets members write only their own posts.
# Comment's policy refuses signed-out viewers. Odd's rule answers a value
# rules may not answer.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

local app = lent.graph {
    lent.schema "User" {
        id = "int",
        fields = { lent.field.string "name":unique() },
        edges = { lent.edge.to "posts" "Post" },
    },
    lent.schema "Post" {
        id = "int",
        fields = { lent.field.string "title":unique(), lent.field.bool "public":default(false),
                   lent.field.int "owner" },
        edges = { lent.edge.from "author" "User":ref "posts":unique(),
                  lent.edge.to "comments" "Comment" },
        hooks = { lent.hook.create(function(c, r) c.Log:create { msg = "create " .. r.title } end) },
        policy = {
            query = {
                function(c, v, q)
                    if v and v.admin then return lent.allow end
                end,
                function(c, v, q)
                    if v == nil then
                        q:where("public", "=", true)
                    else
                        q:where(function(r) return r.public or r.owner == v.id end)
                    end
                end,
            },
            mutation = {
                function(c, v, m)
                    if v == nil then return lent.deny("sign in") end
                end,
                function(c, v, m)
                    if v.admin then return lent.allow end
                end,
                function(c, v, m)
                    if m.op == "create" then
                        return if m.row.owner == v.id then lent.allow
                            else lent.deny("posts are created by their owner")
                    end
                end,
                function(c, v, m)
                    if m.op == "update" or m.op == "delete" then
                        -- c reads every post, the ones the viewer cannot read too
                        return if c.Post:get(m.id).owner == v.id then lent.allow
                            else lent.deny("not the owner")
                    end
                end,
                function(c, v, m)
                    if m.op == "unlink" then return lent.deny end
                    if m.edge == "author" and m.other ~= v.id then
                        return lent.deny("authors link themselves")
                    end
                end,
            },
        },
    },
    lent.schema "Comment" {
        id = "int",
        fields = { lent.field.string "body" },
        edges = { lent.edge.from "post" "Post":ref "comments":unique() },
        policy = { query = { function(c, v, q)
            if v == nil then return lent.deny("sign in to read comments") end
        end } },
    },
    lent.schema "Log" { id = "int", fields = { lent.field.string "msg" } },
    lent.schema "Odd" {
        id = "int",
        fields = { lent.field.int "n" },
        policy = { query = { function() return "yes" end } },
    },
}
local db = client.open(app)

local VIEWERS = { ann = { id = 1 }, bob = { id = 2 }, admin = { admin = true } }

local function list(rows, field)
    local out = {}
    for _, r in rows do out[#out + 1] = tostring(r[field or "title"]) end
    return table.concat(out, ",")
end

-- what fn answers, or its error
local function try(fn)
    local ok, got = pcall(fn)
    return tostring(got)
end

local steps = {}

function steps.seed(c)
    c.User:create { name = "ann" }
    c.User:create { name = "bob" }
    c.Post:create { title = "Ann public", public = true, owner = 1, author = 1 }
    c.Post:create { title = "Ann draft", owner = 1, author = 1 }
    c.Post:create { title = "Bob draft", owner = 2, author = 2 }
    c.Comment:create { body = "nice", post = 1 }
    c.Comment:create { body = "ann note", post = 2 }
    c.Comment:create { body = "bob note", post = 3 }
    c.Comment:create { body = "loose" }
    return "ok"
end

function steps.reads(c)
    local function ann() return c.User:query():where("name", "=", "ann") end
    local with = {}
    for _, u in c.User:query():order("id"):withPosts(function(q) q:order("id") end):all() do
        with[#with + 1] = u.name .. "=" .. list(u.posts)
    end
    return {
        list(c.Post:query():order("id"):all()),
        tostring(c.Post:query():count()),
        try(function() return c.Post:get(2) and c.Post:get(2).title end),
        try(function() local r = c.Post:by("title", "Bob draft") return r and r.title end),
        list(ann():queryPosts():order("id"):all()),
        table.concat(with, " "),
        -- has reads the links without Post's rules
        tostring(c.User:query():hasPostsWith(function(q) q:where("public", "=", false) end):count()),
        c.Post:edge("author", 3, 2) and "linked" or "none",
        -- the second hop starts from the posts the viewer can read
        try(function() return ann():follow("posts.comments"):count() end),
        try(function() return c.Comment:query():count() end),
    }
end

function steps.ann(c)
    return {
        try(function() return c.Post:create { title = "Ann new", owner = 1 }.id end),
        try(function() return c.Post:create { title = "For bob", owner = 2 }.id end),
        try(function() return c.Post:update(3, { title = "Mine now" }).title end),
        try(function() return c.Post:update(2, { public = true }).public end),
        -- every rule answers nil, so the link goes ahead
        try(function() return c.Post:link("comments", 2, 4) ~= nil end),
        try(function() return c.Post:unlink("comments", 2, 4) end),
        -- the create rule allows the row; the link rule refuses its link
        try(function() return c.Post:create { title = "Linked", owner = 1, author = 2 }.id end),
        try(function() return c.Post:query():update { public = false } end),
        list(c.Log:query():order("id"):all(), "msg"),
    }
end

function steps.bob(c)
    return {
        try(function() return c.Post:delete(2) end),
        -- post 3 is updated first, then post 1 is refused: the call takes back both
        try(function() return c.Post:query():order("id", "desc"):update { public = true } end),
        tostring(c.Post:get(3).public),
        try(function() return c.Post:query():where("owner", "=", 2):delete() end),
        list(c.Post:query():order("id"):all()),
    }
end

function steps.anon(c)
    return {
        try(function() return c.Post:create { title = "Anon", owner = 1 }.id end),
        try(function() return c.Post:query():delete() end),
        try(function() return c.Comment:create { body = "hi" }.id end),
    }
end

function steps.odd(c)
    return try(function() return c.Odd:query():count() end)
end

function call(step, who, mode)
    if step == "migrate" then
        return m.migrate(app).done and "done" or "more"
    end
    local pessimistic = mode == "pessimistic"
    if step == "plain" then
        -- a client without the graph runs no policy
        return client.tx(function(c) return c.Post:query():count() end, pessimistic)
    end
    if step == "client" then
        return barch.tx.run(function()
            return db.client(pessimistic, VIEWERS[who]).Post:query():count()
        end, pessimistic)
    end
    return db.tx(function(c) return steps[step](c) end, pessimistic, VIEWERS[who])
end
"""

MODULES = [("VALUES", "lent/values.luau"), ("KEYCODEC", "lent/keycodec.luau"),
           ("ROWCODEC", "lent/rowcodec.luau"), ("SCHEMA", "lent/schema.luau"),
           ("LAYOUT", "lent/layout.luau"), ("MIGRATE", "lent/migrate.luau"),
           ("EXPR", "lent/expr.luau"), ("CLIENT", "lent/client.luau")]


@pytest.fixture(params=["optimistic", "pessimistic"])
def run(client, request):
    for name, path in MODULES:
        install(client, "lent", name, path)
    client.execute_command("USE", re.sub(r"\W", "_", "privacy_" + request.node.name))
    client.execute_command("SETF", "PRIVACY", APP)
    mode = request.param
    run = lambda step, who="": client.execute_command("CALLF", "PRIVACY", step, who, mode)
    assert run("migrate") == "done"
    assert run("seed", "admin") == "ok"
    return run


SIGN_IN = "LENT table Comment policy denies query: sign in to read comments"


@pytest.mark.parametrize("who, expected", [
    ("", ["Ann public", "1", "nil", "nil", "Ann public", "ann=Ann public bob=", "2", "none",
          SIGN_IN, SIGN_IN]),
    ("ann", ["Ann public,Ann draft", "2", "Ann draft", "nil", "Ann public,Ann draft",
             "ann=Ann public,Ann draft bob=", "2", "none", "2", "4"]),
    ("bob", ["Ann public,Bob draft", "2", "nil", "Bob draft", "Ann public",
             "ann=Ann public bob=Bob draft", "2", "linked", "1", "4"]),
    ("admin", ["Ann public,Ann draft,Bob draft", "3", "Ann draft", "Bob draft",
               "Ann public,Ann draft", "ann=Ann public,Ann draft bob=Bob draft", "2", "linked",
               "2", "4"]),
])
def test_query_rules_filter_what_each_viewer_reads(run, who, expected):
    assert run("reads", who) == expected


def test_mutation_rules_decide_a_members_writes(run):
    assert run("ann", "ann") == [
        "4",
        "LENT table Post policy denies create: posts are created by their owner",
        # the rule reads post 3 through its own client, which has no rules
        "LENT table Post policy denies update of row 3: not the owner",
        "true",
        "true",
        "LENT table Post policy denies unlink comments from row 2 to row 4",
        "LENT table Post policy denies link author from row 5 to row 2: authors link themselves",
        "3",
        # the refused "Linked" create takes back its hook's log entry
        "create Ann public,create Ann draft,create Bob draft,create Ann new",
    ]


def test_a_refused_query_write_takes_back_the_rows_it_wrote(run):
    assert run("bob", "bob") == [
        "LENT table Post policy denies delete of row 2: not the owner",
        "LENT table Post policy denies update of row 1: not the owner",
        "false",
        "1",
        "Ann public",
    ]


def test_mutation_rules_refuse_a_signed_out_viewer(run):
    assert run("anon") == [
        "LENT table Post policy denies create: sign in",
        "LENT table Post policy denies delete of row 1: sign in",
        "5",
    ]


def test_rules_answer_allow_deny_or_nil(run):
    assert run("odd", "admin") == (
        "LENT table Odd policy.query rule 1 answered yes; a rule answers lent.allow, lent.deny or nil")


def test_viewer_reaches_rules_through_each_client(run):
    assert run("plain") == 3
    assert run("client") == 1
    assert run("client", "bob") == 2
