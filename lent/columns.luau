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
--   byte       an int field's block in a table with `block` while its
--              values fit in 8 bits: an 8-byte header (1, "b", 0, the
--              rows), then an int8 per slot, -128 for nil.
--   short      an int field's block while its values fit in 16 bits: an
--              8-byte header (1, "h", 0, the rows), then an int16 per slot,
--              -32768 for nil.
--   wide       an int field's block while its values fit in 32 bits: an
--              8-byte header (1, "i", 0, the rows), then an int32 per slot,
--              -2147483648 for nil. An int block takes the narrowest of
--              byte, short, wide and number that holds its values: a new
--              block starts in the one its first value needs, a write of a
--              value outside its range widens it, and a write that removes
--              the last value that needed its width narrows it.
--   text       for string, enum, json and bytes: a 24-byte header (1, "t",
--              0, the rows, the bytes in use, the slots in use, the values
--              kept whole elsewhere, and at least how many distinct values
--              it holds, 0 when unknown), a uint32 per slot, then the values
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
--              values. A new text block starts as a dictionary, becomes
--              plain text when it would hold more than dict_most() values
--              or a value longer than CAP, and turns back into a dictionary
--              when a write that replaces or clears a value leaves it fit
--              for one.
--
-- In the number, wide, text and dictionary headers, the uint16 after the tag
-- holds the parts of a split block, 0 for a block stored whole. A block of
-- a table with `block` whose key and value would pass MAX_ENTRY splits
-- into parts of PART bytes; see put_block. Only an int field's wide and
-- number blocks and a text block grow that large, since block_rows sizes
-- them as short and dictionary blocks.
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

-- A block header: 1, the tag's byte, 0 as a uint16 for the parts of a
-- split block, then the rows.
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

-- The formats of a number block in a table with `block`: f64s, or for
-- an int field the int8s of a byte block, the int16s of a short block or
-- the int32s of a wide one.
-- Each has an 8-byte header, then `width` bytes per slot from byte 8. An
-- int format marks nil with `none` and holds whole numbers within +-most.
-- `rank` orders them from the narrowest.
local SHEAD = 8
local STAG = string.byte("h")
local NIL_SHORT = -32768
local INT8 = { tag = "b", width = 1, kind = "i8", none = -128, most = 127, rank = 1 }
local INT16 = { tag = "h", width = 2, kind = "i16", none = NIL_SHORT, most = 32767, rank = 2 }
local INT32 = { tag = "i", width = 4, kind = "i32", none = -2147483648, most = 2147483647,
                rank = 3 }
local F64 = { tag = "n", width = 8, kind = "f64", rank = 4 }
local FORMATS = { [string.byte("b")] = INT8, [STAG] = INT16, [string.byte("i")] = INT32,
                  [string.byte("n")] = F64 }

-- The int format of number block b, or nil for f64s.
local function int_format(b: buffer): any
    local f = buffer.len(b) > 1 and FORMATS[buffer.readu8(b, 1)]
    return if f and f ~= F64 then f else nil
end

-- The narrowest format that holds x, where nil fits every format.
local function format_for(x: number?): any
    if x == nil or x ~= x then
        return INT8
    elseif x ~= math.floor(x) or math.abs(x) > INT32.most then
        return F64
    end
    local a = math.abs(x)
    return if a <= INT8.most then INT8 elseif a <= INT16.most then INT16 else INT32
end

-- The value in slot s of number block b of format f, NaN for nil.
local function cell(b: buffer, f: any, s: number): number
    local at = SHEAD + s * f.width
    local x
    if f == INT8 then
        x = buffer.readi8(b, at)
    elseif f == INT16 then
        x = buffer.readi16(b, at)
    elseif f == INT32 then
        x = buffer.readi32(b, at)
    else
        return buffer.readf64(b, at)
    end
    return if x == f.none then NAN else x
end

-- Writes x, nil or NaN for nil, into slot s of number block b of format f.
local function set_cell(b: buffer, f: any, s: number, x: number?)
    local at = SHEAD + s * f.width
    if f == F64 then
        buffer.writef64(b, at, x or NAN)
        return
    end
    local v = if x == nil or x ~= x then f.none else x
    if f == INT8 then
        buffer.writei8(b, at, v)
    elseif f == INT16 then
        buffer.writei16(b, at, v)
    else
        buffer.writei32(b, at, v)
    end
end

-- The block of format `to` holding the values of number block b, of
-- format `from` and `rows` slots, written into `out` when it is given.
local function reformat(b: buffer, from: any, rows: number, to: any, out: buffer?): buffer
    local w = out or header(SHEAD + rows * to.width, to.tag, rows)
    if out then
        buffer.writeu8(w, 0, 1)
        buffer.writeu8(w, 1, string.byte(to.tag))
        buffer.writeu16(w, 2, 0)
        buffer.writeu32(w, 4, rows)
    end
    for s = 0, rows - 1 do
        set_cell(w, to, s, cell(b, from, s))
    end
    return w
end

-- The narrowest format that holds every value of number block b, of
-- format f and `rows` slots.
local function narrowest(b: buffer, f: any, rows: number): any
    local best = INT8
    for s = 0, rows - 1 do
        local need = format_for(cell(b, f, s))
        if need.rank > best.rank then
            best = need
            if best.rank >= f.rank then
                break
            end
        end
    end
    return best
end

-- The f64 number block holding the values of int block b, of format f
-- and `rows` slots, written into `out` when it is given.
local function widen(b: buffer, f: any, rows: number, out: buffer?): buffer
    return reformat(b, f, rows, F64, out)
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
        return { rows = rows, text = true, used = 8, slots = 12, over = 16, distinct = 20,
                 lens = 24, vals = 24 + rows * 4, cap = CAP, head = true }
    end
    local short
    if int then
        short = header(SHEAD + rows * 2, "h", rows)
        for s = 0, rows - 1 do
            buffer.writei16(short, SHEAD + s * 2, NIL_SHORT)
        end
    end
    -- an int field's empty number block is made when first needed
    return { rows = rows, data = 8, head = true, short = short,
             empty = if int then nil
                 else empty_numbers(8, rows, header(8 + rows * 8, "n", rows)) }
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
-- nil, or blocks of catalog field f. An int takes 2 bytes, the int16 of a
-- short block, and other numbers 8. A text field takes what a dictionary
-- block needs at its most values, half its rows: a code per row, and per
-- value its length (its maxLen, its longest enum value, or a guess of 12
-- bytes, up to the CAP + 1 bytes a block keeps) and 4 bytes. Each count is
-- a power of two, and a field's is at most the presence's. A block that
-- grows past barch's limit, as plain text or as a wide or number int
-- block, splits into parts.
function block_rows(bytes: number, f: any?): number
    if f == nil then
        return power(bytes, 64, 262144)
    end
    if f.kind == "int" then
        return power(bytes / 2, 64, 131072)
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
    local value = (4 + math.min(len or 12, CAP + 1)) / 2
    -- int16 codes, or int8 for up to 256 rows, whose dictionary holds at
    -- most 128 values
    local rows = power(bytes / (2 + value), 64, 131072)
    if rows <= 256 then
        rows = power(bytes / (1 + value), 64, 256)
    end
    return rows
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

-- split blocks: a block whose value and key pass MAX_ENTRY splits into
-- parts of PART bytes. Part 0 stays at the block's key and keeps the
-- header, whose uint16 holds the number of parts, 0 for a whole block.
-- PART is a multiple of 8, so no cell lies across two parts.
local PART = 262144

-- Whether a value of `size` bytes fits whole at key k. barch counts the
-- key as it encodes it, which adds to its bytes, so this leaves room for
-- twice the key.
local function fits(k: string, size: number): boolean
    return 2 * #k + 64 + size <= MAX_ENTRY
end

-- The key of part p of block k.
local function part_key(k: string, p: number): string
    return if p == 0 then k else k .. "/" .. p
end

-- The parts of a block from its header's first 4 bytes as an int32.
local function parts_in(w: number): number
    return (w // 65536) % 65536
end

-- The whole value of the block at k of field `name`, whose part 0 is
-- `stored`.
local function joined(t: any, name: string, block: number, k: string, stored: string): string
    local n = string.unpack("<I2", stored, 3)
    if n == 0 then
        return stored
    end
    local out = table.create(n)
    out[1] = stored
    for p = 1, n - 1 do
        local part = barch.store.get(part_key(k, p))
        if part == nil then
            fail("table " .. t.name .. " field " .. name .. " column block " .. block
                .. " has lost part " .. p .. " of " .. n)
        end
        out[p + 1] = part
    end
    return table.concat(out)
end

-- Stores block value v at k, in parts when it doesn't fit whole, and
-- removes the parts past its last of the `was` that k held. Answers the
-- parts it takes, 0 for a whole block.
local function put_block(k: string, v: string, was: number): number
    local n = if fits(k, #v) then 0 else (#v + PART - 1) // PART
    if string.unpack("<I2", v, 3) ~= n then
        v = string.sub(v, 1, 2) .. string.pack("<I2", n) .. string.sub(v, 5)
    end
    if n == 0 then
        barch.store.set(k, v)
    else
        for p = 0, n - 1 do
            barch.store.set(part_key(k, p), string.sub(v, p * PART + 1, (p + 1) * PART))
        end
    end
    for p = math.max(n, 1), was - 1 do
        barch.store.remove(part_key(k, p))
    end
    return n
end

-- Removes block k and its parts.
local function remove_block(k: string)
    local w = barch.store.getInt32At(k, 0)
    barch.store.remove(k)
    for p = 1, (if w then parts_in(w) else 0) - 1 do
        barch.store.remove(part_key(k, p))
    end
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

-- Reads block fb of the field of source c into c.b, and its dictionary into
-- c.dict when it has one, unless c holds that block already. Set c.fb to nil
-- to read it again.
local function hold(t: any, c: any, fb: number)
    if fb == c.fb then
        return
    end
    local sp = c.spec
    local k = block_key(c.prefix, fb)
    local stored = barch.store.get(k)
    if stored and sp.head then
        stored = joined(t, c.name, fb, k, stored)
    end
    local b = stored and buffer.fromstring(stored) or false
    if b and sp.head then
        check_rows(t, "field " .. c.name, fb, buffer.readu32(b, 4), sp.rows)
    end
    c.dict = nil
    c.int = b and not c.text and sp.short ~= nil and int_format(b)
    if b and c.text then
        if sp.head and is_dict(b) then
            c.dict, c.cw = dict_of(b, sp.rows), code_width(b)
        else
            starts_of(sp, b, c.starts)
        end
    end
    c.fb, c.b = fb, b
end

-- The value at pk of the field of source c, or nil when it has none.
local function field_at(t: any, c: any, pk: number): any
    local sp = c.spec
    local rows = sp.rows
    local fb = pk // rows
    hold(t, c, fb)
    local b = c.b
    if not b then
        return nil
    end
    local fs = pk - fb * rows
    local dict = c.dict
    if dict then
        local cw = c.cw
        local code = read_code(b, DHEAD + fs * cw, cw)
        local none = nil_code(cw)
        if code == none then
            return nil
        end
        local v = dict[code - none]
        return if c.json then VALUES.parse_json(v) else v
    elseif c.text then
        local len = buffer.readu32(b, sp.lens + fs * 4)
        if len == 0 then
            return nil
        end
        local v = if len - 1 > sp.cap then long_value(t, c.name, c.okey, pk)
            else buffer.readstring(b, c.starts[fs + 1], len - 1)
        return if c.json then VALUES.parse_json(v) else v
    elseif c.int then
        local x = cell(b, c.int, fs)
        return if x == x then x else nil
    end
    local x = buffer.readf64(b, sp.data + fs * 8)
    if x ~= x then
        return nil
    end
    return if c.bool then x == 1 else x
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

-- The tests of `conds` that scan can make on a row's stored values, each a
-- condition's op and value with the column that reads its field: the one
-- in `cols`, or one of its own for a field the rows leave out. A condition
-- on a field outside `fields` or on a json field is left to the caller.
local function tests_of(t: any, g: any, fields: any, cols: { any }, conds: { any }): { any }
    local out = {}
    for _, c in conds do
        local name = c.field
        if name == "id" then
            out[#out + 1] = { op = c.op, value = c.value }
            continue
        end
        local col
        for _, x in cols do
            if x.name == name then
                col = x
            end
        end
        if col == nil then
            col = columns(t, g, fields, { [name] = true })[1]
        end
        if col and not col.json then
            local default
            for _, d in t.fields do
                if d.name == name then
                    default = d.default
                end
            end
            out[#out + 1] = { col = col, op = c.op, value = c.value, default = default }
        end
    end
    return out
end

-- Whether the row at pk passes `tests` (see tests_of).
local function passes(t: any, tests: { any }, pk: number): boolean
    for i = 1, #tests do
        local x = tests[i]
        local v = pk
        if x.col then
            v = field_at(t, x.col, pk)
            if v == nil then
                v = x.default
            end
        end
        if not holds(x.op, v, x.value) then
            return false
        end
    end
    return true
end

-- The row at pk of the fields in `cols`, with no defaults.
local function row_at(t: any, cols: { any }, pk: number): any
    local r = {}
    for i = 1, #cols do
        local c = cols[i]
        r[c.name] = field_at(t, c, pk)
    end
    return r
end

-- Whether a sorts before b in a query's order, with nil first.
local function sorts_before(a: any, b: any): boolean
    if a == nil or b == nil then
        return a == nil and b ~= nil
    end
    if type(a) == "boolean" then
        return not a and b
    end
    return a < b
end

-- Whether the row at pk can join the rows a top-k scan keeps, as `cut` says
-- (see scan). Rows come in id order, so a row whose value equals the cut
-- joins only in desc order. In a dictionary block it compares the slot's
-- code with the code of the cut value, found once per block and cut.
local function joins(t: any, cut: any, pk: number): boolean
    local c = cut.col
    local rows = c.spec.rows
    local fb = pk // rows
    hold(t, c, fb)
    local dict = c.dict
    if dict == nil then
        local v = field_at(t, c, pk)
        if cut.desc then
            return not sorts_before(v, cut.value)
        end
        return sorts_before(v, cut.value)
    end
    if cut.fb ~= fb or cut.seen ~= cut.n then
        -- codes from the cut's code up hold values at or past the cut value
        local w = cut.value
        cut.fb, cut.seen = fb, cut.n
        cut.code = nil_code(c.cw) + (if w == nil then 0 else lower(dict, w))
    end
    local code = read_code(c.b, DHEAD + (pk - fb * rows) * c.cw, c.cw)
    if cut.desc then
        return code >= cut.code
    end
    return code < cut.code
end

-- The slots from `a` to `z` of presence block `block`, in order or, with
-- `back`, highest first, as rows of the fields in `cols`. Calls each(pk, row)
-- until it answers true, and answers whether it did. With `cut`, it skips
-- the rows that cannot join a top-k scan's rows, and with `tests` the rows
-- that fail them.
local function read_block(t: any, g: any, cols: { any }, block: number, presence: string,
                          a: number, z: number, back: boolean?,
                          each: (number, any) -> boolean?, cut: any?, tests: { any }?): boolean
    check_presence(g, block, presence)
    local n = #cols
    for i = 1, n do
        cols[i].fb = nil
    end
    for _, x in tests or {} do
        if x.col then
            x.col.fb = nil
        end
    end
    local base, pbase = block * g.rows, g.pbase
    for s = if back then z else a, if back then a else z, if back then -1 else 1 do
        if string.byte(presence, pbase + s + 1) == 1 then
            local pk = base + s
            if (cut == nil or cut.n == 0 or joins(t, cut, pk))
                and (tests == nil or passes(t, tests, pk)) then
                if each(pk, row_at(t, cols, pk)) then
                    return true
                end
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
--
-- A `cut` lets a scan for the first k rows in the order of a field skip the
-- rows that come after the k-th row kept so far. It holds `field`, the sort
-- field, and `desc`; the caller sets `value` to the k-th row's value and
-- adds 1 to `n` each time it changes, from 0 for no cut yet. Read in id
-- order, a row then joins when its value sorts before `value`, or in desc
-- order when it sorts at or past it. A `json` field takes no cut.
--
-- `conds` holds conditions each row must meet, each a `field`, `op` and
-- `value` as a query keeps them. The scan tests them on the stored values
-- before it builds the row, and leaves the ones it cannot test (see
-- tests_of) to `each`.
function scan(t: any, fields: any, lo: string, hi: string, each: (number, any) -> boolean?,
              first: number?, back: boolean?, need: any?, cut: any?, conds: { any }?): boolean
    local g = geometry(t)
    local rows = g.rows
    local from, last, plo, phi = span(t, g, lo, hi)
    if from > last then
        return false
    end
    local cols = columns(t, g, fields, need)
    if cut then
        cut.col = nil
        for _, c in cols do
            if c.name == cut.field and not c.json then
                cut.col = c
            end
        end
        if back or cut.col == nil then
            cut = nil
        end
    end
    local tests = if conds and #conds > 0 then tests_of(t, g, fields, cols, conds) else nil
    if tests and #tests == 0 then
        tests = nil
    end
    local page = math.clamp((first or rows * 16) // rows + 1, 1, 16)
    local function run(keys: { string }, values: { string }, i: number): boolean
        local block = lay.present_block(keys[i])
        local base = block * rows
        local a, z = math.max(from - base, 0), math.min(last - base, rows - 1)
        return a <= z and read_block(t, g, cols, block, values[i], a, z, back, each, cut, tests)
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

-- The rows of table t at the ids in `pks`, in that order, each holding the
-- fields in the set `need`, or all of them with need nil, and no defaults.
-- It reads each block once when `pks` keeps the ids of a block together.
function rows_at(t: any, fields: any, pks: { number }, need: any?): { any }
    local cols = columns(t, geometry(t), fields, need)
    local out = table.create(#pks)
    for i, pk in pks do
        out[i] = row_at(t, cols, pk)
    end
    return out
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
        local k = block_key(c.prefix, fb)
        local stored = barch.store.getBufferAt(k, 0)
        local b = if type(stored) == "buffer" then stored else nil
        if b and c.spec.head and buffer.readu16(b, 2) ~= 0 then
            b = buffer.fromstring(joined(t, c.name, fb, k, buffer.tostring(b)))
        end
        if b and c.spec.head then
            check_rows(t, "field " .. c.name, fb, buffer.readu32(b, 4), rows)
        end
        c.b, c.fb, c.located, c.elements = b, fb, false, false
        c.coded, c.gmap = c.text and b ~= nil and c.spec.head == true and is_dict(b), nil
        if c.coded then
            c.cw = code_width(b :: buffer)
            c.cnil = nil_code(c.cw)
        end
        c.int = not c.text and b ~= nil and c.spec.short ~= nil and int_format(b :: buffer)
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
    if c.int then
        local x = cell(b, c.int, c.off + s)
        return if x ~= x then c.default else x
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
-- one plain key, count, sum, avg, min and max of plain numbers or rows, and
-- min and max of plain text.
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
        local c = a.source
        if a.distinct or a.scale or (c and not plain(c)
                and not ((a.fn == "min" or a.fn == "max") and plain_text(c))) then
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
--            avg, min and max; a sum or avg with a scale passes it
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
                  records = {}, tree = {}, short = {}, lanes = {},
                  sel = table.create(unit, 0), gids = table.create(unit, 1) }
    if vec and vectors(conds, keys, aggs) then
        -- each aggregate adds to records that grouper id i keeps at 32 * i,
        -- and finish adds them to group gis[i + 1]
        job.vec, job.gis, job.capacity = vec, if #keys == 0 then { 1 } else {}, 0
        job.presence = buffer.create(g.pbase + g.rows)
        job.selb, job.gidb = buffer.create(unit * 4), buffer.create(unit * 4)
        for _, a in aggs do
            if a.source and a.source.text then
                -- see fold_text
                a.text, a.tcap = true, 16
                a.trecs = new_records(16)
            end
        end
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
-- job's grouper, or of an int lane's when `lane` is given.
local function grow(job: any, size: number, lane: any?)
    local l = lane or job
    local was = l.capacity
    if size <= was then
        return
    end
    local cap = math.max(size, was * 2, 16)
    local field = if lane then lane.field else "recs"
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
-- grouper, or an int lane's when `lane` is given.
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
        if c.int then
            c.wide = widen(c.b, c.int, c.rows, c.wide)
            c.b, c.int = c.wide, nil
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

-- The group of id `id` of the grouper of dictionary codes.
local function code_group(job: any, id: number): number
    local code = job.codes:key(id)
    local value = if code == nil then nil else job.cmap[code - job.cnil]
    local k = if value == nil then NIL_KEY else value
    local gi = job.tree[k]
    if gi == nil then
        gi = new_group(job, { value })
        job.tree[k] = gi
    end
    return gi
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
    job.cdict = nil
    for id = 0, size - 1 do
        local gi = code_group(job, id)
        for _, a in job.aggs do
            add_record(a, a.crecs, id * 32, gi)
        end
    end
    for _, a in job.aggs do
        clear_records(a.crecs, 0, size)
    end
    job.csize = 0
end

-- Adds text aggregate a over the chunk's candidates `sel, n` to its groups'
-- running values, when its source's loaded block is a dictionary block.
-- Codes follow the order of the values, so one fold of the codes finds each
-- group's least and greatest code, and only those become text. gids holds
-- the candidates' grouper ids, of which `ids` are in use; gis maps id + 1 to
-- its group, or is nil when the ids are those of the dictionary key's codes.
local function fold_text(job: any, a: any, sel: buffer?, n: number, gids: buffer?, ids: number,
                         gis: { number }?)
    local c = a.source
    if not c.located then
        locate(c)
    end
    if ids > a.tcap then
        a.tcap = math.max(ids, a.tcap * 2)
        a.trecs = new_records(a.tcap)
    end
    local r: buffer, cw = a.trecs, c.cw
    job.vec.fold(code_kind(cw), c.b, DHEAD + c.off * cw, cw, c.cnil, sel, n, gids, r)
    local min, vals, dict, none = a.fn == "min", a.vals, c.dict, c.cnil
    local at = if min then 16 else 24
    for id = 0, ids - 1 do
        if buffer.readf64(r, id * 32) > 0 then
            local w = dict[buffer.readf64(r, id * 32 + at) - none]
            local gi = if gis then gis[id + 1] else code_group(job, id)
            local acc = vals[gi]
            if acc == nil or (if min then w < acc else acc < w) then
                vals[gi] = w
            end
        end
    end
    clear_records(r, 0, ids)
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
    local function in_luau(): boolean
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
    for _, c in job.texts do
        if c.b and buffer.readu32(c.b, c.spec.over) > 0 then
            return in_luau()
        end
    end
    for _, ag in job.aggs do
        -- plain text values compare in Luau
        local c = ag.text and ag.source
        if c and c.b and not c.coded then
            return in_luau()
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
            elseif c.int then
                local f = c.int
                kind, at, stride, none = f.kind, SHEAD + c.off * f.width, f.width, f.none
            end
            n = v.filter(kind, b, at, stride, cd.op, cd.value, none, sel, n, selb)
            sel = selb
            if n == 0 then
                return more
            end
        end
    end
    local gids: buffer? = nil
    -- the int format's lane that groups this chunk, when its key is in one
    local lane = nil
    -- the grouper ids in use and their groups, for fold_text
    local ids, gis = 1, job.gis
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
        ids, gis = job.csize, nil
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
    elseif k and k.int then
        -- int blocks group on a grouper of their format, a lane with its
        -- own records; add_records joins the groups by value
        local f = k.int
        lane = job.lanes[f.kind]
        if lane == nil then
            lane = { grouper = v.grouper(f.kind), gis = {}, capacity = 0, field = "recs" .. f.kind }
            job.lanes[f.kind] = lane
        end
        gids = job.gidb
        local size = lane.grouper:ids(k.b, SHEAD + k.off * f.width, f.width, f.none, sel, n, gids)
        if size > #lane.gis then
            new_ids(job, size, lane)
        end
        ids, gis = size, lane.gis
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
        ids = size
    else
        if #job.records == 0 then
            new_group(job, {})
        end
        -- luau_rows may have made the group, and not these records
        grow(job, 1)
    end
    for _, ag in job.aggs do
        local c = ag.source
        local recs = if coded then ag.crecs elseif lane then ag[lane.field] else ag.recs
        if ag.text then
            if c.b ~= nil then
                fold_text(job, ag, sel, n, gids, ids, gis)
            end
        elseif c == nil then
            v.fold("i8", ZEROS, 0, 1, nil, sel, n, gids, recs)
        elseif c.int then
            local f = c.int
            v.fold(f.kind, c.b, SHEAD + c.off * f.width, f.width, f.none, sel, n, gids, recs)
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
    for _, lane in job.lanes do
        for _, a in job.aggs do
            for id, gi in lane.gis do
                add_record(a, a[lane.field], (id - 1) * 32, gi)
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

-- The format of number block k, or nil when there is no block k, and how
-- many parts it is split into.
local function number_block(k: string): (any, number)
    -- the header's first 4 bytes: 1, the tag, then the parts
    local w = barch.store.getInt32At(k, 0)
    if w == nil then
        return nil, 0
    end
    return FORMATS[(w // 256) % 256] or F64, parts_in(w)
end

-- The key and offset of the cell at `at` in a number block at k of
-- `parts`.
local function cell_at(k: string, parts: number, at: number): (string, number)
    if parts == 0 then
        return k, at
    end
    local p = at // PART
    return part_key(k, p), at - p * PART
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
            if stored and sp.head then
                stored = joined(t, f.name, fb, k, stored)
            end
            local v = stored and text_at(sp, stored, fs)
            if v and #v > sp.cap then
                v = long_value(t, f.name, lay.overflow(t, f.id), pk)
            end
            if v then
                r[f.name] = if f.kind == "json" then VALUES.parse_json(v) else v
            end
        else
            local format, parts = F64, 0
            if sp.short then
                format, parts = number_block(k)
            end
            if format == INT8 or format == INT16 then
                -- 4 bytes ending at the slot's cell, which follows the
                -- header; their top bytes are the signed cell
                local width = format.width
                local w = barch.store.getInt32At(k, SHEAD + (fs + 1) * width - 4)
                local x = w and w // 2 ^ (32 - 8 * width)
                if x and x ~= format.none then
                    r[f.name] = x
                end
                continue
            elseif format == INT32 then
                local x = barch.store.getInt32At(cell_at(k, parts, SHEAD + fs * 4))
                if x and x ~= INT32.none then
                    r[f.name] = x
                end
                continue
            end
            local x = barch.store.getF64At(cell_at(k, parts, sp.data + fs * 8))
            if x and x == x then
                r[f.name] = if f.kind == "bool" then x == 1 else x
            end
        end
    end
    return r
end

-- one cell of a byte or short block, to write with setBufferAt
local CELLS = { [INT8] = buffer.create(1), [INT16] = buffer.create(2) }

-- The empty block of format `to` of an int field's spec sp, made when
-- first needed.
local function empty_of(sp: any, to: any): buffer
    if to == INT16 then
        return sp.short
    end
    local key = "empty" .. to.kind
    if sp[key] == nil then
        sp[key] = reformat(sp.short, INT16, sp.rows, to)
    end
    return sp[key]
end

-- The whole number block at k of `parts`, block `block` of table t's
-- field `name`.
local function whole_numbers(t: any, name: string, block: number, k: string,
                             parts: number): buffer
    if parts == 0 then
        return barch.store.getBufferAt(k, 0)
    end
    return buffer.fromstring(joined(t, name, block, k, barch.store.get(k)))
end

-- Stores number block b at k, which held `was` parts, and answers the
-- parts it takes.
local function numbers(k: string, b: buffer, was: number): number
    if was == 0 and fits(k, buffer.len(b)) then
        barch.store.setBufferAt(k, b, 0)
        return 0
    end
    return put_block(k, buffer.tostring(b), was)
end

-- Stores number `x` in `slot` of number block k, nil as NaN, or as the
-- format's none in an int block. `was` is the value x replaces, and k is
-- block `block` of table t's field `name`. An int field's block takes the
-- narrowest format that holds its values: a write widens it, and a write
-- that replaces the last value that needed its format narrows it.
local function put_number(t: any, name: string, block: number, sp: any, k: string,
                          slot: number, x: number?, was: number?)
    if sp.short then
        local format, parts = number_block(k)
        local need = format_for(x)
        if format == nil then
            if x == nil then
                return
            end
            format = need
            parts = numbers(k, empty_of(sp, format), 0)
        elseif need.rank > format.rank then
            local b = whole_numbers(t, name, block, k, parts)
            parts = numbers(k, reformat(b, format, sp.rows, need), parts)
            format = need
        elseif need.rank < format.rank and format_for(was) == format then
            local b = whole_numbers(t, name, block, k, parts)
            set_cell(b, format, slot, x)
            local to = narrowest(b, format, sp.rows)
            if to ~= format then
                put_block(k, buffer.tostring(reformat(b, format, sp.rows, to)), parts)
                return
            end
        end
        local at, off = cell_at(k, parts, SHEAD + slot * format.width)
        local one = CELLS[format]
        if one then
            if format == INT8 then
                buffer.writei8(one, 0, x or INT8.none)
            else
                buffer.writei16(one, 0, x or NIL_SHORT)
            end
            barch.store.setBufferAt(at, one, off)
        elseif format == INT32 then
            barch.store.setInt32At(at, x or INT32.none, off)
        else
            barch.store.setF64At(at, x or NAN, off)
        end
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
        buffer.writeu32(b, sp.distinct, 1)
    end
    buffer.writeu32(b, sp.lens + slot * 4, #text + 1)
    buffer.writestring(b, sp.vals, text)
    return buffer.tostring(b)
end

-- `stored` with `text` at slot, or nil at slot for text nil, and `dover`
-- added to the values kept whole elsewhere.
local function replaced(sp: any, stored: string, slot: number, text: string?,
                        dover: number): buffer
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
    return b
end

local function replace_text(sp: any, stored: string, slot: number, text: string?,
                            dover: number): string
    return buffer.tostring(replaced(sp, stored, slot, text, dover))
end

-- A plain text block holding vals[s + 1] at each slot s, with `over`
-- values kept whole elsewhere.
local function plain_block(sp: any, vals: { [number]: string }, over: number): string
    local used, slots, seen, distinct = 0, 0, {}, 0
    for s = 0, sp.rows - 1 do
        local v = vals[s + 1]
        if v then
            used += #v
            slots = s + 1
            if not seen[v] then
                seen[v] = true
                distinct += 1
            end
        end
    end
    local b = header(sp.vals + used, "t", sp.rows)
    buffer.writeu32(b, sp.used, used)
    buffer.writeu32(b, sp.slots, slots)
    buffer.writeu32(b, sp.over, over)
    buffer.writeu32(b, sp.distinct, distinct)
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

-- The dictionary block holding the values of plain text block b, or nil
-- when it keeps a value whole elsewhere or holds more than dict_most()
-- distinct values; then also how many distinct values it holds, when that
-- was counted.
local function as_dict(sp: any, b: buffer): (string?, number?)
    if buffer.readu32(b, sp.over) ~= 0 then
        return nil
    end
    local rows = sp.rows
    local vals, index, dict = {}, {}, {}
    local at = sp.vals
    for s = 0, buffer.readu32(b, sp.slots) - 1 do
        local len = buffer.readu32(b, sp.lens + s * 4)
        if len > 0 then
            local v = buffer.readstring(b, at, len - 1)
            at += len - 1
            if index[v] == nil then
                index[v] = true
                dict[#dict + 1] = v
            end
            vals[s] = v
        end
    end
    if #dict > dict_most(rows) then
        return nil, #dict
    end
    table.sort(dict)
    for i, v in dict do
        index[v] = i
    end
    local cw = width_of(#dict)
    local none = nil_code(cw)
    local codes = buffer.create(rows * cw)
    for s = 0, rows - 1 do
        local v = vals[s]
        write_code(codes, s * cw, cw, if v then index[v] + none else none)
    end
    return dict_block(rows, codes, cw, dict)
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
    local b = replaced(sp, stored, slot, text, dover)
    -- only a write that replaces or clears a value can leave fewer distinct
    -- values or none kept whole elsewhere, and it removes at most one
    -- distinct value, so the block counts its values only when the least
    -- it can hold reaches dict_most()
    if sp.head and string.unpack("<I4", stored, sp.lens + slot * 4 + 1) ~= 0 then
        local least = buffer.readu32(b, sp.distinct) - 1
        if not long and least <= dict_most(sp.rows) then
            local dict, n = as_dict(sp, b)
            if dict then
                return dict
            end
            least = n or least
        end
        buffer.writeu32(b, sp.distinct, math.max(least, 0))
    end
    return buffer.tostring(b)
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
    local parts = 0
    if stored and sp.head then
        parts = string.unpack("<I2", stored, 3)
        stored = joined(t, f.name, block, k, stored)
    end
    -- a dictionary block holds no long values
    local was_long = false
    if stored and not (sp.head and string.byte(stored, 2) == DTAG) then
        was_long = (string.unpack("<I4", stored, sp.lens + slot * 4 + 1) :: number) - 1 > sp.cap
    end
    local dover = (if long then 1 else 0) - (if was_long then 1 else 0)
    local value = text_put(sp, stored, slot, inline, long, dover)
    -- a block with a header splits into parts past the limit
    if #value > room and not sp.head then
        too_large(t, f, block, #value)
    end
    return function()
        if sp.head then
            put_block(k, value, parts)
        else
            barch.store.set(k, value)
        end
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

local targets: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

-- While MIGRATE copies table t into another format or blocks of another
-- size, the table it copies into: t with the format, store, block and rows
-- of t.rebuild. Answers nil when no copy runs.
function target(t: any): any
    local m = t.rebuild
    if m == nil then
        return nil
    end
    local n = targets[t]
    if n then
        return n
    end
    n = table.clone(t)
    n.format, n.store, n.block, n.rows, n.rebuild = m.format, m.store, m.block, m.rows, nil
    n.fields = {}
    for i, f in t.fields do
        local d = table.clone(f)
        d.rows = m.fields[i]
        n.fields[i] = d
    end
    targets[t] = n
    return n
end

-- Whether a write to row pk of t also goes to the table MIGRATE copies it
-- into: rows up to the last one it copied keep both copies the same.
function copied(t: any, pk: number): boolean
    local m = t.rebuild
    return m ~= nil and m.upto ~= nil and pk <= m.upto
end

-- write() for a row already checked.
local function put_row(t: any, fields: any, pk: number, old: any, r: any, lock: boolean?): () -> ()
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
                local was = old and old[f.name]
                writes[#writes + 1] = function() put_number(t, f.name, fb, sp, k, fs, x, was) end
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

-- Checks row r for pk, given the row it replaces (nil for a new row), and
-- answers a function that stores it. Everything that can refuse the row
-- happens here, so a caller can check before its first write. `lock` is true
-- for a pessimistic caller.
function write(t: any, fields: any, pk: number, old: any, r: any, lock: boolean?): () -> ()
    rc.validate(fields, r)
    return put_row(t, fields, pk, old, r, lock)
end

-- Answers a function that writes row r, as the store holds it, at pk in
-- the table MIGRATE copies table t into, given the row it replaces there
-- (nil for a new row). A field without a value stays without one. `version`
-- marks a row of a row format.
function copy(t: any, fields: any, version: number, pk: number, old: any, r: any,
              lock: boolean?): () -> ()
    local to = target(t)
    if to.format == "column" then
        return put_row(to, fields, pk, old, r, lock)
    end
    local value = rc.encode(fields, to.format, version, r, true)
    return function() barch.store.set(lay.row(to, pk), value) end
end

-- Removes the row at pk, which holds `old`, from the table MIGRATE copies
-- table t into.
function uncopy(t: any, fields: any, pk: number, old: any, lock: boolean?)
    local to = target(t)
    if to.format == "column" then
        remove(to, fields, pk, old, lock)
    else
        barch.store.remove(lay.row(to, pk))
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
            if sp.head and (sp.text or sp.short) then
                remove_block(k)
            else
                barch.store.remove(k)
            end
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
                put_number(t, f.name, fb, sp, k, fs, nil, was)
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
    -- clearing the long value makes a dictionary again
    long = text_put(sp, long, 3, nil, false, -1)
    if string.byte(long, 2) ~= DTAG or text_at(sp, long, 0) ~= "z"
        or text_at(sp, long, 1) ~= "z" or text_at(sp, long, 3) ~= nil then
        return false, "dictionary block after a long value"
    end
    for s = 0, dict_most(64) - 1 do
        b = text_put(sp, b, s, "v" .. s, false, 0)
    end
    local full = string.byte(b, 2) == DTAG
    b = text_put(sp, b, dict_most(64), "w", false, 0)
    if not full or string.byte(b, 2) ~= string.byte("t") or text_at(sp, b, 5) ~= "v5"
        or text_at(sp, b, dict_most(64)) ~= "w"
        or string.unpack("<I4", b, sp.distinct + 1) ~= dict_most(64) + 1 then
        return false, "dictionary block past its values"
    end
    -- a plain block whose distinct values fall to dict_most() is a
    -- dictionary again; adding to an empty slot leaves it plain
    b = text_put(sp, b, dict_most(64) + 1, "v1", false, 0)
    local still = string.byte(b, 2) == string.byte("t")
    b = text_put(sp, b, dict_most(64), "v0", false, 0)
    if not still or string.byte(b, 2) ~= DTAG or text_at(sp, b, 5) ~= "v5"
        or text_at(sp, b, dict_most(64)) ~= "v0" or text_at(sp, b, dict_most(64) + 1) ~= "v1"
        or string.unpack("<I4", b, 9) ~= dict_most(64) then
        return false, "dictionary block from plain text"
    end
    -- an int block takes the narrowest format that holds its values
    local nb = header(8 + 4 * 8, "n", 4)
    for i, x in { 3, NAN, -32767, 40000 } do
        buffer.writef64(nb, 8 + (i - 1) * 8, x)
    end
    local wide_n = narrowest(nb, F64, 4)
    local wn = reformat(nb, F64, 4, INT32)
    buffer.writef64(nb, 8 + 3 * 8, 32767)
    local h = reformat(nb, F64, 4, narrowest(nb, F64, 4))
    if wide_n ~= INT32 or int_format(wn) ~= INT32 or cell(wn, INT32, 3) ~= 40000
        or cell(wn, INT32, 1) == cell(wn, INT32, 1) or int_format(h) ~= INT16
        or buffer.readi16(h, SHEAD) ~= 3 or buffer.readi16(h, SHEAD + 2) ~= NIL_SHORT
        or buffer.readi16(h, SHEAD + 6) ~= 32767 or format_for(2 ^ 31) ~= F64
        or format_for(-2147483647) ~= INT32 or format_for(0.5) ~= F64
        or format_for(-127) ~= INT8 or format_for(128) ~= INT16 or format_for(nil) ~= INT8 then
        return false, "int block formats"
    end
    buffer.writef64(nb, 8 + 2 * 8, -127)
    buffer.writef64(nb, 8 + 3 * 8, 127)
    local bb = reformat(nb, F64, 4, narrowest(nb, F64, 4))
    if int_format(bb) ~= INT8 or buffer.len(bb) ~= SHEAD + 4 or cell(bb, INT8, 0) ~= 3
        or cell(bb, INT8, 1) == cell(bb, INT8, 1) or buffer.readi8(bb, SHEAD + 1) ~= -128
        or cell(bb, INT8, 2) ~= -127 or cell(bb, INT8, 3) ~= 127 then
        return false, "byte block from a number block"
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
        block_rows(4096) == 4096, block_rows(4096, { kind = "int" }) == 2048,
        block_rows(262144, { kind = "int" }) == 131072,
        block_rows(4096, { kind = "string" }) == 512,
        block_rows(4096, { kind = "string", maxLen = 4 }) == 512,
        block_rows(262144, { kind = "string", maxLen = 1000 }) == 16384,
        block_rows(1024, { kind = "float" }) == 128, block_rows(1000) == 1024,
        block_rows(1024, { kind = "enum", values = { "new", "done" } }) == 256,
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
