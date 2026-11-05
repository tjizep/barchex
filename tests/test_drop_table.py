import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Session keeps binary rows and Log column blocks; both have indexes, edges,
# a counter and statistics. The dropped stage names both with lent.drop, the
# missing stage leaves them out, and the again stage declares them anew.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local lay = require("lent.LAYOUT")
local kc = require("lent.KEYCODEC")
local f = lent.field

local function app(stage)
    local user_edges = {}
    local list = {}
    local declared = stage == "base" or stage == "again" or stage == "both"
    if declared then
        user_edges = { lent.edge.to "sessions" "Session" }
        list = {
            lent.schema "Session" {
                id = "int", fields = { f.string "token":unique(), f.int "at" },
                indexes = { lent.index("at") },
                edges = { lent.edge.from "user" "User":ref "sessions":unique() },
            },
            lent.schema "Log" {
                id = "int", format = "column", block = 1024,
                fields = { f.string "line", f.int "level" },
                indexes = { lent.index("level") },
                edges = { lent.edge.to "keeps" "Keep" },
            },
        }
    end
    if stage == "dropped" or stage == "both" then
        table.insert(list, lent.drop "Session")
        table.insert(list, lent.drop "Log")
    end
    table.insert(list, lent.schema "User" {
        id = "int", fields = { f.string "email":unique(), f.int "age" },
        indexes = { lent.index("age") }, edges = user_edges,
    })
    table.insert(list, lent.schema "Keep" { id = "int", fields = { f.string "name" } })
    return lent.graph(list)
end

local steps = {}

function steps.seed(c, n)
    for i = 1, n do
        local u = c.User:create { email = "u" .. i, age = i % 9 }
        local k = c.Keep:create { name = "k" .. i }
        local s = c.Session:create { token = "t" .. i, at = i }
        c.Session:link("user", s.id, u.id)
        local l = c.Log:create { line = string.rep("x", 1 + i % 300), level = i % 4 }
        c.Log:link("keeps", l.id, k.id)
    end
    return "ok"
end

function steps.fresh(c)
    local s = c.Session:create { token = "new", at = 1 }
    local l = c.Log:create { line = "new", level = 1 }
    return { s.id, l.id, c.Session:query():count(), c.Log:query():count() }
end

function steps.kept(c)
    return { c.User:query():count(), c.User:query():where("age", "=", 3):count(),
             c.Keep:query():count() }
end

-- the keys that Session and Log own, and every key in the space
local function counts()
    local n = 0
    for _, key in { "session", "log" } do
        local t = { key = key }
        local unique, plain = lay.indexes(t)
        for _, prefix in { lay.row(t), lay.present(t), lay.columns(t), unique, plain,
                           lay.counter(t), lay.stats(t) } do
            n += lay.walk(prefix, function() end)
        end
    end
    for _, store in { "user_sessions", "log_keeps" } do
        for _, prefix in { lay.edge_store({ name = store }) } do
            n += lay.walk(prefix, function() end)
        end
    end
    return { n, lay.walk("lent.", function() end) }
end

function call(step, stage, ...)
    local args = { ... }
    for i, a in args do args[i] = tonumber(a) or a end
    if step == "migrate" then
        local r = m.migrate(app(stage), args[1])
        return { if r.done then 1 else 0, r.processed, r.steps }
    end
    if step == "apply" then
        barch.tx.run(function() m.apply(m.plan(m.load(), app(stage))) end)
        return "ok"
    end
    if step == "analyze" then
        for _, name in { "Session", "Log", "User" } do m.analyze(name) end
        return "ok"
    end
    if step == "keys" then
        return barch.tx.run(counts)
    end
    if step == "graph" then
        app(stage)
        return "ok"
    end
    local db = client.open(app(stage))
    return db.tx(function(c) return steps[step](c, table.unpack(args)) end)
end
"""

DROPS = ["drop Log", "drop Session", "drop Log.keeps", "drop User.sessions"]


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", "drop_" + re.sub(r"\W", "_", request.node.name))
    client.execute_command("SETF", "DROPT", APP)
    return lambda step, stage, *a: client.execute_command("CALLF", "DROPT", step, stage, *a)


def migrate(run, stage, page=1000):
    """Runs the migration to its end and answers how many calls it took."""
    calls = 0
    while True:
        calls += 1
        done, _, steps = run("migrate", stage, page)
        if done == 1:
            return calls, steps


def seeded(run, rows=40):
    migrate(run, "base")
    assert run("seed", "base", rows) == "ok"
    assert run("analyze", "base") == "ok"
    owned, total = run("keys", "base")
    assert owned > 0
    return owned, total


def test_a_dropped_table_goes_in_pages(run):
    owned, total = seeded(run)
    kept = run("kept", "base")
    calls, steps = migrate(run, "dropped", 7)
    assert steps == DROPS
    assert calls > owned // 7
    assert run("keys", "dropped") == [0, total - owned]
    assert run("kept", "dropped") == kept


def test_apply_drops_a_table_in_one_transaction(run):
    owned, total = seeded(run)
    assert run("apply", "dropped") == "ok"
    assert run("keys", "dropped") == [0, total - owned]


def test_a_dropped_table_declared_again_starts_empty(run):
    seeded(run)
    migrate(run, "dropped")
    # the drop entry stays until it is removed; a second run changes nothing
    done, processed, steps = run("migrate", "dropped")
    assert (done, processed, steps) == (1, 0, [])
    migrate(run, "again")
    assert run("fresh", "again") == [1, 1, 1, 1]


def test_a_missing_table_is_refused(run):
    owned, total = seeded(run)
    with pytest.raises(redis.ResponseError, match="table Log is missing from the schema;"
                       " declare it, or name it with lent.drop"):
        run("migrate", "missing")
    assert run("keys", "base") == [owned, total]


def test_a_table_cannot_be_declared_and_dropped(run):
    with pytest.raises(redis.ResponseError, match="table Session is declared and dropped"):
        run("graph", "both")
