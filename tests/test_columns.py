import json
import random
import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Sale keeps its rows in column blocks and Plain in binary rows. The same
# calls on both must answer the same, which holds a column table to what the
# row formats already do.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local col = require("lent.COLUMNS")
local VALUES = require("lent.VALUES")
local f = lent.field

local function fields()
    return {
        f.string "region", f.int "qty", f.float "score":optional(),
        f.decimal "amount":scale(2):optional(), f.bool "paid":optional(),
        f.time "at":optional(), f.enum "state":values("new", "done"):optional(),
        f.json "tags":optional(), f.bytes "raw":optional(), f.string "note":optional(),
        f.int "rank":default(7):optional(),
    }
end

local function indexes()
    return { lent.index("region"), lent.index("qty"), lent.index("note"):unique() }
end

local app = lent.graph {
    lent.schema "Sale" {
        id = "int", format = "column", fields = fields(), indexes = indexes(),
        edges = { lent.edge.from "shop" "Shop":ref "sales":unique() },
    },
    lent.schema "Plain" {
        id = "int", format = "binary", fields = fields(), indexes = indexes(),
        edges = { lent.edge.from "shop" "Shop":ref "plains":unique() },
    },
    lent.schema "Shop" {
        id = "int", format = "column", fields = { f.string "city" },
        edges = { lent.edge.to "sales" "Sale", lent.edge.to "plains" "Plain" },
    },
}
local db = client.open(app)


-- a value as text, so Python compares rows whole
local function show(v)
    if type(v) == "table" then return simdjson.encode(v) end
    return tostring(v)
end

local function row_text(r)
    if r == nil then return "nil" end
    local names = {}
    for k in r do names[#names + 1] = k end
    table.sort(names)
    local parts = {}
    for _, n in names do parts[#parts + 1] = n .. "=" .. show(r[n]) end
    return table.concat(parts, " ")
end

local function rows_text(list)
    local out = {}
    for i, r in list do out[i] = row_text(r) end
    return out
end

local function err(fn)
    local ok, e = pcall(fn)
    if ok then return "no error" end
    return tostring(e)
end

local steps = {}

function steps.write(c, tname, op, id, values)
    local t = c[tname]
    local v = VALUES.parse_json(values)
    if op == "create" then
        v.id = id
        return row_text(t:create(v))
    elseif op == "update" then
        return row_text(t:update(id, v))
    elseif op == "clear" then
        return row_text(t:update(id, {}, { v }))
    end
    return tostring(t:delete(id))
end

function steps.get(c, tname, id)
    return row_text(c[tname]:get(id))
end

-- each query answers text for its rows, count or aggregate
local cases = {}
local SPEC = {
    n = { fn = "count" }, qty = { fn = "sum", field = "qty" },
    score = { fn = "avg", field = "score" }, low = { fn = "min", field = "note" },
    regions = { fn = "count", field = "region", distinct = true },
}
function cases.all(t) return rows_text(t:query():all()) end
function cases.desc(t) return rows_text(t:query():order("id", "desc"):all()) end
function cases.top(t) return rows_text(t:query():order("id", "desc"):limit(3):all()) end
function cases.first(t) return rows_text(t:query():limit(2):offset(1):all()) end
function cases.ranged(t) return rows_text(t:query():where("id > 5 and id <= 1500"):all()) end
function cases.back(t)
    return rows_text(t:query():where("id >= 2"):where("id", "<", 2100):order("id", "desc"):all())
end
function cases.spans(t) return rows_text(t:query():where("id < 3 or id > 2040"):all()) end
function cases.one(t) return rows_text(t:query():where("id", "=", 3):all()) end
function cases.region(t) return rows_text(t:query():where("region", "=", "n"):all()) end
function cases.qty(t) return rows_text(t:query():where("qty", ">=", 3):order("qty"):all()) end
function cases.expr(t) return rows_text(t:query():where("qty * 2 > 5 and region ~= 'e'"):all()) end
function cases.fn(t)
    return rows_text(t:query():where(function(r) return r.score ~= nil end):all())
end
function cases.count(t) return t:query():count() end
function cases.countIds(t) return t:query():where("id", ">", 1000):count() end
function cases.countExpr(t) return t:query():where("qty + 1 > 3"):count() end
function cases.aggregate(t) return row_text(t:query():aggregate(SPEC)) end
function cases.grouped(t) return rows_text(t:query():groupBy("region"):aggregate(SPEC)) end
function cases.value(t)
    return row_text(t:query():aggregate({ v = { fn = "sum", value = function(r) return r.qty end } }))
end
function cases.defaults(t) return t:query():sum("rank") end
-- filters on fields without an index, which a column table folds by block
local MORE = {
    amount = { fn = "sum", field = "amount" }, mean = { fn = "avg", field = "amount" },
    late = { fn = "max", field = "at" }, least = { fn = "min", field = "score" },
    anyPaid = { fn = "max", field = "paid" }, qtys = { fn = "sum", field = "qty", distinct = true },
    ranks = { fn = "sum", field = "rank" }, firstRaw = { fn = "min", field = "raw" },
    scored = { fn = "count", field = "score" }, n = { fn = "count" },
    states = { fn = "count", field = "state", distinct = true },
}
function cases.scored(t) return t:query():where("score", ">", 2):count() end
function cases.unscored(t) return t:query():where("score", "=", nil):count() end
function cases.unpaid(t) return t:query():where("paid", "~=", true):count() end
function cases.ranked(t) return t:query():where("rank", "=", 7):where("id", "<", 2049):count() end
function cases.filtered(t)
    return row_text(t:query():where("state", "=", "done"):where("at", "<", 5e8):aggregate(MORE))
end
function cases.byPair(t) return rows_text(t:query():groupBy("paid", "state"):aggregate(MORE)) end
function cases.byRank(t)
    return rows_text(t:query():where("raw", ">=", "ab"):groupBy("rank"):aggregate(MORE))
end
function cases.byQty(t)
    return rows_text(t:query():groupBy("qty"):having("n > 1"):order("amount", "desc")
        :aggregate(MORE))
end
function cases.byRaw(t) return rows_text(t:query():groupBy("raw"):aggregate(MORE)) end
function cases.cheap(t) return t:query():where("at", ">=", 3e8):sum("score") end
function cases.early(t) return t:query():where("at", "<", 5e8):sum("score") end
function cases.byBytes(t)
    return rows_text(t:query():groupBy("raw")
        :aggregate({ n = { fn = "count" }, s = { fn = "sum", field = "score" } }))
end
function cases.byRegion(t)
    return rows_text(t:query():where("score", ">", 1):groupBy("region")
        :aggregate({ n = { fn = "count" }, s = { fn = "sum", field = "score" },
                     hi = { fn = "max", field = "at" }, mean = { fn = "avg", field = "qty" } }))
end
function cases.byId(t)
    return rows_text(t:query():where("id", ">", 9):where("id", "<", 2049):groupBy("id")
        :aggregate({ n = { fn = "count" }, s = { fn = "sum", field = "score" } }))
end

function steps.ask(c, tname, name)
    return cases[name](c[tname])
end

-- rows read a page at a time by cursor, either way
function steps.cursors(c, tname, dir, size)
    local t = c[tname]
    local out, cur = {}, nil
    while true do
        local q = t:query():order("id", dir):limit(size)
        if cur then q = q:after(cur) end
        local list = q:all()
        for _, r in list do out[#out + 1] = r.id end
        if #list < size then return out end
        cur = q:cursor(list[#list])
    end
end

-- an aggregate read in pages, as text
function steps.paged(c, tname, size)
    local state, seen = nil, 0
    while true do
        local r = c[tname]:query():aggregatePage(SPEC, state, size)
        seen += 1
        if r.done then return { row_text(r.result), seen } end
        state = r.state
    end
end

-- a grouped aggregate with filters read in pages, as text
function steps.paged_groups(c, tname, size)
    local state, seen, out = nil, 0, {}
    while true do
        local r = c[tname]:query():where("amount", ">", 10):groupBy("state", "paid")
            :aggregatePage(MORE, state, size)
        seen += 1
        for _, g in r.result or {} do out[#out + 1] = row_text(g) end
        if r.done then return { out, seen } end
        state = r.state
    end
end

function steps.update_all(c, tname)
    return c[tname]:query():where("qty", ">", 2):update({ qty = 1 }, { "note" })
end

function steps.delete_all(c, tname)
    return c[tname]:query():where("region", "=", "n"):delete()
end

-- rows from..to with values that vary by id, some of them nil
function steps.fill(c, tname, from, to)
    local rows = {}
    local regions = { "n", "s", "e" }
    for i = tonumber(from), tonumber(to) do
        rows[#rows + 1] = {
            id = i, region = regions[i % 3 + 1], qty = i % 8,
            score = if i % 5 == 0 then nil else i % 40 / 4,
            amount = if i % 2 == 0 then i % 1000 / 4 else nil,
            paid = if i % 3 == 0 then nil else i % 2 == 0,
            at = if i % 4 == 0 then nil else i * 7919 % 1e9,
            state = if i % 7 == 0 then nil elseif i % 2 == 0 then "new" else "done",
            -- values of 0 to 8 bytes, some repeating
            raw = if i % 6 == 0 then nil else string.sub("bytes" .. i, 1, i % 9),
            note = if i % 4 == 1 then nil else "note" .. i,
        }
    end
    c[tname]:createMany(rows)
    return #rows
end

function steps.bulk(c, n, from)
    for i = 1, n do
        c.Sale:create { id = from + i, region = "r" .. i % 3, qty = i }
    end
    return "ok"
end

-- edges and through indexes reach a column row like any other
function steps.edges(c)
    local shop = c.Shop:create { city = "oslo" }
    local a = c.Sale:create { id = 5000, region = "e", qty = 1, shop = shop }
    local b = c.Sale:create { id = 5001, region = "e", qty = 2 }
    local linked = c.Shop:query():where("id", "=", shop.id):follow("sales"):ids()
    local owner = c.Sale:query():where("id", "=", 5000):has("shop"):count()
    local missing = err(function()
        c.Sale:create { id = 5002, region = "e", qty = 2, shop = 99 }
    end)
    return { linked, owner, a.id, b.id, missing }
end

function steps.refused(c)
    c.Sale:create { id = 40, region = "e", qty = 1, note = "held" }
    return {
        err(function() c.Sale:create { id = 40, region = "e", qty = 2 } end),
        err(function() c.Sale:create { id = 41, region = "e", qty = 2, note = "held" } end),
        err(function() c.Sale:create { id = 42, region = "e", qty = 1.5 } end),
        err(function() c.Sale:create { id = 43, qty = 1 } end),
        err(function() c.Sale:create { id = 44, region = "e", qty = 1, state = "bad" } end),
        tostring(c.Sale:get(41)), tostring(c.Sale:get(42)), tostring(c.Sale:get(43)),
    }
end

function steps.rollback(c)
    c.Sale:create { id = 60, region = "e", qty = 1, note = "keep" }
    return "ok"
end

function steps.fail_after_write(c)
    c.Sale:create { id = 61, region = "e", qty = 1, note = "gone" }
    c.Sale:update(60, { note = "lost" })
    c.Sale:delete(60)
    error("stop")
end

-- a keys summary of Sale's blocks, by kind of key
function steps.keys()
    local out = {}
    local t = { key = "sale", id = "int" }
    local lay = require("lent.LAYOUT")
    local kc = require("lent.KEYCODEC")
    local p = lay.present(t)
    out.present = #barch.store.range(p, kc.after(p), 100)
    local cols = "lent.c" .. kc.encode("string", "sale")
    out.fields = #barch.store.range(cols, kc.after(cols), 100)
    local rows = lay.row(t)
    out.rows = #barch.store.range(rows, kc.after(rows), 100)
    return simdjson.encode(out)
end

-- text big enough to pass a block's limit in `n` rows
function steps.huge(c, from, n, size)
    local text = string.rep("x", size)
    for i = 1, n do
        c.Sale:create { id = from + i, region = "e", qty = 1, raw = text }
    end
    return "ok"
end

function steps.huge_update(c, id, size)
    return err(function() c.Sale:update(id, { raw = string.rep("y", size) }) end)
end

function call(step, mode, ...)
    if step == "migrate" then
        return m.migrate(app).version
    end
    if step == "selftest" then
        return col.call()
    end
    local args = { ... }
    for i, a in args do
        args[i] = tonumber(a) or a
    end
    local pess = mode == "pessimistic"
    return db.tx(function(c) return steps[step](c, table.unpack(args)) end, pess)
end
"""


@pytest.fixture(params=["optimistic", "pessimistic"])
def run(client, request):
    setup(client)
    client.execute_command("USE", "cols_" + re.sub(r"\W", "_", request.node.name))
    client.execute_command("SETF", "COLS", APP)
    assert client.execute_command("CALLF", "COLS", "migrate", "") == 1
    mode = request.param
    return lambda step, *a: client.execute_command("CALLF", "COLS", step, mode, *a)


def write_both(run, op, pk, values):
    """Applies a write to both tables and checks they answer alike."""
    text = json.dumps(values)
    a = run("write", "Sale", op, str(pk), text)
    b = run("write", "Plain", op, str(pk), text)
    assert a == b, (op, pk, values)


def same(run, step, *args):
    a = run(step, "Sale", *args)
    b = run(step, "Plain", *args)
    assert a == b, (step, args)
    return a


CASES = ["all", "desc", "top", "first", "ranged", "back", "spans", "one", "region", "qty",
         "expr", "fn", "count", "countIds", "countExpr", "aggregate", "grouped", "value",
         "defaults", "scored", "unscored", "unpaid", "ranked", "filtered", "byPair", "byRank",
         "byQty", "byRaw", "byId", "cheap", "early", "byBytes", "byRegion"]


def seed_row(rng, pk):
    row = {"region": rng.choice("nse"), "qty": rng.randrange(8)}
    if rng.random() < .7:
        row["score"] = rng.randrange(40) / 4
    if rng.random() < .5:
        row["amount"] = rng.randrange(1000) / 4
    if rng.random() < .5:
        row["paid"] = rng.random() < .5
    if rng.random() < .5:
        row["at"] = rng.randrange(10 ** 9)
    if rng.random() < .5:
        row["state"] = rng.choice(["new", "done"])
    if rng.random() < .5:
        row["tags"] = {"n": rng.randrange(5), "list": [1, "a"]}
    if rng.random() < .5:
        row["raw"] = rng.choice(["", "ab", "bytesé"])
    if rng.random() < .5:
        row["note"] = "note%d" % pk
    return row


def test_selftest(run):
    assert run("selftest") == "ok"


# ids chosen to cross blocks, start them and end them, and to end a hex digit
IDS = [1, 2, 3, 9, 10, 15, 16, 17, 1022, 1023, 1024, 1025, 2047, 2048, 2049, 2100, 5000]


@pytest.mark.parametrize("seed", [1, 2])
def test_column_answers_what_binary_answers(run, seed):
    rng = random.Random(seed)
    live = set()
    for pk in rng.sample(IDS, len(IDS)):
        write_both(run, "create", pk, seed_row(rng, pk))
        live.add(pk)
    for case in CASES:
        same(run, "ask", case)
    for _ in range(60):
        pk = rng.choice(IDS)
        step = rng.random()
        if pk in live and step < .35:
            write_both(run, "update", pk, {k: v for k, v in seed_row(rng, pk).items()
                                           if rng.random() < .5})
        elif pk in live and step < .55:
            field = rng.choice(["score", "paid", "tags", "raw", "note", "amount", "state"])
            write_both(run, "clear", pk, field)
        elif pk in live and step < .8:
            write_both(run, "delete", pk, {})
            live.discard(pk)
        elif pk not in live:
            write_both(run, "create", pk, seed_row(rng, pk))
            live.add(pk)
        assert same(run, "get", str(pk)) != "" and same(run, "ask", "all") is not None
    for pk in IDS:
        same(run, "get", str(pk))
    for case in CASES:
        same(run, "ask", case)
    for dir_ in ("asc", "desc"):
        for size in ("1", "3", "7"):
            got = same(run, "cursors", dir_, size)
            assert got == sorted(live, reverse=dir_ == "desc")
    for size in ("1", "4", "1000"):
        same(run, "paged", size)
        same(run, "paged_groups", size)
    same(run, "update_all")
    same(run, "ask", "all")
    same(run, "delete_all")
    same(run, "ask", "all")


def test_full_blocks_answer_what_binary_answers(run):
    # ids 1024 to 3071 fill two blocks, which a fold reads slot by slot
    for lo in range(1, 3101, 500):
        hi = str(min(lo + 499, 3100))
        assert run("fill", "Sale", str(lo), hi) == run("fill", "Plain", str(lo), hi)
    for case in CASES[13:]:
        same(run, "ask", case)
    for size in ("1000", "2000", "5000"):
        same(run, "paged", size)
        same(run, "paged_groups", size)
    write_both(run, "delete", 1500, {})
    for case in ("count", "cheap", "byBytes", "byRegion"):
        same(run, "ask", case)


def test_rows_use_blocks_and_leave_with_their_last_row(run):
    for pk in (1, 2, 1030):
        write_both(run, "create", pk, {"region": "n", "qty": 1, "note": "n%d" % pk})
    # region, qty, rank and note in each of two blocks
    assert json.loads(run("keys")) == {"present": 2, "fields": 8, "rows": 0}
    write_both(run, "delete", 2, {})
    assert json.loads(run("keys")) == {"present": 2, "fields": 8, "rows": 0}
    write_both(run, "delete", 1, {})
    assert json.loads(run("keys")) == {"present": 1, "fields": 4, "rows": 0}
    write_both(run, "delete", 1030, {})
    assert json.loads(run("keys")) == {"present": 0, "fields": 0, "rows": 0}
    assert run("ask", "Sale", "count") == 0


def test_a_cleared_slot_comes_back_empty(run):
    write_both(run, "create", 1, {"region": "n", "qty": 1, "score": 1.5, "raw": "ab"})
    write_both(run, "create", 2, {"region": "s", "qty": 2, "tags": [1]})
    write_both(run, "delete", 1, {})
    write_both(run, "create", 1, {"region": "e", "qty": 3})
    assert "score" not in run("get", "Sale", "1")
    assert "raw" not in run("get", "Sale", "1")
    same(run, "ask", "all")


def test_edges(run):
    linked, owner, a, b, missing = run("edges")
    assert linked == [5000] and owner == 1 and (a, b) == (5000, 5001)
    assert "99" in missing


def test_refused_writes_leave_nothing(run):
    got = run("refused")
    assert "already has a row 40" in got[0]
    assert "unique" in got[1]
    assert "qty wants int" in got[2]
    assert "region" in got[3]
    assert "state" in got[4]
    assert got[5:] == ["nil", "nil", "nil"]


def test_error_rolls_back_block_writes(run):
    assert run("rollback") == "ok"
    with pytest.raises(redis.exceptions.ResponseError, match="stop"):
        run("fail_after_write")
    assert "note=keep" in run("get", "Sale", "60")
    assert run("get", "Sale", "61") == "nil"


def test_a_block_past_the_value_limit_fails_clearly(run):
    # eleven 50,000 byte values fill a block past its limit of 524,032
    assert run("huge", "0", "10", "50000") == "ok"
    with pytest.raises(redis.exceptions.ResponseError, match="in column block 0, and a block holds"):
        run("huge", "10", "1", "50000")
    assert run("get", "Sale", "11") == "nil"
    got = run("huge_update", "1", "80000")
    assert "in column block 0" in got
    # the value that fit stays readable and whole
    assert len(run("get", "Sale", "1")) > 50000


@pytest.mark.parametrize("rows", [1024, 2500])
def test_blocks_fill_in_batches(run, rows):
    done = 0
    while done < rows:
        n = min(100, rows - done)
        assert run("bulk", str(n), str(done)) == "ok"
        done += n
    assert run("ask", "Sale", "count") == rows
    assert json.loads(run("keys"))["present"] == rows // 1024 + 1
