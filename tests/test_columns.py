import json
import random
import re

import pytest

from .conftest import install
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
-- the block option the test gives Sale
local BLOCK = BLOCK_OPTION

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

-- Sale's blocks are the size `block` names, or 1024 rows each with nil
local function graph(block)
    return lent.graph {
        lent.schema "Sale" {
            id = "int", format = "column", block = block, fields = fields(),
            indexes = indexes(), edges = { lent.edge.from "shop" "Shop":ref "sales":unique() },
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
end
local app = graph(BLOCK)
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
-- the first rows in the order of a field, which a column table finds by
-- keeping that many as it reads, then by cursor pages; o_region and so on
for _, field in { "region", "state", "score", "paid", "raw", "rank", "note", "at" } do
    cases["o_" .. field] = function(t)
        local out = {}
        local function add(q)
            out[#out + 1] = table.concat(rows_text(q:all()), ";")
        end
        for _, dir in { "asc", "desc" } do
            for _, size in { 1, 5, 40, 90 } do
                add(t:query():order(field, dir):limit(size):offset(size // 5))
            end
            add(t:query():where("score", ">", 2):order(field, dir):limit(7))
            add(t:query():where("qty * 2 > 5"):order(field, dir):limit(3))
            add(t:query():where(function(r) return r.qty ~= 2 end):order(field, dir):limit(4))
        end
        local ids, cur = {}, nil
        for _ = 1, 6 do
            local q = t:query():order(field, "desc"):limit(5)
            if cur then q = q:after(cur) end
            local list = q:all()
            for _, r in list do ids[#ids + 1] = r.id end
            if #list < 5 then break end
            cur = q:cursor(list[#list])
        end
        out[#out + 1] = table.concat(ids, ",")
        return out
    end
end
-- the ends of the order of notes, and the rows of one
function cases.notes(t)
    local out = {}
    for _, dir in { "asc", "desc" } do
        out[#out + 1] = table.concat(rows_text(t:query():order("note", dir):limit(3):all()), ";")
    end
    out[#out + 1] = t:query():where("note", "=", "short"):count()
    return out
end
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

-- folds that barch.vec runs: conditions, keys and aggregates on fields
-- without a default, other than bool, decimal and distinct ones; min and
-- max of text fold the codes of dictionary blocks
local STATS = {
    n = { fn = "count" }, scored = { fn = "count", field = "score" },
    sum = { fn = "sum", field = "score" }, mean = { fn = "avg", field = "score" },
    low = { fn = "min", field = "score" }, high = { fn = "max", field = "at" },
    first = { fn = "min", field = "state" }, last = { fn = "max", field = "region" },
}
function cases.vAll(t) return row_text(t:query():aggregate(STATS)) end
function cases.vIds(t) return row_text(t:query():where("id > 5 and id <= 1500"):aggregate(STATS)) end
function cases.vSpans(t) return row_text(t:query():where("id < 3 or id > 2040"):aggregate(STATS)) end
function cases.vRange(t)
    return row_text(t:query():where("at", "<", 5e8):where("score", ">=", 2):aggregate(STATS))
end
function cases.vEq(t) return t:query():where("score", "=", 2.5):count() end
function cases.vNe(t) return t:query():where("score", "~=", 2.5):count() end
function cases.vText(t) return t:query():where("raw", "<", "b"):where("raw", "~=", ""):count() end
function cases.vNoText(t) return t:query():where("note", ">", "note2"):sum("score") end
function cases.vByQty(t) return rows_text(t:query():groupBy("qty"):aggregate(STATS)) end
function cases.vByScore(t) return rows_text(t:query():groupBy("score"):aggregate(STATS)) end
function cases.vByNote(t) return rows_text(t:query():groupBy("note"):aggregate(STATS)) end
function cases.vByState(t)
    return rows_text(t:query():where("state", "~=", "new"):groupBy("state"):aggregate(STATS))
end
-- note blocks hold half the rows of state's in a sized table, so state's
-- chunks start partway into its blocks
function cases.vMixed(t)
    return rows_text(t:query():where("note", ">", "note1"):groupBy("state"):aggregate(STATS))
end
-- min and max of text in plain blocks, some with long values, which fold
-- in Luau, beside one of a dictionary block
function cases.vTextEnds(t)
    return rows_text(t:query():where("score", ">", 1):groupBy("qty"):aggregate({
        n = { fn = "count" }, lo = { fn = "min", field = "raw" }, hi = { fn = "max", field = "note" },
        top = { fn = "max", field = "state" } }))
end
function cases.vMixedText(t)
    return t:query():where("raw", ">=", "by"):where("state", "=", "done"):count()
end
function cases.vPaged(t)
    local out = {}
    for _, size in { 300, 1000, 5000 } do
        local state, pages, r = nil, 0, nil
        repeat
            r = t:query():where("score", ">", 1):groupBy("region"):aggregatePage(STATS, state, size)
            state, pages = r.state, pages + 1
        until r.done
        out[#out + 1] = pages
        out[#out + 1] = rows_text(r.result)
    end
    return out
end

-- region conditions with values stored, absent, and before and after them
function cases.regionOps(t)
    local out = {}
    for _, op in { "=", "~=", "<", "<=", ">", ">=" } do
        for _, w in { "", "a", "e", "f", "n", "s", "t", "z" } do
            out[#out + 1] = t:query():where("region", op, w):count()
        end
    end
    return out
end
-- regions r000 to r299, with values before, among and after them
function cases.manyRegions(t)
    local out = {}
    for _, op in { "=", "~=", "<", "<=", ">", ">=" } do
        for _, w in { "", "r", "r000", "r150", "r1500", "r299", "s" } do
            out[#out + 1] = t:query():where("region", op, w):count()
        end
    end
    return out
end
function cases.byManyRegions(t)
    return rows_text(t:query():where("region", ">", "r100"):groupBy("region"):aggregate(STATS))
end
function cases.vRegion(t)
    return rows_text(t:query():where("region", ">", "e"):where("region", "<=", "s")
        :groupBy("region"):aggregate(STATS))
end

function steps.ask(c, tname, name)
    return cases[name](c[tname])
end

-- case `name` answered with each set of kernels a fold can use: barch.vec
-- when barch has it, lent.VEC, and the Luau loops
function steps.paths(c, tname, name)
    local out = {}
    local was = col.kernels(nil)
    for _, k in { barch.vec or false, require("lent.VEC"), false } do
        col.kernels(k or nil)
        local ok, v = pcall(cases[name], c[tname])
        if not ok then
            col.kernels(was)
            error(v, 0)
        end
        out[#out + 1] = show(v)
    end
    col.kernels(was)
    return out
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
            -- values of 0 to 8 bytes, some repeating, and a long one that
            -- repeats
            raw = if i % 6 == 0 then nil elseif i % 37 == 0 then string.rep("r", 40)
                else string.sub("bytes" .. i, 1, i % 9),
            note = if i % 4 == 1 then nil elseif i % 50 == 0 then string.rep("long", 10) .. i
                else "note" .. i,
        }
    end
    c[tname]:createMany(rows)
    return #rows
end

-- rows from..to of table tname, whose regions repeat every `regions` rows
function steps.spread(c, tname, from, to, regions)
    local rows = {}
    for i = from, to do
        rows[#rows + 1] = { id = i, region = string.format("r%03d", i % regions), qty = i % 8,
                            score = i % 40 / 4, at = i * 7919 % 1e9 }
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

-- how fields' blocks are stored, region's and note's by default: "d" for
-- dictionary blocks with int8 codes, "D" with int16 codes, "t" for plain
-- text, "b" for int8, "h" for int16, "i" for int32 and "n" for f64
-- numbers, and after the letter the parts of a split block
function steps.kinds(_, ...)
    local lay = require("lent.LAYOUT")
    local kc = require("lent.KEYCODEC")
    local t = m.load().tables.sale
    local out = {}
    local names = { ... }
    if #names == 0 then names = { "region", "note" } end
    for _, name in names do
        for _, f in t.fields do
            if f.name == name then
                local p = lay.column(t, f.id)
                local keys, values = barch.store.rangeValues(p, kc.after(p) :: string, 1000)
                local tags = {}
                for i, v in values do
                    -- block keys, past the overflow keys of long values
                    -- and before the keys of parts past the first
                    if string.sub(keys[i], #p + 1, #p + 1) == "i"
                        and not string.find(keys[i], "/", #p + 1, true) then
                        local tag = string.sub(v, 2, 2)
                        if tag == "d" and string.unpack("<I4", v, 9) > 255 then
                            tag = "D"
                        end
                        local parts = string.unpack("<I2", v, 3)
                        tags[tag .. (if parts > 0 then parts else "")] = true
                    end
                end
                local list = {}
                for tag in tags do list[#list + 1] = tag end
                table.sort(list)
                out[#out + 1] = name .. "=" .. table.concat(list)
            end
        end
    end
    return table.concat(out, " ")
end

-- the keys of Sale's split blocks past their first part
function steps.parts()
    local kc = require("lent.KEYCODEC")
    local p = "lent.c" .. kc.encode("string", "sale")
    local n = 0
    for _, k in barch.store.range(p, kc.after(p), 10000) do
        if string.find(k, "/", #p + 1, true) then n += 1 end
    end
    return n
end

-- rows `from` to `to` with a distinct note of `width` digits each
function steps.notes(c, tname, from, to, width)
    local rows = {}
    for i = tonumber(from), tonumber(to) do
        rows[#rows + 1] = { id = i, region = "n", qty = 1,
                            note = string.format("%0" .. width .. "d", i) }
    end
    c[tname]:createMany(rows)
    return #rows
end

-- clears the notes of rows `from` to `to`
function steps.clear_notes(c, tname, from, to)
    for i = tonumber(from), tonumber(to) do
        c[tname]:update(i, {}, { "note" })
    end
    return "ok"
end

-- the rows the catalog keeps for Sale and some of its fields
function steps.catalog()
    local t = m.load().tables.sale
    local out = { tostring(t.block), tostring(t.rows) }
    for _, f in t.fields do
        if f.name == "region" or f.name == "qty" or f.name == "state" or f.name == "raw" then
            out[#out + 1] = f.name .. "=" .. tostring(f.rows)
        end
    end
    return out
end

-- the schemas and migrations a block option refuses
function steps.refused_blocks()
    local function declare(spec)
        return function()
            spec.fields = { f.int "a" }
            lent.schema "Odd" (spec)
        end
    end
    return {
        err(declare { id = "int", block = "htap" }),
        err(declare { id = "int", format = "column", block = "huge" }),
        err(declare { id = "int", format = "column", block = 512 }),
        err(declare { id = "int", format = "column", block = 2048.5 }),
        err(function() m.plan(m.load(), graph(if BLOCK then nil else "scan")) end),
        lent.schema "Fine" { id = "int", format = "column", block = "balanced",
                             fields = { f.int "a" } }.block,
    }
end

-- whether a value longer than a block keeps is stored whole, by id
function steps.long(c, tname, id)
    local lay = require("lent.LAYOUT")
    local t = m.load().tables.sale
    for _, f in t.fields do
        if f.name == "note" then
            return if barch.store.exists(lay.overflow(t, f.id, id)) then 1 else 0
        end
    end
    return 0
end

function call(step, mode, ...)
    if step == "migrate" then
        return m.migrate(app).version
    end
    if step == "catalog" or step == "refused_blocks" then
        return steps[step]()
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


# Sale with blocks of 1024 rows and no header, and with the smallest blocks
# a `block` option asks for, whose field blocks hold 128 to 512 rows. Tests
# of large blocks use `large`, whose text blocks hold 2048 rows.
BLOCKS = {"fixed": "nil", "small": "1024", "large": "16384", "most": "262144"}
MODES = ("optimistic", "pessimistic")


@pytest.fixture(params=[(m, b) for b in ("fixed", "small") for m in MODES],
                ids=lambda p: "-".join(p))
def run(client, request):
    return start(client, request, *request.param)


@pytest.fixture(params=MODES)
def large(client, request):
    return start(client, request, request.param, "large")


@pytest.fixture(params=MODES)
def most(client, request):
    return start(client, request, request.param, "most")


def start(client, request, mode, block):
    setup(client)
    install(client, "lent", "VEC", "lent/vec.luau")
    client.execute_command("USE", "cols_" + re.sub(r"\W", "_", request.node.name))
    client.execute_command("SETF", "COLS", APP.replace("BLOCK_OPTION", BLOCKS[block], 1))
    assert client.execute_command("CALLF", "COLS", "migrate", "") == 1

    def call(step, *a):
        return client.execute_command("CALLF", "COLS", step, mode, *a)
    call.block, call.mode = block, mode
    return call


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
ORDERED = ["o_region", "o_state", "o_score", "o_paid", "o_raw", "o_rank", "o_note", "o_at"]


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
        row["raw"] = rng.choice(["", "ab", "bytesé", "é" * 16, "b" * 33, "c" * 32])
    if rng.random() < .5:
        row["note"] = "note%d" % pk + ("-" * 40 if rng.random() < .3 else "")
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
    for case in CASES + ORDERED:
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
    for case in CASES + ORDERED:
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


VECTOR_CASES = ["vAll", "vIds", "vSpans", "vRange", "vEq", "vNe", "vText", "vNoText",
                "vByQty", "vByScore", "vByNote", "vByState", "vMixed", "vMixedText", "vPaged",
                "vRegion", "regionOps", "vTextEnds"]


def test_vector_kernels_answer_what_luau_loops_answer(run):
    rng = random.Random(3)
    # full blocks, then nils and holes in them
    for lo in range(1, 3101, 500):
        hi = str(min(lo + 499, 3100))
        assert run("fill", "Sale", str(lo), hi) == run("fill", "Plain", str(lo), hi)
    for pk in rng.sample(range(1, 3101), 300):
        write_both(run, "update", pk, {k: v for k, v in seed_row(rng, pk).items()
                                       if k in ("score", "at", "raw", "note", "state")})
    for pk in rng.sample(range(1, 3101), 200):
        write_both(run, "delete", pk, {})
    for case in VECTOR_CASES:
        answers = same(run, "paths", case)
        assert len(set(answers)) == 1, (case, answers)


def test_full_blocks_answer_what_binary_answers(run):
    # ids 1024 to 3071 fill two blocks, which a fold reads slot by slot
    for lo in range(1, 3101, 500):
        hi = str(min(lo + 499, 3100))
        assert run("fill", "Sale", str(lo), hi) == run("fill", "Plain", str(lo), hi)
    for case in CASES[13:] + ORDERED:
        same(run, "ask", case)
    for size in ("1000", "2000", "5000"):
        same(run, "paged", size)
        same(run, "paged_groups", size)
    write_both(run, "delete", 1500, {})
    for case in ("count", "cheap", "byBytes", "byRegion"):
        same(run, "ask", case)


def test_rows_use_blocks_and_leave_with_their_last_row(run):
    # a row of each table in two presence blocks, of 1024 rows either way
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
    if run.block != "fixed":
        pytest.skip("a block of a sized table keeps 33 bytes of each value")
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


def test_the_catalog_keeps_block_rows(run):
    got = run("catalog")
    if run.block == "fixed":
        assert got == ["nil", "nil", "region=nil", "qty=nil", "state=nil", "raw=nil"]
    else:
        # 1024 bytes: 1024 presence bytes, 512 int16s, and dictionaries
        # of 128 rows with half of them values of up to 12 bytes, or of
        # 256 rows with values of up to 4 bytes for the enum
        assert got == ["1024", "1024", "region=128", "qty=512", "state=256", "raw=128"]


def test_block_options_refused(run):
    got = run("refused_blocks")
    assert "sets block, which needs format = \"column\"" in got[0]
    assert "block takes htap, balanced, scan or a whole number of bytes" in got[1]
    assert "got huge" in got[1]
    assert "got 512" in got[2]
    assert "got 2048.5" in got[3]
    assert "table Sale changes block from" in got[4]
    assert got[5] == 8192


def test_field_blocks_leave_with_their_last_row(run):
    if run.block == "fixed":
        pytest.skip("each field block of a fixed table spans its presence block")
    # ids 1 and 200 share a presence block and an int block of 512 rows,
    # and lie in two text blocks of 128 rows
    for pk in (1, 200):
        write_both(run, "create", pk, {"region": "n", "qty": 1, "note": "n%d" % pk})
    assert json.loads(run("keys")) == {"present": 1, "fields": 6, "rows": 0}
    write_both(run, "delete", 200, {})
    assert json.loads(run("keys")) == {"present": 1, "fields": 4, "rows": 0}
    same(run, "ask", "all")


def test_long_text_keeps_its_whole_value(run):
    long = "x" * 40
    write_both(run, "create", 1, {"region": "n", "qty": 1, "note": long})
    write_both(run, "create", 2, {"region": long, "qty": 2, "note": "c" * 33})
    assert run("long", "Sale", "1") == int(run.block != "fixed")
    same(run, "get", "1")
    write_both(run, "update", 1, {"note": "y" * 32})
    assert run("long", "Sale", "1") == 0
    same(run, "get", "1")
    write_both(run, "update", 1, {"note": long + "z"})
    assert run("long", "Sale", "1") == int(run.block != "fixed")
    for case in ("all", "region", "grouped", "byRaw"):
        same(run, "ask", case)
    write_both(run, "delete", 1, {})
    assert run("long", "Sale", "1") == 0
    write_both(run, "clear", 2, "note")
    write_both(run, "delete", 2, {})
    assert json.loads(run("keys")) == {"present": 0, "fields": 0, "rows": 0}


def test_a_long_value_past_the_value_limit_fails_clearly(run):
    if run.block == "fixed":
        pytest.skip("a fixed table keeps whole values in its blocks")
    # a block keeps 33 bytes of each value, so eleven of 50,000 bytes fit
    assert run("huge", "0", "11", "50000") == "ok"
    assert len(run("get", "Sale", "11")) > 50000
    got = run("huge_update", "1", "600000")
    assert "would hold a value of 600000 bytes" in got
    assert len(run("get", "Sale", "1")) > 50000


def test_repeated_text_uses_dictionary_blocks(run):
    if run.block == "fixed":
        pytest.skip("a fixed table keeps its text blocks plain")
    assert run("fill", "Sale", "1", "600") == run("fill", "Plain", "1", "600")
    # three regions repeat; notes differ in nearly every row
    assert run("kinds") == "region=d note=t"
    cases = ("regionOps", "vRegion", "byRegion", "grouped", "region", "vAll", "vByQty",
             "vByState", "o_region", "o_state")
    for case in cases:
        same(run, "ask", case)
    # values before, between and after the stored ones, then a long one,
    # which turns its block plain
    for pk, region in ((5, "a"), (6, "m"), (7, "z"), (8, ""), (70, "x" * 40)):
        write_both(run, "update", pk, {"region": region})
        for case in cases:
            same(run, "ask", case)
    assert run("kinds") == "region=dt note=t"
    # replacing the long value makes its block a dictionary again
    write_both(run, "update", 70, {"region": "x"})
    assert run("kinds") == "region=d note=t"
    # more distinct values than half its rows turn a block plain, and
    # fewer turn it back
    for pk in range(10, 80):
        write_both(run, "update", pk, {"region": "q%02d" % pk})
    assert run("kinds") == "region=dt note=t"
    for case in cases:
        same(run, "ask", case)
    for pk in range(10, 80):
        write_both(run, "update", pk, {"region": "q"})
    assert run("kinds") == "region=d note=t"
    # the last row holding "m" leaves the dictionary with it
    write_both(run, "update", 6, {"region": "n"})
    write_both(run, "delete", 7, {})
    for case in cases:
        same(run, "ask", case)
        answers = same(run, "paths", case)
        assert len(set(answers)) == 1, (case, answers)


def test_dictionary_blocks_past_255_values_take_int16_codes(large):
    run = large
    # 300 regions in 2,048-row blocks, in calls that each stay under the
    # function deadline
    for start in range(1, 3001, 500):
        end = str(start + 499)
        assert run("spread", "Sale", str(start), end, "300") == 500
        assert run("spread", "Plain", str(start), end, "300") == 500
    assert run("kinds", "region") == "region=D"
    cases = ("manyRegions", "byManyRegions", "regionOps", "vRegion", "byRegion", "grouped",
             "vAll", "vByQty", "vByState", "o_region", "o_state")
    for case in cases:
        same(run, "ask", case)
    # a value before, among and after the others moves the codes
    for pk, region in ((5, "a"), (6, "r150x"), (7, "z")):
        write_both(run, "update", pk, {"region": region})
    for case in cases:
        same(run, "ask", case)
    # emptying regions in the second block takes it back to int8 codes
    for pk in range(2048, 3001):
        if pk % 300 >= 200:
            write_both(run, "update", pk, {"region": "r000"})
    assert run("kinds", "region") == "region=Dd"
    for case in cases:
        same(run, "ask", case)
        # every row's state is nil here, and three runs of o_state over
        # 3,000 rows in one call can pass the function deadline
        if case != "o_state":
            answers = same(run, "paths", case)
            assert len(set(answers)) == 1, (case, answers)


def test_small_whole_numbers_use_narrow_blocks(run):
    if run.block == "fixed":
        pytest.skip("a fixed table keeps its number blocks as f64")
    assert run("fill", "Sale", "1", "600") == run("fill", "Plain", "1", "600")
    # qty holds 0 to 7 and rank its default, so each block takes int8s
    assert run("kinds", "qty", "rank") == "qty=b rank=b"
    cases = ("qty", "vByQty", "expr", "countExpr", "byQty", "aggregate", "value",
             "defaults", "byRank", "ranked")
    for case in cases:
        same(run, "ask", case)
    # nil and +-127 stay in int8s
    write_both(run, "clear", 5, "rank")
    for pk, qty in ((6, -127), (7, 127), (8, 0)):
        write_both(run, "update", pk, {"qty": qty})
    for case in cases:
        same(run, "ask", case)
    assert run("kinds", "qty", "rank") == "qty=b rank=b"
    # a value past a width widens its block to int16, int32 or f64; rows 9
    # to 300 share a block, and rows from 512 keep int8s
    for pk, qty, kinds in ((9, 128, "bh"), (300, -32767, "bh"), (10, 40000, "bi"),
                           (11, -2147483647, "bi"), (12, 3000000000, "bn")):
        write_both(run, "update", pk, {"qty": qty})
        assert run("kinds", "qty") == "qty=" + kinds
        for case in cases:
            same(run, "ask", case)
    # a block narrows when its last value past a width goes, by an update,
    # a delete or a cleared field, to the narrowest width its values fit
    for pk, kinds in ((12, "bi"), (11, "bi"), (10, "bh"), (300, "bh")):
        write_both(run, "update", pk, {"qty": 1})
        assert run("kinds", "qty") == "qty=" + kinds
    write_both(run, "delete", 9, {})
    assert run("kinds", "qty") == "qty=b"
    write_both(run, "update", 13, {"qty": 3000000000})
    assert run("kinds", "qty") == "qty=bn"
    write_both(run, "update", 13, {"qty": 1})
    assert run("kinds", "qty") == "qty=b"
    write_both(run, "update", 10, {"rank": 5000000000})
    assert run("kinds", "rank") == "rank=bn"
    for case in cases:
        same(run, "ask", case)
    write_both(run, "clear", 10, "rank")
    assert run("kinds", "rank") == "rank=b"
    # each width's least value marks nil, so it takes the next width
    for qty, kinds in ((-128, "bh"), (-32768, "bi"), (-2147483648, "bn")):
        write_both(run, "update", 14, {"qty": qty})
        assert run("kinds", "qty") == "qty=" + kinds
        for case in cases:
            same(run, "ask", case)
        write_both(run, "update", 14, {"qty": 0})
        assert run("kinds", "qty") == "qty=b"
    write_both(run, "delete", 7, {})
    write_both(run, "create", 2000, {"region": "n", "qty": 70000})
    write_both(run, "create", 2001, {"region": "n", "qty": -2147483648})
    for case in cases:
        same(run, "ask", case)
        answers = same(run, "paths", case)
        assert len(set(answers)) == 1, (case, answers)



def test_int_blocks_split_past_the_value_limit(most):
    run = most
    # 131,072 int8s or int16s fit in one key; as int32s they take 524,296
    # bytes, which split into three parts, and as f64s 1,048,584, which
    # take five
    assert run("fill", "Sale", "1", "600") == run("fill", "Plain", "1", "600")
    assert run("kinds", "qty") == "qty=b"
    cases = ("qty", "vByQty", "expr", "countExpr", "byQty", "aggregate", "value", "all")
    # values either side of the first part's end, and in the last part
    write_both(run, "update", 9, {"qty": 40000})
    for pk, qty in ((65533, 5), (65534, -70000), (131071, 3)):
        write_both(run, "create", pk, {"region": "n", "qty": qty})
    assert run("kinds", "qty") == "qty=i3"
    assert run("parts") == 2
    for pk in (9, 65533, 65534, 131071):
        same(run, "get", str(pk))
    for case in cases:
        same(run, "ask", case)
    for pk, qty in ((32766, 5), (32767, -7000000000)):
        write_both(run, "create", pk, {"region": "n", "qty": qty})
    assert run("kinds", "qty") == "qty=n5"
    assert run("parts") == 4
    write_both(run, "update", 131071, {"qty": 80000})
    for pk in (9, 32766, 32767, 65534, 131071):
        same(run, "get", str(pk))
    for case in cases:
        same(run, "ask", case)
        answers = same(run, "paths", case)
        assert len(set(answers)) == 1, (case, answers)
    # the block narrows to int32 when its last value past 32 bits goes,
    # and takes int8s whole when its last value past +-127 goes
    write_both(run, "update", 32767, {"qty": 2})
    assert run("kinds", "qty") == "qty=i3"
    assert run("parts") == 2
    for case in cases:
        same(run, "ask", case)
    for pk in (9, 65534, 131071):
        write_both(run, "update", pk, {"qty": 2})
    assert run("kinds", "qty") == "qty=b"
    assert run("parts") == 0
    for case in cases:
        same(run, "ask", case)
    # a block that starts with a value past 32 bits starts split, and goes
    # with its parts when its last row leaves
    write_both(run, "create", 200000, {"region": "n", "qty": 9000000000})
    assert run("kinds", "qty") == "qty=bn5"
    assert run("parts") == 4
    same(run, "get", "200000")
    write_both(run, "delete", 200000, {})
    assert run("parts") == 0
    write_both(run, "create", 200000, {"region": "n", "qty": 90000})
    assert run("kinds", "qty") == "qty=bi3"
    assert run("parts") == 2
    same(run, "get", "200000")
    write_both(run, "delete", 200000, {})
    assert run("parts") == 0
    for case in cases:
        same(run, "ask", case)
        answers = same(run, "paths", case)
        assert len(set(answers)) == 1, (case, answers)


def test_text_blocks_split_past_the_value_limit(most):
    run = most
    if run.mode == "pessimistic":
        pytest.skip("filling a block of this size takes a while; one mode covers it")
    # 32,768-row blocks of 40-byte notes, which keep 33 bytes each and turn
    # their block plain, pass the limit after about 11,900 rows. Each write
    # rewrites the block, so 200 rows a call stay under the function deadline.
    for lo in range(1, 12001, 200):
        assert run("notes", "Sale", str(lo), str(lo + 199), "40") == 200
        assert run("notes", "Plain", str(lo), str(lo + 199), "40") == 200
    assert run("kinds", "note") == "note=t3"
    assert run("parts") == 2
    write_both(run, "update", 11000, {"note": "short"})
    write_both(run, "update", 12, {"note": "x" * 50})
    for pk in ("1", "12", "8000", "11000", "12000"):
        same(run, "get", pk)
    for case in ("notes", "aggregate", "count"):
        same(run, "ask", case)
    answers = same(run, "paths", "aggregate")
    assert len(set(answers)) == 1, answers
    # with fewer values the block fits in one key again
    for lo in (1, 51):
        hi = str(lo + 49)
        assert run("clear_notes", "Sale", str(lo), hi) == run("clear_notes", "Plain", str(lo), hi)
    assert run("kinds", "note") == "note=t"
    assert run("parts") == 0
    for case in ("notes", "aggregate", "count"):
        same(run, "ask", case)
    answers = same(run, "paths", "aggregate")
    assert len(set(answers)) == 1, answers
