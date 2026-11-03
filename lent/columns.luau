--!native
-- Rows of a table with format = "column", stored by field in blocks.
--
-- Required, not called: `local col = require("lent.COLUMNS")`. A function key
-- has to define call(), so this one answers a self-check:
--
--   lent.COLUMNS             -> "ok" or which check failed (from any space)
--
-- Ids split into blocks of 1024: block = floor(id / 1024), and the slot is
-- the id's place in its block. Each block has one presence key and at most
-- one key per field, as LAYOUT names them:
--
--   presence   1024 bytes, 1 for a slot that holds a row, then the number of
--              rows as an int32
--   number     8 bytes per slot, an f64, for int, float and what ROWCODEC
--              stores as those, and bool as 1 and 0. NaN is nil, since every
--              row format refuses NaN as a value.
--   text       for string, enum, json and bytes: the bytes in use and the
--              slots in use as uint32s, a uint32 per slot, then the values
--              in slot order. A slot's uint32 is its length plus 1, and 0
--              for nil.
--
-- A field with no key has no value in that block, so a new field costs
-- nothing to add. A number field changes in place. A text field rewrites
-- its key: inside a transaction barch copies the whole value for a patch
-- too, and appending with setBufferAt gained 5%. The slots in use stay in
-- the header so a later version can append without changing stored blocks.
-- The last row to leave a block removes the block.

local kc = require("lent.KEYCODEC")
local rc = require("lent.ROWCODEC")
local VALUES = require("lent.VALUES")
local lay = require("lent.LAYOUT")

local SIZE = 1024
local TEXT_KINDS = { string = true, enum = true, json = true, bytes = true }
local TEXT_SLOTS = 8                    -- where a text block's lengths start
local TEXT_VALUES = TEXT_SLOTS + SIZE * 4
-- barch's largest key and value together
local MAX_ENTRY = 524032

local NAN = 0 / 0

-- barch's vector kernels (docs/barch-vec.md), or nil on a barch without
-- them; folds then run their own Luau loops
local vec = (barch :: any).vec

local function fill_nil(): buffer
    local b = buffer.create(SIZE * 8)
    for i = 0, SIZE - 1 do
        buffer.writef64(b, i * 8, NAN)
    end
    return b
end

local NIL_NUMBERS = fill_nil()
-- SIZE str elements that are all nil, SIZE i8 elements that are all 0,
-- and each slot's number as an f64
local NIL_TEXTS = buffer.create(SIZE * 8)
local ZEROS = buffer.create(SIZE)
local SLOTS = buffer.create(SIZE * 8)
for s = 0, SIZE - 1 do
    buffer.writef64(SLOTS, s * 8, s)
end
local NO_ROWS = buffer.create(SIZE + 4)
local PRESENT, ABSENT = buffer.create(1), buffer.create(1)
buffer.writeu8(PRESENT, 0, 1)

local function fail(message: string)
    error("LENT " .. message, 0)
end

local function place(pk: number): (number, number)
    local block = pk // SIZE
    return block, pk - block * SIZE
end

local function block_key(prefix: string, block: number): string
    return prefix .. kc.encode("int", block)
end

local function live(presence: string): number
    return (string.unpack("<i4", presence, SIZE + 1))
end

-- The first id at or past row key or key bound `key`, under `prefix`, the
-- prefix of the table's row keys. Bounds come from row keys with a byte
-- added, or with KEYCODEC's after() applied to the last digit, which then
-- reads as one past it.
local function first_id(prefix: string, key: string): number
    if key <= prefix then
        return -math.huge
    end
    if string.sub(key, 1, #prefix) ~= prefix then
        return math.huge
    end
    local at = #prefix + 1
    local width = #key - #prefix
    if string.byte(key, at) ~= string.byte("i") or width < 17 then
        return if key < prefix .. "i" then -math.huge else math.huge
    end
    local hi = tonumber(string.sub(key, at + 1, at + 8), 16) :: number
    local mid = tonumber(string.sub(key, at + 9, at + 15), 16) :: number
    local last = string.byte(key, at + 16)
    -- 0-9 and the : past 9, or a-f and the g past f
    local low = if last <= 58 then last - 48 else last - 87
    local id = (hi - 0x80000000) * 2 ^ 32 + mid * 16 + low
    return if width > 17 then id + 1 else id
end

-- The ids from `lo` up to `hi`, row keys or key bounds, as the first and last
-- id, and the presence keys that hold them.
local function span(t: any, lo: string, hi: string): (number, number, string, string)
    local prefix = lay.row(t)
    local from, last = first_id(prefix, lo), first_id(prefix, hi) - 1
    local all = lay.present(t)
    local plo = if from == -math.huge then all else lay.present(t, from // SIZE)
    local phi = if last == math.huge then kc.after(all) else
        kc.after(lay.present(t, last // SIZE))
    return from, last, plo, phi :: string
end

-- how each field a scan reads is held, in the order of `fields.list`
local function columns(t: any, fields: any, need: any): { any }
    local out = {}
    for _, f in fields.list do
        if need == nil or need[f.name] then
            out[#out + 1] = { name = f.name, prefix = lay.column(t, f.id),
                              text = TEXT_KINDS[f.kind] == true, json = f.kind == "json",
                              bool = f.kind == "bool", starts = table.create(SIZE, 0) }
        end
    end
    return out
end

-- The slots from `a` to `z` of the block, in order or, with `back`, highest
-- first, as rows of the fields in `cols`. Calls each(pk, row) until it
-- answers true, and answers whether it did.
local function read_block(cols: { any }, block: number, presence: string, a: number, z: number,
                          back: boolean?, each: (number, any) -> boolean?): boolean
    local blocks = {}
    local n = #cols
    for i = 1, n do
        local c = cols[i]
        local stored = barch.store.get(block_key(c.prefix, block))
        local b = stored and buffer.fromstring(stored) or false
        blocks[i] = b
        if b and c.text then
            local starts, at = c.starts, TEXT_VALUES
            for s = 0, SIZE - 1 do
                starts[s + 1] = at
                local len = buffer.readu32(b, TEXT_SLOTS + s * 4)
                if len > 0 then
                    at += len - 1
                end
            end
        end
    end
    local base = block * SIZE
    for s = if back then z else a, if back then a else z, if back then -1 else 1 do
        if string.byte(presence, s + 1) == 1 then
            local r = {}
            for i = 1, n do
                local b = blocks[i]
                if b then
                    local c = cols[i]
                    if c.text then
                        local len = buffer.readu32(b, TEXT_SLOTS + s * 4)
                        if len > 0 then
                            local v = buffer.readstring(b, c.starts[s + 1], len - 1)
                            r[c.name] = if c.json then VALUES.parse_json(v) else v
                        end
                    else
                        local x = buffer.readf64(b, s * 8)
                        if x == x then
                            r[c.name] = if c.bool then x == 1 else x
                        end
                    end
                end
            end
            if each(base + s, r) then
                return true
            end
        end
    end
    return false
end

-- Calls each(pk, row) for every row of table t from `lo` up to `hi`, row
-- keys or key bounds, until `each` answers true, and answers whether it
-- stopped early. Each row holds the fields in the set `need`, or all of them
-- with need nil, and no defaults. `first` says how many rows the caller
-- expects to read, which sets how many blocks the first page holds. `back`
-- reads highest id first; `each` must not add or remove rows then.
function scan(t: any, fields: any, lo: string, hi: string, each: (number, any) -> boolean?,
              first: number?, back: boolean?, need: any?): boolean
    local from, last, plo, phi = span(t, lo, hi)
    if from > last then
        return false
    end
    local cols = columns(t, fields, need)
    local page = math.clamp((first or SIZE * 16) // SIZE + 1, 1, 16)
    local function run(keys: { string }, values: { string }, i: number): boolean
        local block = lay.present_block(keys[i])
        local base = block * SIZE
        local a, z = math.max(from - base, 0), math.min(last - base, SIZE - 1)
        return a <= z and read_block(cols, block, values[i], a, z, back, each)
    end
    if back then
        local pos = barch.store.count(plo, phi)
        while pos > 0 do
            local at = math.max(0, pos - page)
            local keys, values = barch.store.rangeValues(plo, phi, pos - at, at)
            for i = #keys, 1, -1 do
                if run(keys, values, i) then
                    return true
                end
            end
            pos = at
            page = math.min(page * 2, 16)
        end
        return false
    end
    while true do
        local keys, values = barch.store.rangeValues(plo, phi, page)
        for i in keys do
            if run(keys, values, i) then
                return true
            end
        end
        if #keys < page then
            return false
        end
        plo = keys[#keys] .. "\2"
        page = math.min(page * 2, 16)
    end
end

-- Up to `limit` row keys from `lo` up to `hi`, with the row each one holds,
-- for a read that pages by key.
function page(t: any, fields: any, lo: string, hi: string, limit: number,
              need: any?): ({ string }, { any })
    local keys, rows = {}, {}
    scan(t, fields, lo, hi, function(pk, r)
        keys[#keys + 1], rows[#rows + 1] = lay.row(t, pk), r
        return #keys == limit
    end, limit, false, need)
    return keys, rows
end

-- How many rows lie from `lo` up to `hi`, row keys or key bounds.
function count(t: any, lo: string, hi: string): number
    local from, last, plo, phi = span(t, lo, hi)
    if from > last then
        return 0
    end
    local n = 0
    while true do
        local keys, values = barch.store.rangeValues(plo, phi, 256)
        for i, k in keys do
            local base = lay.present_block(k) * SIZE
            local a, z = math.max(from - base, 0), math.min(last - base, SIZE - 1)
            if a == 0 and z == SIZE - 1 then
                n += live(values[i])
            else
                for s = a, z do
                    if string.byte(values[i], s + 1) == 1 then
                        n += 1
                    end
                end
            end
        end
        if #keys < 256 then
            return n
        end
        plo = keys[#keys] .. "\2"
    end
end

-- How many rows presence block value `presence` holds.
function rows_in(presence: string): number
    return live(presence)
end

-- The id of row n, counted from 0, of block `block`, whose presence block
-- value is `presence`, or nil when the block holds n rows or fewer.
function nth_id(block: number, presence: string, n: number): number?
    for s = 0, SIZE - 1 do
        if string.byte(presence, s + 1) == 1 then
            if n == 0 then
                return block * SIZE + s
            end
            n -= 1
        end
    end
    return nil
end

-- folds -----------------------------------------------------------------------

-- A field a fold reads: "id", which reads each row's id, or a field's
-- blocks, with the value a slot without one reads as.
local function source(t: any, fields: any, name: string): any
    if name == "id" then
        return { id = true, base = 0 }
    end
    local f
    for _, g in fields.list do
        if g.name == name then
            f = g
        end
    end
    local default
    for _, d in t.fields do
        if d.name == name then
            default = d.default
        end
    end
    return { prefix = lay.column(t, f.id), text = TEXT_KINDS[f.kind] == true,
             bool = f.kind == "bool", default = default, starts = table.create(SIZE, 0) }
end

-- Reads source c's block, or notes that the block holds no value.
local function load(c: any, block: number)
    if c.id then
        c.base = block * SIZE
        return
    end
    -- a key removed in this transaction reads as barch.tomb
    local stored = barch.store.getBufferAt(block_key(c.prefix, block), 0)
    local b = if type(stored) == "buffer" then stored else nil
    c.b, c.located, c.elements = b, false, false
end

-- Finds where each slot's value starts in text source c's loaded block.
local function locate(c: any)
    local b: buffer, starts, at = c.b, c.starts, TEXT_VALUES
    for s = 0, SIZE - 1 do
        starts[s + 1] = at
        local len = buffer.readu32(b, TEXT_SLOTS + s * 4)
        if len > 0 then
            at += len - 1
        end
    end
    c.located = true
end

-- The value of `slot` in source c's loaded block.
local function value_at(c: any, s: number): any
    if c.id then
        return c.base + s
    end
    local b = c.b
    if b == nil then
        return c.default
    end
    if c.text then
        local len = buffer.readu32(b, TEXT_SLOTS + s * 4)
        if len == 0 then
            return c.default
        end
        if not c.located then
            locate(c)
        end
        return buffer.readstring(b, c.starts[s + 1], len - 1)
    end
    local x = buffer.readf64(b, s * 8)
    if x ~= x then
        return c.default
    end
    if c.bool then
        return x == 1
    end
    return x
end

-- Whether `v op w` holds, as a query condition compares a row's value.
local function holds(op: string, v: any, w: any): boolean
    if op == "=" then
        return v == w
    elseif op == "~=" then
        return v ~= w
    elseif v == nil then
        return false
    elseif op == "<" then
        return v < w
    elseif op == "<=" then
        return v <= w
    elseif op == ">" then
        return v > w
    end
    return v >= w
end

-- Keeps the slots of sel[1..n] whose value of source c passes `op w`, and
-- answers how many it kept. `full` says sel holds every slot in order.
local function filter(c: any, op: string, w: any, sel: { number }, n: number, full: boolean): number
    if c.b == nil and not c.id then
        return if holds(op, c.default, w) then n else 0
    end
    local m = 0
    if not (c.id or c.text or c.bool) and c.default == nil then
        -- NaN, a slot without a value, fails every comparison but ~=
        local b: buffer = c.b
        if op == "<" then
            for i = 1, n do
                local s = if full then i - 1 else sel[i]
                if buffer.readf64(b, s * 8) < w then
                    m += 1
                    sel[m] = s
                end
            end
        elseif op == "<=" then
            for i = 1, n do
                local s = if full then i - 1 else sel[i]
                if buffer.readf64(b, s * 8) <= w then
                    m += 1
                    sel[m] = s
                end
            end
        elseif op == ">" then
            for i = 1, n do
                local s = if full then i - 1 else sel[i]
                if buffer.readf64(b, s * 8) > w then
                    m += 1
                    sel[m] = s
                end
            end
        elseif op == ">=" then
            for i = 1, n do
                local s = if full then i - 1 else sel[i]
                if buffer.readf64(b, s * 8) >= w then
                    m += 1
                    sel[m] = s
                end
            end
        else
            local want = op == "="
            for i = 1, n do
                local s = if full then i - 1 else sel[i]
                local x = buffer.readf64(b, s * 8)
                if (if w == nil then x ~= x else x == w) == want then
                    m += 1
                    sel[m] = s
                end
            end
        end
        return m
    end
    for i = 1, n do
        local s = sel[i]
        if holds(op, value_at(c, s), w) then
            m += 1
            sel[m] = s
        end
    end
    return m
end

local NIL_KEY = {}
local ALL_SLOTS = table.create(SIZE, 0)
for s = 1, SIZE do
    ALL_SLOTS[s] = s - 1
end

-- Adds a group with key values `values` to the job: job.group answers its
-- record, and the group's running values start from the record's. Answers
-- the group's index.
local function new_group(job: any, values: { any }): number
    local g = job.group(values)
    local gi = #job.records + 1
    job.records[gi] = g
    for _, a in job.aggs do
        local acc = g.acc[a.name]
        if a.fn == "avg" then
            a.vals[gi], a.ns[gi] = acc and acc.sum, acc and acc.n
        else
            a.vals[gi] = acc
        end
        if a.distinct then
            local seen = g.seen[a.name] or {}
            g.seen[a.name] = seen
            a.seen[gi] = seen
        end
    end
    return gi
end

-- The group index of the row at `slot`, by the values of the job's key
-- sources.
local function group_index(job: any, s: number): number
    local node = job.tree
    local ks = job.keys
    local nk = #ks
    for i = 1, nk do
        local v = value_at(ks[i], s)
        if v == nil then
            v = NIL_KEY
        end
        local next = node[v]
        if next == nil then
            if i == nk then
                local values = table.create(nk)
                for j = 1, nk do
                    values[j] = value_at(ks[j], s)
                end
                next = new_group(job, values)
            else
                next = {}
            end
            node[v] = next
        end
        node = next
    end
    return node :: any
end

local function less(a: any, b: any): boolean
    if type(a) == "boolean" then
        return not a and b
    end
    return a < b
end

-- Adds the slots sel[1..n], in groups gids[1..n], to aggregate a. `full`
-- says sel holds every slot in order.
local function fold_aggregate(a: any, sel: { number }, n: number, gids: { number }, full: boolean)
    local vals, fn, c = a.vals, a.fn, a.source
    if c == nil then
        -- count with no field counts rows
        if a.single then
            vals[1] = (vals[1] or 0) + n
            return
        end
        for i = 1, n do
            local gi = gids[i]
            vals[gi] = (vals[gi] or 0) + 1
        end
        return
    end
    if a.single and fn == "sum" and a.scale == nil and not a.distinct
        and not (c.id or c.text or c.bool) and c.default == nil then
        local b: buffer? = c.b
        if b == nil then
            return
        end
        local sum, any = vals[1] or 0, false
        for i = 1, n do
            local x = buffer.readf64(b, (if full then i - 1 else sel[i]) * 8)
            if x == x then
                sum += x
                any = true
            end
        end
        if any then
            vals[1] = sum
        end
        return
    end
    if not (a.distinct or a.scale or c.id or c.text or c.bool) and c.default == nil then
        local b: buffer? = c.b
        if b == nil then
            return
        end
        local ns = a.ns
        if fn == "count" then
            for i = 1, n do
                local x = buffer.readf64(b, (if full then i - 1 else sel[i]) * 8)
                if x == x then
                    local gi = gids[i]
                    vals[gi] = (vals[gi] or 0) + 1
                end
            end
        elseif fn == "sum" then
            for i = 1, n do
                local x = buffer.readf64(b, (if full then i - 1 else sel[i]) * 8)
                if x == x then
                    local gi = gids[i]
                    vals[gi] = (vals[gi] or 0) + x
                end
            end
        elseif fn == "avg" then
            for i = 1, n do
                local x = buffer.readf64(b, (if full then i - 1 else sel[i]) * 8)
                if x == x then
                    local gi = gids[i]
                    vals[gi] = (vals[gi] or 0) + x
                    ns[gi] = (ns[gi] or 0) + 1
                end
            end
        else
            local min = fn == "min"
            for i = 1, n do
                local x = buffer.readf64(b, (if full then i - 1 else sel[i]) * 8)
                if x == x then
                    local gi = gids[i]
                    local acc = vals[gi]
                    if acc == nil or (if min then x < acc else acc < x) then
                        vals[gi] = x
                    end
                end
            end
        end
        return
    end
    local ns, seens, scale = a.ns, a.seen, a.scale
    for i = 1, n do
        local v = value_at(c, sel[i])
        if v ~= nil then
            local gi = gids[i]
            local fresh = true
            if seens then
                local seen = seens[gi]
                local t = type(v)
                local set = seen[t]
                if set == nil then
                    set = {}
                    seen[t] = set
                end
                fresh = not set[v]
                set[v] = true
            end
            if fresh then
                if scale then
                    v = math.round(v * 10 ^ scale)
                end
                local acc = vals[gi]
                if fn == "count" then
                    vals[gi] = (acc or 0) + 1
                elseif fn == "sum" then
                    vals[gi] = (acc or 0) + v
                elseif fn == "avg" then
                    vals[gi] = (acc or 0) + v
                    ns[gi] = (ns[gi] or 0) + 1
                elseif acc == nil or (if fn == "min" then less(v, acc) else less(acc, v)) then
                    vals[gi] = v
                end
            end
        end
    end
end

-- Whether source c holds plain numbers: f64 values, NaN for nil, and no
-- default to read in its place.
local function plain(c: any): boolean
    return c ~= nil and not (c.id or c.text or c.bool) and c.default == nil
end

-- Whether source c holds text with no default to read in place of nil.
local function plain_text(c: any): boolean
    return c.text and c.default == nil
end

-- Whether barch.vec can run every step of a fold: conditions that compare
-- ids or plain numbers with a number or plain text with a string, at most
-- one plain key, and count, sum, avg, min and max of plain numbers or rows.
local function vectors(conds: { any }, keys: { any }, aggs: { any }): boolean
    for _, c in conds do
        local kind = type(c.value)
        if not ((kind == "number" and (plain(c.source) or c.source.id))
                or (kind == "string" and plain_text(c.source))) then
            return false
        end
    end
    if #keys > 1 or (#keys == 1 and not (plain(keys[1]) or plain_text(keys[1]))) then
        return false
    end
    for _, a in aggs do
        if a.distinct or a.scale or (a.source and not plain(a.source)) then
            return false
        end
    end
    return true
end

-- A fold over the rows of table t: the conditions they must pass, the
-- fields they group by and the aggregates to add them to. `spec` holds
--
--   conds    { field, op, value } with op one of = ~= < <= > >=
--   keys     the field names to group by, or none for one group
--   aggs     { name, fn, field?, distinct?, scale? }, fn one of count, sum,
--            avg, min and max; a decimal sum or avg passes its scale
--   group    a function of a group's key values that answers its record,
--            { acc, seen }, with the running values by aggregate name as
--            the client's fold keeps them
--   budget   the most rows to read, or nil for all of them
--
-- Fields may be "id". json fields have no order or key, so a fold takes
-- none.
function start_fold(t: any, fields: any, spec: any): any
    local sources = {}
    local function get(name: string): any
        local c = sources[name]
        if c == nil then
            c = source(t, fields, name)
            sources[name] = c
        end
        return c
    end
    local conds = {}
    for i, c in spec.conds do
        local w = c.value
        conds[i] = { source = get(c.field), op = c.op, value = w }
    end
    local keys = {}
    for i, name in spec.keys do
        keys[i] = get(name)
    end
    local aggs = {}
    for i, a in spec.aggs do
        aggs[i] = { name = a.name, fn = a.fn, source = a.field and get(a.field),
                    scale = a.scale, distinct = a.distinct, single = #keys == 0, vals = {},
                    ns = if a.fn == "avg" then {} else nil,
                    seen = if a.distinct then {} else nil }
    end
    local list = {}
    for _, c in sources do
        list[#list + 1] = c
    end
    local job = { sources = list, conds = conds, keys = keys, aggs = aggs, group = spec.group,
                  budget = spec.budget, seen = 0, records = {}, tree = {}, short = {},
                  sel = table.create(SIZE, 0), gids = table.create(SIZE, 1) }
    if vec and vectors(conds, keys, aggs) then
        -- each aggregate adds to records that grouper id i keeps at 32 * i,
        -- and finish adds them to group gis[i + 1]
        job.vec, job.gis, job.capacity = vec, if #keys == 0 then { 1 } else {}, 0
        job.presence, job.selb, job.gidb = buffer.create(SIZE), buffer.create(SIZE * 4),
            buffer.create(SIZE * 4)
        if #keys == 1 then
            job.grouper = vec.grouper(if keys[1].text then "str" else "f64")
        end
        return job
    end
    -- one number range filter and one plain sum fold in one pass
    local a1, c1 = aggs[1], conds[1]
    if #conds == 1 and #keys == 0 and #aggs == 1 and a1.fn == "sum" and plain(a1.source)
        and not a1.distinct and a1.scale == nil and plain(c1.source) and type(c1.value) == "number"
        and (c1.op == "<" or c1.op == "<=" or c1.op == ">" or c1.op == ">=") then
        job.fuse = c1
    end
    return job
end

-- The bits of the first 4 and the next 2 bytes that a text value of 0 to 6
-- bytes holds, read as little-endian numbers
local LO_MASK, HI_MASK = {}, {}
for len = 0, 6 do
    LO_MASK[len] = 2 ^ (8 * math.min(len, 4)) - 1
    HI_MASK[len] = 2 ^ (8 * math.max(len - 4, 0)) - 1
end

-- Sets gids[1..n] to the groups of the slots in sel[1..n] by text key c.
local function text_gids(job: any, c: any, sel: { number }, n: number, gids: { number }, full: boolean)
    -- a value of up to 6 bytes, with its length, makes a number below 2^53
    -- that names its group without making a string
    local b: buffer, starts, tree, short = c.b, c.starts, job.tree, job.short
    local blen = buffer.len(b)
    if not (full or c.located) then
        locate(c)
    end
    -- a full block's values follow each other in slot order
    local at = TEXT_VALUES
    for i = 1, n do
        local s = if full then i - 1 else sel[i]
        local len = buffer.readu32(b, TEXT_SLOTS + s * 4) - 1
        if not full then
            at = starts[s + 1]
        end
        local gi
        if len < 0 then
            gi = group_index(job, s)
        elseif len <= 6 and at + 6 <= blen then
            local code = len * 2 ^ 48 + bit32.band(buffer.readu16(b, at + 4), HI_MASK[len]) * 2 ^ 32
                + bit32.band(buffer.readu32(b, at), LO_MASK[len])
            gi = short[code]
            if gi == nil then
                gi = group_index(job, s)
                short[code] = gi
            end
        else
            gi = tree[buffer.readstring(b, at, len)] or group_index(job, s)
        end
        gids[i] = gi
        if len > 0 then
            at += len
        end
    end
end

-- Sets gids[1..n] to the groups of the slots in sel[1..n] by number key c.
local function number_gids(job: any, c: any, sel: { number }, n: number, gids: { number }, full: boolean)
    local b: buffer, tree = c.b, job.tree
    for i = 1, n do
        local s = if full then i - 1 else sel[i]
        local x = buffer.readf64(b, s * 8)
        gids[i] = (x == x and tree[x]) or group_index(job, s)
    end
end

-- Adds the full block's rows whose value of source c passes `op w` to the
-- one-group sum a, in one pass. Answers false when the job doesn't have
-- that shape.
local function filtered_sum(job: any, c: any, op: string, w: any, a: any): boolean
    local v: buffer?, b: buffer? = a.source.b, c.b
    if v == nil or b == nil then
        return false
    end
    local sum, any = a.vals[1] or 0, false
    if op == "<" then
        for s = 0, SIZE - 1 do
            if buffer.readf64(b, s * 8) < w then
                local x = buffer.readf64(v, s * 8)
                if x == x then
                    sum += x
                    any = true
                end
            end
        end
    elseif op == "<=" then
        for s = 0, SIZE - 1 do
            if buffer.readf64(b, s * 8) <= w then
                local x = buffer.readf64(v, s * 8)
                if x == x then
                    sum += x
                    any = true
                end
            end
        end
    elseif op == ">" then
        for s = 0, SIZE - 1 do
            if buffer.readf64(b, s * 8) > w then
                local x = buffer.readf64(v, s * 8)
                if x == x then
                    sum += x
                    any = true
                end
            end
        end
    else
        for s = 0, SIZE - 1 do
            if buffer.readf64(b, s * 8) >= w then
                local x = buffer.readf64(v, s * 8)
                if x == x then
                    sum += x
                    any = true
                end
            end
        end
    end
    if any then
        a.vals[1] = sum
    end
    return true
end

-- Text source c's loaded block as str elements: a buffer of SIZE elements,
-- then the block, which the elements point into.
local function elements(v: any, c: any): buffer
    local w = c.work
    if not c.elements then
        local b: buffer = c.b
        local need = SIZE * 8 + buffer.len(b)
        if w == nil or buffer.len(w) < need then
            w = buffer.create(need)
            c.work = w
        end
        buffer.copy(w, SIZE * 8, b)
        v.offsets(w, SIZE * 8 + TEXT_SLOTS, SIZE, SIZE * 8 + TEXT_VALUES, w)
        c.elements = true
    end
    return w
end

-- Makes room in each aggregate's records for `size` grouper ids, each
-- record starting as no values: a count and sum of 0, a least of inf and a
-- greatest of -inf.
local function grow(job: any, size: number)
    local was = job.capacity
    if size <= was then
        return
    end
    local cap = math.max(size, was * 2, 16)
    for _, a in job.aggs do
        local r = buffer.create(cap * 32)
        if a.recs then
            buffer.copy(r, 0, a.recs, 0, was * 32)
        end
        for i = was, cap - 1 do
            buffer.writef64(r, i * 32 + 16, math.huge)
            buffer.writef64(r, i * 32 + 24, -math.huge)
        end
        a.recs = r
    end
    job.capacity = cap
end

-- Gives the grouper's ids from #job.gis to size - 1 their groups.
local function new_ids(job: any, size: number)
    local g, gis, tree = job.grouper, job.gis, job.tree
    for id = #gis, size - 1 do
        local v = g:key(id)
        local k = if v == nil then NIL_KEY else v
        local gi = tree[k]
        if gi == nil then
            gi = new_group(job, { v })
            tree[k] = gi
        end
        gis[id + 1] = gi
    end
    grow(job, size)
end

-- fold_block with barch.vec: the selection, group ids and running values
-- stay in buffers, and each step is one kernel call over the block.
local function vector_block(job: any, block: number, presence: string, a: number,
                            z: number): boolean
    local v = job.vec
    local selb: buffer = job.selb
    local budget, seen = job.budget, job.seen
    local sel: buffer?, n, more = nil, SIZE, false
    if not (a == 0 and z == SIZE - 1 and live(presence) == SIZE
            and (budget == nil or budget - seen >= SIZE)) then
        -- the slots from a to z that hold rows, up to the budget
        local pb: buffer = job.presence
        buffer.writestring(pb, 0, presence, SIZE)
        buffer.fill(pb, 0, 0, a)
        buffer.fill(pb, z + 1, 0, SIZE - 1 - z)
        sel, n = selb, v.mask(pb, 0, SIZE, selb)
        if budget ~= nil and n > budget - seen then
            n, more = budget - seen, true
        end
    end
    job.seen = seen + n
    if n == 0 then
        return more
    end
    job.last = block * SIZE + (if sel then buffer.readu32(sel, (n - 1) * 4) else n - 1)
    for _, c in job.sources do
        load(c, block)
    end
    for _, cd in job.conds do
        local c = cd.source
        if c.id then
            -- slot s holds id c.base + s
            n = v.filter("f64", SLOTS, 0, 8, cd.op, cd.value - c.base, nil, sel, n, selb)
            sel = selb
            if n == 0 then
                return more
            end
        elseif c.b == nil then
            -- every row reads nil, which passes only ~=
            if cd.op ~= "~=" then
                return more
            end
        else
            local kind, b = "f64", c.b
            if c.text then
                kind, b = "str", elements(v, c)
            end
            n = v.filter(kind, b, 0, 8, cd.op, cd.value, nil, sel, n, selb)
            sel = selb
            if n == 0 then
                return more
            end
        end
    end
    local gids: buffer? = nil
    local k = job.keys[1]
    if k then
        local b = if k.b == nil then (if k.text then NIL_TEXTS else NIL_NUMBERS)
            elseif k.text then elements(v, k) else k.b
        gids = job.gidb
        local size = job.grouper:ids(b, 0, 8, nil, if k.b == nil then nil else sel, n, gids)
        if size > #job.gis then
            new_ids(job, size)
        end
    elseif #job.records == 0 then
        new_group(job, {})
        grow(job, 1)
    end
    for _, ag in job.aggs do
        local c = ag.source
        if c == nil then
            v.fold("i8", ZEROS, 0, 1, nil, sel, n, gids, ag.recs)
        elseif c.b ~= nil then
            v.fold("f64", c.b, 0, 8, nil, sel, n, gids, ag.recs)
        end
    end
    return more
end

-- Adds the records of a job that ran on barch.vec to its groups' running
-- values.
local function add_records(job: any)
    for _, a in job.aggs do
        local r: buffer, vals, ns, fn = a.recs, a.vals, a.ns, a.fn
        if r == nil then
            continue
        end
        for id, gi in job.gis do
            local at = (id - 1) * 32
            local count = buffer.readf64(r, at)
            if count > 0 then
                local acc = vals[gi]
                if fn == "count" then
                    vals[gi] = (acc or 0) + count
                elseif fn == "sum" then
                    vals[gi] = (acc or 0) + buffer.readf64(r, at + 8)
                elseif fn == "avg" then
                    vals[gi] = (acc or 0) + buffer.readf64(r, at + 8)
                    ns[gi] = (ns[gi] or 0) + count
                elseif fn == "min" then
                    local x = buffer.readf64(r, at + 16)
                    if acc == nil or x < acc then
                        vals[gi] = x
                    end
                else
                    local x = buffer.readf64(r, at + 24)
                    if acc == nil or x > acc then
                        vals[gi] = x
                    end
                end
            end
        end
    end
end

-- Adds the slots from `a` to `z` of a block to the job's groups. Answers
-- true when the job's budget ran out before the block's last row.
local function fold_block(job: any, block: number, presence: string, a: number, z: number): boolean
    if job.vec then
        return vector_block(job, block, presence, a, z)
    end
    local sel: { number }, n = job.sel, 0
    local budget, seen = job.budget, job.seen
    local more, full = false, false
    if a == 0 and z == SIZE - 1 and live(presence) == SIZE
        and (budget == nil or budget - seen >= SIZE) then
        -- a full block reads every slot
        table.move(ALL_SLOTS, 1, SIZE, 1, sel)
        n, seen, full = SIZE, seen + SIZE, true
    else
        for s = a, z do
            if string.byte(presence, s + 1) == 1 then
                if seen == budget then
                    more = true
                    break
                end
                seen += 1
                n += 1
                sel[n] = s
            end
        end
    end
    job.seen = seen
    if n > 0 then
        job.last = block * SIZE + sel[n]
    end
    if n == 0 then
        return more
    end
    for _, c in job.sources do
        load(c, block)
    end
    local fuse = job.fuse
    if full and fuse then
        if #job.records == 0 then
            new_group(job, {})
        end
        if filtered_sum(job, fuse.source, fuse.op, fuse.value, job.aggs[1]) then
            return more
        end
    end
    for _, c in job.conds do
        n = filter(c.source, c.op, c.value, sel, n, full)
        if n == 0 then
            return more
        end
        full = full and n == SIZE
    end
    local gids = job.gids
    local ks = job.keys
    if #ks == 1 and ks[1].text and ks[1].b then
        text_gids(job, ks[1], sel, n, gids, full)
    elseif #ks == 1 and not (ks[1].text or ks[1].id or ks[1].bool) and ks[1].b
        and ks[1].default == nil then
        number_gids(job, ks[1], sel, n, gids, full)
    elseif #ks > 0 then
        for i = 1, n do
            gids[i] = group_index(job, sel[i])
        end
    elseif #job.records == 0 then
        new_group(job, {})
    end
    for _, ag in job.aggs do
        fold_aggregate(ag, sel, n, gids, full)
    end
    return more
end

-- Adds the rows of the job's table from `lo` up to `hi`, row keys or key
-- bounds, in id order, to its groups. Answers true when the budget ran out
-- first; job.last is then the last id read, and job.seen counts the rows
-- read.
function fold(t: any, job: any, lo: string, hi: string): boolean
    local from, last, plo, phi = span(t, lo, hi)
    if from > last then
        return false
    end
    while true do
        local keys, values = barch.store.rangeValues(plo, phi, 16)
        for i, k in keys do
            local block = lay.present_block(k)
            local base = block * SIZE
            local a, z = math.max(from - base, 0), math.min(last - base, SIZE - 1)
            if a <= z and fold_block(job, block, values[i], a, z) then
                return true
            end
        end
        if #keys < 16 then
            return false
        end
        plo = keys[#keys] .. "\2"
    end
end

-- Writes the job's running values into the group records it read.
function finish(job: any)
    if job.vec then
        add_records(job)
    end
    for gi, g in job.records do
        for _, a in job.aggs do
            local v = a.vals[gi]
            if a.fn == "avg" then
                local acc = g.acc[a.name]
                if acc then
                    acc.sum, acc.n = v, a.ns[gi]
                elseif v ~= nil then
                    g.acc[a.name] = { sum = v, n = a.ns[gi] }
                end
            else
                g.acc[a.name] = v
            end
        end
    end
end

-- Sets the kernels later folds use: barch.vec, lent.VEC, or nil for the
-- Luau loops. Answers the kernels it replaces. Tests compare the paths.
function kernels(v: any): any
    local was = vec
    vec = v
    return was
end

-- Whether table t holds a row at pk.
function exists(t: any, pk: number): boolean
    local block, slot = place(pk)
    local presence = barch.store.get(lay.present(t, block))
    return presence ~= nil and string.byte(presence, slot + 1) == 1
end

-- Where the value of `slot` starts in text block b.
local function text_start(b: buffer, slot: number): number
    local at = TEXT_VALUES
    for s = 0, slot - 1 do
        local len = buffer.readu32(b, TEXT_SLOTS + s * 4)
        if len > 0 then
            at += len - 1
        end
    end
    return at
end

-- The value at `slot` of a text block.
local function text_at(stored: string, slot: number): string?
    local b = buffer.fromstring(stored)
    local at = text_start(b, slot)
    local len = buffer.readu32(b, TEXT_SLOTS + slot * 4)
    if len == 0 then
        return nil
    end
    return buffer.readstring(b, at, len - 1)
end

-- The row at pk with no defaults, or nil. `lock` reads the block's presence
-- with the exclusive lock, for a pessimistic caller about to write.
function read(t: any, fields: any, pk: number, lock: boolean?): any
    local block, slot = place(pk)
    local key = lay.present(t, block)
    local presence = if lock then barch.store.get(key, true) else barch.store.get(key)
    if presence == nil or string.byte(presence, slot + 1) ~= 1 then
        return nil
    end
    local r = {}
    for _, f in fields.list do
        local k = block_key(lay.column(t, f.id), block)
        if TEXT_KINDS[f.kind] then
            local stored = barch.store.get(k)
            local v = stored and text_at(stored, slot)
            if v then
                r[f.name] = if f.kind == "json" then VALUES.parse_json(v) else v
            end
        else
            local x = barch.store.getF64At(k, slot * 8)
            if x and x == x then
                r[f.name] = if f.kind == "bool" then x == 1 else x
            end
        end
    end
    return r
end

-- Stores number `x` in `slot` of number block k, nil as NaN.
local function put_number(k: string, slot: number, x: number?)
    if not barch.store.exists(k) then
        if x == nil then
            return
        end
        barch.store.setBufferAt(k, NIL_NUMBERS, 0)
    end
    barch.store.setF64At(k, x or NAN, slot * 8)
end

local function too_large(t: any, f: any, block: number, size: number)
    fail("table " .. t.name .. " field " .. f.name .. " would hold " .. size .. " bytes in"
        .. " column block " .. block .. ", and a block holds at most "
        .. MAX_ENTRY .. " with its key; store large values in a binary table")
end

-- A text block holding `text` at slot, which the first value makes.
local function new_text(slot: number, text: string): string
    local b = buffer.create(TEXT_VALUES + #text)
    buffer.writeu32(b, 0, #text)
    buffer.writeu32(b, 4, slot + 1)
    buffer.writeu32(b, TEXT_SLOTS + slot * 4, #text + 1)
    buffer.writestring(b, TEXT_VALUES, text)
    return buffer.tostring(b)
end

-- `stored` with `text` at slot, or nil at slot for text nil.
local function replace_text(stored: string, slot: number, text: string?): string
    local old = buffer.fromstring(stored)
    local at = text_start(old, slot)
    local was = buffer.readu32(old, TEXT_SLOTS + slot * 4)
    local gone = if was > 0 then was - 1 else 0
    local size = if text then #text else 0
    local total = buffer.readu32(old, 0) - gone + size
    local b = buffer.create(TEXT_VALUES + total)
    buffer.copy(b, 0, old, 0, at)
    buffer.writeu32(b, 0, total)
    buffer.writeu32(b, 4, math.max(buffer.readu32(old, 4), if text then slot + 1 else 0))
    buffer.writeu32(b, TEXT_SLOTS + slot * 4, if text then size + 1 else 0)
    if text then
        buffer.writestring(b, at, text)
    end
    buffer.copy(b, at + size, old, at + gone, buffer.len(old) - at - gone)
    return buffer.tostring(b)
end

-- The write that stores `text` at slot of text block k, nil for a nil value,
-- or nil when none is needed. Checks the block's size without writing.
local function plan_text(t: any, f: any, block: number, k: string, slot: number,
                         text: string?): (() -> ())?
    local room = MAX_ENTRY - #k
    local stored = barch.store.get(k)
    if stored == nil then
        if text == nil then
            return nil
        end
        if TEXT_VALUES + #text > room then
            too_large(t, f, block, TEXT_VALUES + #text)
        end
        local value = new_text(slot, text)
        return function() barch.store.set(k, value) end
    end
    local value = replace_text(stored, slot, text)
    if #value > room then
        too_large(t, f, block, #value)
    end
    return function() barch.store.set(k, value) end
end

-- How row r stores in a text block.
local function text_of(f: any, v: any): string?
    if v ~= nil and f.kind == "json" then
        return VALUES.json(v)
    end
    return v
end

-- Whether a field's value differs between the old row and the new one.
local function differs(f: any, was: any, v: any): boolean
    if f.kind == "json" and was ~= nil and v ~= nil then
        return VALUES.json(was) ~= VALUES.json(v)
    end
    return was ~= v
end

-- Sets slot of the block's presence to `on` and counts the row in or out.
-- Answers how many rows the block then holds.
local function mark(t: any, block: number, slot: number, on: boolean, lock: boolean?): number
    local key = lay.present(t, block)
    local presence = if lock then barch.store.get(key, true) else barch.store.get(key)
    local n = (presence and live(presence) or 0) + (if on then 1 else -1)
    if n == 0 then
        barch.store.remove(key)
        return 0
    end
    if presence == nil then
        barch.store.setBufferAt(key, NO_ROWS, 0)
    end
    barch.store.setBufferAt(key, if on then PRESENT else ABSENT, slot)
    barch.store.setInt32At(key, n, SIZE)
    return n
end

-- Checks row r for pk, given the row it replaces (nil for a new row), and
-- answers a function that stores it. Everything that can refuse the row
-- happens here, so a caller can check before its first write. `lock` is true
-- for a pessimistic caller.
function write(t: any, fields: any, pk: number, old: any, r: any, lock: boolean?): () -> ()
    rc.validate(fields, r)
    local block, slot = place(pk)
    if lock then
        barch.store.get(lay.present(t, block), true)
    end
    local writes = {}
    for _, f in fields.list do
        local v = r[f.name]
        -- a slot without a row holds nil in every field
        local changed = if old then differs(f, old[f.name], v) else v ~= nil
        if changed then
            local k = block_key(lay.column(t, f.id), block)
            if TEXT_KINDS[f.kind] then
                local put = plan_text(t, f, block, k, slot, text_of(f, v))
                if put then
                    writes[#writes + 1] = put
                end
            else
                local x = v
                if f.kind == "bool" and v ~= nil then
                    x = if v then 1 else 0
                end
                writes[#writes + 1] = function() put_number(k, slot, x) end
            end
        end
    end
    return function()
        if old == nil then
            mark(t, block, slot, true, lock)
        end
        for _, put in writes do
            put()
        end
    end
end

-- Removes the row at pk, which holds `old`. The last row of a block takes
-- the block with it. `lock` is true for a pessimistic caller.
function remove(t: any, fields: any, pk: number, old: any, lock: boolean?)
    local block, slot = place(pk)
    if mark(t, block, slot, false, lock) == 0 then
        for _, f in fields.list do
            barch.store.remove(block_key(lay.column(t, f.id), block))
        end
        return
    end
    for _, f in fields.list do
        if old[f.name] ~= nil then
            local k = block_key(lay.column(t, f.id), block)
            if TEXT_KINDS[f.kind] then
                local put = plan_text(t, f, block, k, slot, nil)
                if put then
                    put()
                end
            else
                put_number(k, slot, nil)
            end
        end
    end
end

function selftest(): (boolean, string?)
    local t = { key = "sale", id = "int" }
    local prefix = lay.row(t)
    local function check(key: string, want: number): string?
        local got = first_id(prefix, key)
        if got ~= want then
            return "first_id wants " .. want .. ", got " .. got
        end
        return nil
    end
    local checks = {
        check(prefix, -math.huge),
        check(kc.after(prefix) :: string, math.huge),
        check(lay.row(t, 0), 0),
        check(lay.row(t, -3), -3),
        check(lay.row(t, 4096), 4096),
        check(lay.row(t, 7) .. "\2", 8),
    }
    for _, id in { 9, 10, 15, 16, 1023, -1, -16 } do
        checks[#checks + 1] = check(kc.after(lay.row(t, id)) :: string, id + 1)
    end
    for _, why in checks do
        return false, why
    end
    local block, slot = place(-1)
    if block ~= -1 or slot ~= SIZE - 1 then
        return false, "place of -1"
    end
    local b = new_text(2, "abc")
    b = replace_text(b, 0, "x")
    b = replace_text(b, 1, "")
    if text_at(b, 0) ~= "x" or text_at(b, 1) ~= "" or text_at(b, 2) ~= "abc"
        or text_at(b, 3) ~= nil then
        return false, "text block slots"
    end
    b = replace_text(b, 2, nil)
    if text_at(b, 0) ~= "x" or text_at(b, 2) ~= nil or #b ~= TEXT_VALUES + 1 then
        return false, "text block removal"
    end
    return true
end

function call()
    local ok, why = selftest()
    return ok and "ok" or ("failed: " .. why)
end
