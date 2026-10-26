from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

import pytest

from .helpers import connect
from .test_client import setup

redis = pytest.importorskip("redis")

APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local lay = require("lent.LAYOUT")

local function app(ids, format)
    return lent.graph {
        lent.schema "Item" {
            id = ids, format = format,
            fields = {
                lent.field.string "scope":default("main"),
                lent.field.string "key",
                lent.field.string "email":optional():unique(),
                lent.field.string "name":notEmpty(),
                lent.field.int "value":min(0):default(3),
                lent.field.string "note":optional(),
                lent.field.int "created":default(function() return 7 end):immutable(),
                lent.field.int "updated":default(function() return 11 end)
                    :updateDefault(function() return 22 end),
                lent.field.bool "flag":optional():unique(),
            },
            indexes = { lent.index("scope", "key"):unique():name("identity"),
                        lent.index("name") },
            edges = { lent.edge.from "group" "Group":ref "items":unique() },
            hooks = {
                create = { function(c, r)
                    r.name = r.name or r.key
                    c.Log:create { msg = "create " .. tostring(r.key) }
                    if r.name == "refuse" then error("hook refused", 0) end
                end },
                update = { function(c, id, r, old)
                    c.Log:create { msg = "update " .. old.key }
                    if r.name == "refuse" then error("hook refused", 0) end
                end },
            },
        },
        lent.schema "Group" {
            id = "int", fields = { lent.field.string "name" },
            edges = { lent.edge.to "items" "Item" },
        },
        lent.schema "Log" { id = "int", fields = { lent.field.string "msg" } },
    }
end

local function logs(c)
    local out = {}
    for _, r in c.Log:query():all() do out[#out + 1] = r.msg end
    return table.concat(out, "; ")
end

local function entries()
    local t = m.load().tables.item
    local out = {}
    for _, ix in t.indexes do
        out[#out + 1] = ix.name .. "=" .. lay.walk(lay.index(t, ix), function() end)
    end
    table.sort(out)
    return table.concat(out, " ")
end

local steps = {}

function steps.bulk(c)
    local g = c.Group:create { name = "group" }
    local input = {
        { key = "a", email = "a@b", group = g },
        { key = "b", email = "b@b", name = "Bee", value = 9, group = g.id },
    }
    local rows = c.Item:createMany(input)
    local a, b = rows[1], rows[2]
    return {
        #rows, a.key .. " " .. b.key,
        type(a.id) .. " " .. tostring(a.id < b.id
            and (type(a.id) ~= "number" or (a.id == 1 and b.id == 2))),
        tostring(input[1].id == nil and input[1].created == nil and input[1].name == nil),
        a.scope .. " " .. a.name .. " " .. a.value .. " " .. a.created .. " " .. a.updated,
        tostring(c.Item:by("email", "b@b").id == b.id),
        c.Group:query():where("id", "=", g.id):queryItems():count(),
        c.Item:query():where("id", "=", a.id):queryGroup():first().name,
        #c.Item:createMany({}), entries(), logs(c),
    }
end

function steps.upsert(c)
    local g = c.Group:create { name = "group" }
    local input = { scope = "s", key = "a", email = "a@b", name = "Ann", note = "keep", group = g }
    local a, made = c.Item:upsert("identity", input)
    local b, changed = c.Item:upsert("by_email", { email = "a@b", name = "Amy", value = 9 })
    local d, again = c.Item:upsert("email", { email = "a@b", note = "changed" })
    local other, otherMade = c.Item:upsert("identity", { scope = "other", key = "a" })
    local f, flagMade = c.Item:upsert("flag", { flag = false, key = "f", name = "Flag" })
    local f2, flagChanged = c.Item:upsert("by_flag", { flag = false, value = 4 })
    return {
        tostring(made) .. " " .. tostring(changed) .. " " .. tostring(again) .. " "
            .. tostring(otherMade) .. " " .. tostring(flagMade) .. " " .. tostring(flagChanged),
        tostring(a.id == b.id and b.id == d.id and f.id == f2.id and other.id ~= a.id),
        d.name .. " " .. d.value .. " " .. d.note .. " " .. d.created .. " " .. d.updated,
        a.value .. " " .. a.updated .. " " .. f2.value .. " " .. tostring(f2.flag),
        tostring(input.id == nil and input.created == nil),
        c.Item:query():where("name", "=", "Ann"):count(),
        c.Item:query():where("name", "=", "Amy"):count(),
        c.Item:query():where("id", "=", a.id):queryGroup():first().name,
        c.Item:query():count(), entries(), logs(c),
    }
end

local function failed(c, kind)
    local second = { key = "b" }
    if kind == "duplicate" then second.key = "a"
    elseif kind == "rule" then second.value = -1
    elseif kind == "hook" then second.name = "refuse"
    elseif kind == "edge" then second.group = 999 end
    c.Item:createMany { { key = "a", email = "a@b" }, second, { key = "unreached" } }
end

steps.fail = failed

function steps.caught(c, kind)
    local ok, err = pcall(failed, c, kind)
    local count = c.Item:query():count()
    local next = c.Item:create { key = "next" }
    return { tostring(ok), err, count, next.id, entries(), logs(c) }
end

function steps.inspect(c)
    return { c.Item:query():count(), entries(), logs(c) }
end

local bad = {
    list = function(c) c.Item:createMany(false) end,
    map = function(c) c.Item:createMany { named = { key = "a" } } end,
    gap = function(c) c.Item:createMany { [2] = { key = "a" } } end,
    row = function(c) c.Item:createMany { { key = "a" }, false } end,
    index = function(c) c.Item:upsert("missing", {}) end,
    nonunique = function(c) c.Item:upsert("by_name", {}) end,
    values = function(c) c.Item:upsert("identity", false) end,
    partial = function(c) c.Item:upsert("identity", { scope = "main" }) end,
    defaulted = function(c) c.Item:upsert("identity", { key = "a" }) end,
    optional = function(c) c.Item:upsert("email", { key = "a" }) end,
    kind = function(c) c.Item:upsert("flag", { flag = "false", key = "a" }) end,
    immutable = function(c)
        c.Item:upsert("identity", { scope = "main", key = "a" })
        c.Item:upsert("identity", { scope = "main", key = "a", created = 8 })
    end,
    conflict = function(c)
        c.Item:createMany { { key = "a", email = "a@b" }, { key = "b", email = "b@b" } }
        c.Item:upsert("identity", { scope = "main", key = "a", email = "b@b" })
    end,
    update_hook = function(c)
        c.Item:upsert("identity", { scope = "main", key = "a" })
        c.Item:upsert("identity", { scope = "main", key = "a", name = "refuse" })
    end,
    edge_update = function(c)
        local g = c.Group:create { name = "group" }
        c.Item:upsert("identity", { scope = "main", key = "a", group = g })
        c.Item:upsert("identity", { scope = "main", key = "a", group = g })
    end,
}

function steps.bad(c, which) return bad[which](c) end

function steps.shape(c)
    local ok, err = pcall(bad.row, c)
    return { tostring(ok), err, c.Item:query():count(), logs(c) }
end

function steps.race(c, name)
    local r, made = c.Item:upsert("identity", { scope = "race", key = "one", name = name })
    return { r.id, tostring(made) }
end

function call(step, mode, ids, format, arg)
    local graph = app(ids, format)
    if step == "migrate" then return m.migrate(graph).version end
    return client.open(graph).tx(function(c) return steps[step](c, arg) end, mode == "pessimistic")
end
"""


def app(client, space, mode="optimistic", ids="int", format="binary"):
    setup(client)
    client.execute_command("USE", space)
    client.execute_command("SETF", "BULKAPP", APP)

    def run(step, arg=""):
        return client.execute_command("CALLF", "BULKAPP", step, mode, ids, format, arg)

    assert run("migrate") == 1
    return run


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("ids", ["int", "uuid"])
@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_bulk_create_rows_defaults_hooks_and_edges(client, mode, ids, format):
    run = app(client, f"bulk_{mode}_{ids}_{format}", mode, ids, format)
    assert run("bulk") == [
        2, "a b", ("number" if ids == "int" else "string") + " true", "true",
        "main a 3 7 11", "true", 2, "group", 0,
        "by_email=2 by_flag=0 by_name=2 identity=2", "create a; create b",
    ]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("ids", ["int", "uuid"])
@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_upsert_selects_create_or_update(client, mode, ids, format):
    run = app(client, f"upsert_{mode}_{ids}_{format}", mode, ids, format)
    assert run("upsert") == [
        "true false false true true false", "true", "Amy 9 changed 7 22",
        "3 11 4 false", "true", 0, 1, "group", 3,
        "by_email=1 by_flag=1 by_name=3 identity=3",
        "create a; update a; update a; create a; create f; update f",
    ]


FAILURES = {
    "duplicate": "index identity is unique",
    "rule": "field value wants at least 0, got -1",
    "hook": "hook refused",
    "edge": "table Group has no row 999",
}
EMPTY = [0, "by_email=0 by_flag=0 by_name=0 identity=0", ""]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("ids", ["int", "uuid"])
@pytest.mark.parametrize("kind, error", FAILURES.items())
def test_bulk_error_rolls_back_the_transaction(client, mode, ids, kind, error):
    run = app(client, f"bulk_fail_{mode}_{ids}_{kind}", mode, ids)
    with pytest.raises(redis.ResponseError, match=error):
        run("fail", kind)
    assert run("inspect") == EMPTY
    # A retry can create both rows; integer counters and unique keys rolled back too.
    assert run("bulk")[:3] == [2, "a b", ("number" if ids == "int" else "string") + " true"]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_caught_bulk_error_keeps_the_completed_prefix_and_hook_writes(client, mode):
    run = app(client, "bulk_caught_" + mode, mode)
    out = run("caught", "duplicate")
    assert out[:1] == ["false"]
    assert FAILURES["duplicate"] in out[1]
    assert out[2:] == [
        1, 2, "by_email=1 by_flag=0 by_name=2 identity=2", "create a; create a; create next",
    ]


ERRORS = {
    "list": "createMany takes a list of rows",
    "map": "createMany takes a list of rows",
    "gap": "createMany row 1 must be a table of values",
    "row": "createMany row 2 must be a table of values",
    "index": "has no unique index missing",
    "nonunique": "has no unique index by_name",
    "values": "upsert takes a table of values",
    "partial": "upsert index identity needs a value for key",
    "defaulted": "upsert index identity needs a value for scope",
    "optional": "upsert index by_email needs a value for email",
    "kind": "KEYCODEC bool needs a boolean",
    "immutable": "field created is immutable",
    "conflict": "index by_email is unique",
    "update_hook": "hook refused",
    "edge_update": "edge group changes with link and unlink",
}


@pytest.mark.parametrize("which, error", ERRORS.items())
def test_bulk_and_upsert_errors(client, which, error):
    run = app(client, "bulk_error_" + which)
    with pytest.raises(redis.ResponseError, match=error):
        run("bad", which)
    assert run("inspect") == EMPTY


def test_bulk_validates_the_list_shape_before_creating_rows(client):
    run = app(client, "bulk_shape")
    out = run("shape")
    assert out == ["false", "LENT table Item createMany row 2 must be a table of values", 0, ""]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("ids", ["int", "uuid"])
def test_concurrent_upserts_choose_one_row(server, client, mode, ids):
    space = f"upsert_race_{mode}_{ids}"
    run = app(client, space, mode, ids)
    barrier = Barrier(4)

    def writer(n):
        conn = connect(server.port)
        try:
            conn.execute_command("USE", space)
            barrier.wait(timeout=10)
            return conn.execute_command("CALLF", "BULKAPP", "race", mode, ids, "binary", f"writer{n}")
        finally:
            conn.close()

    with ThreadPoolExecutor(max_workers=4) as pool:
        first = list(pool.map(writer, range(4)))
        second = list(pool.map(writer, range(4)))
    assert len({row[0] for row in first + second}) == 1
    assert sum(row[1] == "true" for row in first) == 1
    assert all(row[1] == "false" for row in second)
    count, indexes, log = run("inspect")
    assert count == 1
    assert indexes == "by_email=0 by_flag=0 by_name=1 identity=1"
    assert log == "; ".join(["create one"] + ["update one"] * 7)
