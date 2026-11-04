--!native
-- Rows of a table with format = "column", stored by field in blocks.
--
-- Required, not called: `local col = require("lent.COLUMNS")`. A function key
-- has to define call(), so this one answers a self-check:
--
--   lent.COLUMNS             -> "ok" or which check failed (from any space)
--
-- Ids split into blocks: block = floor(id / rows), and the slot is the id's
-- place in its block. Each presence block has one key, and each field one
-- key per block of its own rows, as LAYOUT names them. A table's `block`
-- option, a target size in bytes, sets the rows: the catalog keeps the
-- presence rows in the table's `rows` and each field's in its own `rows`,
-- powers of two, with a field's rows at most the presence rows. A table
-- without `block` keeps 1024 rows in every block and the blocks start
-- with no header.
--
--   presence   a 16-byte header, then a byte per slot, 1 for a slot that
--              holds a row. The header is 1, "p", 0 as a uint16, the rows,
--              the rows held, and 0, as uint32s. Without `block`: the 1024
--              bytes, then the rows held as an int32.
--   number     an 8-byte header (1, "n", 0, the rows), then 8 bytes per
--              slot, an f64, for int, float and what ROWCODEC stores as
--              those, and bool as 1 and 0. NaN is nil, since every row
--              format refuses NaN as a value. Without `block`: no header.
--   short      an int field's block in a table with `block` while its
--              values fit: an 8-byte header (1, "h", 0, the rows), then an
--              int16 per slot, -32768 for nil. A new int block starts short
--              when its first value fits, and becomes a number block for
--              good when a write gives it a value outside +-32767.
--   text       for string, enum, json and bytes: a 24-byte header (1, "t",
--              0, the rows, the bytes in use, the slots in use, the values
--              kept whole elsewhere, 0), a uint32 per slot, then the values
--              in slot order. A slot's uint32 is its length plus 1, and 0
--              for nil. A value longer than CAP bytes keeps its first
--              CAP + 1 bytes here and the whole value at LAYOUT's overflow
--              key, so a stored length past CAP marks it. Without `block`:
--              the bytes and slots in use, the lengths and the values, and
--              every value whole.
--   dictionary a text block of a table with `block` while its values repeat:
--              a 24-byte header (1, "d", 0, the rows, the values in its
--              dictionary, and three 0s), a code per slot, then the
--              dictionary: a uint32 length per value and the values, sorted
--              by byte. A dictionary of up to 255 values takes int8 codes,
--              where code i - 128 is the i-th value and -128 is nil; a
--              larger one takes int16 codes, where code i - 32768 is the
--              i-th value and -32768 is nil. Codes follow the order of the
--              values. A new text block starts as a dictionary, and becomes
--              plain text for good when it would hold more than dict_most()
--              values or a value longer than CAP.
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

local TEXT_KINDS = { string = true, enum = true, json = true, bytes = true }
-- barch's largest key and value together
local MAX_ENTRY = 524032
-- the most bytes of a text value a block keeps whole, with `block`
local CAP = 32
-- the rows of every block without `block`
local LEGACY = 1024

local NAN = 0 / 0

-- barch's vector kernels (docs/barch-vec.md), or nil on a barch without
-- them; folds then run their own Luau loops
local vec = (barch :: any).vec

local function fail(message: string)
    error("LENT " .. message, 0)
end

-- Buffers of `roomy` slots that folds share: each slot's number as an f64,
-- f64s that are all nil, str elements that are all nil, i8s that are all 0,
-- and the slot numbers in a table.
local roomy = 0
local SLOTS, NIL_NUMBERS, NIL_TEXTS, ZEROS = buffer.create(0), buffer.create(0),
    buffer.create(0), buffer.create(0)
local ALL_SLOTS = {}

local function room(n: number)
    if n <= roomy then
        return
    end
    SLOTS, NIL_NUMBERS = buffer.create(n * 8), buffer.create(n * 8)
    NIL_TEXTS, ZEROS = buffer.create(n * 8), buffer.create(n)
    for s = 0, n - 1 do
        buffer.writef64(SLOTS, s * 8, s)
        buffer.writef64(NIL_NUMBERS, s * 8, NAN)
        ALL_SLOTS[s + 1] = s
    end
    roomy = n
end
room(LEGACY)

local PRESENT, ABSENT = buffer.create(1), buffer.create(1)
buffer.writeu8(PRESENT, 0, 1)

-- geometry ---------------------------------------------------------------------

-- A block header: 1, the tag's byte, 0 as a uint16, then the rows.
local function header(size: number, tag: string, rows: number): buffer
    local b = buffer.create(size)
    buffer.writeu8(b, 0, 1)
    buffer.writeu8(b, 1, string.byte(tag))
    buffer.writeu32(b, 4, rows)
    return b
end

local function empty_numbers(data: number, rows: number, b: buffer): buffer
    for s = 0, rows - 1 do
        buffer.writef64(b, data + s * 8, NAN)
    end
    return b
end

-- short blocks: the header's bytes, its tag, the int16 of nil, and the
-- most a short block holds either side of 0
local SHEAD = 8
local STAG = string.byte("h")
local NIL_SHORT = -32768
local SHORT_MOST = 32767

local function is_short(b: buffer): boolean
    return buffer.len(b) > 1 and buffer.readu8(b, 1) == STAG
end

local function fits_short(x: number?): boolean
    return x == nil or (x >= -SHORT_MOST and x <= SHORT_MOST and x == math.floor(x))
end

-- The number block holding the values of short block b, of `rows` slots,
-- written into `out` when it is given.
local function widen(b: buffer, rows: number, out: buffer?): buffer
    local w = out or header(8 + rows * 8, "n", rows)
    if out then
        buffer.writeu8(w, 0, 1)
        buffer.writeu8(w, 1, string.byte("n"))
        buffer.writeu16(w, 2, 0)
        buffer.writeu32(w, 4, rows)
    end
    for s = 0, rows - 1 do
        local h = buffer.readi16(b, SHEAD + s * 2)
        buffer.writef64(w, 8 + s * 8, if h == NIL_SHORT then NAN else h)
    end
    return w
end

local LEGACY_NUMBER = { rows = LEGACY, data = 0,
                        empty = empty_numbers(0, LEGACY, buffer.create(LEGACY * 8)) }
local LEGACY_TEXT = { rows = LEGACY, text = true, used = 0, slots = 4, lens = 8,
                      vals = 8 + LEGACY * 4, cap = math.huge }

-- How a field's blocks are laid out: its rows, and for numbers where the
-- f64s start and an empty block, or for text where each header field, the
-- lengths and the values start and the longest value kept whole.
local function new_spec(rows: number, text: boolean, int: boolean): any
    if text then
        return { rows = rows, text = true, used = 8, slots = 12, over = 16, lens = 24,
                 vals = 24 + rows * 4, cap = CAP, head = true }
    end
    local short
    if int then
        short = header(SHEAD + rows * 2, "h", rows)
        for s = 0, rows - 1 do
            buffer.writei16(short, SHEAD + s * 2, NIL_SHORT)
        end
    end
    return { rows = rows, data = 8, head = true, short = short,
             empty = empty_numbers(8, rows, header(8 + rows * 8, "n", rows)) }
end

local geometries: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

-- How table t lays out its blocks: the presence rows, where the presence
-- bytes and the rows held start, an empty presence block, and each field's
-- spec by id, which spec() fills in.
local function geometry(t: any): any
    local g = geometries[t]
    if g then
        return g
    end
    if t.block == nil then
        g = { rows = LEGACY, pbase = 0, plive = LEGACY, legacy = true,
              empty = buffer.create(LEGACY + 4), specs = {} }
    else
        local rows = t.rows
        g = { rows = rows, pbase = 16, plive = 8, empty = header(16 + rows, "p", rows),
              specs = {} }
    end
    g.t = t
    geometries[t] = g
    return g
end

-- The spec of field f, which has an id and a kind, in table geometry g.
local function spec(g: any, f: any): any
    local sp = g.specs[f.id]
    if sp then
        return sp
    end
    local text = TEXT_KINDS[f.kind] == true
    if g.legacy then
        sp = if text then LEGACY_TEXT else LEGACY_NUMBER
    else
        local rows
        for _, d in g.t.fields do
            if d.id == f.id then
                rows = d.rows
            end
        end
        if rows == nil then
            fail("table " .. g.t.name .. " field " .. f.name .. " has no block rows in the"
                .. " catalog; migrate the schema")
        end
        sp = new_spec(rows, text, f.kind == "int")
    end
    g.specs[f.id] = sp
    return sp
end

local function power(x: number, least: number, most: number): number
    return math.clamp(2 ^ math.round(math.log(math.max(x, 1), 2)), least, most)
end

-- The rows a block holds for a target of `bytes`: presence blocks with f
-- nil, or blocks of catalog field f. A text value's width is its length
-- (its maxLen, its longest enum value, or a guess of 12 bytes, up to the
-- CAP + 1 bytes a block keeps) and 4 bytes for its length. Each count is a
-- power of two, and a field's is at most the presence's.
function block_rows(bytes: number, f: any?): number
    if f == nil then
        return power(bytes, 64, 262144)
    end
    if not TEXT_KINDS[f.kind] then
        return power(bytes / 8, 64, 32768)
    end
    local len = f.maxLen
    if len == nil and f.kind == "enum" and f.values then
        len = 0
        for _, v in f.values do
            len = math.max(len, #tostring(v))
        end
    end
    -- 8192 rows of CAP + 1 bytes and a length each fit in a block
    return power(bytes / (4 + math.min(len or 12, CAP + 1)), 64, 8192)
end

local function check_rows(t: any, what: string, block: number, got: number, rows: number)
    if got ~= rows then
        fail("table " .. t.name .. " " .. what .. " block " .. block .. " holds " .. got
            .. " rows, and the catalog gives " .. rows .. "; the stored blocks do not match"
            .. " the schema")
    end
end

-- dictionary blocks ------------------------------------------------------------

local DTAG = string.byte("d")
-- where a dictionary block's codes start
local DHEAD = 24
-- the code of nil with int8 codes; the i-th value, counting from 1, has
-- code i - 128
local NIL_CODE = -128

local function is_dict(b: buffer): boolean
    return buffer.readu8(b, 1) == DTAG
end

-- The bytes of each code of a dictionary of k values.
local function width_of(k: number): number
    return if k <= 255 then 1 else 2
end

-- The code of nil among codes of `width` bytes. Code c stands for value
-- c - nil_code(width), counting from 1.
local function nil_code(width: number): number
    return if width == 1 then NIL_CODE else -32768
end

-- The vec kind of codes of `width` bytes.
local function code_kind(width: number): string
    return if width == 1 then "i8" else "i16"
end

local function read_code(b: buffer, at: number, width: number): number
    return if width == 1 then buffer.readi8(b, at) else buffer.readi16(b, at)
end

local function write_code(b: buffer, at: number, width: number, code: number)
    if width == 1 then
        buffer.writei8(b, at, code)
    else
        buffer.writei16(b, at, code)
    end
end

-- The bytes of each code of dictionary block b.
local function code_width(b: buffer): number
    return width_of(buffer.readu32(b, 8))
end

-- The most values a dictionary block of `rows` slots holds. Past half the
-- rows, a code and a dictionary entry cost more than a plain length.
local function dict_most(rows: number): number
    return math.min(65535, rows // 2)
end

-- The sorted values of dictionary block b of `rows` slots.
local function dict_of(b: buffer, rows: number): { string }
    local k = buffer.readu32(b, 8)
    local out = table.create(k)
    local lens = DHEAD + rows * code_width(b)
    local at = lens + k * 4
    for i = 1, k do
        local len = buffer.readu32(b, lens + (i - 1) * 4)
        out[i] = buffer.readstring(b, at, len)
        at += len
    end
    return out
end

-- The i-th value of dictionary block b of `rows` slots.
local function dict_value(b: buffer, rows: number, i: number): string
    local lens = DHEAD + rows * code_width(b)
    local at = lens + buffer.readu32(b, 8) * 4
    for j = 0, i - 2 do
        at += buffer.readu32(b, lens + j * 4)
    end
    return buffer.readstring(b, at, buffer.readu32(b, lens + (i - 1) * 4))
end

-- `codes` of `rows` slots, `width` bytes each, as codes `to` bytes each.
local function recode(codes: buffer, rows: number, width: number, to: number): buffer
    local d = nil_code(to) - nil_code(width)
    local out = buffer.create(rows * to)
    for s = 0, rows - 1 do
        write_code(out, s * to, to, read_code(codes, s * width, width) + d)
    end
    return out
end

-- A dictionary block of `rows` slots with `codes` of `width` bytes and the
-- sorted values `dict`.
local function dict_block(rows: number, codes: buffer, width: number, dict: { string }): string
    local to = width_of(#dict)
    if to ~= width then
        codes = recode(codes, rows, width, to)
    end
    local lens = DHEAD + rows * to
    local size = lens + #dict * 4
    for _, v in dict do
        size += #v
    end
    local b = header(size, "d", rows)
    buffer.writeu32(b, 8, #dict)
    buffer.copy(b, DHEAD, codes, 0, rows * to)
    local at = lens + #dict * 4
    for i, v in dict do
        buffer.writeu32(b, lens + (i - 1) * 4, #v)
        buffer.writestring(b, at, v)
        at += #v
    end
    return buffer.tostring(b)
end

-- The index of the first of the sorted values `dict` at or past w, from 1
-- to #dict + 1.
local function lower(dict: { string }, w: string): number
    local lo, hi = 1, #dict + 1
    while lo < hi do
        local mid = (lo + hi) // 2
        if dict[mid] < w then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

-- Adds d to each code of `width` bytes in `codes` from `from` up.
local function shift(codes: buffer, rows: number, width: number, from: number, d: number)
    local none = nil_code(width)
    for s = 0, rows - 1 do
        local c = read_code(codes, s * width, width)
        if c ~= none and c >= from then
            write_code(codes, s * width, width, c + d)
        end
    end
end

-- Whether a slot of `codes`, `width` bytes each, holds `code`.
local function holds_code(codes: buffer, width: number, code: number): boolean
    local text = buffer.tostring(codes)
    local find = if width == 1 then string.char(code % 256) else string.pack("<i2", code)
    local at = string.find(text, find, 1, true)
    -- a match must start at a code, and not inside one
    while at and (at - 1) % width ~= 0 do
        at = string.find(text, find, at + 1, true)
    end
    return at ~= nil
end

-- blocks -----------------------------------------------------------------------

local function place(rows: number, pk: number): (number, number)
    local block = pk // rows
    return block, pk - block * rows
end

local function block_key(prefix: string, block: number): string
    return prefix .. kc.encode("int", block)
end

local function live(g: any, presence: string): number
    return (string.unpack("<i4", presence, g.plive + 1))
end

local function check_presence(g: any, block: number, presence: string)
    if not g.legacy then
        check_rows(g.t, "presence", block, (string.unpack("<I4", presence, 5)), g.rows)
    end
end

-- Whether a presence block, as stored before slot `slot` changed, holds a
-- row in slots `from` to from + n - 1 besides `slot`.
local function others(g: any, presence: string?, from: number, n: number, slot: number): boolean
    if presence == nil then
        return false
    end
    local lo, me = g.pbase + from + 1, g.pbase + slot + 1
    local at = string.find(presence, "\1", lo, true)
    if at == me then
        at = string.find(presence, "\1", me + 1, true)
    end
    return at ~= nil and at < lo + n
end

-- The whole value of the field whose overflow prefix is `okey` at row pk,
-- whose block keeps only its start.
local function long_value(t: any, name: string, okey: string, pk: number): string
    local v = barch.store.get(okey .. kc.encode("int", pk))
    if v == nil then
        fail("table " .. t.name .. " field " .. name .. " row " .. pk .. " has lost the rest"
            .. " of its value")
    end
    return v :: string
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
local function span(t: any, g: any, lo: string, hi: string): (number, number, string, string)
    local prefix = lay.row(t)
    local from, last = first_id(prefix, lo), first_id(prefix, hi) - 1
    local all = lay.present(t)
    local plo = if from == -math.huge then all else lay.present(t, from // g.rows)
    local phi = if last == math.huge then kc.after(all) else
        kc.after(lay.present(t, last // g.rows))
    return from, last, plo, phi :: string
end

-- how each field a scan reads is held, in the order of `fields.list`
local function columns(t: any, g: any, fields: any, need: any): { any }
    local out = {}
    for _, f in fields.list do
        if need == nil or need[f.name] then
            local sp = spec(g, f)
            out[#out + 1] = { name = f.name, prefix = lay.column(t, f.id),
                              okey = lay.overflow(t, f.id), spec = sp,
                              text = TEXT_KINDS[f.kind] == true, json = f.kind == "json",
                              bool = f.kind == "bool", starts = table.create(sp.rows, 0) }
        end
    end
    return out
end

-- Where each slot's value starts in text block b, laid out as sp says.
local function starts_of(sp: any, b: buffer, starts: { number })
    local at, lens = sp.vals, sp.lens
    for s = 0, sp.rows - 1 do
        starts[s + 1] = at
        local len = buffer.readu32(b, lens + s * 4)
        if len > 0 then
            at += len - 1
        end
    end
end

-- The slots from `a` to `z` of presence block `block`, in order or, with
-- `back`, highest first, as rows of the fields in `cols`. Calls each(pk, row)
-- until it answers true, and answers whether it did.
local function read_block(t: any, g: any, cols: { any }, block: number, presence: string,
                          a: number, z: number, back: boolean?,
                          each: (number, any) -> boolean?): boolean
    check_presence(g, block, presence)
    local n = #cols
    for i = 1, n do
        cols[i].fb = nil
    end
    local base, pbase = block * g.rows, g.pbase
    for s = if back then z else a, if back then a else z, if back then -1 else 1 do
        if string.byte(presence, pbase + s + 1) == 1 then
            local pk = base + s
            local r = {}
            for i = 1, n do
                local c = cols[i]
                local sp = c.spec
                local rows = sp.rows
                local fb = pk // rows
                if fb ~= c.fb then
                    local stored = barch.store.get(block_key(c.prefix, fb))
                    local b = stored and buffer.fromstring(stored) or false
                    if b and sp.head then
                        check_rows(t, "field " .. c.name, fb, buffer.readu32(b, 4), rows)
                    end
                    c.dict = nil
                    c.short = b and not c.text and sp.short ~= nil and is_short(b)
                    if b and c.text then
                        if sp.head and is_dict(b) then
                            c.dict, c.cw = dict_of(b, rows), code_width(b)
                        else
                            starts_of(sp, b, c.starts)
                        end
                    end
                    c.fb, c.b = fb, b
                end
                local b = c.b
                if b then
                    local fs = pk - fb * rows
                    local dict = c.dict
                    if dict then
                        local cw = c.cw
                        local code = read_code(b, DHEAD + fs * cw, cw)
                        local none = nil_code(cw)
                        if code ~= none then
                            local v = dict[code - none]
                            r[c.name] = if c.json then VALUES.parse_json(v) else v
                        end
                    elseif c.text then
                        local len = buffer.readu32(b, sp.lens + fs * 4)
                        if len > 0 then
                            local v = if len - 1 > sp.cap then long_value(t, c.name, c.okey, pk)
                                else buffer.readstring(b, c.starts[fs + 1], len - 1)
                            r[c.name] = if c.json then VALUES.parse_json(v) else v
                        end
                    elseif c.short then
                        local h = buffer.readi16(b, SHEAD + fs * 2)
                        if h ~= NIL_SHORT then
                            r[c.name] = h
                        end
                    else
                        local x = buffer.readf64(b, sp.data + fs * 8)
                        if x == x then
                            r[c.name] = if c.bool then x == 1 else x
                        end
                    end
                end
            end
            if each(pk, r) then
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
    local g = geometry(t)
    local rows = g.rows
    local from, last, plo, phi = span(t, g, lo, hi)
    if from > last then
        return false
    end
    local cols = columns(t, g, fields, need)
    local page = math.clamp((first or rows * 16) // rows + 1, 1, 16)
    local function run(keys: { string }, values: { string }, i: number): boolean
        local block = lay.present_block(keys[i])
        local base = block * rows
        local a, z = math.max(from - base, 0), math.min(last - base, rows - 1)
        return a <= z and read_block(t, g, cols, block, values[i], a, z, back, each)
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
    local g = geometry(t)
    local rows, pbase = g.rows, g.pbase
    local from, last, plo, phi = span(t, g, lo, hi)
    if from > last then
        return 0
    end
    local n = 0
    while true do
        local keys, values = barch.store.rangeValues(plo, phi, 256)
        for i, k in keys do
            local base = lay.present_block(k) * rows
            local a, z = math.max(from - base, 0), math.min(last - base, rows - 1)
            if a == 0 and z == rows - 1 then
                n += live(g, values[i])
            else
                for s = a, z do
                    if string.byte(values[i], pbase + s + 1) == 1 then
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

-- How many rows presence block value `presence` of table t holds.
function rows_in(t: any, presence: string): number
    return live(geometry(t), presence)
end

-- The id of row n, counted from 0, of block `block` of table t, whose
-- presence block value is `presence`, or nil when the block holds n rows or
-- fewer.
function nth_id(t: any, block: number, presence: string, n: number): number?
    local g = geometry(t)
    for s = 0, g.rows - 1 do
        if string.byte(presence, g.pbase + s + 1) == 1 then
            if n == 0 then
                return block * g.rows + s
            end
            n -= 1
        end
    end
    return nil
end

-- folds -----------------------------------------------------------------------
--
-- A fold reads a presence block in chunks of job.unit slots, the fewest rows
-- of any block it reads, so each chunk lies in one block of every field.
-- Slots in a fold count from the chunk's first id.

-- A field a fold reads: "id", which reads each row's id, or a field's
-- blocks, with the value a slot without one reads as.
local function source(t: any, g: any, fields: any, name: string): any
    if name == "id" then
        return { id = true, base = 0 }
    end
    local f
    for _, d in fields.list do
        if d.name == name then
            f = d
        end
    end
    local default
    for _, d in t.fields do
        if d.name == name then
            default = d.default
        end
    end
    local sp = spec(g, f)
    return { name = name, prefix = lay.column(t, f.id), okey = lay.overflow(t, f.id), spec = sp,
             rows = sp.rows, text = TEXT_KINDS[f.kind] == true, bool = f.kind == "bool",
             default = default, starts = table.create(sp.rows, 0), off = 0, at = 0 }
end

-- Reads the block of source c that holds id `first`, unless it holds it
-- already, or notes that the block holds no value. Sets c.off to the slot
-- of `first` in the block, and c.at to where its f64 starts.
local function load(t: any, c: any, first: number)
    if c.id then
        c.base = first
        return
    end
    local rows = c.rows
    local fb = first // rows
    if fb ~= c.fb then
        -- a key removed in this transaction reads as barch.tomb
        local stored = barch.store.getBufferAt(block_key(c.prefix, fb), 0)
        local b = if type(stored) == "buffer" then stored else nil
        if b and c.spec.head then
            check_rows(t, "field " .. c.name, fb, buffer.readu32(b, 4), rows)
        end
        c.b, c.fb, c.located, c.elements = b, fb, false, false
        c.coded, c.gmap = c.text and b ~= nil and c.spec.head == true and is_dict(b), nil
        if c.coded then
            c.cw = code_width(b :: buffer)
            c.cnil = nil_code(c.cw)
        end
        c.short = not c.text and b ~= nil and c.spec.short ~= nil and is_short(b)
    end
    c.off = first - fb * rows
    c.at = if c.text then 0 else c.spec.data + c.off * 8
end

-- Finds where each slot's value starts in text source c's loaded block, or
-- reads its dictionary and the bytes that hold it. A dictionary stored the
-- same as the last block's keeps the values read from that block.
local function locate(c: any)
    local b: buffer = c.b
    if c.coded then
        local at = DHEAD + c.rows * c.cw
        local key = buffer.readstring(b, at, buffer.len(b) - at)
        if key ~= c.dictkey then
            c.dict, c.dictkey = dict_of(b, c.rows), key
        end
    else
        starts_of(c.spec, b, c.starts)
    end
    c.located = true
end

-- The value of chunk slot s in source c's loaded block.
local function value_at(c: any, s: number): any
    if c.id then
        return c.base + s
    end
    local b = c.b
    if b == nil then
        return c.default
    end
    if c.coded then
        local cw = c.cw
        local code = read_code(b, DHEAD + (c.off + s) * cw, cw)
        if code == c.cnil then
            return c.default
        end
        if not c.located then
            locate(c)
        end
        return c.dict[code - c.cnil]
    end
    if c.text then
        local sp = c.spec
        local fs = c.off + s
        local len = buffer.readu32(b, sp.lens + fs * 4)
        if len == 0 then
            return c.default
        end
        if len - 1 > sp.cap then
            return long_value(c.table, c.name, c.okey, c.fb * c.rows + fs)
        end
        if not c.located then
            locate(c)
        end
        return buffer.readstring(b, c.starts[fs + 1], len - 1)
    end
    if c.short then
        local h = buffer.readi16(b, SHEAD + (c.off + s) * 2)
        return if h == NIL_SHORT then c.default else h
    end
    local x = buffer.readf64(b, c.at + s * 8)
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
        local b: buffer, at = c.b, c.at
        if op == "<" then
            for i = 1, n do
                local s = if full then i - 1 else sel[i]
                if buffer.readf64(b, at + s * 8) < w then
                    m += 1
                    sel[m] = s
                end
            end
        elseif op == "<=" then
            for i = 1, n do
                local s = if full then i - 1 else sel[i]
                if buffer.readf64(b, at + s * 8) <= w then
                    m += 1
                    sel[m] = s
                end
            end
        elseif op == ">" then
            for i = 1, n do
                local s = if full then i - 1 else sel[i]
                if buffer.readf64(b, at + s * 8) > w then
                    m += 1
                    sel[m] = s
                end
            end
        elseif op == ">=" then
            for i = 1, n do
                local s = if full then i - 1 else sel[i]
                if buffer.readf64(b, at + s * 8) >= w then
                    m += 1
                    sel[m] = s
                end
            end
        else
            local want = op == "="
            for i = 1, n do
                local s = if full then i - 1 else sel[i]
                local x = buffer.readf64(b, at + s * 8)
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

-- Sets the records from `from` to `to` - 1 to no values: a count and sum of
-- 0, a least of inf and a greatest of -inf.
local function clear_records(r: buffer, from: number, to: number)
    buffer.fill(r, from * 32, 0, (to - from) * 32)
    for i = from, to - 1 do
        buffer.writef64(r, i * 32 + 16, math.huge)
        buffer.writef64(r, i * 32 + 24, -math.huge)
    end
end

local function new_records(n: number): buffer
    local r = buffer.create(n * 32)
    clear_records(r, 0, n)
    return r
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
        local at = c.at
        local sum, any = vals[1] or 0, false
        for i = 1, n do
            local x = buffer.readf64(b, at + (if full then i - 1 else sel[i]) * 8)
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
        local ns, at = a.ns, c.at
        if fn == "count" then
            for i = 1, n do
                local x = buffer.readf64(b, at + (if full then i - 1 else sel[i]) * 8)
                if x == x then
                    local gi = gids[i]
                    vals[gi] = (vals[gi] or 0) + 1
                end
            end
        elseif fn == "sum" then
            for i = 1, n do
                local x = buffer.readf64(b, at + (if full then i - 1 else sel[i]) * 8)
                if x == x then
                    local gi = gids[i]
                    vals[gi] = (vals[gi] or 0) + x
                end
            end
        elseif fn == "avg" then
            for i = 1, n do
                local x = buffer.readf64(b, at + (if full then i - 1 else sel[i]) * 8)
                if x == x then
                    local gi = gids[i]
                    vals[gi] = (vals[gi] or 0) + x
                    ns[gi] = (ns[gi] or 0) + 1
                end
            end
        else
            local min = fn == "min"
            for i = 1, n do
                local x = buffer.readf64(b, at + (if full then i - 1 else sel[i]) * 8)
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
    local g = geometry(t)
    local sources = {}
    local function get(name: string): any
        local c = sources[name]
        if c == nil then
            c = source(t, g, fields, name)
            c.table = t
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
    local list, unit = {}, g.rows
    for _, c in sources do
        list[#list + 1] = c
        if not c.id then
            unit = math.min(unit, c.rows)
        end
    end
    room(unit)
    local job = { t = t, g = g, unit = unit, sources = list, conds = conds, keys = keys,
                  aggs = aggs, group = spec.group, budget = spec.budget, seen = 0,
                  records = {}, tree = {}, short = {},
                  sel = table.create(unit, 0), gids = table.create(unit, 1) }
    if vec and vectors(conds, keys, aggs) then
        -- each aggregate adds to records that grouper id i keeps at 32 * i,
        -- and finish adds them to group gis[i + 1]
        job.vec, job.gis, job.capacity = vec, if #keys == 0 then { 1 } else {}, 0
        job.presence = buffer.create(g.pbase + g.rows)
        job.selb, job.gidb = buffer.create(unit * 4), buffer.create(unit * 4)
        -- text sources whose order or groups a long value would change
        local texts = {}
        for _, c in conds do
            if c.source.text and c.source.spec.over then
                texts[#texts + 1] = c.source
            end
        end
        if #keys == 1 then
            job.grouper = vec.grouper(if keys[1].text then "str" else "f64")
            if keys[1].text and keys[1].spec.over then
                texts[#texts + 1] = keys[1]
            end
            if keys[1].text and keys[1].spec.head then
                -- dictionary blocks fold into records by code; see flush_codes
                job.csize, job.ccap = 0, 256
                for _, a in aggs do
                    a.crecs = new_records(256)
                end
            end
        end
        job.texts = texts
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

-- Sets gids[1..n] to the groups of the slots in sel[1..n] by text key c,
-- whose loaded block is a dictionary block, one lookup per code.
local function dict_gids(job: any, c: any, sel: { number }, n: number, gids: { number }, full: boolean)
    local b: buffer, cw = c.b, c.cw
    local at = DHEAD + c.off * cw
    local map = c.gmap
    if map == nil then
        map = {}
        c.gmap = map
    end
    for i = 1, n do
        local s = if full then i - 1 else sel[i]
        local code = read_code(b, at + s * cw, cw)
        local gi = map[code]
        if gi == nil then
            gi = group_index(job, s)
            map[code] = gi
        end
        gids[i] = gi
    end
end

-- Sets gids[1..n] to the groups of the slots in sel[1..n] by text key c.
local function text_gids(job: any, c: any, sel: { number }, n: number, gids: { number }, full: boolean)
    if c.coded then
        dict_gids(job, c, sel, n, gids, full)
        return
    end
    -- a value of up to 6 bytes, with its length, makes a number below 2^53
    -- that names its group without making a string
    local b: buffer, starts, tree, short = c.b, c.starts, job.tree, job.short
    local sp, off = c.spec, c.off
    local blen, lens, cap = buffer.len(b), sp.lens + off * 4, sp.cap
    if not (c.located or (full and off == 0)) then
        locate(c)
    end
    -- a full chunk's values follow each other in slot order
    local at = if off == 0 then sp.vals else starts[off + 1]
    for i = 1, n do
        local s = if full then i - 1 else sel[i]
        local len = buffer.readu32(b, lens + s * 4) - 1
        if not full then
            at = starts[off + s + 1]
        end
        local gi
        if len < 0 or len > cap then
            -- nil, or a value the block keeps only the start of
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
    local b: buffer, tree, at = c.b, job.tree, c.at
    for i = 1, n do
        local s = if full then i - 1 else sel[i]
        local x = buffer.readf64(b, at + s * 8)
        gids[i] = (x == x and tree[x]) or group_index(job, s)
    end
end

-- Adds the n rows of a full chunk whose value of source c passes `op w` to
-- the one-group sum a, in one pass. Answers false when the job doesn't have
-- that shape.
local function filtered_sum(c: any, op: string, w: any, a: any, n: number): boolean
    local v: buffer?, b: buffer? = a.source.b, c.b
    if v == nil or b == nil then
        return false
    end
    local vat, bat = a.source.at, c.at
    local sum, any = a.vals[1] or 0, false
    if op == "<" then
        for s = 0, n - 1 do
            if buffer.readf64(b, bat + s * 8) < w then
                local x = buffer.readf64(v, vat + s * 8)
                if x == x then
                    sum += x
                    any = true
                end
            end
        end
    elseif op == "<=" then
        for s = 0, n - 1 do
            if buffer.readf64(b, bat + s * 8) <= w then
                local x = buffer.readf64(v, vat + s * 8)
                if x == x then
                    sum += x
                    any = true
                end
            end
        end
    elseif op == ">" then
        for s = 0, n - 1 do
            if buffer.readf64(b, bat + s * 8) > w then
                local x = buffer.readf64(v, vat + s * 8)
                if x == x then
                    sum += x
                    any = true
                end
            end
        end
    else
        for s = 0, n - 1 do
            if buffer.readf64(b, bat + s * 8) >= w then
                local x = buffer.readf64(v, vat + s * 8)
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

-- Text source c's loaded block as str elements: a buffer of an element per
-- slot of the block, then the block, which the elements point into. A
-- chunk's elements start at byte c.off * 8.
local function elements(v: any, c: any): buffer
    local w = c.work
    if not c.elements then
        local b: buffer, sp = c.b, c.spec
        local head = sp.rows * 8
        local need = head + buffer.len(b)
        if w == nil or buffer.len(w) < need then
            w = buffer.create(need)
            c.work = w
        end
        buffer.copy(w, head, b)
        v.offsets(w, head + sp.lens, sp.rows, head + sp.vals, w)
        c.elements = true
    end
    return w
end

-- Makes room in each aggregate's records for `size` grouper ids, of the
-- job's grouper, or of the short lane's when `lane` is given.
local function grow(job: any, size: number, lane: any?)
    local l = lane or job
    local was = l.capacity
    if size <= was then
        return
    end
    local cap = math.max(size, was * 2, 16)
    local field = if lane then "srecs" else "recs"
    for _, a in job.aggs do
        local r = new_records(cap)
        if a[field] then
            buffer.copy(r, 0, a[field], 0, was * 32)
        end
        a[field] = r
    end
    l.capacity = cap
end

-- Gives the grouper's ids from #gis to size - 1 their groups, for the job's
-- grouper, or the short lane's when `lane` is given.
local function new_ids(job: any, size: number, lane: any?)
    local l = lane or job
    local g, gis, tree = l.grouper, l.gis, job.tree
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
    grow(job, size, lane)
end

-- Adds the rows at chunk slots sel[1..n] to the job's groups with Luau
-- loops, once the chunk's blocks are loaded. `full` says sel holds every
-- slot of the chunk in order.
local function luau_rows(job: any, sel: { number }, n: number, full: boolean)
    -- the Luau loops read f64s
    for _, c in job.sources do
        if c.short then
            c.wide = widen(c.b, c.rows, c.wide)
            c.b, c.short = c.wide, false
        end
    end
    local fuse = job.fuse
    if full and fuse then
        if #job.records == 0 then
            new_group(job, {})
        end
        if filtered_sum(fuse.source, fuse.op, fuse.value, job.aggs[1], n) then
            return
        end
    end
    local unit = job.unit
    for _, c in job.conds do
        n = filter(c.source, c.op, c.value, sel, n, full)
        if n == 0 then
            return
        end
        full = full and n == unit
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
end

-- Whether the chunk of `unit` slots whose presence bytes start at byte
-- `from` of `presence` holds a row in every slot.
local function packed(presence: string, from: number, unit: number): boolean
    local gap = string.find(presence, "\0", from + 1, true)
    return gap == nil or gap > from + unit
end

local function load_sources(job: any, first: number)
    local t = job.t
    for _, c in job.sources do
        load(t, c, first)
    end
end

-- The test on codes of text source c's dictionary block that matches
-- `op w` on its values: an op and a code for vec.filter, "none" when no
-- value passes, or "all" when every slot passes.
local function code_bound(c: any, op: string, w: string): (string, number)
    if not c.located then
        locate(c)
    end
    local dict = c.dict
    local k = #dict
    -- lt values sort before w, and le are at most w
    local lt = lower(dict, w) - 1
    local le = if dict[lt + 1] == w then lt + 1 else lt
    -- the code of the value after the lt or le values
    local after_lt, after_le = lt + 1 + c.cnil, le + 1 + c.cnil
    if op == "=" then
        return if le > lt then "=" else "none", after_lt
    elseif op == "~=" then
        return if le > lt then "~=" else "all", after_lt
    elseif op == "<" then
        return if lt > 0 then "<" else "none", after_lt
    elseif op == "<=" then
        return if le > 0 then "<" else "none", after_le
    elseif op == ">" then
        return if le < k then ">=" else "none", after_le
    end
    return if lt < k then ">=" else "none", after_lt
end

-- Adds record `at` of buffer r, which ran on barch.vec, to group gi's
-- running values of aggregate a.
local function add_record(a: any, r: buffer, at: number, gi: number)
    local count = buffer.readf64(r, at)
    if count == 0 then
        return
    end
    local vals, fn = a.vals, a.fn
    local acc = vals[gi]
    if fn == "count" then
        vals[gi] = (acc or 0) + count
    elseif fn == "sum" then
        vals[gi] = (acc or 0) + buffer.readf64(r, at + 8)
    elseif fn == "avg" then
        vals[gi] = (acc or 0) + buffer.readf64(r, at + 8)
        a.ns[gi] = (a.ns[gi] or 0) + count
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

-- Adds the records that dictionary blocks folded by code to the job's
-- groups, by the values the codes stood for, and clears them. Blocks with
-- the same dictionary share one set of records, so this runs when the
-- dictionary changes and when the fold ends.
local function flush_codes(job: any)
    local size = job.csize
    if not size or size == 0 then
        return
    end
    local g, dict, tree, none = job.codes, job.cmap, job.tree, job.cnil
    job.cdict = nil
    for id = 0, size - 1 do
        local code = g:key(id)
        local value = if code == nil then nil else dict[code - none]
        local k = if value == nil then NIL_KEY else value
        local gi = tree[k]
        if gi == nil then
            gi = new_group(job, { value })
            tree[k] = gi
        end
        for _, a in job.aggs do
            add_record(a, a.crecs, id * 32, gi)
        end
    end
    for _, a in job.aggs do
        clear_records(a.crecs, 0, size)
    end
    job.csize = 0
end

-- fold_chunk with barch.vec: the selection, group ids and running values
-- stay in buffers, and each step is one kernel call over the chunk. A text
-- block with a value it keeps only the start of runs luau_rows.
local function vector_chunk(job: any, first: number, presence: string, from: number,
                            a: number, z: number, packed_block: boolean): boolean
    local v, unit = job.vec, job.unit
    local selb: buffer = job.selb
    local budget, seen = job.budget, job.seen
    local sel: buffer?, n, more = nil, unit, false
    if not (a == 0 and z == unit - 1 and (packed_block or packed(presence, from, unit))
            and (budget == nil or budget - seen >= unit)) then
        -- job.presence holds no rows outside the fold's range
        sel, n = selb, v.mask(job.presence, from, unit, selb)
        if budget ~= nil and n > budget - seen then
            n, more = budget - seen, true
        end
    end
    job.seen = seen + n
    if n == 0 then
        return more
    end
    job.last = first + (if sel then buffer.readu32(sel, (n - 1) * 4) else n - 1)
    load_sources(job, first)
    for _, c in job.texts do
        local sp = c.spec
        if c.b and buffer.readu32(c.b, sp.over) > 0 then
            local slots = job.sel
            if sel then
                for i = 1, n do
                    slots[i] = buffer.readu32(sel, (i - 1) * 4)
                end
            else
                table.move(ALL_SLOTS, 1, n, 1, slots)
            end
            luau_rows(job, slots, n, sel == nil)
            return more
        end
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
        elseif c.coded then
            local op, code = code_bound(c, cd.op, cd.value)
            if op == "none" then
                return more
            elseif op ~= "all" then
                local cw = c.cw
                n = v.filter(code_kind(cw), c.b, DHEAD + c.off * cw, cw, op, code, c.cnil, sel, n,
                    selb)
                sel = selb
                if n == 0 then
                    return more
                end
            end
        else
            local kind, b, at, stride, none = "f64", c.b, c.at, 8, nil
            if c.text then
                kind, b, at = "str", elements(v, c), c.off * 8
            elseif c.short then
                kind, at, stride, none = "i16", SHEAD + c.off * 2, 2, NIL_SHORT
            end
            n = v.filter(kind, b, at, stride, cd.op, cd.value, none, sel, n, selb)
            sel = selb
            if n == 0 then
                return more
            end
        end
    end
    local gids: buffer? = nil
    local k = job.keys[1]
    local coded = k and k.coded
    if coded then
        if not k.located then
            locate(k)
        end
        if job.cdict ~= k.dictkey then
            -- codes stand for other values from here
            flush_codes(job)
            job.cdict, job.cmap, job.cnil = k.dictkey, k.dict, k.cnil
            job.codes = v.grouper(code_kind(k.cw))
        end
        gids = job.gidb
        job.csize = job.codes:ids(k.b, DHEAD + k.off * k.cw, k.cw, k.cnil, sel, n, gids)
        if job.csize > job.ccap then
            -- int16 codes number more groups than the records hold
            local cap = math.max(job.csize, job.ccap * 2)
            for _, a in job.aggs do
                local r = new_records(cap)
                buffer.copy(r, 0, a.crecs, 0, job.ccap * 32)
                a.crecs = r
            end
            job.ccap = cap
        end
    elseif k and k.short then
        -- short blocks group on their own grouper; add_records joins the
        -- groups by value
        local lane = job.slane
        if lane == nil then
            lane = { grouper = v.grouper("i16"), gis = {}, capacity = 0 }
            job.slane = lane
        end
        gids = job.gidb
        local size = lane.grouper:ids(k.b, SHEAD + k.off * 2, 2, NIL_SHORT, sel, n, gids)
        if size > #lane.gis then
            new_ids(job, size, lane)
        end
    elseif k then
        local b, at = k.b, k.at
        if b == nil then
            b, at = if k.text then NIL_TEXTS else NIL_NUMBERS, 0
        elseif k.text then
            b, at = elements(v, k), k.off * 8
        end
        gids = job.gidb
        local size = job.grouper:ids(b, at, 8, nil, if k.b == nil then nil else sel, n, gids)
        if size > #job.gis then
            new_ids(job, size)
        end
    else
        if #job.records == 0 then
            new_group(job, {})
        end
        -- luau_rows may have made the group, and not these records
        grow(job, 1)
    end
    for _, ag in job.aggs do
        local c = ag.source
        local recs = if coded then ag.crecs elseif k and k.short then ag.srecs else ag.recs
        if c == nil then
            v.fold("i8", ZEROS, 0, 1, nil, sel, n, gids, recs)
        elseif c.short then
            v.fold("i16", c.b, SHEAD + c.off * 2, 2, NIL_SHORT, sel, n, gids, recs)
        elseif c.b ~= nil then
            v.fold("f64", c.b, c.at, 8, nil, sel, n, gids, recs)
        end
    end
    return more
end

-- Adds the slots from `a` to `z` of the chunk starting at id `first`, whose
-- presence bytes start at byte `from` of `presence`, to the job's groups.
-- Answers true when the job's budget ran out before the chunk's last row.
local function fold_chunk(job: any, first: number, presence: string, from: number, a: number,
                          z: number, packed_block: boolean): boolean
    if job.vec then
        return vector_chunk(job, first, presence, from, a, z, packed_block)
    end
    local unit = job.unit
    local sel: { number }, n = job.sel, 0
    local budget, seen = job.budget, job.seen
    local more, full = false, false
    if a == 0 and z == unit - 1 and (packed_block or packed(presence, from, unit))
        and (budget == nil or budget - seen >= unit) then
        -- a full chunk reads every slot
        table.move(ALL_SLOTS, 1, unit, 1, sel)
        n, seen, full = unit, seen + unit, true
    else
        for s = a, z do
            if string.byte(presence, from + s + 1) == 1 then
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
    if n == 0 then
        return more
    end
    job.last = first + sel[n]
    load_sources(job, first)
    luau_rows(job, sel, n, full)
    return more
end

-- Adds the slots from `a` to `z` of a presence block to the job's groups,
-- a chunk at a time. Answers true when the job's budget ran out before the
-- block's last row.
local function fold_block(job: any, block: number, presence: string, a: number, z: number): boolean
    local g, unit = job.g, job.unit
    local rows, pbase = g.rows, g.pbase
    check_presence(g, block, presence)
    local whole = a == 0 and z == rows - 1
    local packed_block = whole and live(g, presence) == rows
    if job.vec and not (packed_block and job.budget == nil) then
        local pb: buffer = job.presence
        buffer.writestring(pb, 0, presence, pbase + rows)
        buffer.fill(pb, pbase, 0, a)
        buffer.fill(pb, pbase + z + 1, 0, rows - 1 - z)
    end
    local base = block * rows
    for c = a - a % unit, z, unit do
        local ca, cz = math.max(a - c, 0), math.min(z - c, unit - 1)
        if fold_chunk(job, base + c, presence, pbase + c, ca, cz, packed_block) then
            return true
        end
    end
    return false
end

-- Adds the rows of the job's table from `lo` up to `hi`, row keys or key
-- bounds, in id order, to its groups. Answers true when the budget ran out
-- first; job.last is then the last id read, and job.seen counts the rows
-- read.
function fold(t: any, job: any, lo: string, hi: string): boolean
    local g = job.g
    local from, last, plo, phi = span(t, g, lo, hi)
    if from > last then
        return false
    end
    -- blocks read in an earlier call may have changed since
    for _, c in job.sources do
        c.fb = nil
    end
    local rows = g.rows
    while true do
        local keys, values = barch.store.rangeValues(plo, phi, 16)
        for i, k in keys do
            local block = lay.present_block(k)
            local base = block * rows
            local a, z = math.max(from - base, 0), math.min(last - base, rows - 1)
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

-- Adds the records of a job that ran on barch.vec to its groups' running
-- values.
local function add_records(job: any)
    flush_codes(job)
    for _, a in job.aggs do
        local r: buffer? = a.recs
        if r == nil then
            continue
        end
        for id, gi in job.gis do
            add_record(a, r, (id - 1) * 32, gi)
        end
    end
    local lane = job.slane
    if lane then
        for _, a in job.aggs do
            for id, gi in lane.gis do
                add_record(a, a.srecs, (id - 1) * 32, gi)
            end
        end
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

-- rows -------------------------------------------------------------------------

-- Whether table t holds a row at pk.
function exists(t: any, pk: number): boolean
    local g = geometry(t)
    local block, slot = place(g.rows, pk)
    local presence = barch.store.get(lay.present(t, block))
    return presence ~= nil and string.byte(presence, g.pbase + slot + 1) == 1
end

-- Where the value of `slot` starts in text block b, laid out as sp says.
local function text_start(sp: any, b: buffer, slot: number): number
    local at, lens = sp.vals, sp.lens
    for s = 0, slot - 1 do
        local len = buffer.readu32(b, lens + s * 4)
        if len > 0 then
            at += len - 1
        end
    end
    return at
end

-- The value at `slot` of a text block, as far as the block keeps it.
local function text_at(sp: any, stored: string, slot: number): string?
    local b = buffer.fromstring(stored)
    if sp.head and is_dict(b) then
        local cw = code_width(b)
        local code, none = read_code(b, DHEAD + slot * cw, cw), nil_code(cw)
        return if code == none then nil else dict_value(b, sp.rows, code - none)
    end
    local len = buffer.readu32(b, sp.lens + slot * 4)
    if len == 0 then
        return nil
    end
    return buffer.readstring(b, text_start(sp, b, slot), len - 1)
end

-- Whether number block k is short, or nil when there is no block k.
local function short_block(k: string): boolean?
    -- the header's first 4 bytes: 1, the tag, then 0
    local w = barch.store.getInt32At(k, 0)
    if w == nil then
        return nil
    end
    return (w // 256) % 256 == STAG
end

-- The row at pk with no defaults, or nil. `lock` reads the block's presence
-- with the exclusive lock, for a pessimistic caller about to write.
function read(t: any, fields: any, pk: number, lock: boolean?): any
    local g = geometry(t)
    local block, slot = place(g.rows, pk)
    local key = lay.present(t, block)
    local presence = if lock then barch.store.get(key, true) else barch.store.get(key)
    if presence == nil or string.byte(presence, g.pbase + slot + 1) ~= 1 then
        return nil
    end
    local r = {}
    for _, f in fields.list do
        local sp = spec(g, f)
        local fb, fs = place(sp.rows, pk)
        local k = block_key(lay.column(t, f.id), fb)
        if sp.text then
            local stored = barch.store.get(k)
            local v = stored and text_at(sp, stored, fs)
            if v and #v > sp.cap then
                v = long_value(t, f.name, lay.overflow(t, f.id), pk)
            end
            if v then
                r[f.name] = if f.kind == "json" then VALUES.parse_json(v) else v
            end
        elseif sp.short and short_block(k) then
            -- 4 bytes ending at the slot's int16, which follows the header
            local w = barch.store.getInt32At(k, SHEAD + fs * 2 - 2)
            local h = w and (w // 65536) % 65536
            if h and h ~= 32768 then
                r[f.name] = if h > 32767 then h - 65536 else h
            end
        else
            local x = barch.store.getF64At(k, sp.data + fs * 8)
            if x and x == x then
                r[f.name] = if f.kind == "bool" then x == 1 else x
            end
        end
    end
    return r
end

local SHORT_CELL = buffer.create(2)

-- Stores number `x` in `slot` of number block k, nil as NaN, or as
-- NIL_SHORT in a short block.
local function put_number(sp: any, k: string, slot: number, x: number?)
    if sp.short then
        local short = short_block(k)
        if short == nil then
            if x == nil then
                return
            end
            short = fits_short(x)
            barch.store.setBufferAt(k, if short then sp.short else sp.empty, 0)
        end
        if short then
            if fits_short(x) then
                buffer.writei16(SHORT_CELL, 0, x or NIL_SHORT)
                barch.store.setBufferAt(k, SHORT_CELL, SHEAD + slot * 2)
                return
            end
            -- a value outside +-32767 makes it a number block for good
            barch.store.setBufferAt(k, widen(barch.store.getBufferAt(k, 0), sp.rows), 0)
        end
        barch.store.setF64At(k, x or NAN, sp.data + slot * 8)
        return
    end
    if not barch.store.exists(k) then
        if x == nil then
            return
        end
        barch.store.setBufferAt(k, sp.empty, 0)
    end
    barch.store.setF64At(k, x or NAN, sp.data + slot * 8)
end

local function too_large(t: any, f: any, block: number, size: number)
    fail("table " .. t.name .. " field " .. f.name .. " would hold " .. size .. " bytes in"
        .. " column block " .. block .. ", and a block holds at most "
        .. MAX_ENTRY .. " with its key; store large values in a binary table")
end

-- A text block holding `text` at slot, which the first value makes, with
-- `over` values kept whole elsewhere.
local function new_text(sp: any, slot: number, text: string, over: number): string
    local b = if sp.head then header(sp.vals + #text, "t", sp.rows)
        else buffer.create(sp.vals + #text)
    buffer.writeu32(b, sp.used, #text)
    buffer.writeu32(b, sp.slots, slot + 1)
    if sp.over then
        buffer.writeu32(b, sp.over, over)
    end
    buffer.writeu32(b, sp.lens + slot * 4, #text + 1)
    buffer.writestring(b, sp.vals, text)
    return buffer.tostring(b)
end

-- `stored` with `text` at slot, or nil at slot for text nil, and `dover`
-- added to the values kept whole elsewhere.
local function replace_text(sp: any, stored: string, slot: number, text: string?,
                            dover: number): string
    local old = buffer.fromstring(stored)
    local at = text_start(sp, old, slot)
    local was = buffer.readu32(old, sp.lens + slot * 4)
    local gone = if was > 0 then was - 1 else 0
    local size = if text then #text else 0
    local total = buffer.readu32(old, sp.used) - gone + size
    local b = buffer.create(sp.vals + total)
    buffer.copy(b, 0, old, 0, at)
    buffer.writeu32(b, sp.used, total)
    buffer.writeu32(b, sp.slots, math.max(buffer.readu32(old, sp.slots), if text then slot + 1 else 0))
    if sp.over then
        buffer.writeu32(b, sp.over, buffer.readu32(old, sp.over) + dover)
    end
    buffer.writeu32(b, sp.lens + slot * 4, if text then size + 1 else 0)
    if text then
        buffer.writestring(b, at, text)
    end
    buffer.copy(b, at + size, old, at + gone, buffer.len(old) - at - gone)
    return buffer.tostring(b)
end

-- A plain text block holding vals[s + 1] at each slot s, with `over`
-- values kept whole elsewhere.
local function plain_block(sp: any, vals: { [number]: string }, over: number): string
    local used, slots = 0, 0
    for s = 0, sp.rows - 1 do
        local v = vals[s + 1]
        if v then
            used += #v
            slots = s + 1
        end
    end
    local b = header(sp.vals + used, "t", sp.rows)
    buffer.writeu32(b, sp.used, used)
    buffer.writeu32(b, sp.slots, slots)
    buffer.writeu32(b, sp.over, over)
    local at = sp.vals
    for s = 0, slots - 1 do
        local v = vals[s + 1]
        if v then
            buffer.writeu32(b, sp.lens + s * 4, #v + 1)
            buffer.writestring(b, at, v)
            at += #v
        end
    end
    return buffer.tostring(b)
end

-- Dictionary block `stored` with `text` at slot, or nil at slot for text
-- nil. A dictionary holds only whole values, so a `long` text, the start
-- of a longer value, or a value past dict_most() makes a plain block.
local function dict_put(sp: any, stored: string, slot: number, text: string?,
                        long: boolean): string
    local rows = sp.rows
    local old = buffer.fromstring(stored)
    local dict = dict_of(old, rows)
    local cw = code_width(old)
    local none = nil_code(cw)
    local codes = buffer.create(rows * cw)
    buffer.copy(codes, 0, old, DHEAD, rows * cw)
    local was = read_code(codes, slot * cw, cw)
    write_code(codes, slot * cw, cw, none)
    if was ~= none and not holds_code(codes, cw, was) then
        -- no other slot holds the value slot held
        table.remove(dict, was - none)
        shift(codes, rows, cw, was + 1, -1)
    end
    local p = if text then lower(dict, text) else 0
    if long or (text and dict[p] ~= text and #dict >= dict_most(rows)) then
        local vals = {}
        for s = 0, rows - 1 do
            local code = read_code(codes, s * cw, cw)
            if code ~= none then
                vals[s + 1] = dict[code - none]
            end
        end
        vals[slot + 1] = text
        return plain_block(sp, vals, if long then 1 else 0)
    end
    if text then
        if dict[p] ~= text then
            if width_of(#dict + 1) > cw then
                -- the new value needs int16 codes
                codes = recode(codes, rows, cw, 2)
                cw, none = 2, nil_code(2)
            end
            table.insert(dict, p, text)
            shift(codes, rows, cw, p + none, 1)
        end
        write_code(codes, slot * cw, cw, p + none)
    end
    return dict_block(rows, codes, cw, dict)
end

-- Text block `stored`, or a new block for stored nil, with `text` at slot,
-- or nil at slot for text nil. `long` says text is the start of a longer
-- value, and `dover` how the values kept whole elsewhere change.
local function text_put(sp: any, stored: string?, slot: number, text: string?, long: boolean,
                        dover: number): string
    if stored == nil then
        if sp.head and not long then
            local codes = buffer.create(sp.rows)
            buffer.fill(codes, 0, 0x80, sp.rows)
            buffer.writei8(codes, slot, 1 - 128)
            return dict_block(sp.rows, codes, 1, { text :: string })
        end
        return new_text(sp, slot, text :: string, dover)
    end
    if sp.head and string.byte(stored, 2) == DTAG then
        return dict_put(sp, stored, slot, text, long)
    end
    return replace_text(sp, stored, slot, text, dover)
end

-- The write that stores `text` at slot of text block k, nil for a nil value,
-- or nil when none is needed. A value longer than the block keeps goes
-- whole to overflow key `okey`. Checks the sizes without writing.
local function plan_text(t: any, f: any, sp: any, block: number, k: string, okey: string,
                         slot: number, text: string?): (() -> ())?
    local room = MAX_ENTRY - #k
    local inline, long = text, false
    if text and #text > sp.cap then
        if #okey + #text > MAX_ENTRY then
            fail("table " .. t.name .. " field " .. f.name .. " would hold a value of " .. #text
                .. " bytes, and a value holds at most " .. (MAX_ENTRY - #okey) .. "; store"
                .. " large values in a binary table")
        end
        inline, long = string.sub(text, 1, sp.cap + 1), true
    end
    local stored = barch.store.get(k)
    if stored == nil and text == nil then
        return nil
    end
    -- a dictionary block holds no long values
    local was_long = false
    if stored and not (sp.head and string.byte(stored, 2) == DTAG) then
        was_long = (string.unpack("<I4", stored, sp.lens + slot * 4 + 1) :: number) - 1 > sp.cap
    end
    local dover = (if long then 1 else 0) - (if was_long then 1 else 0)
    local value = text_put(sp, stored, slot, inline, long, dover)
    if #value > room then
        too_large(t, f, block, #value)
    end
    return function()
        barch.store.set(k, value)
        if long then
            barch.store.set(okey, text)
        elseif was_long then
            barch.store.remove(okey)
        end
    end
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
-- Answers how many rows the block then holds, and its value before.
local function mark(t: any, g: any, block: number, slot: number, on: boolean,
                    lock: boolean?): (number, string?)
    local key = lay.present(t, block)
    local presence = if lock then barch.store.get(key, true) else barch.store.get(key)
    local n = (presence and live(g, presence) or 0) + (if on then 1 else -1)
    if n == 0 then
        barch.store.remove(key)
        return 0, presence
    end
    if presence == nil then
        barch.store.setBufferAt(key, g.empty, 0)
    end
    barch.store.setBufferAt(key, if on then PRESENT else ABSENT, g.pbase + slot)
    barch.store.setInt32At(key, n, g.plive)
    return n, presence
end

-- Checks row r for pk, given the row it replaces (nil for a new row), and
-- answers a function that stores it. Everything that can refuse the row
-- happens here, so a caller can check before its first write. `lock` is true
-- for a pessimistic caller.
function write(t: any, fields: any, pk: number, old: any, r: any, lock: boolean?): () -> ()
    rc.validate(fields, r)
    local g = geometry(t)
    local block, slot = place(g.rows, pk)
    if lock then
        barch.store.get(lay.present(t, block), true)
    end
    local writes = {}
    for _, f in fields.list do
        local v = r[f.name]
        -- a slot without a row holds nil in every field
        local changed = if old then differs(f, old[f.name], v) else v ~= nil
        if changed then
            local sp = spec(g, f)
            local fb, fs = place(sp.rows, pk)
            local k = block_key(lay.column(t, f.id), fb)
            if sp.text then
                local put = plan_text(t, f, sp, fb, k, lay.overflow(t, f.id, pk), fs,
                                      text_of(f, v))
                if put then
                    writes[#writes + 1] = put
                end
            else
                local x = v
                if f.kind == "bool" and v ~= nil then
                    x = if v then 1 else 0
                end
                writes[#writes + 1] = function() put_number(sp, k, fs, x) end
            end
        end
    end
    return function()
        if old == nil then
            mark(t, g, block, slot, true, lock)
        end
        for _, put in writes do
            put()
        end
    end
end

-- Removes the row at pk, which holds `old`. A field block whose last row
-- leaves goes with it, and so does the presence block. `lock` is true for a
-- pessimistic caller.
function remove(t: any, fields: any, pk: number, old: any, lock: boolean?)
    local g = geometry(t)
    local block, slot = place(g.rows, pk)
    local n, presence = mark(t, g, block, slot, false, lock)
    for _, f in fields.list do
        local sp = spec(g, f)
        local fb, fs = place(sp.rows, pk)
        local k = block_key(lay.column(t, f.id), fb)
        local was = old[f.name]
        if n == 0 or not others(g, presence, fb * sp.rows - block * g.rows, sp.rows, slot) then
            barch.store.remove(k)
            local text = sp.text and text_of(f, was)
            if text and #text > sp.cap then
                barch.store.remove(lay.overflow(t, f.id, pk))
            end
        elseif was ~= nil then
            if sp.text then
                local put = plan_text(t, f, sp, fb, k, lay.overflow(t, f.id, pk), fs, nil)
                if put then
                    put()
                end
            else
                put_number(sp, k, fs, nil)
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
    local block, slot = place(LEGACY, -1)
    if block ~= -1 or slot ~= LEGACY - 1 then
        return false, "place of -1"
    end
    for _, sp in { LEGACY_TEXT, new_spec(64, true) } do
        local b = new_text(sp, 2, "abc", 0)
        b = replace_text(sp, b, 0, "x", 0)
        b = replace_text(sp, b, 1, "", 0)
        if text_at(sp, b, 0) ~= "x" or text_at(sp, b, 1) ~= "" or text_at(sp, b, 2) ~= "abc"
            or text_at(sp, b, 3) ~= nil then
            return false, "text block slots"
        end
        b = replace_text(sp, b, 2, nil, 0)
        if text_at(sp, b, 0) ~= "x" or text_at(sp, b, 2) ~= nil or #b ~= sp.vals + 1 then
            return false, "text block removal"
        end
    end
    -- a dictionary block keeps its values sorted, drops one no slot holds,
    -- and turns plain for a long value or too many values
    local sp = new_spec(64, true)
    local b = text_put(sp, nil, 2, "m", false, 0)
    b = text_put(sp, b, 0, "z", false, 0)
    b = text_put(sp, b, 1, "a", false, 0)
    local function codes(): (number, number, number)
        return string.unpack("<i1i1i1", b, DHEAD + 1)
    end
    local c0, c1, c2 = codes()
    if string.byte(b, 2) ~= DTAG or text_at(sp, b, 0) ~= "z" or text_at(sp, b, 1) ~= "a"
        or text_at(sp, b, 2) ~= "m" or text_at(sp, b, 3) ~= nil or not (c1 < c2 and c2 < c0) then
        return false, "dictionary block slots"
    end
    b = text_put(sp, b, 2, nil, false, 0)
    b = text_put(sp, b, 1, "z", false, 0)
    c0, c1, c2 = codes()
    if string.unpack("<I4", b, 9) ~= 1 or c0 ~= c1 or c2 ~= NIL_CODE
        or text_at(sp, b, 1) ~= "z" then
        return false, "dictionary block removal"
    end
    local long = text_put(sp, b, 3, string.rep("q", CAP + 1), true, 1)
    if string.byte(long, 2) ~= string.byte("t") or text_at(sp, long, 0) ~= "z"
        or text_at(sp, long, 3) ~= string.rep("q", CAP + 1)
        or string.unpack("<I4", long, sp.over + 1) ~= 1 then
        return false, "dictionary block with a long value"
    end
    for s = 0, dict_most(64) - 1 do
        b = text_put(sp, b, s, "v" .. s, false, 0)
    end
    local full = string.byte(b, 2) == DTAG
    b = text_put(sp, b, dict_most(64), "w", false, 0)
    if not full or string.byte(b, 2) ~= string.byte("t") or text_at(sp, b, 5) ~= "v5"
        or text_at(sp, b, dict_most(64)) ~= "w" then
        return false, "dictionary block past its values"
    end
    -- past 255 values a dictionary block takes int16 codes, and int8 codes
    -- again when its values fall back to 255
    local wide = new_spec(1024, true)
    local w: string? = nil
    for s = 0, 299 do
        -- each value sorts first, so every write moves the other codes
        w = text_put(wide, w, s, string.format("k%03d", 299 - s), false, 0)
    end
    local ws = w :: string
    if string.byte(ws, 2) ~= DTAG or code_width(buffer.fromstring(ws)) ~= 2
        or text_at(wide, ws, 0) ~= "k299" or text_at(wide, ws, 299) ~= "k000"
        or text_at(wide, ws, 300) ~= nil then
        return false, "dictionary block with int16 codes"
    end
    for s = 255, 299 do
        ws = text_put(wide, ws, s, nil, false, 0)
    end
    if code_width(buffer.fromstring(ws)) ~= 1 or text_at(wide, ws, 0) ~= "k299"
        or text_at(wide, ws, 254) ~= "k045" or text_at(wide, ws, 255) ~= nil then
        return false, "dictionary block back to int8 codes"
    end
    local sizes = {
        block_rows(4096) == 4096, block_rows(4096, { kind = "int" }) == 512,
        block_rows(4096, { kind = "string" }) == 256,
        block_rows(4096, { kind = "string", maxLen = 4 }) == 512,
        block_rows(262144, { kind = "string", maxLen = 1000 }) == 8192,
        block_rows(1024, { kind = "float" }) == 128, block_rows(1000) == 1024,
        block_rows(1024, { kind = "enum", values = { "new", "done" } }) == 128,
    }
    for i, ok in sizes do
        if not ok then
            return false, "block size " .. i
        end
    end
    return true
end

function call()
    local ok, why = selftest()
    return ok and "ok" or ("failed: " .. why)
end
