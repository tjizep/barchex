import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Cold keeps its rows in column blocks and Warm in binary rows. Each stage of
# the schema migrates both, and both must then answer the same. The swapped
# stages move Cold to binary rows, or json rows in swapped_json, and Warm to
# column blocks.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local lay = require("lent.LAYOUT")
local f = lent.field

local function total(r) return r.qty * 2 end

local function table_of(stage, name, format, other)
    local has = function(...) return table.find({ ... }, stage) ~= nil end
    local fields = {
        f.string "name", f.int "qty",
        (if has("kinds") then f.float "price" else f.int "price"):optional(),
        (if has("kinds") then f.string "state" else f.enum "state":values("new", "old")):optional(),
        f.string "note":optional(),
    }
    local indexes, edges = {}, {}
    if has("index", "unique") then indexes = { lent.index("qty") } end
    if has("unique") then indexes[2] = lent.index("name"):unique():name("by_name") end
    if has("added", "sized_added", "swapped_added") then
        table.insert(fields, f.int "rank":default(5))
        table.insert(fields, f.string "memo":default("new"))
        table.insert(fields, f.string "extra":optional())
    end
    if has("renamed") then fields[5] = f.string "remark":was("note"):optional() end
    if has("dropped", "sized_dropped") then table.remove(fields, 5) end
    if has("computed") then
        table.insert(fields, f.int "total":computed(total):stored())
        table.insert(fields, f.string "label":computed(function(r)
            return r.name .. "#" .. r.qty
        end):stored())
        indexes = { lent.index("total") }
    end
    if has("edge", "through") then
        edges = { lent.edge.from "shop" "Shop":ref(other):unique() }
    end
    if has("through") then
        table.insert(edges, lent.edge.through "towns" "Town":via "shop.town":stored())
    end
    local policy = has("guarded") and { query = { function(c, v, q)
        q:where(function(r) return r.qty % 2 == 0 end)
    end } } or nil
    -- the block option of the column table: 1024 bytes in the sized stages
    local block = if format ~= "column" then nil
        elseif has("sized", "sized_added", "sized_dropped", "swapped_added") then 1024
        elseif has("resized") then 4096 else nil
    return lent.schema(name) { id = "int", format = format, block = block, fields = fields,
                               indexes = indexes, edges = edges, policy = policy }
end

local function app(stage)
    local cold, warm = "column", "binary"
    if string.find(stage, "^swapped") then
        cold, warm = if stage == "swapped_json" then "json" else "binary", "column"
    end
    local tables = {
        table_of(stage, "Cold", cold, "colds"), table_of(stage, "Warm", warm, "warms"),
    }
    if stage == "edge" or stage == "through" then
        table.insert(tables, lent.schema "Shop" {
            id = "int", format = "column", fields = { f.string "city" },
            edges = { lent.edge.to "colds" "Cold", lent.edge.to "warms" "Warm",
                      lent.edge.from "town" "Town":ref "shops":unique() },
        })
        table.insert(tables, lent.schema "Town" {
            id = "int", format = "column", fields = { f.string "name" },
            edges = { lent.edge.to "shops" "Shop" },
        })
    end
    return lent.graph(tables)
end

local function show(r)
    local names = {}
    for k in r do names[#names + 1] = k end
    table.sort(names)
    local parts = {}
    for _, n in names do parts[#parts + 1] = n .. "=" .. tostring(r[n]) end
    return table.concat(parts, " ")
end

local function rows(t)
    local out = {}
    for i, r in t:query():order("id"):all() do out[i] = show(r) end
    return out
end

local steps = {}

function steps.seed(c, n)
    for i = 1, n do
        local values = { name = "n" .. i, qty = i % 7, price = i * 3,
                         state = if i % 2 == 0 then "new" else "old",
                         note = if i % 3 == 0 then nil else "note " .. i }
        c.Cold:create(values)
        c.Warm:create(values)
    end
    return "ok"
end

function steps.dump(c) return { rows(c.Cold), rows(c.Warm) } end

function steps.both(c, what, ...)
    return { steps[what](c, c.Cold, ...), steps[what](c, c.Warm, ...) }
end

function steps.by_qty(c, t, qty)
    local out = {}
    for i, r in t:query():where("qty", "=", qty):order("id"):all() do out[i] = r.id end
    return out
end

function steps.by_total(c, t, value)
    local out = {}
    for i, r in t:query():where("total", "=", value):order("id"):all() do out[i] = r.id end
    return out
end

function steps.by_extra(c, t, value)
    return t:query():where("extra", "=", value):count()
end

function steps.by_rank(c, t, value)
    return t:query():where("rank", "=", value):count()
end

function steps.by_label(c, t, value)
    return t:query():where("label", "=", value):first().id
end

function steps.write(c, t, pk)
    t:update(pk, { qty = 100 })
    return show(t:get(pk))
end

function steps.long(c, t, pk)
    t:update(pk, { note = string.rep("long ", 10) .. pk })
    return show(t:get(pk))
end

function steps.delete(c, t, pk)
    return tostring(t:delete(pk))
end

function steps.create(c, t, name, qty)
    return t:create({ name = name, qty = qty }).id
end

function steps.summed(c, t)
    return { t:query():count(), t:query():aggregate({ n = { fn = "sum", field = "price" } }).n }
end

function steps.summed_value(c, t)
    return t:query():aggregate({ n = { fn = "sum", value = function(r)
        return r.total + #r.label
    end } }).n
end

function steps.linked(c)
    local town = c.Town:create { name = "oslo" }
    local shop = c.Shop:create { city = "oslo", town = town }
    c.Cold:link("shop", 1, shop.id)
    c.Warm:link("shop", 1, shop.id)
    return "ok"
end

function steps.towns(c, t, pk)
    local out = {}
    for i, r in t:query():where("id", "=", pk):follow("towns"):all() do out[i] = r.name end
    return out
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
    if step == "blocks" then
        -- how many blocks field id args[1] of Cold holds
        return barch.tx.run(function()
            return lay.walk(lay.column(m.load().tables.cold, args[1]), function() end)
        end)
    end
    if step == "stored" then
        -- Cold's block, store, and the keys under store args[1]
        return barch.tx.run(function()
            local t = m.load().tables.cold
            local from = { key = "cold", store = args[1] }
            return { tostring(t.block), tostring(t.store),
                     lay.walk(lay.present(from), function() end)
                         + lay.walk(lay.columns(from), function() end) }
        end)
    end
    if step == "format" then
        -- table args[1]'s format and store, and how many row keys it holds
        return barch.tx.run(function()
            local t = m.load().tables[args[1]]
            return { t.format, tostring(t.store), lay.walk(lay.row(t), function() end) }
        end)
    end
    local db = client.open(app(stage))
    return db.tx(function(c) return steps[step](c, table.unpack(args)) end)
end
"""


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", "colm_" + re.sub(r"\W", "_", request.node.name))
    client.execute_command("SETF", "COLM", APP)
    return lambda step, stage, *a: client.execute_command("CALLF", "COLM", step, stage, *a)


def migrate(run, stage, page=1000):
    """Runs the migration to its end and answers how many calls it took."""
    calls = 0
    while True:
        calls += 1
        done = run("migrate", stage, page)[0]
        if done == 1:
            return calls


def same_rows(run, stage):
    cold, warm = run("dump", stage)
    assert cold == warm
    assert cold


def seeded(run, rows=30):
    migrate(run, "base")
    assert run("seed", "base", rows) == "ok"


def test_an_index_builds_from_blocks(run):
    seeded(run, 2500)
    migrate(run, "index")
    cold, warm = run("both", "index", "by_qty", 3)
    assert cold == warm
    assert len(cold) == 357


def test_an_index_builds_in_pages_past_a_block(run):
    seeded(run, 1100)
    assert migrate(run, "index", 256) > 4
    cold, warm = run("both", "index", "by_qty", 3)
    assert cold == warm
    assert len(cold) == 157


def test_rows_written_during_a_paged_build_reach_the_index(run):
    seeded(run, 1100)
    assert run("migrate", "index", 200)[0] == 0
    # a pending migration leaves the rows writable through the same schema
    cold, warm = run("both", "index", "write", 5)
    assert cold == warm
    cold, warm = run("both", "index", "write", 1050)
    assert cold == warm
    migrate(run, "index", 200)
    same_rows(run, "index")
    assert run("both", "index", "by_qty", 100) == [[5, 1050], [5, 1050]]


def test_a_unique_build_finds_duplicates_in_blocks(run):
    seeded(run, 40)
    run("both", "base", "create", "n3", 1)
    with pytest.raises(redis.ResponseError, match="(?i)unique|duplicate"):
        migrate(run, "unique")


def test_a_stored_computed_field_fills_and_indexes(run):
    seeded(run, 1100)
    assert migrate(run, "computed", 300) > 2
    same_rows(run, "computed")
    cold, warm = run("both", "computed", "by_total", 6)
    assert cold == warm
    assert len(cold) == 157
    assert run("both", "computed", "by_label", "n5#5") == [5, 5]
    # a later write computes it again
    cold, warm = run("both", "computed", "write", 5)
    assert cold == warm
    assert "total=200" in cold


def test_a_sum_over_stored_computed_fields_reads_them(run):
    seeded(run, 30)
    migrate(run, "computed")
    cold, warm = run("both", "computed", "summed_value")
    assert cold == warm
    assert cold > 0


def test_a_query_policy_filters_what_a_sum_reads(run):
    seeded(run, 30)
    migrate(run, "base")
    cold, warm = run("both", "guarded", "summed")
    assert cold == warm
    assert cold[0] < 30


def test_an_added_field_answers_its_default(run):
    seeded(run, 30)
    migrate(run, "added")
    same_rows(run, "added")
    assert run("both", "added", "by_rank", 5) == [30, 30]
    assert "memo=new" in run("dump", "added")[0][0]
    assert run("both", "added", "by_extra", "x") == [0, 0]


def test_a_renamed_field_keeps_its_values(run):
    seeded(run, 30)
    migrate(run, "renamed")
    same_rows(run, "renamed")
    assert "remark=note 1" in run("dump", "renamed")[0][0]
    assert run("both", "renamed", "write", 1)[0] == run("both", "renamed", "write", 1)[1]


def test_a_kind_change_keeps_its_values(run):
    seeded(run, 30)
    migrate(run, "kinds")
    same_rows(run, "kinds")
    assert run("both", "kinds", "write", 1)[0] == run("both", "kinds", "write", 1)[1]


def test_a_dropped_field_stays_gone(run):
    seeded(run, 30)
    migrate(run, "dropped")
    same_rows(run, "dropped")
    assert "note" not in run("dump", "dropped")[0][0]
    # the same name comes back empty
    migrate(run, "base")
    same_rows(run, "base")
    assert "note=" not in run("dump", "base")[0][0]


NOTE, QTY = 5, 2


def test_a_dropped_field_takes_its_blocks_in_pages(run):
    seeded(run, 2500)
    assert run("blocks", "base", NOTE) == 3
    done, processed, steps = run("migrate", "dropped", 2)
    assert (done, processed) == (0, 2)
    assert steps == ["drop Cold.note blocks"]
    assert run("blocks", "base", NOTE) == 1
    # writes go on while the blocks leave
    cold, warm = run("both", "dropped", "write", 2100)
    assert cold == warm
    assert run("migrate", "dropped", 2)[:2] == [1, 1]
    assert run("blocks", "base", NOTE) == 0
    assert run("blocks", "base", QTY) == 3
    same_rows(run, "dropped")


def test_apply_drops_the_blocks_in_one_transaction(run):
    seeded(run, 2500)
    assert run("apply", "dropped") == "ok"
    assert run("blocks", "base", NOTE) == 0
    same_rows(run, "dropped")


@pytest.mark.parametrize("stage", ["renamed", "kinds"])
def test_a_renamed_or_retyped_field_keeps_its_blocks(run, stage):
    seeded(run, 30)
    assert run("migrate", stage)[2] == []
    assert run("blocks", "base", NOTE) == 1


def test_a_stored_path_edge_fills_over_column_tables(run):
    seeded(run, 30)
    migrate(run, "edge")
    assert run("linked", "edge") == "ok"
    migrate(run, "through")
    assert run("both", "through", "towns", 1) == [["oslo"], ["oslo"]]


@pytest.mark.parametrize("schema, want", [
    ('lent.schema "U" { id = "uuid", format = "column", fields = {} }',
     'has format column, which needs id = "int"'),
    ('lent.schema "U" { format = "column", fields = {} }',
     'has format column, which needs id = "int"'),
])
def test_a_column_table_needs_int_ids(client, schema, want):
    setup(client)
    client.execute_command("USE", "colm_uuid")
    client.execute_command("SETF", "COLMU", 'local lent = require("lent.SCHEMA")\n'
                           "function call() lent.graph { " + schema + " } return 1 end")
    with pytest.raises(redis.ResponseError, match=re.escape(want)):
        client.execute_command("CALLF", "COLMU")


COPY = ["copy Cold blocks", "drop Cold old blocks"]


def test_a_block_change_copies_rows_in_pages(run):
    seeded(run, 2500)
    old = run("stored", "base", "cold")[2]
    done, processed, steps = run("migrate", "sized", 1000)
    assert (done, processed, steps) == (0, 1000, COPY)
    # rows stay readable and writable while the copy runs: one it copied,
    # one it has not reached, a new one, and deletes on both sides
    for pk in (5, 2400):
        cold, warm = run("both", "sized", "write", pk)
        assert cold == warm
    assert run("both", "sized", "create", "late", 3) == [2501, 2501]
    assert run("both", "sized", "delete", 7) == ["true", "true"]
    assert run("both", "sized", "delete", 2300) == ["true", "true"]
    same_rows(run, "sized")
    assert migrate(run, "sized", 1000) == 2
    same_rows(run, "sized")
    assert run("both", "sized", "by_qty", 100) == [[5, 2400], [5, 2400]]
    block, store, kept = run("stored", "sized", "cold")
    assert (block, store, kept) == ("1024", "cold@2", 0)
    assert old > 0 and run("stored", "sized", "cold@2")[2] > 0


def test_a_block_change_goes_back_to_fixed_blocks(run):
    seeded(run, 1100)
    migrate(run, "sized", 300)
    migrate(run, "base", 300)
    same_rows(run, "base")
    assert run("stored", "base", "cold@2")[:2] == ["nil", "cold@3"]
    assert run("stored", "base", "cold@2")[2] == 0
    cold, warm = run("both", "base", "write", 1050)
    assert cold == warm


def test_a_block_change_keeps_long_text(run):
    seeded(run, 1100)
    migrate(run, "sized")
    for pk in (3, 1000):
        run("both", "sized", "long", pk)
    assert run("migrate", "resized", 500)[0] == 0
    # one long value the copy reached and one it has not
    for pk in (4, 1001):
        cold, warm = run("both", "resized", "long", pk)
        assert cold == warm
    migrate(run, "resized", 500)
    same_rows(run, "resized")
    assert run("stored", "resized", "cold@2")[2] == 0


@pytest.mark.parametrize("stage, steps", [
    ("sized_added", COPY), ("sized_dropped", ["drop Cold.note blocks"] + COPY)])
def test_a_block_change_with_field_changes(run, stage, steps):
    seeded(run, 1100)
    assert run("migrate", stage, 400)[2] == steps
    migrate(run, stage, 400)
    same_rows(run, stage)
    assert run("stored", stage, "cold")[2] == 0
    if stage == "sized_added":
        assert run("both", stage, "by_rank", 5) == [1100, 1100]
        cold, warm = run("both", stage, "write", 9)
        assert cold == warm
    else:
        assert "note" not in run("dump", stage)[0][0]


def test_a_schema_change_waits_for_the_copy(run):
    seeded(run, 1100)
    assert run("migrate", "sized", 300)[0] == 0
    with pytest.raises(redis.ResponseError, match="a migration is in progress"):
        run("migrate", "resized", 300)
    migrate(run, "sized", 300)
    same_rows(run, "sized")


def test_apply_changes_the_block_in_one_transaction(run):
    seeded(run, 1100)
    assert run("apply", "sized") == "ok"
    same_rows(run, "sized")
    assert run("stored", "sized", "cold")[:3] == ["1024", "cold@2", 0]


MOVE = ["copy Cold rows", "copy Warm blocks", "drop Cold old blocks", "drop Warm old rows"]


def test_a_format_change_copies_rows_in_pages(run):
    seeded(run, 2500)
    done, processed, steps = run("migrate", "swapped", 1000)
    assert (done, processed, steps) == (0, 1000, MOVE)
    # rows stay readable and writable while the copy runs: one it copied,
    # one it has not reached, a new one, and deletes on both sides
    for pk in (5, 2400):
        cold, warm = run("both", "swapped", "write", pk)
        assert cold == warm
    assert run("both", "swapped", "create", "late", 3) == [2501, 2501]
    assert run("both", "swapped", "delete", 7) == ["true", "true"]
    assert run("both", "swapped", "delete", 2300) == ["true", "true"]
    same_rows(run, "swapped")
    migrate(run, "swapped", 1000)
    same_rows(run, "swapped")
    assert run("both", "swapped", "by_qty", 100) == [[5, 2400], [5, 2400]]
    assert run("format", "swapped", "cold") == ["binary", "nil", 2499]
    assert run("stored", "swapped", "cold")[2] == 0
    assert run("format", "swapped", "warm") == ["column", "warm@2", 0]


@pytest.mark.parametrize("stage", ["swapped", "swapped_json", "swapped_added"])
def test_a_format_change_goes_both_ways(run, stage):
    seeded(run, 1100)
    for pk in (3, 1000):
        run("both", "base", "long", pk)
    migrate(run, stage, 300)
    same_rows(run, stage)
    assert run("format", stage, "cold")[0] == ("json" if stage == "swapped_json" else "binary")
    if stage == "swapped_added":
        assert run("both", stage, "by_rank", 5) == [1100, 1100]
    cold, warm = run("both", stage, "write", 9)
    assert cold == warm
    migrate(run, "base", 300)
    same_rows(run, "base")
    assert run("format", "base", "cold") == ["column", "cold@3", 0]
    assert run("format", "base", "warm") == ["binary", "nil", 1100]
    assert run("stored", "base", "warm@2")[2] == 0
    cold, warm = run("both", "base", "long", 1050)
    assert cold == warm


def test_apply_changes_the_format_in_one_transaction(run):
    seeded(run, 1100)
    assert run("apply", "swapped") == "ok"
    same_rows(run, "swapped")
    assert run("format", "swapped", "cold") == ["binary", "nil", 1100]
    assert run("format", "swapped", "warm") == ["column", "warm@2", 0]
    assert run("stored", "swapped", "cold")[2] == 0
