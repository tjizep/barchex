import pytest

from .conftest import install

redis = pytest.importorskip("redis")

# Migrates the default space to a User table, stores three rows by hand with
# LAYOUT and ROWCODEC, then migrates to a version that adds a unique index and
# drops the name index, and answers what the store and catalog hold.
APP = """
local lent = require("lent.SCHEMA")
local rc = require("lent.ROWCODEC")
local lay = require("lent.LAYOUT")
local m = require("lent.MIGRATE")

local function v1()
    return lent.graph {
        lent.schema "User" {
            id = "int",
            fields = { lent.field.string "email", lent.field.string "name" },
            edges = { lent.edge.to "posts" "Post" },
            indexes = { lent.index("name") },
        },
        lent.schema "Post" { id = "int", fields = { lent.field.string "title" } },
    }
end

local function v2(unique)
    local email = lent.field.string "email"
    return lent.graph {
        lent.schema "User" {
            id = "int",
            fields = { unique and email:unique() or email, lent.field.string "name",
                       lent.field.int "age":optional() },
            edges = { lent.edge.to "posts" "Post" },
            indexes = { lent.index("email", "name") },
        },
        lent.schema "Post" { id = "int", fields = { lent.field.string "title" } },
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
                 barch.graph.get("/lent/version"),
                 barch.graph.stat("/lent/tables/user/indexes/by_name/on/1").refs,
                 barch.graph.stat("/lent/edges/user_posts/to").type }
    end
    if which == "dup" then
        return m.migrate(v2(true))
    end
    local r = m.migrate(v2(false))
    local u = m.load().tables.user
    return { r.version, table.concat(r.steps, ","),
             count("lent.i"), count(lay.index(u, u.indexes[1], { "a@b" })),
             tostring(barch.graph.stat("/lent/tables/user/indexes/by_name") == nil),
             barch.graph.stat("/lent/tables/user/fields/age") and "age" or "no age" }
end
"""


def setup(client):
    for name, path in [("VALUES", "lent/values.luau"),
                       ("KEYCODEC", "lent/keycodec.luau"), ("ROWCODEC", "lent/rowcodec.luau"),
                       ("SCHEMA", "lent/schema.luau"), ("LAYOUT", "lent/layout.luau"),
                       ("MIGRATE", "lent/migrate.luau")]:
        install(client, "lent", name, path)


@pytest.mark.parametrize("name", ["LAYOUT", "MIGRATE"])
def test_selftest(client, name):
    setup(client)
    client.execute_command("USE", "lent")
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
