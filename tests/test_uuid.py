import pytest

from .conftest import install

redis = pytest.importorskip("redis")

# Authors take barch.uuid() ids, the default; books keep integer ids. Each
# step answers a list of strings, with uuids replaced by A1, A2, ... in
# creation order so the expectations stay readable.
APP = """
local ent = require("ent.SCHEMA")
local m = require("ent.MIGRATE")
local client = require("ent.CLIENT")

local function app(bookIds)
    return ent.graph {
        ent.schema "Author" {
            fields = { ent.field.string "name":unique(), ent.field.int "born" },
            indexes = { ent.index("born") },
            edges = { ent.edge.to "books" "Book", ent.edge.to "fans" "Author" },
        },
        ent.schema "Book" {
            id = bookIds,
            fields = { ent.field.string "title" },
            edges = { ent.edge.from "author" "Author":ref "books":unique() },
        },
    }
end

local names = {}
local function name(id)
    if type(id) == "number" then
        return tostring(id)
    end
    if names[id] == nil then
        local n = 0
        for _ in names do
            n += 1
        end
        names[id] = "A" .. (n + 1)
    end
    return names[id]
end

local function ids(q)
    local out = {}
    for i, id in q:ids() do
        out[i] = name(id)
    end
    return table.concat(out, ",")
end

local steps = {}

function steps.rows(c)
    local A = c.Author
    local ann = A:create { name = "ann", born = 1970 }
    local bob = A:create { name = "bob", born = 1950 }
    local cy = A:create { name = "cy", born = 1990 }
    for _, a in { ann, bob, cy } do
        name(a.id)
    end
    local b1 = c.Book:create { title = "one", author = ann }
    c.Book:create { title = "two", author = ann.id }
    c.Book:create { title = "three", author = bob }
    A:link("fans", cy.id, ann.id)
    A:link("fans", cy.id, bob.id)
    A:update(bob.id, { born = 1951 })
    return {
        tostring(#ann.id) .. " " .. tostring(ann.id < bob.id and bob.id < cy.id),
        name(A:get(bob.id).id) .. " " .. A:get(bob.id).born,
        name(A:by("name", "cy").id),
        ids(A:query():order("id", "desc")),
        ids(A:query():where("id", ">", ann.id)),
        ids(A:query():where("id", "=", bob.id)),
        ids(A:query():order("born")),
        ids(A:query():where("name", "=", "ann"):queryBooks():order("id", "desc")),
        ids(c.Book:query():where("id", "=", b1.id):queryAuthor()),
        ids(A:query():where("id", "=", cy.id):follow("fans")),
        tostring(A:unlink("fans", cy.id, ann.id)) .. " " .. ids(A:query():where("id", "=", cy.id):queryFans()),
        tostring(A:delete(bob.id)) .. " " .. tostring(A:get(bob.id)) .. " "
            .. tostring(c.Book:get(3).title) .. " " .. ids(c.Book:query():where("id", "=", 3):queryAuthor()),
        ids(A:query():where("id", "=", cy.id):queryFans()),
    }
end

local errors = {
    int = function(c) c.Author:get(1) end,
    upper = function(c) c.Author:get(string.upper(c.Author:create({ name = "x", born = 1 }).id)) end,
    where = function(c) c.Author:query():where("id", "=", 3) end,
    book = function(c) c.Book:get("x") end,
}

function call(step, mode)
    if step == "migrate" then
        return m.migrate(app(mode or "int")).version
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
    client.execute_command("SETF", "UUIDAPP", APP)
    assert client.execute_command("CALLF", "UUIDAPP", "migrate") == 1


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_uuid_rows_queries_and_edges(client, mode):
    setup(client, "uuid_" + mode)
    assert client.execute_command("CALLF", "UUIDAPP", "rows", mode) == [
        # barch.uuid() ids are 36 characters and sort in creation order
        "36 true",
        "A2 1951",
        "A3",
        "A3,A2,A1",
        "A2,A3",
        "A2",
        "A2,A1,A3",
        "2,1",
        "A1",
        "A1,A2",
        "true A2",
        # deleting an author removes its edges and keeps the book
        "true nil three ",
        "",
    ]


@pytest.mark.parametrize("step, error", [
    ("int", "ENT table Author wants a uuid id, got 1"),
    ("upper", "ENT table Author wants a uuid id, got [0-9A-F]{8}-"),
    ("where", "ENT table Author field id is uuid"),
    ("book", "ENT table Book wants an integer id, got x"),
])
def test_uuid_errors(client, step, error):
    setup(client, "uuid_errors")
    with pytest.raises(redis.ResponseError, match=error):
        client.execute_command("CALLF", "UUIDAPP", step)


def test_migrate_keeps_the_id_kind(client):
    setup(client, "uuid_migrate")
    with pytest.raises(redis.ResponseError, match='table Book has int ids, so its schema needs id = "int"'):
        client.execute_command("CALLF", "UUIDAPP", "migrate", "uuid")
