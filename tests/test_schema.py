import pytest

from .conftest import install

redis = pytest.importorskip("redis")

# Declares a User and a Post table from the default space, stores a user row
# with the field ids SCHEMA gives out, then reads it back after a second
# version renames a field and adds one.
APP = """
function call()
    local ent = require("ent.SCHEMA")
    local rc = require("ent.ROWCODEC")
    local User = ent.schema "User" {
        fields = {
            ent.field.string "email":unique(),
            ent.field.string "name",
            ent.field.int "age":optional(),
        },
        edges = { ent.edge.to "posts" "Post" },
        indexes = { ent.index("name", "age") },
    }
    local Post = ent.schema "Post" {
        format = "text",
        fields = { ent.field.string "title" },
        edges = { ent.edge.from "author" "User":ref "posts":unique() },
    }
    local app = ent.graph { User, Post }

    local v1, fields1 = ent.ids(User)
    barch.store.set("u.1", rc.encode(rc.fields(fields1), User.format, 1,
        { email = "a@b", name = "ann", age = 41 }))

    local User2 = ent.schema "User" {
        fields = {
            ent.field.string "email":unique(),
            ent.field.string "full_name":was("name"),
            ent.field.string "nick":optional(),
        },
    }
    local v2, fields2 = ent.ids(User2, v1)
    local row, version = rc.decode(rc.fields(fields2), barch.store.get("u.1"))

    local out = {}
    for _, ix in User.indexes do
        out[#out + 1] = ix.name .. (ix.unique and "!" or "") .. "=" .. table.concat(ix.on, ",")
    end
    local e = app.edges.user_posts
    out[#out + 1] = e.from .. "->" .. e.to .. (e.inverseUnique and " one author" or "")
    out[#out + 1] = Post.format
    out[#out + 1] = "v" .. version .. " " .. row.email .. " " .. row.full_name
        .. " " .. tostring(row.nick) .. " next=" .. v2.next .. " nick=" .. v2.ids.nick
    return out
end
"""

BAD = """
function call(which)
    local ent = require("ent.SCHEMA")
    if which == "edge" then
        ent.graph { ent.schema "A" { fields = { ent.field.int "n" },
                                     edges = { ent.edge.to "bs" "B" } } }
    else
        ent.schema "A" { fields = { ent.field.int "n" }, indexes = { ent.index("m") } }
    end
end
"""


def setup(client):
    install(client, "ent", "SCHEMA", "ent/schema.luau")
    install(client, "ent", "ROWCODEC", "ent/rowcodec.luau")
    client.execute_command("USE", "default")


def test_schema_selftest(client):
    install(client, "ent", "SCHEMA", "ent/schema.luau")
    client.execute_command("USE", "ent")
    assert client.execute_command("CALLF", "SCHEMA") == "ok"


def test_schema_ids_carry_rows_across_versions(client):
    setup(client)
    client.execute_command("SETF", "APP", APP)
    assert client.execute_command("CALLF", "APP") == [
        "by_email!=email",
        "by_name_age=name,age",
        "User->Post one author",
        "text",
        # age's id 3 is retired, so nick takes 4 and the old age value is skipped
        "v1 a@b ann nil next=5 nick=4",
    ]


@pytest.mark.parametrize("which, error", [
    ("edge", "SCHEMA table A edge bs names table B, which is not declared"),
    ("index", "SCHEMA table A index on m, which is not a field"),
])
def test_schema_errors_name_the_problem(client, which, error):
    setup(client)
    client.execute_command("SETF", "BAD", BAD)
    with pytest.raises(redis.ResponseError, match=error):
        client.execute_command("CALLF", "BAD", which)
