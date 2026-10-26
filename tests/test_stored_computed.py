import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Orders hold a quantity and a price. The stored computed total is indexed,
# tag is unique, and label was a plain field before it was computed.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

local function app(version)
    local fields = {
        lent.field.string "item",
        lent.field.int "qty",
        lent.field.float "price",
    }
    local indexes = {}
    if version == "plain" then
        table.insert(fields, lent.field.string "label":optional())
    else
        local total = function(r) return r.qty * r.price end
        local rev = 1
        if version == "rev2" then
            total = function(r) return r.qty * r.price * 2 end
            rev = 2
        elseif version == "badfill" then
            total = function(r) return r.item end
            rev = 3
        elseif version == "badwrite" then
            total = function(r) return r.qty > 5 and "many" or r.qty * r.price end
        end
        table.insert(fields, lent.field.float "total":computed(total):stored(rev))
        table.insert(fields, { kind = "string", name = "tag", stored = true, unique = true,
                               computed = function(r) return r.item .. "#" .. r.qty end })
        table.insert(fields, lent.field.string "label":computed(function(r)
            return string.upper(r.item)
        end):stored())
        indexes = { lent.index("total") }
    end
    return lent.graph {
        lent.schema "Order" { id = "int", fields = fields, indexes = indexes },
    }
end

local function show(r)
    return r.id .. ":" .. tostring(r.total) .. ":" .. tostring(r.tag) .. ":" .. tostring(r.label)
end

local function list(q)
    local out = {}
    for _, r in q:all() do out[#out + 1] = show(r) end
    return table.concat(out, " ")
end

local steps = {}

function steps.seed(c, version)
    c.Order:create { item = "pen", qty = 2, price = 1.5 }
    c.Order:create { item = "ink", qty = 1, price = 4 }
    c.Order:create { item = "pad", qty = 3, price = 2,
                     label = version == "plain" and "old" or nil }
    return "ok"
end

function steps.read(c)
    local q = c.Order:query():where("total", ">", 3.5)
    return { list(c.Order:query()), list(q) .. " | " .. q:explain() }
end

function steps.write(c)
    local a = c.Order:create { item = "cap", qty = 4, price = 0.5 }
    local b = c.Order:update(a.id, { qty = 5 })
    return { show(a), show(b), show(c.Order:get(a.id)), show(c.Order:by("tag", "cap#5")) }
end

local bad = {
    set = function(c) c.Order:create { item = "x", qty = 1, price = 1, total = 3 } end,
    setupdate = function(c) c.Order:update(1, { tag = "x" }) end,
    unique = function(c) c.Order:create { item = "pen", qty = 2, price = 9 } end,
}

function call(step, version, arg)
    version = version ~= "" and version or nil
    if step == "seed" then
        -- label is a plain field until version "" makes it computed
        return client.open(app(version)).tx(function(c) return steps.seed(c, version) end)
    end
    if step == "migrate" then
        local r = m.migrate(app(version), tonumber(arg))
        return { r.version, tostring(r.done), table.concat(r.steps, " ") }
    end
    if step == "raw" then
        -- a client without the graph reads the stored values
        return client.tx(function(c) return list(c.Order:query()) end)
    end
    if step == "rawwrite" then
        return client.tx(function(c) return show(c.Order:create { item = "x", qty = 1, price = 1 }) end)
    end
    return client.open(app(version)).tx(function(c)
        if step == "bad" then
            bad[arg](c)
            return "no error"
        end
        if step == "badwrite" then
            return show(c.Order:create { item = "lot", qty = 9, price = 1 })
        end
        return steps[step](c)
    end)
end
"""


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", "stored_" + request.node.name)
    client.execute_command("SETF", "ORDERS", APP)
    return lambda *a: client.execute_command("CALLF", "ORDERS", *a)


def test_stored_computed(run):
    assert run("migrate", "plain")[0] == 1
    assert run("seed", "plain") == "ok"
    # one row per page: the fill stores row 1 and stops
    assert run("migrate", "", "1") == [
        2, "false", "fill Order.total,tag,label build Order.by_tag build Order.by_total"]
    assert run("raw") == "1:3:pen#2:PEN 2:nil:nil:nil 3:nil:nil:old"
    # a client with the graph computes the rows the fill has not reached
    assert run("read", "") == [
        "1:3:pen#2:PEN 2:4:ink#1:INK 3:6:pad#3:PAD",
        "2:4:ink#1:INK 3:6:pad#3:PAD | id",
    ]
    report = run("migrate", "", "1000")
    assert report[:2] == [2, "true"]
    assert run("raw") == "1:3:pen#2:PEN 2:4:ink#1:INK 3:6:pad#3:PAD"
    assert run("read", "") == [
        "1:3:pen#2:PEN 2:4:ink#1:INK 3:6:pad#3:PAD",
        "2:4:ink#1:INK 3:6:pad#3:PAD | by_total range total",
    ]
    assert run("migrate", "")[:2] == [2, "true"]
    assert run("write", "") == [
        "4:2:cap#4:CAP", "4:2.5:cap#5:CAP", "4:2.5:cap#5:CAP", "4:2.5:cap#5:CAP"]


def test_stored_computed_revision(run):
    assert run("migrate", "")[0] == 1
    assert run("seed", "") == "ok"
    with pytest.raises(redis.ResponseError) as err:
        run("read", "rev2")
    assert ("LENT table Order field total is declared with stored revision 2, and this"
            " space's catalog has stored revision 1; run MIGRATE") in str(err.value)
    # a new revision computes every row again and rebuilds the index on it
    assert run("migrate", "rev2") == [
        2, "true", "drop Order.by_total fill Order.total build Order.by_total"]
    assert run("read", "rev2") == [
        "1:6:pen#2:PEN 2:8:ink#1:INK 3:12:pad#3:PAD",
        "1:6:pen#2:PEN 2:8:ink#1:INK 3:12:pad#3:PAD | by_total range total",
    ]
    with pytest.raises(redis.ResponseError) as err:
        run("migrate", "badfill")
    assert ("MIGRATE table Order field total is a computed float, and its function"
            " answered pen for row 1") in str(err.value)
    # the refused fill left the catalog at revision 2
    assert run("migrate", "rev2")[:2] == [2, "true"]


ERRORS = {
    "set": "LENT table Order field total is computed, so a row cannot set it",
    "setupdate": "LENT table Order field tag is computed, so a row cannot set it",
    "unique": "LENT table Order index by_tag is unique, and row 1 already has tag=pen#2",
}


def test_stored_computed_errors(run):
    assert run("migrate", "")[0] == 1
    assert run("seed", "") == "ok"
    for which, message in ERRORS.items():
        with pytest.raises(redis.ResponseError) as err:
            run("bad", "", which)
        assert message in str(err.value), which
    with pytest.raises(redis.ResponseError) as err:
        run("badwrite", "badwrite")
    assert ("LENT table Order field total is a computed float, and its function answered"
            " many") in str(err.value)
    with pytest.raises(redis.ResponseError) as err:
        run("rawwrite")
    assert ("LENT table Order field total is computed and stored, so writing rows needs"
            " its function; open the client with lent.open(app)") in str(err.value)
