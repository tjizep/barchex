import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Shifts clock in and out; worked, long and size are computed from them.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

local deleted = {}

local function app(plain, bad)
    local fields = {
        lent.field.time "clockIn",
        lent.field.time "clockOut":optional(),
    }
    if not plain then
        table.insert(fields, lent.field.int "worked":computed(function(r)
            return r.clockOut and r.clockOut - r.clockIn
        end))
        -- a computed field sees the computed fields declared before it
        table.insert(fields, { kind = "bool", name = "long", computed = function(r)
            return r.worked ~= nil and r.worked >= 8
        end })
        table.insert(fields, lent.field.enum "size":values("short", "long"):computed(function(r)
            return r.long and "long" or "short"
        end))
    end
    if bad then
        table.insert(fields, lent.field.int "broken":computed(function() return bad end))
    end
    return lent.graph {
        lent.schema "User" { id = "int", fields = { lent.field.string "name" },
                             edges = { lent.edge.to "shifts" "Shift" } },
        lent.schema "Shift" {
            id = "int",
            fields = fields,
            indexes = { lent.index("clockIn") },
            edges = { lent.edge.from "user" "User":ref "shifts":unique() },
            hooks = { delete = { function(c, id, old) deleted[#deleted + 1] = tostring(old.worked) end } },
        },
    }
end

local db = client.open(app())

local function show(r)
    return r.id .. ":" .. tostring(r.worked) .. ":" .. tostring(r.long) .. ":" .. tostring(r.size)
end

local function list(q)
    local out = {}
    for _, r in q:all() do out[#out + 1] = show(r) end
    return table.concat(out, " ")
end

local steps = {}

function steps.rows(c)
    local ann = c.User:create { name = "ann" }
    local bob = c.User:create { name = "bob" }
    local a = c.Shift:create { clockIn = 0, clockOut = 9, user = ann }
    c.Shift:create { clockIn = 10, clockOut = 14, user = ann }
    c.Shift:create { clockIn = 20, clockOut = 30, user = bob }
    local open = c.Shift:create { clockIn = 40, user = bob }
    local closed = c.Shift:update(open.id, { clockOut = 41 })
    local q = c.Shift:query():order("worked", "desc"):limit(2)
    local page = q:all()
    local totals = {}
    for _, g in c.Shift:query():groupBy("user", "size"):aggregate {
        worked = { fn = "sum", field = "worked" }, n = { fn = "count" } } do
        totals[#totals + 1] = g.user .. "/" .. g.size .. "=" .. g.worked .. "x" .. g.n
    end
    local out = {
        show(a) .. " " .. show(open) .. " " .. show(closed) .. " " .. show(c.Shift:get(closed.id)),
        list(c.Shift:query():where("worked", ">=", 5)),
        list(c.Shift:query():where("size", "=", "short"):order("worked")),
        list(q) .. " | " .. list(c.Shift:query():order("worked", "desc"):after(q:cursor(page[2]))),
        c.Shift:query():explain() .. " | " .. c.Shift:query():where("worked", ">", 1):explain(),
        tostring(c.Shift:query():sum("worked")) .. " " .. tostring(c.Shift:query():max("worked")),
        table.concat(totals, " "),
        list(c.User:query():where("name", "=", "bob"):queryShifts()),
    }
    c.Shift:delete(a.id)
    out[#out + 1] = table.concat(deleted, " ")
    return out
end

-- a client opened without the graph reads stored fields only
function steps.plain(c)
    local r = c.Shift:query():order("clockIn"):first()
    local ok, err = pcall(function() return c.Shift:query():where("worked", ">", 1):count() end)
    return { tostring(r.worked), tostring(ok) .. " " .. err }
end

local bad = {
    create = function(c) c.Shift:create { clockIn = 1, worked = 3 } end,
    update = function(c) c.Shift:update(c.Shift:create({ clockIn = 1 }).id, { worked = 3 }) end,
    clear = function(c) c.Shift:update(c.Shift:create({ clockIn = 1 }).id, {}, { "worked" }) end,
    query = function(c) c.Shift:query():update { long = true } end,
}

function call(step, which)
    if step == "migrate" then
        return m.migrate(app()).version
    end
    if step == "migrate_plain" then
        -- computed fields are not stored, so dropping them changes nothing
        return m.migrate(app(true)).version
    end
    if step == "plain" then
        return client.tx(steps.plain)
    end
    if step == "kind" then
        local values = { whole = 5, text = "x", fraction = 1.5 }
        return client.open(app(false, values[which])).tx(function(c) return c.Shift:get(2) and "read" end)
    end
    return db.tx(function(c)
        if step == "bad" then
            bad[which](c)
            return "no error"
        end
        return steps[step](c)
    end)
end
"""


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", "computed_" + request.node.name)
    client.execute_command("SETF", "SHIFTS", APP)
    assert client.execute_command("CALLF", "SHIFTS", "migrate") == 1
    return lambda *a: client.execute_command("CALLF", "SHIFTS", *a)


def test_computed_fields(run):
    assert run("rows") == [
        "1:9:true:long 4:nil:false:short 4:1:false:short 4:1:false:short",
        "1:9:true:long 3:10:true:long",
        "4:1:false:short 2:4:false:short",
        # the cursor pages on the computed order, after 9 comes 4
        "3:10:true:long 1:9:true:long | 2:4:false:short 4:1:false:short",
        "id | id",
        "24 10",
        "1/long=9x1 1/short=4x1 2/long=10x1 2/short=1x1",
        "3:10:true:long 4:1:false:short",
        # the delete hook saw the computed value
        "9",
    ]
    assert run("migrate_plain") == 1
    assert run("plain") == ["nil", "false LENT table Shift has no field worked"]


ERRORS = {
    "create": "LENT table Shift field worked is computed, so a row cannot set it",
    "update": "LENT table Shift field worked is computed, so a row cannot set it",
    "clear": "LENT table Shift field worked is computed, so a row cannot set it",
    "query": "LENT table Shift field long is computed, so a row cannot set it",
}


def test_computed_errors(run):
    for which, message in ERRORS.items():
        with pytest.raises(redis.ResponseError) as err:
            run("bad", which)
        assert message in str(err.value), which
    run("rows")
    assert run("kind", "whole") == "read"
    for value, shown in [("text", "x"), ("fraction", "1.5")]:
        with pytest.raises(redis.ResponseError) as err:
            run("kind", value)
        assert ("LENT table Shift field broken is a computed int, and its function answered "
                + shown) in str(err.value)
