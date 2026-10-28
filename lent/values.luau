-- Shared value handling for SCHEMA, ROWCODEC, CLIENT and MIGRATE.
-- JSON objects have string keys; arrays are dense lists. An empty table is
-- an object; array() marks an array, including an empty one. JSON null is
-- simdjson.null. json() is canonical so object key order does not affect equality.

local ARRAY = { __lent_json_array = true }
local MAX_INT = 2 ^ 53
local INT_MAX = integer.create(MAX_INT)
local INT_MIN = integer.neg(INT_MAX)

-- `v` as a Luau number when it is a Luau integer from -2^53 to 2^53, which a
-- number holds exactly, and any other value as it is. simdjson.parse answers
-- whole numbers beyond 32 bits as integers, which do not compare or add with
-- numbers.
function number(v: any): any
    if type(v) == "integer" and integer.le(v, INT_MAX) and integer.ge(v, INT_MIN) then
        return integer.tonumber(v)
    end
    return v
end

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
        return number(v)
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
    v = number(v)
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

-- Dates are Unix milliseconds in UTC, on the proleptic Gregorian calendar,
-- for years 1 to 9999.
local DAY_MS = 86400000

-- Days from 1970-01-01 to year y, month m, day d, and back, by Howard
-- Hinnant's days_from_civil and civil_from_days.
local function days_from_civil(y: number, m: number, d: number): number
    y -= m <= 2 and 1 or 0
    local era = y // 400
    local yoe = y - era * 400
    local doy = (153 * ((m + 9) % 12) + 2) // 5 + d - 1
    return era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
end

local function civil_from_days(z: number): (number, number, number)
    z += 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local m = mp < 10 and mp + 3 or mp - 9
    return yoe + era * 400 + (m <= 2 and 1 or 0), m, doy - (153 * mp + 2) // 5 + 1
end

local function month_days(y: number, m: number): number
    if m == 2 then
        return (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) and 29 or 28
    end
    return (m == 4 or m == 6 or m == 9 or m == 11) and 30 or 31
end

local function whole(v: any, lo: number, hi: number): boolean
    return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

-- The Unix milliseconds of a UTC date and time, or nil and why there is no
-- such time.
function date(y: any, mo: any, d: any, h: any?, mi: any?, s: any?, ms: any?): (number?, string?)
    local parts = { y, mo, d, h or 0, mi or 0, s or 0, ms or 0 }
    for i = 1, 7 do
        parts[i] = number(parts[i])
    end
    y, mo, d, h, mi, s, ms = table.unpack(parts, 1, 7)
    if not (whole(y, 1, 9999) and whole(mo, 1, 12) and whole(h, 0, 23) and whole(mi, 0, 59)
        and whole(s, 0, 59) and whole(ms, 0, 999)) or not whole(d, 1, month_days(y, mo)) then
        local text = {}
        for i = 1, 7 do text[i] = tostring(parts[i]) end
        return nil, "has no date and time year " .. text[1] .. ", month " .. text[2]
            .. ", day " .. text[3] .. ", " .. text[4] .. ":" .. text[5] .. ":" .. text[6]
            .. "." .. text[7]
    end
    return days_from_civil(y, mo, d) * DAY_MS + ((h * 60 + mi) * 60 + s) * 1000 + ms
end

-- The Unix milliseconds of ISO 8601 text: a date such as 1995-03-15, or a
-- date and time such as 1995-03-15T10:20:30.250Z, with T or a space before
-- the time, optional seconds and milliseconds, and a zone of Z, +hh:mm or
-- -hh:mm; a time without a zone is UTC. Answers nil and why for other text.
function parse_date(text: any): (number?, string?)
    local why = "wants a date such as 1995-03-15 or 1995-03-15T10:20:30Z, got "
        .. (type(text) == "string" and json(text) or tostring(text))
    if type(text) ~= "string" then return nil, why end
    local y, mo, d, rest = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
    if y == nil then return nil, why end
    local h, mi, s, ms, offset = "0", "0", "0", "0", 0
    if rest ~= "" then
        h, mi, rest = string.match(rest, "^[T ](%d%d):(%d%d)(.*)$")
        if h == nil then return nil, why end
        local ss, tail = string.match(rest, "^:(%d%d)(.*)$")
        if ss then
            s, rest = ss, tail
            local frac, tail2 = string.match(rest, "^%.(%d%d?%d?)(.*)$")
            if frac then ms, rest = string.sub(frac .. "00", 1, 3), tail2 end
        end
        local sign, zh, zm = string.match(rest, "^([+-])(%d%d):(%d%d)$")
        if sign then
            if tonumber(zh) > 23 or tonumber(zm) > 59 then return nil, why end
            offset = (sign == "-" and -1 or 1) * (tonumber(zh) * 60 + tonumber(zm)) * 60000
        elseif rest ~= "" and rest ~= "Z" then
            return nil, why
        end
    end
    local t = date(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi),
                   tonumber(s), tonumber(ms))
    if t == nil then return nil, why end
    return t - offset
end

-- t as a Luau number, or nil and why t is no time in Unix milliseconds.
local function time_value(t: any): (number?, string?)
    t = number(t)
    if type(t) ~= "number" or t ~= math.floor(t) or math.abs(t) > 2 ^ 53 then
        return nil, "takes a time in Unix milliseconds, got " .. tostring(t)
    end
    return t
end

-- The UTC calendar parts of time t: year, month, day, hour, minute,
-- second, millisecond, and the ISO weekday, 1 for Monday to 7 for Sunday.
-- Answers nil and why when t is no time.
function date_parts(t: any): (any, string?)
    local v, why = time_value(t)
    if v == nil then return nil, why end
    local days = v // DAY_MS
    local ms = v - days * DAY_MS
    local y, m, d = civil_from_days(days)
    return {
        year = y, month = m, day = d, hour = ms // 3600000, minute = ms // 60000 % 60,
        second = ms // 1000 % 60, millisecond = ms % 1000, weekday = (days + 3) % 7 + 1,
    }
end

-- Time t moved by n calendar months, keeping its time of day. A day past
-- the end of the new month becomes its last day, so January 31 plus one
-- month is February 28 or 29.
function add_months(t: any, n: any): (number?, string?)
    local p, why = date_parts(t)
    if p == nil then return nil, why end
    n = number(n)
    if not whole(n, -120000, 120000) then
        return nil, "takes a whole number of months, got " .. tostring(n)
    end
    local months = p.year * 12 + p.month - 1 + n
    local y, m = months // 12, months % 12 + 1
    return date(y, m, math.min(p.day, month_days(y, m)), p.hour, p.minute, p.second,
                p.millisecond)
end

-- Time t as ISO 8601 text: 1995-03-15, or 1995-03-15T10:20:30.250Z with
-- the time of day.
function format_date(t: any, withTime: boolean?): (string?, string?)
    local p, why = date_parts(t)
    if p == nil then return nil, why end
    local text = string.format("%04d-%02d-%02d", p.year, p.month, p.day)
    if withTime then
        text ..= string.format("T%02d:%02d:%02d.%03dZ", p.hour, p.minute, p.second,
                               p.millisecond)
    end
    return text
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
    for _, case in { { "1970-01-01", 0 }, { "1995-03-15", 795225600000 },
                     { "2000-02-29T23:59:59.999Z", 951868799999 }, { "1969-12-31 23:00", -3600000 },
                     { "1970-01-01T02:00:00+02:00", 0 }, { "1970-01-01T00:00:00.5", 500 },
                     { "0001-01-01", -62135596800000 }, { "9999-12-31", 253402214400000 },
                     { "1995-02-29", nil }, { "1995-3-15", nil }, { "1995-03-15T24:00", nil },
                     { "1995-03-15Z", nil }, { "1995-03-15T10:00:00.1234", nil } } do
        if parse_date(case[1]) ~= case[2] then
            return "failed: date " .. case[1]
        end
    end
    local p = date_parts(-1)
    if p.year ~= 1969 or p.month ~= 12 or p.day ~= 31 or p.hour ~= 23 or p.millisecond ~= 999
        or p.weekday ~= 3 or date_parts(0).weekday ~= 4 or date_parts(1.5) ~= nil then
        return "failed: date parts"
    end
    if format_date(add_months(parse_date("2024-01-31T10:00Z"), 1), true)
            ~= "2024-02-29T10:00:00.000Z"
        or format_date(add_months(parse_date("2024-03-31"), -13) :: number) ~= "2023-02-28"
        or add_months(parse_date("9999-12-01"), 1) ~= nil then
        return "failed: add months"
    end
    return "ok"
end
