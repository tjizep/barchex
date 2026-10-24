import pytest

from .conftest import install
from .helpers import connect

redis = pytest.importorskip("redis")

# Each call(which) runs one step against the default space's User table.
APP = """
local ent = require("ent.SCHEMA")
local m = require("ent.MIGRATE")
local client = require("ent.CLIENT")
local lay = require("ent.LAYOUT")

local function schema(admin)
    local fields = { ent.field.string "email":unique(), ent.field.string "name",
                     ent.field.int "age":optional() }
    local indexes = { ent.index("name") }
    if admin then
        fields[#fields + 1] = ent.field.bool "admin":default(false)
        indexes[#indexes + 1] = ent.index("admin", "name")
    end
    return ent.graph { ent.schema "User" { fields = fields, indexes = indexes } }
end

local function entries()
    local u = m.load().tables.user
    local n = {}
    for i, ix in u.indexes do
        n[i] = ix.name .. "=" .. lay.walk(lay.index(u, ix), function() end)
    end
    return table.concat(n, " ")
end

local function show(r)
    if r == nil then
        return "nil"
    end
    return r.id .. ":" .. r.email .. "," .. r.name .. "," .. tostring(r.age)
        .. (r.admin ~= nil and "," .. tostring(r.admin) or "")
end

function call(which, pessimistic)
    local p = pessimistic == "pessimistic"
    if which == "migrate" then
        return m.migrate(schema(false)).version
    end
    if which == "migrate2" then
        return m.migrate(schema(true)).version
    end
    if which == "crud" then
        return client.tx(function(c)
            local a = c.User:create { email = "a@b", name = "ann", age = 41 }
            local b = c.User:create { email = "c@d", name = "bob" }
            local out = { show(a), show(b), show(c.User:get(1)), show(c.User:by("email", "c@d")),
                          show(c.User:get(9)) }
            out[#out + 1] = show(c.User:update(1, { email = "e@f", name = "al" }, { "age" }))
            out[#out + 1] = show(c.User:by("email", "a@b")) .. " " .. show(c.User:by("by_email", "e@f"))
            out[#out + 1] = entries()
            return out
        end, p)
    end
    if which == "dup" then
        -- a refused create inside the transaction leaves nothing behind
        return client.tx(function(c)
            local ok, err = pcall(c.User.create, c.User, { email = "c@d", name = "x" })
            local d = c.User:create { email = "g@h", name = "dee" }
            return { ok and "created" or err, show(d), entries() }
        end, p)
    end
    if which == "delete" then
        return client.tx(function(c)
            return { tostring(c.User:delete(2)), tostring(c.User:delete(2)),
                     show(c.User:by("email", "c@d")), entries() }
        end, p)
    end
    if which == "defaults" then
        return client.tx(function(c)
            return { show(c.User:get(1)), entries() }
        end, p)
    end
    -- the remaining steps raise their error
    client.tx(function(c)
        if which == "table" then
            return c.Users:get(1)
        elseif which == "field" then
            return c.User:create { email = "x", name = "y", nick = "z" }
        elseif which == "kind" then
            return c.User:create { email = "x", name = 3 }
        elseif which == "missing" then
            return c.User:update(99, { name = "z" })
        elseif which == "id" then
            return c.User:create { id = 5, email = "x", name = "y" }
        end
    end, p)
end
"""

# Reads the schema in the caller's transaction and creates a row.
WRITE = """
local client = require("ent.CLIENT")
function call()
    return client.client().User:create { email = "w@x", name = "w" }.id
end
"""


def setup(client):
    for name, path in [("KEYCODEC", "ent/keycodec.luau"), ("ROWCODEC", "ent/rowcodec.luau"),
                       ("SCHEMA", "ent/schema.luau"), ("LAYOUT", "ent/layout.luau"),
                       ("MIGRATE", "ent/migrate.luau"), ("CLIENT", "ent/client.luau")]:
        install(client, "ent", name, path)


def app(client, space):
    setup(client)
    client.execute_command("USE", space)
    # SETF keeps the first body of a name, so each test space gets its own
    client.execute_command("SETF", "CLIENTAPP", APP)
    client.execute_command("SETF", "CLIENTWRITE", WRITE)


def test_client_selftest(client):
    setup(client)
    client.execute_command("USE", "ent")
    assert client.execute_command("CALLF", "CLIENT") == "ok"


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_client_rows_and_indexes(client, mode):
    app(client, "client_" + mode)
    run = lambda *a: client.execute_command("CALLF", "CLIENTAPP", *a, mode)
    assert run("migrate") == 1
    assert run("crud") == [
        "1:a@b,ann,41", "2:c@d,bob,nil", "1:a@b,ann,41", "2:c@d,bob,nil", "nil",
        "1:e@f,al,nil",
        # the old email's entry moved with the update
        "nil 1:e@f,al,nil",
        "by_email=2 by_name=2",
    ]
    out = run("dup")
    assert out[0] == "ENT table User index by_email is unique, and row 2 already has email=c@d"
    # the refused create did not take id 3 or leave index entries
    assert out[1:] == ["3:g@h,dee,nil", "by_email=3 by_name=3"]
    assert run("delete") == ["true", "false", "nil", "by_email=2 by_name=2"]

    # rows stored before admin was added read its default, in the new index too
    assert run("migrate2") == 2
    assert run("defaults") == ["1:e@f,al,nil,false", "by_email=2 by_name=2 by_admin_name=2"]


@pytest.mark.parametrize("which, error", [
    ("table", "ENT this space's schema has no table Users"),
    ("field", "ENT table User has no field nick"),
    ("kind", "ROWCODEC field name wants string, got 3"),
    ("missing", "ENT table User has no row 99"),
    ("id", "ENT table User gives out ids itself, so a row cannot set id"),
])
def test_client_errors(client, which, error):
    app(client, "client_errors")
    client.execute_command("CALLF", "CLIENTAPP", "migrate")
    with pytest.raises(redis.ResponseError, match=error):
        client.execute_command("CALLF", "CLIENTAPP", which)


def test_client_without_schema(client):
    app(client, "client_empty")
    with pytest.raises(redis.ResponseError, match="ENT this space has no schema; run MIGRATE first"):
        client.execute_command("CALLF", "CLIENTAPP", "crud")


def test_migration_during_a_transaction_conflicts(server, client):
    app(client, "client_conflict")
    client.execute_command("CALLF", "CLIENTAPP", "migrate")
    other = connect(server.port)
    other.execute_command("USE", "client_conflict")
    try:
        client.execute_command("BEGINTX")
        assert client.execute_command("CALLF", "CLIENTWRITE") == 1
        assert other.execute_command("CALLF", "CLIENTAPP", "migrate2") == 2
        with pytest.raises(redis.ResponseError, match="TXCONFLICT"):
            client.execute_command("COMMITTX")
    finally:
        other.close()
    assert client.execute_command("CALLF", "CLIENTAPP", "defaults")[1] == \
        "by_email=0 by_name=0 by_admin_name=0"
