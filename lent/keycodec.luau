-- Order-preserving key encoding for lent's rows, indexes and edges.
--
-- Required, not called: `local kc = require("lent.KEYCODEC")`. A function key
-- has to define call(), so this one answers a self-check of the round trips:
--
--   lent.KEYCODEC            -> "ok" or which check failed (from any space)
--
-- An index key is a prefix followed by encoded values, and barch.store.range
-- walks keys in byte order. Each encoded value sorts the way its value does,
-- and each one ends itself, so values can be packed back to back and a range
-- over a packed prefix holds exactly the keys that start with those values.
--
-- barch reads a key with a space in it as a tuple, and a key or tuple part
-- that parses as a number as that number (integers before doubles, whatever
-- their values), and refuses a key with a NUL in it. Earlier barch builds gave
-- a key with "\1" in it back from RANGE and KEYS cut short at that byte, and
-- keys stored then still have to sort the same way. So an encoded value never
-- holds a NUL, a "\1" or a space, and the caller's prefix has to start with a
-- letter, such as "lent.". barch walks every other byte in unsigned order.
--
--   kind      encoded as                                   decodes to
--   (nil)     "-"                                          nil, before any value
--   "bool"    "b0" or "b1"                                 false, true
--   "int"     "i" + 16 hex digits, sign bit flipped        integer in +-2^53
--   "float"   "f" + 16 hex digits of the IEEE bits,        number; -0 is 0,
--             sign bit flipped (all bits when negative)    NaN is refused
--   "string"  "s" + escaped bytes + "\2\2"                 string, any bytes
--   "uuid"    "u" + its 32 hex digits                      the uuid, 36 lowercase
--                                                          characters with dashes
--   "time"    as "int", for Unix milliseconds              integer
--
-- A string escapes five bytes and keeps the order of all of them:
--   "\0" -> "\2\3"   "\1" -> "\2\4"   "\2" -> "\2\5"
--   "\31" -> "\31\2"   " " -> "\31\3"
-- The terminator "\2\2" sorts below every escape and every plain byte, so a
-- string sorts before any longer string it is a prefix of.

local MAX_INT = 2 ^ 53
local TWO32 = 2 ^ 32
local SIGN = 0x80000000

local ESCAPE = {
    ["\0"] = "\2\3",
    ["\1"] = "\2\4",
    ["\2"] = "\2\5",
    ["\31"] = "\31\2",
    [" "] = "\31\3",
}
local UNESCAPE_2 = { [3] = "\0", [4] = "\1", [5] = "\2" }
local UNESCAPE_31 = { [2] = "\31", [3] = " " }

local scratch = buffer.create(8)

local function enc_int(n: number): string
    if type(n) ~= "number" or n ~= n or math.floor(n) ~= n then
        error("KEYCODEC int needs an integer, got " .. tostring(n), 3)
    end
    if n > MAX_INT or n < -MAX_INT then
        error("KEYCODEC int is limited to +-2^53, got " .. tostring(n), 3)
    end
    local hi = n // TWO32
    local lo = n - hi * TWO32
    return string.format("i%08x%08x", hi + SIGN, lo)
end

local function enc_float(x: number): string
    if type(x) ~= "number" or x ~= x then
        error("KEYCODEC float needs a number other than NaN, got " .. tostring(x), 3)
    end
    if x == 0 then
        x = 0 -- -0 and 0 are one value, so they are one key
    end
    buffer.writef64(scratch, 0, x)
    local lo = buffer.readu32(scratch, 0)
    local hi = buffer.readu32(scratch, 4)
    if hi >= SIGN then
        hi, lo = bit32.bnot(hi), bit32.bnot(lo)
    else
        hi = hi + SIGN
    end
    return string.format("f%08x%08x", hi, lo)
end

local function enc_string(s: string): string
    if type(s) ~= "string" then
        error("KEYCODEC string needs a string, got " .. type(s), 3)
    end
    return "s" .. string.gsub(s, "[%z\1\2\31 ]", ESCAPE) .. "\2\2"
end

local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

-- Whether `s` is a uuid as barch.uuid() writes it: 36 characters, lowercase
-- hex digits and four dashes.
function is_uuid(s: any): boolean
    return type(s) == "string" and string.match(s, UUID) ~= nil and string.lower(s) == s
end

local function enc_uuid(s: string): string
    if not is_uuid(s) then
        error("KEYCODEC uuid needs 36 lowercase characters like barch.uuid(), got "
            .. tostring(s), 3)
    end
    return "u" .. string.gsub(s, "-", "")
end

local function enc_bool(b: boolean): string
    if type(b) ~= "boolean" then
        error("KEYCODEC bool needs a boolean, got " .. type(b), 3)
    end
    return b and "b1" or "b0"
end

local ENCODERS = {
    int = enc_int,
    float = enc_float,
    string = enc_string,
    bool = enc_bool,
    uuid = enc_uuid,
    time = enc_int,
}

-- How many bytes a value of `kind` takes, for the kinds whose values all
-- take the same: a pk at the end of a key is read from there.
WIDTH = { int = 17, uuid = 33 }

-- The key text for one value of `kind`: "int", "float", "string", "bool"
-- or "uuid".
-- nil encodes as null whatever the kind.
function encode(kind: string, value: any): string
    local enc = ENCODERS[kind]
    if enc == nil then
        error("KEYCODEC has no kind " .. tostring(kind), 2)
    end
    if value == nil then
        return "-"
    end
    return enc(value)
end

-- Values packed back to back: kinds[i] encodes values[i]. values may have
-- holes, which pack as null; #kinds says how many there are.
function pack(kinds: { string }, values: { any }): string
    local parts = table.create(#kinds)
    for i, kind in kinds do
        parts[i] = encode(kind, values[i])
    end
    return table.concat(parts)
end

local function hex32(key: string, at: number): number
    local n = tonumber(string.sub(key, at, at + 7), 16)
    if n == nil or #key < at + 7 then
        error("KEYCODEC truncated number at byte " .. at, 3)
    end
    return n
end

-- One value from `key` starting at byte `at` (default 1): the value and the
-- byte after it. The tag says the kind, so decoding needs no schema.
function decode(key: string, at: number?): (any, number)
    local pos = at or 1
    local tag = string.sub(key, pos, pos)
    if tag == "-" then
        return nil, pos + 1
    elseif tag == "b" then
        local v = string.sub(key, pos + 1, pos + 1)
        if v == "1" then return true, pos + 2 end
        if v == "0" then return false, pos + 2 end
        error("KEYCODEC bad bool at byte " .. pos, 2)
    elseif tag == "i" then
        local hi, lo = hex32(key, pos + 1), hex32(key, pos + 9)
        return (hi - SIGN) * TWO32 + lo, pos + 17
    elseif tag == "u" then
        local h = string.sub(key, pos + 1, pos + 32)
        if #h ~= 32 or not string.match(h, "^%x+$") then
            error("KEYCODEC truncated uuid at byte " .. pos, 2)
        end
        return string.sub(h, 1, 8) .. "-" .. string.sub(h, 9, 12) .. "-" .. string.sub(h, 13, 16)
            .. "-" .. string.sub(h, 17, 20) .. "-" .. string.sub(h, 21), pos + 33
    elseif tag == "f" then
        local hi, lo = hex32(key, pos + 1), hex32(key, pos + 9)
        if hi >= SIGN then
            hi = hi - SIGN
        else
            hi, lo = bit32.bnot(hi), bit32.bnot(lo)
        end
        buffer.writeu32(scratch, 0, lo)
        buffer.writeu32(scratch, 4, hi)
        return buffer.readf64(scratch, 0), pos + 17
    elseif tag == "s" then
        local parts = {}
        pos += 1
        while true do
            local i = string.find(key, "[\2\31]", pos)
            if i == nil then
                error("KEYCODEC unterminated string", 2)
            end
            parts[#parts + 1] = string.sub(key, pos, i - 1)
            local c, d = string.byte(key, i, i + 1)
            local out
            if c == 2 then
                if d == 2 then
                    return table.concat(parts), i + 2
                end
                out = UNESCAPE_2[d]
            else
                out = UNESCAPE_31[d]
            end
            if out == nil then
                error("KEYCODEC bad escape at byte " .. i, 2)
            end
            parts[#parts + 1] = out
            pos = i + 2
        end
    end
    error("KEYCODEC no value at byte " .. pos, 2)
end

-- `n` values from `key` starting at `at` (default 1), as a table that may
-- have holes for nulls, and the byte after the last one.
function unpack(key: string, n: number, at: number?): ({ any }, number)
    local values = table.create(n)
    local pos = at or 1
    for i = 1, n do
        values[i], pos = decode(key, pos)
    end
    return values, pos
end

-- The upper bound for a range over every key that starts with `prefix`: the
-- shortest string greater than all of them, for barch.store.range's
-- exclusive `hi`. nil when there is none (an empty prefix, or all "\255").
-- A byte that would become a space becomes "!" instead, which bounds the
-- same keys because no key here holds a space.
function after(prefix: string): string?
    local n = #prefix
    while n > 0 and string.byte(prefix, n) == 255 do
        n -= 1
    end
    if n == 0 then
        return nil
    end
    local b = string.byte(prefix, n) + 1
    if b == 32 then
        b = 33
    end
    return string.sub(prefix, 1, n - 1) .. string.char(b)
end

local function same(a: any, b: any): boolean
    if a ~= b then return false end
    -- 0 and -0 compare equal; a key always decodes to 0
    if a == 0 and 1 / b < 0 then return false end
    return true
end

function selftest(): (boolean, string?)
    local cases = {
        { "int", 0 }, { "int", 1 }, { "int", -1 }, { "int", MAX_INT }, { "int", -MAX_INT },
        { "int", 4294967296 }, { "int", -4294967297 },
        { "float", 0 }, { "float", 1.5 }, { "float", -1.5 }, { "float", math.huge },
        { "float", -math.huge }, { "float", 5e-324 }, { "float", -5e-324 }, { "float", 1e308 },
        { "string", "" }, { "string", "plain" }, { "string", "a b" }, { "string", "\0\1\2\31 \255" },
        { "string", "\2\2" }, { "string", "\1\1" }, { "string", "\31\31\2" },
        { "bool", true }, { "bool", false },
        { "uuid", "01a16f3f-429a-7b08-9017-ec30094a149b" }, { "uuid", barch.uuid() },
    }
    for _, c in cases do
        local key = encode(c[1], c[2])
        if string.find(key, "[%z\1 ]") then
            return false, c[1] .. " " .. tostring(c[2]) .. " encoded a NUL, a \\1 or a space"
        end
        local v, next = decode(key)
        if not same(v, c[2]) or next ~= #key + 1 then
            return false, c[1] .. " " .. tostring(c[2]) .. " decoded as " .. tostring(v)
        end
    end
    if encode("float", -0.0) ~= encode("float", 0) then
        return false, "-0 and 0 encoded differently"
    end
    if encode("string", nil) ~= "-" then
        return false, "nil did not encode as null"
    end
    local kinds = { "string", "int", "float", "bool", "string" }
    local key = pack(kinds, { "x y", nil, -2.25, true, "" })
    local back, next = unpack(key, #kinds)
    if back[1] ~= "x y" or back[2] ~= nil or back[3] ~= -2.25 or back[4] ~= true
        or back[5] ~= "" or next ~= #key + 1 then
        return false, "pack and unpack disagreed"
    end
    local u1, u2 = barch.uuid(), barch.uuid()
    if not (encode("uuid", u1) < encode("uuid", u2)) or #encode("uuid", u1) ~= WIDTH.uuid
        or #encode("int", 7) ~= WIDTH.int then
        return false, "uuid order or width"
    end
    for _, bad in { { "int", 1.5 }, { "int", 2 ^ 54 }, { "float", 0 / 0 }, { "string", 1 },
                    { "uuid", "01A16F3F-429A-7B08-9017-EC30094A149B" }, { "uuid", "x" } } do
        if pcall(encode, bad[1], bad[2]) then
            return false, bad[1] .. " accepted " .. tostring(bad[2])
        end
    end
    if after("ab") ~= "ac" or after("a\255\255") ~= "b" or after("\255") ~= nil
        or after("a\31") ~= "a!" then
        return false, "after"
    end
    return true
end

function call()
    local ok, why = selftest()
    return ok and "ok" or ("failed: " .. why)
end
