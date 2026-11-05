import json
import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Task stores a state enum with an index on it and a unique index on
# (title, state). The replace stage removes "old" and rewrites its rows to
# "done"; the narrow stage removes it with no replacement.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local f = lent.field

local function app(stage, format)
    local state = f.enum "state":values("new", "old", "done"):default("new")
    if stage == "replace" then
        state = f.enum "state":values("new", "done"):replaces { old = "done" }:default("new")
    elseif stage == "narrow" then
        state = f.enum "state":values("new", "done"):default("new")
    end
    local kind = f.enum "kind":values("weak", "strong")
    if stage == "edge" then
        kind = f.enum "kind":values("strong"):replaces { weak = "strong" }
    end
    return lent.graph {
        lent.schema "Task" {
            id = "int", format = format,
            fields = { f.string "title", state, f.int "n" },
            indexes = { lent.index("state"):name("by_state"),
                        lent.index("title", "state"):unique():name("by_title") },
            edges = { lent.edge.to "blocks" "Task":fields { kind } },
        },
    }
end

local steps = {}

function steps.seed(c, n)
    local states = { "new", "old", "done" }
    for i = 1, n do
        c.Task:create { title = "t" .. i, state = states[i % 3 + 1], n = i }
    end
    return "ok"
end

function steps.dup(c)
    c.Task:create { title = "dup", state = "old", n = 0 }
    c.Task:create { title = "dup", state = "done", n = 0 }
    return "ok"
end

function steps.undup(c)
    local r = c.Task:query():where("title", "=", "dup"):where("state", "=", "done"):first()
    c.Task:delete(r.id)
    return "ok"
end

function steps.counts(c)
    local out = {}
    for _, s in { "new", "done" } do
        out[s] = c.Task:query():using("by_state"):where("state", "=", s):count()
    end
    out.all = c.Task:query():count()
    return out
end

-- the states every row answers, by n
function steps.states(c)
    local out = {}
    for _, r in c.Task:query():all() do out[tostring(r.n)] = r.state end
    return out
end

function steps.write(c, state)
    local r = c.Task:create { title = "w" .. state, state = "new", n = -1 }
    local ok, err = pcall(c.Task.update, c.Task, r.id, { state = state })
    return { ok, tostring(err) }
end

function call(step, stage, format, ...)
    local args = { ... }
    for i, a in args do args[i] = tonumber(a) or a end
    if step == "migrate" then
        local r = m.migrate(app(stage, format), args[1])
        return { if r.done then 1 else 0, r.processed, r.steps }
    end
    if step == "apply" then
        barch.tx.run(function() m.apply(m.plan(m.load(), app(stage, format))) end)
        return "ok"
    end
    if step == "replaces" then
        local tasks = m.load().tables.task
        return simdjson.encode(tasks and tasks.fields[2].replaces or {})
    end
    local db = client.open(app(stage, format))
    return simdjson.encode(db.tx(function(c) return steps[step](c, table.unpack(args)) end))
end
"""

FORMATS = ["binary", "json", "column"]
STEPS = ["drop Task.by_state", "drop Task.by_title", "fill Task.state",
         "build Task.by_state", "build Task.by_title"]


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", "enumrep_" + re.sub(r"\W", "_", request.node.name))
    client.execute_command("SETF", "ENUMREP", APP)
    return lambda step, stage, fmt, *a: client.execute_command("CALLF", "ENUMREP", step, stage,
                                                               fmt, *a)


def migrate(run, stage, fmt, page=1000):
    """Runs the migration to its end and answers how many calls it took."""
    calls = 0
    while True:
        calls += 1
        done, _, steps = run("migrate", stage, fmt, page)
        if done == 1:
            return calls, steps


def seeded(run, fmt, rows=30):
    migrate(run, "base", fmt)
    assert run("seed", "base", fmt, rows) == '"ok"'


def decode(answer):
    return json.loads(answer)


@pytest.mark.parametrize("fmt", FORMATS)
def test_a_removed_choice_is_rewritten_in_pages_and_indexes_are_rebuilt(run, fmt):
    seeded(run, fmt)
    before = decode(run("states", "base", fmt))
    calls, steps = migrate(run, "replace", fmt, 4)
    assert steps == STEPS
    assert calls > 30 // 4
    after = decode(run("states", "replace", fmt))
    assert after == {k: ("done" if v == "old" else v) for k, v in before.items()}
    assert decode(run("counts", "replace", fmt)) == {"new": 10, "done": 20, "all": 30}
    assert decode(run("replaces", "replace", fmt)) == {}
    # the replaces map may stay in the schema; a second run changes nothing
    assert run("migrate", "replace", fmt) == [1, 0, []]


@pytest.mark.parametrize("fmt", FORMATS)
def test_rows_keep_the_removed_choice_until_the_fill_reaches_them(run, fmt):
    seeded(run, fmt)
    # the first page drops both indexes' 60 entries and fills one row
    done, processed, steps = run("migrate", "replace", fmt, 61)
    assert (done, processed, steps) == (0, 61, STEPS)
    assert decode(run("replaces", "replace", fmt)) == {"old": "done"}
    states = decode(run("states", "replace", fmt))
    assert set(states.values()) == {"new", "old", "done"}
    ok, err = decode(run("write", "replace", fmt, "old"))
    assert not ok and 'wants one of ["new","done"]' in err
    ok, _ = decode(run("write", "replace", fmt, "done"))
    assert ok
    migrate(run, "replace", fmt, 12)
    assert "old" not in decode(run("states", "replace", fmt)).values()


def test_apply_rewrites_a_removed_choice_in_one_transaction(run):
    seeded(run, "binary")
    assert run("apply", "replace", "binary") == "ok"
    assert decode(run("counts", "replace", "binary")) == {"new": 10, "done": 20, "all": 30}
    assert decode(run("replaces", "replace", "binary")) == {}
    assert run("migrate", "replace", "binary") == [1, 0, []]


def test_a_replacement_that_duplicates_a_unique_value_stops_the_build(run):
    seeded(run, "binary")
    assert run("dup", "base", "binary") == '"ok"'
    with pytest.raises(redis.ResponseError, match="index by_title is unique"):
        migrate(run, "replace", "binary")
    assert run("undup", "replace", "binary") == '"ok"'
    migrate(run, "replace", "binary")
    assert decode(run("counts", "replace", "binary"))["done"] == 21


def test_removing_a_choice_without_a_replacement_is_refused(run):
    seeded(run, "binary")
    with pytest.raises(redis.ResponseError, match='field state removes enum value "old";'
                       " name the choice its rows take with :replaces"):
        run("migrate", "narrow", "binary")
    assert decode(run("replaces", "base", "binary")) == {}


def test_removing_a_choice_from_an_edge_field_is_refused(run):
    migrate(run, "base", "binary")
    with pytest.raises(redis.ResponseError, match='field kind removes enum value "weak",'
                       " which stored links may hold"):
        run("migrate", "edge", "binary")


@pytest.mark.parametrize("field, error", [
    ('f.string "s":replaces { a = "b" }', "field s is a string field, which takes no replaces"),
    ('f.enum "s":values("a"):replaces("a")', "replaces takes a table of removed choice = choice,"
                                             " got string"),
    ('f.enum "s":values("a"):replaces { [1] = "a" }', "replaces needs removed choices that are"
                                                      " non-empty UTF-8 strings, got 1"),
    ('f.enum "s":values("a", "b"):replaces { a = "b" }', 'replaces "a", which is still one of'
                                                         " its values"),
    ('f.enum "s":values("a"):replaces { b = "c" }', 'replaces "b" with c, which is not one of'
                                                    " its values"),
])
def test_the_schema_checks_replaces(client, field, error):
    setup(client)
    name = "ENUMREPS" + str(abs(hash(field)))
    client.execute_command("USE", "enumrep_schema")
    client.execute_command("SETF", name, f"""
local lent = require("lent.SCHEMA")
local f = lent.field
function call()
    lent.graph {{ lent.schema "T" {{ id = "int", fields = {{ {field} }} }} }}
    return "ok"
end
""")
    with pytest.raises(redis.ResponseError, match="SCHEMA .*" + re.escape(error)):
        client.execute_command("CALLF", name)
