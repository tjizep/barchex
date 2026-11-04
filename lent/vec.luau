--!native
-- Reference versions of the vector kernels lent asks barch to provide in
-- C++ as barch.vec. Each function here has the arguments, results and
-- errors the native version must match; docs/barch-vec.md describes them,
-- and tests/test_vec.py runs the same checks on both. Callers take
-- `barch.vec or require("lent.VEC")`.
--
-- Required, not called: `local vec = require("lent.VEC")`. A function key
-- has to define call(), so this one answers a self-check:
--
--   lent.VEC                 -> "ok" or which check failed (from any space)
--
-- A column of elements lives in a buffer b: element i starts at byte
-- off + i * stride. A column block packs its elements (stride is the
-- element's width), and a block of fixed-width rows holds one element per
-- row (stride is the row's width). Reads need no alignment.
--
--   kind  element, little-endian           nil
--   i8    int8                             equal to `none`
--   i16   int16                            equal to `none`
--   i32   int32                            equal to `none`
--   i64   int64                            equal to `none`
--   f64   float64                          NaN
--   str   u32 start, u32 length + 1; the   length + 1 = 0
--         bytes are b[start, start + length)
--
-- The candidates of a call are the u32 indexes sel[0..n) when sel is a
-- buffer, or 0 to n - 1 when sel is nil. Results go to caller buffers, so a
-- caller reuses them from block to block.

local WIDTH = { i8 = 1, i16 = 2, i32 = 4, i64 = 8, f64 = 8, str = 8 }
local CODE = { i8 = 1, i32 = 2, i64 = 3, f64 = 4, str = 5, i16 = 6 }
local OPS = { ["="] = 1, ["~="] = 2, ["<"] = 3, ["<="] = 4, [">"] = 5, [">="] = 6 }
local TWO32 = 4294967296

local function fail(fn: string, message: string)
    error("vec." .. fn .. ": " .. message, 0)
end

local function whole(fn: string, name: string, v: any, least: number)
    if type(v) ~= "number" or v ~= math.floor(v) or v < least or v > 2 ^ 53 then
        fail(fn, name .. " must be a whole number from " .. least)
    end
end

-- Checks a column's arguments and that its last element lies in b, when
-- the candidates run from 0 to n - 1. Answers the kind's code.
local function column(fn: string, kind: any, b: any, off: any, stride: any, sel: any,
                      n: any): number
    local code = CODE[kind]
    if code == nil then
        fail(fn, "unknown kind " .. tostring(kind))
    end
    if type(b) ~= "buffer" then
        fail(fn, "takes a buffer of elements")
    end
    whole(fn, "off", off, 0)
    whole(fn, "stride", stride, 1)
    whole(fn, "n", n, 0)
    if sel ~= nil and type(sel) ~= "buffer" then
        fail(fn, "takes a buffer of u32 indexes or nil for sel")
    end
    local last = if sel == nil then n - 1 else -1
    if (sel ~= nil and n * 4 > buffer.len(sel))
        or (last >= 0 and off + last * stride + WIDTH[kind] > buffer.len(b)) then
        fail(fn, "reads past the end of a buffer")
    end
    return code
end

local function output(fn: string, out: any)
    if type(out) ~= "buffer" then
        fail(fn, "takes a buffer for its results")
    end
end

-- The number at byte `at` of b, for every kind code but 5.
local function read(code: number, b: buffer, at: number): number
    if code == 4 then
        return buffer.readf64(b, at)
    elseif code == 1 then
        return buffer.readi8(b, at)
    elseif code == 2 then
        return buffer.readi32(b, at)
    elseif code == 6 then
        return buffer.readi16(b, at)
    end
    return buffer.readu32(b, at) + buffer.readi32(b, at + 4) * TWO32
end

-- Whether `x o w` holds, for op code o.
local function holds(o: number, x: any, w: any): boolean
    if o == 1 then
        return x == w
    elseif o == 2 then
        return x ~= w
    elseif o == 3 then
        return x < w
    elseif o == 4 then
        return x <= w
    elseif o == 5 then
        return x > w
    end
    return x >= w
end

-- The string element at byte `at` of b, or nil.
local function text(b: buffer, at: number): string?
    local size = buffer.readu32(b, at + 4)
    if size == 0 then
        return nil
    end
    return buffer.readstring(b, buffer.readu32(b, at), size - 1)
end

-- Writes into `out` the u32 index of each byte of m[off, off + n) that is
-- not 0, in order, and answers how many it wrote. A presence block gives
-- the slots that hold rows.
function mask(m: buffer, off: number, n: number, out: buffer): number
    if type(m) ~= "buffer" then
        fail("mask", "takes a buffer of bytes")
    end
    whole("mask", "off", off, 0)
    whole("mask", "n", n, 0)
    output("mask", out)
    if off + n > buffer.len(m) then
        fail("mask", "reads past the end of a buffer")
    end
    local count = 0
    for i = 0, n - 1 do
        if buffer.readu8(m, off + i) ~= 0 then
            buffer.writeu32(out, count * 4, i)
            count += 1
        end
    end
    return count
end

-- Writes into `out` the candidates whose element passes `element op
-- value`, in order, and answers how many it wrote. op is one of = ~= < <=
-- > >=; value is a number, or a string for str, which compares by bytes.
-- A nil element passes only ~=. `none` gives the nil of the integer kinds,
-- or nil when they have none. out may be sel.
function filter(kind: string, b: buffer, off: number, stride: number, op: string, value: any,
                none: number?, sel: buffer?, n: number, out: buffer): number
    local code = column("filter", kind, b, off, stride, sel, n)
    local o = OPS[op]
    if o == nil then
        fail("filter", "unknown op " .. tostring(op))
    end
    if code == 5 then
        if type(value) ~= "string" then
            fail("filter", "kind str compares with a string")
        end
    elseif type(value) ~= "number" or value ~= value then
        fail("filter", "kind " .. kind .. " compares with a number")
    end
    output("filter", out)
    local kept = 0
    for k = 0, n - 1 do
        local i = if sel then buffer.readu32(sel, k * 4) else k
        local at = off + i * stride
        local pass
        if code == 5 then
            local s = text(b, at)
            pass = if s == nil then o == 2 else holds(o, s, value)
        else
            local x = read(code, b, at)
            pass = if x == none then o == 2 else holds(o, x, value)
        end
        if pass then
            buffer.writeu32(out, kept * 4, i)
            kept += 1
        end
    end
    return kept
end

-- Writes into `out` the candidates whose code c, of kind i8, i16 or i32, has
-- 0 <= c < len(set) and set[c] ~= 0, in order, and answers how many it
-- wrote. A dictionary column tests any condition on its strings this way:
-- the caller marks the codes whose strings pass. out may be sel.
function filterIn(kind: string, b: buffer, off: number, stride: number, set: buffer,
                  sel: buffer?, n: number, out: buffer): number
    local code = column("filterIn", kind, b, off, stride, sel, n)
    if code ~= 1 and code ~= 2 and code ~= 6 then
        fail("filterIn", "takes kind i8, i16 or i32")
    end
    if type(set) ~= "buffer" then
        fail("filterIn", "takes a buffer of bytes for set")
    end
    output("filterIn", out)
    local size = buffer.len(set)
    local kept = 0
    for k = 0, n - 1 do
        local i = if sel then buffer.readu32(sel, k * 4) else k
        local c = read(code, b, off + i * stride)
        if c >= 0 and c < size and buffer.readu8(set, c) ~= 0 then
            buffer.writeu32(out, kept * 4, i)
            kept += 1
        end
    end
    return kept
end

-- Adds each candidate's element to its group's record in `out`: the k-th
-- candidate belongs to group gids[k], a u32, or to group 0 when gids is
-- nil. Group g's record is 4 f64s at byte 32 * g: the count of non-nil
-- elements, their sum, their least and their greatest. A caller starts a
-- record at 0, 0, inf and -inf and folds block after block into it. Kind
-- str counts and leaves the other three alone.
function fold(kind: string, b: buffer, off: number, stride: number, none: number?,
              sel: buffer?, n: number, gids: buffer?, out: buffer)
    local code = column("fold", kind, b, off, stride, sel, n)
    if gids ~= nil and (type(gids) ~= "buffer" or n * 4 > buffer.len(gids)) then
        fail("fold", "takes a buffer of n u32 group ids or nil for gids")
    end
    output("fold", out)
    if gids == nil then
        local count, sum = buffer.readf64(out, 0), buffer.readf64(out, 8)
        local least, most = buffer.readf64(out, 16), buffer.readf64(out, 24)
        for k = 0, n - 1 do
            local i = if sel then buffer.readu32(sel, k * 4) else k
            local at = off + i * stride
            if code == 5 then
                if buffer.readu32(b, at + 4) ~= 0 then
                    count += 1
                end
            else
                local x = read(code, b, at)
                if x == x and x ~= none then
                    count += 1
                    sum += x
                    if x < least then
                        least = x
                    end
                    if x > most then
                        most = x
                    end
                end
            end
        end
        buffer.writef64(out, 0, count)
        if code ~= 5 then
            buffer.writef64(out, 8, sum)
            buffer.writef64(out, 16, least)
            buffer.writef64(out, 24, most)
        end
        return
    end
    for k = 0, n - 1 do
        local i = if sel then buffer.readu32(sel, k * 4) else k
        local at = off + i * stride
        local g = buffer.readu32(gids, k * 4) * 32
        if code == 5 then
            if buffer.readu32(b, at + 4) ~= 0 then
                buffer.writef64(out, g, buffer.readf64(out, g) + 1)
            end
        else
            local x = read(code, b, at)
            if x == x and x ~= none then
                buffer.writef64(out, g, buffer.readf64(out, g) + 1)
                buffer.writef64(out, g + 8, buffer.readf64(out, g + 8) + x)
                if x < buffer.readf64(out, g + 16) then
                    buffer.writef64(out, g + 16, x)
                end
                if x > buffer.readf64(out, g + 24) then
                    buffer.writef64(out, g + 24, x)
                end
            end
        end
    end
end

-- Turns n u32 lengths at b[off], each a length + 1 or 0 for nil, with the
-- values stored one after another from byte `start`, into str elements in
-- `out`: element i is the u32 start of value i and its length + 1. Answers
-- the byte after the last value. lent's text blocks store lengths this way.
function offsets(b: buffer, off: number, n: number, start: number, out: buffer): number
    if type(b) ~= "buffer" then
        fail("offsets", "takes a buffer of lengths")
    end
    whole("offsets", "off", off, 0)
    whole("offsets", "n", n, 0)
    whole("offsets", "start", start, 0)
    output("offsets", out)
    if off + n * 4 > buffer.len(b) then
        fail("offsets", "reads past the end of a buffer")
    end
    for i = 0, n - 1 do
        local size = buffer.readu32(b, off + i * 4)
        buffer.writeu32(out, i * 8, start)
        buffer.writeu32(out, i * 8 + 4, size)
        if size > 0 then
            start += size - 1
        end
    end
    return start
end

-- groupers --------------------------------------------------------------------

-- A grouper numbers the distinct values of one kind from 0, in the order it
-- first meets them, across every call to its ids(). Nil is one value too,
-- and so are -0 and 0, which key as 0.
-- Its ids serve as a groupBy's group ids, and as a dictionary's codes.
local Grouper = {}
Grouper.__index = Grouper

local NIL = {}

function grouper(kind: string): any
    if CODE[kind] == nil then
        fail("grouper", "unknown kind " .. tostring(kind))
    end
    return setmetatable({ kind = kind, index = {}, keys = {} }, Grouper)
end

-- Writes the group id of the k-th candidate's element at gids[k], a u32,
-- adding the groups of values it hasn't met. Answers how many groups the
-- grouper then holds.
function Grouper.ids(g: any, b: buffer, off: number, stride: number, none: number?,
                     sel: buffer?, n: number, gids: buffer): number
    local code = column("ids", g.kind, b, off, stride, sel, n)
    output("ids", gids)
    local ids, keys = g.index, g.keys
    for k = 0, n - 1 do
        local i = if sel then buffer.readu32(sel, k * 4) else k
        local at = off + i * stride
        local v: any
        if code == 5 then
            v = text(b, at)
        else
            v = read(code, b, at)
            if v ~= v or v == none then
                v = nil
            elseif v == 0 then
                v = 0 -- -0 and 0 are one value
            end
        end
        local key = if v == nil then NIL else v
        local id = ids[key]
        if id == nil then
            id = #keys
            ids[key] = id
            keys[id + 1] = key
        end
        buffer.writeu32(gids, k * 4, id)
    end
    return #keys
end

-- The value group `id` holds, or nil for the nil group.
function Grouper.key(g: any, id: number): any
    local key = g.keys[id + 1]
    if key == nil then
        fail("key", "has no group " .. tostring(id))
    end
    return if key == NIL then nil else key
end

-- How many groups the grouper holds.
function Grouper.size(g: any): number
    return #g.keys
end

-- self-check ------------------------------------------------------------------

local function raises(fn: () -> (), want: string): boolean
    local ok, err = pcall(fn)
    return not ok and string.find(tostring(err), want, 1, true) ~= nil
end

function selftest(): (boolean, string?)
    local b = buffer.create(32)
    for i = 0, 3 do
        buffer.writef64(b, i * 8, i * 1.5)
    end
    buffer.writef64(b, 16, 0 / 0)
    local sel = buffer.create(16)
    if filter("f64", b, 0, 8, ">", 1, nil, nil, 4, sel) ~= 2
        or buffer.readu32(sel, 4) ~= 3 then
        return false, "filter f64"
    end
    if filter("f64", b, 0, 8, "~=", 0, nil, nil, 4, sel) ~= 3 then
        return false, "a nil passes ~="
    end
    local out = buffer.create(32)
    buffer.writef64(out, 16, math.huge)
    buffer.writef64(out, 24, -math.huge)
    fold("f64", b, 0, 8, nil, nil, 4, nil, out)
    if buffer.readf64(out, 0) ~= 3 or buffer.readf64(out, 8) ~= 6
        or buffer.readf64(out, 16) ~= 0 or buffer.readf64(out, 24) ~= 4.5 then
        return false, "fold f64"
    end
    local codes = buffer.create(4)
    buffer.writei8(codes, 0, 2)
    buffer.writei8(codes, 1, 0)
    buffer.writei8(codes, 2, 2)
    buffer.writei8(codes, 3, -1)
    local set = buffer.create(3)
    buffer.writeu8(set, 2, 1)
    if filterIn("i8", codes, 0, 1, set, nil, 4, sel) ~= 2 then
        return false, "filterIn i8"
    end
    local wide = buffer.create(6)
    buffer.writei16(wide, 0, 300)
    buffer.writei16(wide, 2, -32768)
    buffer.writei16(wide, 4, -2)
    if filter("i16", wide, 0, 2, "<", 0, -32768, nil, 3, sel) ~= 1
        or buffer.readu32(sel, 0) ~= 2 then
        return false, "filter i16"
    end
    local g = grouper("i8")
    local gids = buffer.create(16)
    if g:ids(codes, 0, 1, 0, nil, 4, gids) ~= 3 or buffer.readu32(gids, 8) ~= 0
        or g:key(1) ~= nil or g:key(2) ~= -1 then
        return false, "grouper i8"
    end
    if not raises(function() filter("u8", b, 0, 8, "=", 1, nil, nil, 4, sel) end,
                  "vec.filter: unknown kind u8")
        or not raises(function() filter("f64", b, 0, 8, "=", 1, nil, nil, 5, sel) end,
                      "vec.filter: reads past the end of a buffer") then
        return false, "errors"
    end
    return true
end

function call()
    local ok, why = selftest()
    return if ok then "ok" else why
end
