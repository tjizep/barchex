import pytest

from .conftest import install

redis = pytest.importorskip("redis")

# Migrates the default space to a User table, stores three rows by hand with
# LAYOUT and ROWCODEC, then migrates to a version that adds a unique index and
# drops the name index, and answers what the store and catalog hold.
APP = """
local ent = require("ent.SCHEMA")
local rc = require("ent.ROWCODEC")
local lay = require("ent.LAYOUT")
local m = require("ent.MIGRATE")

local function v1()
    return ent.graph {
        ent.schema "User" {
            id = "int",
            fields = { ent.field.string "email", ent.field.string "name" },
            edges = { ent.edge.to "posts" "Post" },
            indexes = { ent.index("name") },
        },
        ent.schema "Post" { id = "int", fields = { ent.field.string "title" } },
    }
end

local function v2(unique)
    local email = ent.field.string "email"
    return ent.graph {
        ent.schema "User" {
            id = "int",
            fields = { unique and email:unique() or email, ent.field.string "name",
                       ent.field.int "age":optional() },
            edges = { ent.edge.to "posts" "Post" },
            indexes = { ent.index("email", "name") },
        },
        ent.schema "Post" { id = "int", fields = { ent.field.string "title" } },
    }
end

local function count(prefix)
    return lay.walk(prefix, function() end)
end

function call(which)
    if which == "v1" then
        local r = m.migrate(v1())
        local again = m.migrate(v1())
        local c = m.load()
        local u = c.tables.user
        local fields = rc.fields(u.fields)
        barch.tx.run(function()
            for pk, row in { { "a@b", "ann" }, { "c@d", "bob" }, { "a@b", "cy" } } do
                barch.store.set(lay.row(u, pk), rc.encode(fields, u.format, c.version,
                    { email = row[1], name = row[2] }))
            end
        end)
        return { r.version, tostring(r.changed), table.concat(r.steps, ","),
                 again.version, tostring(again.changed),
                 barch.graph.get("/ent/version"),
                 barch.graph.stat("/ent/tables/user/indexes/by_name/on/1").refs,
                 barch.graph.stat("/ent/edges/user_posts/to").type }
    end
    if which == "dup" then
        return m.migrate(v2(true))
    end
    local r = m.migrate(v2(false))
    local u = m.load().tables.user
    return { r.version, table.concat(r.steps, ","),
             count("ent.i"), count(lay.index(u, u.indexes[1], { "a@b" })),
             tostring(barch.graph.stat("/ent/tables/user/indexes/by_name") == nil),
             barch.graph.stat("/ent/tables/user/fields/age") and "age" or "no age" }
end
"""


def setup(client):
    for name, path in [("KEYCODEC", "ent/keycodec.luau"), ("ROWCODEC", "ent/rowcodec.luau"),
                       ("SCHEMA", "ent/schema.luau"), ("LAYOUT", "ent/layout.luau"),
                       ("MIGRATE", "ent/migrate.luau")]:
        install(client, "ent", name, path)


@pytest.mark.parametrize("name", ["LAYOUT", "MIGRATE"])
def test_selftest(client, name):
    setup(client)
    client.execute_command("USE", "ent")
    assert client.execute_command("CALLF", name) == "ok"


def test_migrate_builds_catalog_and_indexes(client):
    setup(client)
    client.execute_command("USE", "default")
    client.execute_command("SETF", "MIGAPP", APP)
    assert client.execute_command("CALLF", "MIGAPP", "v1") == [
        1, "true", "build User.by_name",
        # the same schema again changes nothing
        1, "false",
        "1",
        # the index's field link and the field leaf share a node
        2, "json",
    ]
    # two rows share an email, so a unique index on it is refused and the
    # whole migration rolls back
    with pytest.raises(redis.ResponseError, match="MIGRATE table User index by_email is unique"):
        client.execute_command("CALLF", "MIGAPP", "dup")
    assert client.execute_command("CALLF", "MIGAPP", "v2") == [
        2, "drop User.by_name,build User.by_email_name",
        # by_name's three entries are gone and by_email_name has three
        3, 2, "true", "age",
    ]
