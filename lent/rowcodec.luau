-- Row encoding for lent: a row table to a stored value and back, in one of
-- three formats a table picks.
--
-- Required, not called: `local rc = require("lent.ROWCODEC")`. A function key
-- has to define call(), so this one answers a self-check of the round trips:
--
--   lent.ROWCODEC            -> "ok" or which check failed (from any space)
--
-- A row is checked against a field list made by fields():
--
--   local users = rc.fields({
--       { name = "email", kind = "string", id = 1 },
--       { name = "age", kind = "int", id = 2, optional = true },
--   })
--   local value = rc.encode(users, "binary", 3, { email = "a@b", age = 41 })
--   local row, version, format = rc.decode(users, value)  -- row, 3, "binary"
--
-- Fields support string, int (an integer in +-2^53), float, decimal, bool,
-- time, enum, json and bytes. Time uses int storage. Decimal uses float
-- storage for the value lent.CLIENT rounded to the field's scale. Enum uses
-- strings and a required `values` list. Bytes are Luau strings, stored as hex in JSON and
-- text rows and raw bytes in binary rows. JSON values preserve nulls and
-- array/object distinctions through lent.VALUES. A field's id is 1 to 65535 and stays
-- with the field for the table's life: text and binary rows name fields by
-- id, so a field can be renamed without rewriting them.
--
--   format    stored value                                      fields named by
--   "json"    a JSON object, with the schema version in "_v"    name
--   "text"    "t" + version, then "\t" + id + "=" + value       id
--   "binary"  "b", a u32 version, then id, tag, value entries   id
--
-- decode() reads any of the three, whatever the table's format is now, and
-- answers the schema version the row was written with. A row written by an
-- older schema decodes with the current field list: a field it has no value
-- for is nil, and a value for a field the list no longer has is skipped. An
-- int value decodes into a float field. A float value decodes into an int
-- field when it is a whole number in range. MIGRATE checks compatible kind
-- changes before publishing a schema.
--
-- encode() refuses a row with a key the field list has no field for, a
-- missing value for a field that is not optional, or a value of the wrong
-- kind. NaN is refused in every format. A "json" row also refuses a string
-- that is not UTF-8 and an infinite float, which JSON has no way to write;
-- use "text" or "binary" for those. JSON fields require valid UTF-8 strings
-- and finite numbers in every row format. Bytes fields hold any bytes in all three.

local MAX_INT = 2 ^ 53
local VALUES = require("lent.VALUES")
local KINDS = { string = true, int = true, float = true, decimal = true, bool = true,
                time = true, enum = true, json = true, bytes = true }
local STORED_AS = { time = "int", decimal = "float" }

-- binary entry tags
local FALSE, TRUE, INT, FLOAT, STRING, JSON, BYTES = 0, 1, 2, 3, 4, 5, 6

-- Compiles a field list: { name, kind, id, optional?, values? } entries in the order
-- rows should be written. Names start with a letter and hold letters, digits
-- and "_". Answers { list, byName, byId }.
function fields(list: { any }): any
    local out, byName, byId = table.create(#list), {}, {}
    for i, f in list do
        local where = "ROWCODEC field " .. i
        if type(f.name) ~= "string" or not string.match(f.name, "^%a[%w_]*$") then
            error(where .. " needs a name of letters, digits and _", 2)
        end
        where = "ROWCODEC field " .. f.name
        if not KINDS[f.kind] then
            error(where .. " has no kind " .. tostring(f.kind), 2)
        end
        if type(f.id) ~= "number" or f.id ~= math.floor(f.id) or f.id < 1 or f.id > 65535 then
            error(where .. " needs an id from 1 to 65535", 2)
        end
        if byName[f.name] then
            error(where .. " is defined twice", 2)
        end
        if byId[f.id] then
            error(where .. " has the id of " .. byId[f.id].name, 2)
        end
        local kind = STORED_AS[f.kind] or f.kind
        local field = { name = f.name, kind = kind, id = f.id, optional = f.optional == true }
        if kind == "enum" then field.values = VALUES.enum_values(f.values, where) end
        byName[f.name] = field
        byId[f.id] = field
        out[i] = field
    end
    return { list = out, byName = byName, byId = byId }
end

local function is_int(v: any): boolean
    return type(v) == "number" and v == math.floor(v) and v <= MAX_INT and v >= -MAX_INT
end

-- The value checked for `field` before it is written, or an error.
local function check(field: any, v: any): any
    local kind, ok = field.kind, false
    if kind == "json" then
        local valid, why = pcall(VALUES.json, v)
        if not valid then error("ROWCODEC field " .. field.name .. " wants JSON: " .. tostring(why), 3) end
        return v
    elseif kind == "enum" then
        local why = VALUES.enum_error(field.values, v)
        if why then error("ROWCODEC field " .. field.name .. " " .. why, 3) end
        return v
    elseif kind == "string" or kind == "bytes" then
        ok = type(v) == "string"
    elseif kind == "int" then
        ok = is_int(v)
    elseif kind == "float" then
        ok = type(v) == "number" and v == v
    else
        ok = type(v) == "boolean"
    end
    if not ok then
        error("ROWCODEC field " .. field.name .. " wants " .. kind .. ", got " .. tostring(v), 3)
    end
    return v
end

-- A value read back for `field`, converted where the change of kind loses
-- nothing, or an error.
local function coerce(field: any, v: any): any
    if field.kind == "json" or field.kind == "enum" or field.kind == "bytes" then
        return check(field, v)
    end
    if type(v) == "integer" then
        v = integer.tonumber(v)
    end
    local kind = field.kind
    if (kind == "string" and type(v) == "string")
        or (kind == "bool" and type(v) == "boolean")
        or (kind == "float" and type(v) == "number")
        or (kind == "int" and is_int(v)) then
        return v
    end
    error("ROWCODEC field " .. field.name .. " wants " .. kind .. ", the row holds "
        .. tostring(v), 3)
end

local function check_row(schema: any, row: { [string]: any })
    for k in row do
        if schema.byName[k] == nil then
            error("ROWCODEC has no field " .. tostring(k), 3)
        end
    end
    for _, f in schema.list do
        local v = row[f.name]
        if v == nil then
            if not f.optional then
                error("ROWCODEC field " .. f.name .. " is not optional", 3)
            end
        else
            check(f, v)
        end
    end
end

local function check_version(version: number)
    if type(version) ~= "number" or version ~= math.floor(version)
        or version < 0 or version > 0xffffffff then
        error("ROWCODEC version must be an integer from 0 to 2^32-1", 3)
    end
end

-- json ----------------------------------------------------------------------

local function enc_json(schema: any, version: number, row: any): string
    local out = { '"_v":' .. simdjson.encode(version) }
    for _, f in schema.list do
        local v = row[f.name]
        if (f.kind == "string" or f.kind == "enum") and v ~= nil and utf8.len(v) == nil then
            error("ROWCODEC field " .. f.name .. " is not UTF-8, which a json row needs", 3)
        end
        if v ~= nil then
            local encoded
            if f.kind == "json" then encoded = VALUES.json(v)
            elseif f.kind == "bytes" then encoded = simdjson.encode(VALUES.hex(v))
            else encoded = simdjson.encode(v) end
            out[#out + 1] = simdjson.encode(f.name) .. ":" .. encoded
        end
    end
    return "{" .. table.concat(out, ",") .. "}"
end

local function dec_json(schema: any, value: string): (any, number)
    local doc = VALUES.parse_json(value, 129)
    local version = doc._v
    if type(version) == "integer" then
        version = integer.tonumber(version)
    end
    if not is_int(version) then
        error("ROWCODEC json row has no _v version", 3)
    end
    local row = {}
    for _, f in schema.list do
        local v = doc[f.name]
        if v ~= nil and (f.kind == "json" or v ~= simdjson.null) then
            if f.kind == "bytes" then
                local ok, decoded = pcall(VALUES.unhex, v)
                if not ok then error("ROWCODEC field " .. f.name .. " " .. tostring(decoded), 3) end
                v = decoded
            end
            row[f.name] = coerce(f, v)
        end
    end
    return row, version
end

-- text ----------------------------------------------------------------------

local TEXT_ESCAPE = { ["\\"] = "\\\\", ["\t"] = "\\t", ["\n"] = "\\n", ["\r"] = "\\r" }
local TEXT_UNESCAPE = { ["\\"] = "\\", t = "\t", n = "\n", r = "\r" }

local function escaped(s: string): string
    return (string.gsub(s, "[\\\t\n\r]", TEXT_ESCAPE))
end

local function read_json(field: any, s: string): any
    local ok, value = pcall(VALUES.parse_json, s)
    if not ok then error("ROWCODEC field " .. field.name .. " has invalid JSON: " .. tostring(value), 4) end
    return value
end

local function num_text(x: number): string
    if x == math.huge then return "inf" end
    if x == -math.huge then return "-inf" end
    return string.format("%.17g", x)
end

local function enc_text(schema: any, version: number, row: any): string
    local parts = { "t" .. string.format("%d", version) }
    for _, f in schema.list do
        local v = row[f.name]
        if v ~= nil then
            local s
            if f.kind == "string" or f.kind == "enum" then
                s = escaped(v)
            elseif f.kind == "json" then
                s = escaped(VALUES.json(v))
            elseif f.kind == "bytes" then
                s = VALUES.hex(v)
            elseif f.kind == "int" then
                s = string.format("%.0f", v)
            elseif f.kind == "float" then
                s = num_text(v)
            else
                s = v and "1" or "0"
            end
            parts[#parts + 1] = f.id .. "=" .. s
        end
    end
    return table.concat(parts, "\t")
end

local function text_value(field: any, s: string): any
    local kind = field.kind
    if kind == "string" or kind == "enum" or kind == "json" then
        local bad = false
        local out = string.gsub(s, "\\(.?)", function(c)
            local u = TEXT_UNESCAPE[c]
            if u == nil then bad = true end
            return u
        end)
        if bad then
            error("ROWCODEC field " .. field.name .. " has a bad text escape", 4)
        end
        if kind == "json" then return read_json(field, out) end
        return kind == "enum" and coerce(field, out) or out
    elseif kind == "bytes" then
        local ok, decoded = pcall(VALUES.unhex, s)
        if not ok then error("ROWCODEC field " .. field.name .. " " .. tostring(decoded), 4) end
        return decoded
    elseif kind == "bool" then
        if s == "1" then return true end
        if s == "0" then return false end
    else
        local x = if s == "inf" then math.huge elseif s == "-inf" then -math.huge else tonumber(s)
        if x ~= nil then
            return coerce(field, x)
        end
    end
    error("ROWCODEC field " .. field.name .. " wants " .. kind .. ", the row holds " .. s, 4)
end

local function dec_text(schema: any, value: string): (any, number)
    local row, version = {}, nil
    for part in string.gmatch(value, "[^\t]+") do
        if version == nil then
            version = tonumber(string.sub(part, 2))
            if not is_int(version) then
                error("ROWCODEC text row has a bad version", 3)
            end
        else
            local id, s = string.match(part, "^(%d+)=(.*)$")
            if id == nil then
                error("ROWCODEC text row has a bad entry " .. part, 3)
            end
            local f = schema.byId[tonumber(id)]
            if f then
                row[f.name] = text_value(f, s)
            end
        end
    end
    return row, version
end

-- binary --------------------------------------------------------------------

local function enc_binary(schema: any, version: number, row: any): string
    local size = 5
    local payloads = {}
    for _, f in schema.list do
        local v = row[f.name]
        if v ~= nil then
            size += 3
            if f.kind == "int" or f.kind == "float" then
                size += 8
            elseif f.kind == "json" then
                payloads[f.name] = VALUES.json(v)
                size += 4 + #payloads[f.name]
            elseif f.kind == "string" or f.kind == "enum" or f.kind == "bytes" then
                size += 4 + #v
            end
        end
    end
    local b = buffer.create(size)
    buffer.writeu8(b, 0, string.byte("b"))
    buffer.writeu32(b, 1, version)
    local at = 5
    for _, f in schema.list do
        local v = row[f.name]
        if v ~= nil then
            buffer.writeu16(b, at, f.id)
            local kind = f.kind
            if kind == "bool" then
                buffer.writeu8(b, at + 2, v and TRUE or FALSE)
                at += 3
            elseif kind == "string" or kind == "enum" or kind == "bytes" or kind == "json" then
                v = payloads[f.name] or v
                local tag = kind == "json" and JSON or kind == "bytes" and BYTES or STRING
                buffer.writeu8(b, at + 2, tag)
                buffer.writeu32(b, at + 3, #v)
                buffer.writestring(b, at + 7, v)
                at += 7 + #v
            else
                buffer.writeu8(b, at + 2, kind == "int" and INT or FLOAT)
                buffer.writef64(b, at + 3, v)
                at += 11
            end
        end
    end
    return buffer.tostring(b)
end

local function dec_binary(schema: any, value: string): (any, number)
    local b = buffer.fromstring(value)
    local size = buffer.len(b)
    local function need(at: number, n: number)
        if at + n > size then
            error("ROWCODEC binary row is truncated", 4)
        end
    end
    need(0, 5)
    local version = buffer.readu32(b, 1)
    local row = {}
    local at = 5
    while at < size do
        need(at, 3)
        local id, tag = buffer.readu16(b, at), buffer.readu8(b, at + 2)
        at += 3
        local v
        if tag == FALSE or tag == TRUE then
            v = tag == TRUE
        elseif tag == INT or tag == FLOAT then
            need(at, 8)
            v = buffer.readf64(b, at)
            at += 8
        elseif tag == STRING or tag == JSON or tag == BYTES then
            need(at, 4)
            local n = buffer.readu32(b, at)
            need(at + 4, n)
            v = buffer.readstring(b, at + 4, n)
            at += 4 + n
        else
            error("ROWCODEC binary row has a bad tag " .. tag, 3)
        end
        local f = schema.byId[id]
        if f then
            if (tag == JSON) ~= (f.kind == "json") or (tag == BYTES) ~= (f.kind == "bytes") then
                error("ROWCODEC field " .. f.name .. " has an incompatible binary kind", 3)
            end
            if tag == JSON then v = read_json(f, v) end
            row[f.name] = coerce(f, v)
        end
    end
    return row, version
end

-------------------------------------------------------------------------------

local ENCODE = { json = enc_json, text = enc_text, binary = enc_binary }
local DECODE = { ["{"] = dec_json, t = dec_text, b = dec_binary }
local FORMAT = { ["{"] = "json", t = "text", b = "binary" }

-- The stored value for `row` in `format` ("json", "text" or "binary"),
-- marked with the schema `version` (an integer from 0 to 2^32-1).
function encode(schema: any, format: string, version: number, row: { [string]: any }): string
    local enc = ENCODE[format]
    if enc == nil then
        error("ROWCODEC has no format " .. tostring(format), 2)
    end
    check_version(version)
    check_row(schema, row)
    return enc(schema, version, row)
end

-- The row in a stored value, the schema version it was written with, and
-- its format.
function decode(schema: any, value: string): ({ [string]: any }, number, string)
    local lead = string.sub(value, 1, 1)
    local dec = DECODE[lead]
    if dec == nil then
        error("ROWCODEC value is not a row", 2)
    end
    local row, version = dec(schema, value)
    return row, version, FORMAT[lead]
end

local function same_row(a: any, b: any): boolean
    for k, v in a do
        if b[k] ~= v then return false end
    end
    for k in b do
        if a[k] == nil then return false end
    end
    return true
end

function selftest(): (boolean, string?)
    local schema = fields({
        { name = "name", kind = "string", id = 1 },
        { name = "age", kind = "int", id = 2, optional = true },
        { name = "score", kind = "float", id = 3, optional = true },
        { name = "admin", kind = "bool", id = 4, optional = true },
    })
    local rows = {
        { name = "ann" },
        { name = "", age = 0, score = 0, admin = false },
        { name = "tab\there\nline\\ \0é", age = -MAX_INT, score = -2.5e-300, admin = true },
        { name = "big", age = MAX_INT, score = 0.1 },
    }
    for _, format in { "json", "text", "binary" } do
        for i, row in rows do
            local value = encode(schema, format, 7, row)
            local back, version, got = decode(schema, value)
            if not same_row(row, back) or version ~= 7 or got ~= format then
                return false, format .. " row " .. i .. " did not round trip"
            end
        end
    end
    for _, format in { "text", "binary" } do
        local value = encode(schema, format, 1, { name = "\255\\", score = math.huge })
        local back = decode(schema, value)
        if back.score ~= math.huge or back.name ~= "\255\\" then
            return false, format .. " lost infinity or a byte"
        end
    end

    -- an older schema's row: field 3 is gone, 5 is new, 2 became a float
    local later = fields({
        { name = "name", kind = "string", id = 1 },
        { name = "years", kind = "float", id = 2, optional = true },
        { name = "admin", kind = "bool", id = 4, optional = true },
        { name = "email", kind = "string", id = 5, optional = true },
    })
    for _, format in { "text", "binary" } do
        local value = encode(schema, format, 1, { name = "x", age = 3, score = 1.5, admin = true })
        local back, version = decode(later, value)
        if not same_row(back, { name = "x", years = 3, admin = true }) or version ~= 1 then
            return false, format .. " did not read an older row"
        end
    end

    local refused = {
        { "json", { name = "x", nope = 1 } },
        { "json", { age = 1 } },
        { "text", { name = 1 } },
        { "text", { name = "x", age = 1.5 } },
        { "binary", { name = "x", age = 2 ^ 54 } },
        { "binary", { name = "x", score = 0 / 0 } },
        { "json", { name = "x", score = math.huge } },
        { "json", { name = "\255" } },
        { "csv", { name = "x" } },
    }
    for i, case in refused do
        if pcall(encode, schema, case[1], 1, case[2]) then
            return false, "encode accepted bad row " .. i
        end
    end
    local wrong = fields({ { name = "name", kind = "int", id = 1 } })
    if pcall(decode, wrong, encode(schema, "binary", 1, { name = "x" })) then
        return false, "decode turned a string into an int"
    end
    for _, bad in { "", "x", "b\1\0", "t1\t9" } do
        if pcall(decode, schema, bad) then
            return false, "decode accepted " .. string.format("%q", bad)
        end
    end
    return true
end

function call()
    local ok, why = selftest()
    return ok and "ok" or ("failed: " .. why)
end
