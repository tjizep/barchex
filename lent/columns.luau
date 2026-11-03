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

local function fill_nil(): buffer
    local b = buffer.create(SIZE * 8)
    for i = 0, SIZE - 1 do
        buffer.writef64(b, i * 8, NAN)
    end
    return b
end

local NIL_NUMBERS = fill_nil()
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
    local stored = barch.store.get(block_key(c.prefix, block))
    local b = if stored then buffer.fromstring(stored) else nil
    c.b = b
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
-- answers how many it kept.
local function filter(c: any, op: string, w: any, sel: { number }, n: number): number
    if c.b == nil and not c.id then
        return if holds(op, c.default, w) then n else 0
    end
    local m = 0
    if not (c.id or c.text or c.bool) and c.default == nil then
        -- NaN, a slot without a value, fails every comparison but ~=
        local b: buffer = c.b
        if op == "<" then
            for i = 1, n do
                local s = sel[i]
                if buffer.readf64(b, s * 8) < w then
                    m += 1
                    sel[m] = s
                end
            end
        elseif op == "<=" then
            for i = 1, n do
                local s = sel[i]
                if buffer.readf64(b, s * 8) <= w then
                    m += 1
                    sel[m] = s
                end
            end
        elseif op == ">" then
            for i = 1, n do
                local s = sel[i]
                if buffer.readf64(b, s * 8) > w then
                    m += 1
                    sel[m] = s
                end
            end
        elseif op == ">=" then
            for i = 1, n do
                local s = sel[i]
                if buffer.readf64(b, s * 8) >= w then
                    m += 1
                    sel[m] = s
                end
            end
        else
            local want = op == "="
            for i = 1, n do
                local s = sel[i]
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

-- Adds the slots sel[1..n], in groups gids[1..n], to aggregate a.
local function fold_aggregate(a: any, sel: { number }, n: number, gids: { number })
    local vals, fn, c = a.vals, a.fn, a.source
    if c == nil then
        -- count with no field counts rows
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
            local x = buffer.readf64(b, sel[i] * 8)
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
        if fn == "sum" or fn == "avg" or fn == "count" then
            local ns = a.ns
            for i = 1, n do
                local x = buffer.readf64(b, sel[i] * 8)
                if x == x then
                    local gi = gids[i]
                    if fn == "count" then
                        vals[gi] = (vals[gi] or 0) + 1
                    else
                        vals[gi] = (vals[gi] or 0) + x
                        if ns then
                            ns[gi] = (ns[gi] or 0) + 1
                        end
                    end
                end
            end
        else
            local min = fn == "min"
            for i = 1, n do
                local x = buffer.readf64(b, sel[i] * 8)
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
    return { sources = list, conds = conds, keys = keys, aggs = aggs, group = spec.group,
             budget = spec.budget, seen = 0, records = {}, tree = {},
             sel = table.create(SIZE, 0), gids = table.create(SIZE, 1) }
end

-- Adds the slots from `a` to `z` of a block to the job's groups. Answers
-- true when the job's budget ran out before the block's last row.
local function fold_block(job: any, block: number, presence: string, a: number, z: number): boolean
    local sel: { number }, n = job.sel, 0
    local budget, seen = job.budget, job.seen
    local more = false
    if a == 0 and z == SIZE - 1 and live(presence) == SIZE
        and (budget == nil or budget - seen >= SIZE) then
        -- a full block reads every slot
        table.move(ALL_SLOTS, 1, SIZE, 1, sel)
        n, seen = SIZE, seen + SIZE
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
    for _, c in job.conds do
        n = filter(c.source, c.op, c.value, sel, n)
        if n == 0 then
            return more
        end
    end
    local gids = job.gids
    local ks = job.keys
    if #ks == 1 and ks[1].text and ks[1].b then
        -- one text key: look its value up in the groups found so far
        local c = ks[1]
        local b: buffer, starts, tree = c.b, c.starts, job.tree
        for i = 1, n do
            local s = sel[i]
            local len = buffer.readu32(b, TEXT_SLOTS + s * 4)
            local gi = if len > 0 then tree[buffer.readstring(b, starts[s + 1], len - 1)] else nil
            gids[i] = gi or group_index(job, s)
        end
    elseif #ks == 1 and not (ks[1].text or ks[1].id or ks[1].bool) and ks[1].b
        and ks[1].default == nil then
        local b: buffer, tree = ks[1].b, job.tree
        for i = 1, n do
            local s = sel[i]
            local x = buffer.readf64(b, s * 8)
            gids[i] = (x == x and tree[x]) or group_index(job, s)
        end
    elseif #ks > 0 then
        for i = 1, n do
            gids[i] = group_index(job, sel[i])
        end
    elseif #job.records == 0 then
        new_group(job, {})
    end
    for _, ag in job.aggs do
        fold_aggregate(ag, sel, n, gids)
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
