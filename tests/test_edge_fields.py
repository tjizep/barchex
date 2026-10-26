import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Users like posts; each like stores when it happened, a weight and an
# optional note. Users follow users without fields.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

local clock = 100

local function app(version)
    local likes = lent.edge.to "likes" "Post"
    if version ~= "plain" then
        local fields = {
            -- optional, so links stored before the edge had fields can read it
            lent.field.time "at":optional():default(function() clock += 1; return clock end)
                :immutable(),
            lent.field.int "weight":default(1):min(1),
            lent.field.string "note":optional():validate(function(v) return v ~= "spam" end),
        }
        if version == "more" then
            table.insert(fields, lent.field.bool "seen":default(false))
        elseif version == "required" then
            table.insert(fields, lent.field.bool "seen")
        end
        likes = likes:fields(fields)
    end
    return lent.graph {
        lent.schema "User" {
            id = "int",
            fields = { lent.field.string "name" },
            edges = { likes, lent.edge.to "follows" "User" },
        },
        lent.schema "Post" {
            id = "int",
            fields = { lent.field.string "title" },
            edges = { lent.edge.from "likers" "User":ref "likes" },
        },
    }
end

local function show(v)
    if v == nil then return "nil" end
    local keys = {}
    for k in v do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in keys do parts[#parts + 1] = k .. "=" .. tostring(v[k]) end
    return table.concat(parts, " ")
end

local function titles(list)
    local out = {}
    for _, p in list do out[#out + 1] = p.title .. "@" .. show(p._edge) end
    return table.concat(out, ", ")
end

local steps = {}

function steps.seed(c)
    local ann = c.User:create { name = "ann" }
    local bob = c.User:create { name = "bob" }
    local a = c.Post:create { title = "a", likers = { ann, bob } }
    local b = c.Post:create { title = "b" }
    c.User:link("likes", ann.id, b.id, { weight = 3, note = "good" })
    c.User:link("follows", bob.id, ann.id)
    return {
        show(c.User:edge("likes", 1, a.id)),
        show(c.User:edge("likes", 2, a.id)),
        show(c.User:edge("likes", 1, b.id)),
        show(c.User:edge("likes", 2, b.id)),
        -- the edge.from reads the same values
        show(c.Post:edge("likers", b.id, 1)),
        show(c.User:edge("follows", 2, 1)),
    }
end

function steps.update(c)
    -- linking again without values keeps the link; with values, sets them
    local same = c.User:link("likes", 1, 2)
    local changed = c.User:link("likes", 1, 2, { weight = 5 })
    return { show(same), show(changed), show(c.User:edge("likes", 1, 2)) }
end

function steps.queries(c)
    local u = c.User:query():where("name", "=", "ann"):withLikes():first()
    local heavy = c.User:query():hasLikesWith(function(q)
        return q:whereEdge("weight", ">=", 3)
    end):all()
    local noted = c.Post:query():hasLikersWith(function(q)
        return q:whereEdge(function(v) return v.note ~= nil end)
    end):all()
    local light = c.User:query():where("name", "=", "ann"):withLikes(function(q)
        return q:whereEdge("weight", "<", 3):order("title")
    end):first()
    local likers = c.Post:query():where("title", "=", "a"):withLikers():first()
    local names = {}
    for _, r in likers.likers do names[#names + 1] = r.name .. "@" .. r._edge.weight end
    local f = c.User:query():where("name", "=", "bob"):withFollows():first()
    return {
        titles(u.likes),
        #heavy .. " " .. heavy[1].name,
        #noted .. " " .. noted[1].title,
        titles(light.likes),
        table.concat(names, " "),
        tostring(f.follows[1]._edge),
    }
end

function steps.seed_plain(c)
    local ann = c.User:create { name = "ann" }
    c.Post:create { title = "a", likers = { ann } }
    return "ok"
end

function steps.old(c)
    return show(c.User:edge("likes", 1, 1))
end

local bad = {
    field = function(c) c.User:link("likes", 2, 2, { colour = "red" }) end,
    min = function(c) c.User:link("likes", 2, 2, { weight = 0 }) end,
    kind = function(c) c.User:link("likes", 2, 2, { weight = "x" }) end,
    validate = function(c) c.User:link("likes", 2, 2, { note = "spam" }) end,
    immutable = function(c) c.User:link("likes", 1, 1, { at = 5 }) end,
    values = function(c) c.User:link("likes", 2, 2, 7) end,
    plain = function(c) c.User:link("follows", 1, 2, { weight = 1 }) end,
    outside = function(c) c.Post:query():whereEdge("weight", ">", 1) end,
    nofields = function(c) c.User:query():hasFollowsWith(function(q) q:whereEdge("weight", ">", 1) end) end,
    wherekind = function(c) c.User:query():hasLikesWith(function(q) q:whereEdge("weight", "=", "x") end) end,
}

function call(step, version, which)
    version = version ~= "" and version or nil
    if step == "migrate" then
        return m.migrate(app(version)).version
    end
    return client.open(app(version)).tx(function(c)
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
    client.execute_command("USE", "edgef_" + request.node.name)
    client.execute_command("SETF", "LIKES", APP)
    return lambda *a: client.execute_command("CALLF", "LIKES", *a)


def test_edge_fields(run):
    assert run("migrate", "") == 1
    assert run("seed", "") == [
        "at=101 weight=1",
        "at=102 weight=1",
        "at=103 note=good weight=3",
        "nil",
        "at=103 note=good weight=3",
        "",
    ]
    assert run("update", "") == [
        "at=103 note=good weight=3",
        "at=103 note=good weight=5",
        "at=103 note=good weight=5",
    ]
    assert run("queries", "") == [
        "a@at=101 weight=1, b@at=103 note=good weight=5",
        "1 ann",
        "1 b",
        "a@at=101 weight=1",
        "ann@1 bob@1",
        # an edge without fields loads rows without _edge
        "nil",
    ]


def test_edge_field_migrations(run):
    assert run("migrate", "plain") == 1
    assert run("seed_plain", "plain") == "ok"
    # a link stored without fields reads the defaults
    assert run("migrate", "") == 2
    assert run("old", "") == "weight=1"
    assert run("migrate", "") == 2
    with pytest.raises(redis.ResponseError) as err:
        run("migrate", "required")
    assert ("MIGRATE edge user_likes field seen is new, so links stored before it have"
            " no value") in str(err.value)
    assert run("migrate", "more") == 3
    assert run("old", "more") == "seen=false weight=1"


ERRORS = {
    "field": "LENT table User edge likes has no field colour",
    "min": "LENT table User edge likes field weight wants at least 1, got 0",
    "kind": "ROWCODEC field weight wants int, got x",
    "validate": "LENT table User edge likes field note refuses \"spam\"",
    "immutable": "LENT table User edge likes field at is immutable",
    "values": "LENT table User edge likes values must be a table, got 7",
    "plain": "LENT table User edge follows has no fields",
    "outside": "LENT table Post query whereEdge works inside the function given to has or with",
    "nofields": "LENT table User edge follows has no fields",
    "wherekind": "LENT table User edge likes field weight is int, got x",
}


def test_edge_field_errors(run):
    assert run("migrate", "") == 1
    run("seed", "")
    for which, message in ERRORS.items():
        with pytest.raises(redis.ResponseError) as err:
            run("bad", "", which)
        assert message in str(err.value), which
