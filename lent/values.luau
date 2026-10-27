-- Shared value handling for SCHEMA, ROWCODEC, CLIENT and MIGRATE.
-- JSON objects have string keys; arrays are dense lists. An empty table is
-- an object; array() marks an array, including an empty one. JSON null is
-- simdjson.null. json() is canonical so object key order does not affect equality.

local ARRAY = { __lent_json_array = true }
local MAX_INT = 2 ^ 53

function is_array(v: any): boolean
    local mt = type(v) == "table" and getmetatable(v)
    return type(mt) == "table" and rawget(mt, "__lent_json_array") == true
end

local function utf8_string(s: string)
    if utf8.len(s) == nil then error("JSON strings and object keys must be UTF-8", 0) end
end

local function encode(v: any, stack: any, depth: number): string
    if v == simdjson.null then return "null" end
    local kind = type(v)
    if kind == "string" then
        utf8_string(v)
        return simdjson.encode(v)
    elseif kind == "number" then
        if v ~= v or math.abs(v) == math.huge then error("JSON numbers must be finite", 0) end
        return v == 0 and "0" or simdjson.encode(v)
    elseif kind == "integer" or kind == "boolean" then
        return simdjson.encode(v)
    elseif kind ~= "table" then
        error("JSON needs a value, plain object or dense array; use simdjson.null for null", 0)
    end
    if depth >= 128 then error("JSON exceeds 128 levels of nesting", 0) end
    if stack[v] then error("JSON contains a cyclic table", 0) end
    local marked = is_array(v)
    if getmetatable(v) ~= nil and not marked then error("JSON objects must be plain tables", 0) end
    stack[v] = true
    local keys, numeric = {}, 0
    for k in v do
        if type(k) == "number" and k >= 1 and k == math.floor(k) then
            numeric += 1
        elseif type(k) == "string" then
            utf8_string(k)
        else
            error("JSON object keys must be strings and array keys must be positive integers", 0)
        end
        keys[#keys + 1] = k
    end
    local parts = {}
    local array = marked or numeric > 0
    if array then
        if numeric ~= #keys then error("JSON arrays must be dense lists without object keys", 0) end
        for i = 1, numeric do
            if v[i] == nil then error("JSON arrays must be dense lists without gaps", 0) end
            parts[i] = encode(v[i], stack, depth + 1)
        end
    else
        table.sort(keys)
        for i, k in keys do
            parts[i] = simdjson.encode(k) .. ":" .. encode(v[k], stack, depth + 1)
        end
    end
    stack[v] = nil
    return (array and "[" or "{") .. table.concat(parts, ",") .. (array and "]" or "}")
end

function json(v: any): string
    return encode(v, {}, 0)
end

function array(list: any?): any
    if list ~= nil and type(list) ~= "table" then error("jsonArray takes a list", 0) end
    local out = setmetatable(table.clone(list or {}), ARRAY)
    json(out)
    return out
end

-- Native parsing validates the whole document. This walk restores array
-- markers, which simdjson.parse loses, without reparsing leaf values.
function parse_json(text: string, maxDepth: number?): any
    if type(text) ~= "string" then error("parseJson takes a JSON string", 0) end
    local root = simdjson.parse(text)
    maxDepth = maxDepth or 128
    local at = 1
    local function space()
        local _, last = string.find(text, "^%s*", at)
        at = (last or at - 1) + 1
    end
    local function quoted(): string
        local first = at
        at += 1
        while true do
            local ch = string.sub(text, at, at)
            at += 1
            if ch == "\\" then at += 1
            elseif ch == '"' then return string.sub(text, first, at - 1) end
        end
    end
    local walk
    function walk(v: any, depth: number): any
        space()
        local ch = string.sub(text, at, at)
        if (ch == "[" or ch == "{") and depth >= maxDepth then
            error("JSON exceeds " .. maxDepth .. " levels of nesting", 0)
        end
        if ch == "[" then
            if type(v) ~= "table" then error("JSON objects must have unique keys", 0) end
            setmetatable(v, ARRAY)
            at += 1
            space()
            local i = 1
            while string.sub(text, at, at) ~= "]" do
                v[i] = walk(v[i], depth + 1)
                i += 1
                space()
                if string.sub(text, at, at) == "," then at += 1 end
                space()
            end
            at += 1
        elseif ch == "{" then
            if type(v) ~= "table" then error("JSON objects must have unique keys", 0) end
            at += 1
            space()
            local seen = {}
            while string.sub(text, at, at) ~= "}" do
                local key = simdjson.parse(quoted())
                if seen[key] then error("JSON objects must have unique keys", 0) end
                seen[key] = true
                space()
                at += 1 -- colon
                v[key] = walk(v[key], depth + 1)
                space()
                if string.sub(text, at, at) == "," then at += 1 end
                space()
            end
            at += 1
        elseif ch == '"' then
            quoted()
        else
            at = string.find(text, "[,}%]%s]", at) or #text + 1
        end
        if type(v) == "integer" then
            local n = integer.tonumber(v)
            if math.abs(n) <= MAX_INT then return n end
        end
        return v
    end
    return walk(root, 0)
end

function copy_json(v: any): any
    return parse_json(json(v))
end

function equal_json(a: any, b: any): boolean
    if a == nil or b == nil then return a == b end
    return json(a) == json(b)
end

function hex(s: string): string
    return (string.gsub(s, ".", function(ch) return string.format("%02x", string.byte(ch)) end))
end

function unhex(s: string): string
    if type(s) ~= "string" or #s % 2 ~= 0 or string.find(s, "[^%da-fA-F]") then
        error("bytes need an even-length hexadecimal string", 0)
    end
    return (string.gsub(s, "..", function(pair) return string.char(tonumber(pair, 16) :: number) end))
end

function enum_error(list: { string }, value: any): string?
    for _, allowed in list do
        if allowed == value then return nil end
    end
    local got = tostring(value)
    if type(value) == "string" then
        got = utf8.len(value) == nil and "invalid UTF-8 string" or json(value)
    end
    return "wants one of " .. json(list) .. ", got " .. got
end

function enum_values(list: any, where: string): { string }
    if type(list) ~= "table" then error(where .. " enum needs a list of values", 0) end
    local n, seen, out = 0, {}, {}
    for i in list do
        if type(i) ~= "number" or i < 1 or i ~= math.floor(i) then
            error(where .. " enum values must be a dense list", 0)
        end
        n += 1
    end
    if n == 0 then error(where .. " enum needs at least one value", 0) end
    for i = 1, n do
        local s = list[i]
        if type(s) ~= "string" or s == "" or utf8.len(s) == nil then
            error(where .. " enum values must be non-empty UTF-8 strings", 0)
        end
        if seen[s] then error(where .. " enum value " .. json(s) .. " is repeated", 0) end
        seen[s], out[i] = true, s
    end
    return out
end

-- A decimal holds at most this many digits, which a double keeps exactly.
DECIMAL_DIGITS = 15
DECIMAL_SCALE = 15

-- `v` rounded to `scale` digits after the point, half away from zero, as
-- the number nearest that decimal; or nil and why `v` is no such decimal.
-- Rounding reads the shortest text that gives back `v`, so 2.675 rounds to
-- 2.68 although its double is a little less.
function decimal(v: any, scale: number): (number?, string?)
    if type(v) == "integer" then v = integer.tonumber(v) end
    local why = "wants a decimal of at most " .. DECIMAL_DIGITS .. " digits with " .. scale
        .. " after the point, got " .. tostring(v)
    if type(v) ~= "number" or v ~= v or math.abs(v) == math.huge then
        return nil, why
    end
    local sign, whole, frac, exp = string.match(tostring(v), "^(%-?)(%d*)%.?(%d*)e?([-+]?%d*)$")
    if sign == nil then
        return nil, why
    end
    -- v * 10^scale = digits * 10^shift
    local digits = whole .. frac
    local shift = (tonumber(exp) or 0) - #frac + scale
    local keep, next = digits, 0
    if shift >= 0 then
        keep = digits .. string.rep("0", math.min(shift, DECIMAL_DIGITS + 1))
    else
        local cut = #digits + shift
        keep = cut > 0 and string.sub(digits, 1, cut) or ""
        next = cut >= 0 and tonumber(string.sub(digits, cut + 1, cut + 1)) or 0
    end
    keep = string.gsub(keep, "^0+", "")
    if #keep > DECIMAL_DIGITS then
        return nil, why
    end
    local n = (tonumber(keep) or 0) + (next >= 5 and 1 or 0)
    if n >= 10 ^ DECIMAL_DIGITS then
        return nil, why
    end
    if n == 0 then
        return 0
    end
    return (sign == "-" and -n or n) / 10 ^ scale
end

-- The whole number of 10^-scale units in decimal `v`, which decimal()
-- answered; sums of these are exact.
function decimal_units(v: number, scale: number): number
    return math.round(v * 10 ^ scale)
end

function call()
    local value = parse_json('{"z":[],"a":[{},null,1099511627776]}')
    if json(value) ~= '{"a":[{},null,1099511627776],"z":[]}'
        or hex(unhex("00ff01")) ~= "00ff01" then return "failed: values" end
    for _, case in { { 2.675, 2, 2.68 }, { 1.005, 2, 1.01 }, { -1.005, 2, -1.01 },
                     { 0.004, 2, 0 }, { 0.005, 2, 0.01 }, { 1.5e-7, 8, 1.5e-7 },
                     { 1.5e-7, 7, 2e-7 }, { 1e14, 0, 1e14 }, { 0.1 + 0.2, 2, 0.3 },
                     { 12, 3, 12 } } do
        if decimal(case[1], case[2]) ~= case[3] then
            return "failed: decimal " .. tostring(case[1])
        end
    end
    if decimal(1e15, 0) ~= nil or decimal(1e13, 2) ~= nil or decimal(0 / 0, 2) ~= nil
        or decimal("1", 2) ~= nil or decimal_units(decimal(12.34, 2) :: number, 2) ~= 1234 then
        return "failed: decimal limits"
    end
    return "ok"
end
