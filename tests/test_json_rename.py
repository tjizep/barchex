import json
import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Doc stores json rows with an index on title. The renamed stage renames
# title to headline; the binary stage also moves the table to binary rows.
# The nonote stage drops note, the intnote stage adds an int note again, and
# the renote stage renames title to the dropped name note.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local lay = require("lent.LAYOUT")
local f = lent.field

local NAMES = { renamed = "headline", binary = "headline", renote = "note" }

local function app(stage)
    local name = NAMES[stage] or "title"
    local title = f.string(name)
    if name ~= "title" then title:was("title") end
    local fields = { title, f.int "n" }
    if stage == "base" or stage == "renamed" or stage == "binary" then
        table.insert(fields, f.string "note":optional())
    elseif stage == "intnote" then
        table.insert(fields, f.int "note":optional())
    end
    return lent.graph {
        lent.schema "Doc" {
            id = "int", format = if stage == "binary" then "binary" else "json",
            fields = fields,
            indexes = { lent.index(name):name("by_title") },
        },
    }
end

local steps = {}

function steps.seed(c, n)
    for i = 1, n do c.Doc:create { title = "t" .. i, n = i, note = "s" .. i } end
    return "ok"
end

-- each row's note, by n, after a create that sets an int note
function steps.notes(c)
    c.Doc:create { title = "new", n = 0, note = 5 }
    local out = {}
    for _, r in c.Doc:query():all() do out[tostring(r.n)] = r.note or false end
    return out
end

-- each row's title, by n, and how many rows the index finds for t1
function steps.titles(c, name)
    local out = {}
    for _, r in c.Doc:query():all() do out[tostring(r.n)] = r[name] end
    -- while the index builds, `using` raises and hits is false
    local ok, hits = pcall(function()
        return c.Doc:query():using("by_title"):where(name, "=", "t1"):count()
    end)
    return { out, ok and hits }
end

function steps.touch(c, id)
    c.Doc:update(id, { headline = "touched" })
    return "ok"
end

-- how many stored rows still name title, and the formats rows are stored in
local function raw()
    local old, formats = 0, {}
    lay.walk(lay.row({ key = "doc" }), function(k)
        local v = barch.store.get(k)
        if string.find(v, '"title"', 1, true) then old += 1 end
        formats[string.sub(v, 1, 1)] = true
    end)
    local list = {}
    for lead in formats do table.insert(list, lead) end
    table.sort(list)
    return { old, table.concat(list) }
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
    if step == "renames" then
        return tostring(m.load().tables.doc.fields[1].renames)
    end
    if step == "raw" then
        return barch.tx.run(raw)
    end
    local db = client.open(app(stage))
    return simdjson.encode(db.tx(function(c) return steps[step](c, table.unpack(args)) end))
end
"""

STEPS = ["drop Doc.by_title", "fill Doc.headline", "build Doc.by_title"]


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", "jsonren_" + re.sub(r"\W", "_", request.node.name))
    client.execute_command("SETF", "JSONREN", APP)
    return lambda step, stage, *a: client.execute_command("CALLF", "JSONREN", step, stage, *a)


def migrate(run, stage, page=1000):
    """Runs the migration to its end and answers how many calls it took."""
    calls = 0
    while True:
        calls += 1
        done, _, steps = run("migrate", stage, page)
        if done == 1:
            return calls, steps


def seeded(run, rows=30):
    migrate(run, "base")
    assert run("seed", "base", rows) == '"ok"'
    titles, hits = json.loads(run("titles", "base", "title"))
    assert hits == 1
    return titles


def test_a_json_field_rename_rewrites_rows_in_pages(run):
    titles = seeded(run)
    assert run("raw", "base") == [30, "{"]
    calls, steps = migrate(run, "renamed", 4)
    assert steps == STEPS
    assert calls > 30 // 4
    assert json.loads(run("titles", "renamed", "headline")) == [titles, 1]
    assert run("raw", "renamed") == [0, "{"]
    assert run("renames", "renamed") == "nil"
    # the :was entry may stay in the schema; a second run changes nothing
    assert run("migrate", "renamed") == [1, 0, []]


def test_rows_read_the_new_name_before_the_fill_reaches_them(run):
    titles = seeded(run)
    # the first page drops the index's 30 entries and rewrites one row
    assert run("migrate", "renamed", 31) == [0, 31, STEPS]
    assert run("renames", "renamed") == "title"
    assert run("raw", "renamed") == [29, "{"]
    assert json.loads(run("titles", "renamed", "headline")) == [titles, False]
    # a write to a row the fill has not reached stores it with the new name
    assert run("touch", "renamed", 30) == '"ok"'
    assert run("raw", "renamed") == [28, "{"]
    migrate(run, "renamed", 4)
    titles["30"] = "touched"
    assert json.loads(run("titles", "renamed", "headline")) == [titles, 1]
    assert run("raw", "renamed") == [0, "{"]


def test_apply_renames_a_json_field_in_one_transaction(run):
    titles = seeded(run)
    assert run("apply", "renamed") == "ok"
    assert json.loads(run("titles", "renamed", "headline")) == [titles, 1]
    assert run("raw", "renamed") == [0, "{"]
    assert run("renames", "renamed") == "nil"


def test_a_rename_with_a_move_to_binary_rewrites_rows_as_binary(run):
    titles = seeded(run)
    calls, steps = migrate(run, "binary", 7)
    assert steps == STEPS
    assert json.loads(run("titles", "binary", "headline")) == [titles, 1]
    assert run("raw", "binary") == [0, "b"]

