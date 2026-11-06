-- Filter expressions for lent queries, written as Luau expression strings:
--
--   q:where("age > 10 and age <= 100 and salary < max", { max = 1000 })
--
-- An expression reads the row's fields and the parameters by name, and uses
-- literals (numbers, strings, true, false, nil), `and`, `or`, `not`, the
-- comparisons == ~= < <= > >=, the arithmetic + - * / // % ^, unary minus,
-- `..`, `#`, parentheses, and the calls below. Nothing else parses, so an
-- expression reaches only the row and its parameters. A `?` stands for the
-- next of the values given after the expression:
--
--   q:where("age > ? and name == ?", 10, "ann")
--
--   date('1995-03-15')   Unix milliseconds of ISO 8601 text, as lent.date
--   year(t), month(t), day(t)   the UTC calendar part of a time
--   like(text, pattern)  whether text matches: % is any run of characters,
--                        _ is one character, \ takes the next one literally
--
-- A call on a constant is worked out once, so `shipdate >= date('1994-01-01')`
-- is a comparison with a value that an index can use. So is a constant like
-- pattern that starts with literal text: `like(type, 'PROMO%')` holds only
-- within the range of values starting with PROMO.
--
-- Required, not called: `local EXPR = require("lent.EXPR")`. A function key
-- has to define call(), so this one answers a self-check:
--
--   lent.EXPR                -> "ok" or which check failed
--
-- parse(src) answers the expression's tree, slots(src) how many `?`s it has,
-- and values(...) the values for those `?`s, to pass as compile's params.
-- compile(src, kindOf, params, where) answers the expression split at its
-- top-level `and`s: each part is either { field, op, value }, a comparison
-- the caller can hand to an index, or { fn }, a function of the row.
-- kindOf(name) answers a field's lent kind or nil. Errors start with `where`.

local VALUES = require("lent.VALUES")

local KEYWORDS = { ["and"] = true, ["or"] = true, ["not"] = true }
local CONSTANTS = { ["true"] = true, ["false"] = false, ["nil"] = "nil" }
local RESERVED = {
    ["break"] = true, ["continue"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
    ["end"] = true, ["for"] = true, ["function"] = true, ["if"] = true, ["in"] = true,
    ["local"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["until"] = true,
    ["while"] = true,
}
local SYMBOLS2 = { ["=="] = true, ["~="] = true, ["<="] = true, [">="] = true, ["//"] = true,
                   [".."] = true }
local SYMBOLS1 = { ["<"] = true, [">"] = true, ["+"] = true, ["-"] = true, ["*"] = true,
                   ["/"] = true, ["%"] = true, ["^"] = true, ["#"] = true, ["("] = true,
                   [")"] = true, [","] = true }
local ESCAPES = { n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v",
                  ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }

-- Left and right binding powers, as Luau has them.
local BINARY = {
    ["or"] = { 1, 1 }, ["and"] = { 2, 2 },
    ["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 }, [">="] = { 3, 3 },
    ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
    [".."] = { 5, 4 }, ["+"] = { 6, 6 }, ["-"] = { 6, 6 },
    ["*"] = { 7, 7 }, ["/"] = { 7, 7 }, ["//"] = { 7, 7 }, ["%"] = { 7, 7 },
    ["^"] = { 10, 9 },
}
local UNARY = 8

-- The functions an expression may call: the type of value each takes, and
-- a function answering the result, or nil and why.
local function part(name: string)
    return function(t)
        local p, why = VALUES.date_parts(t)
        return p and p[name], why
    end
end
local CALLS = {
    date = { takes = "string", fn = VALUES.parse_date },
    year = { takes = "number", fn = part("year") },
    month = { takes = "number", fn = part("month") },
    day = { takes = "number", fn = part("day") },
    like = { takes = "string", two = true, gives = "boolean" },
}

-- Stands for `_` in a like pattern's pieces.
local ONE = false

-- The pieces of like pattern p, which its `%`s separate. A piece is a list
-- of literal strings and ONEs. Answers nil and why for a bad pattern.
local function like_pieces(p: string): (any, string?)
    local piece, pieces, text = {}, {}, {}
    local function flush()
        if #text > 0 then
            piece[#piece + 1] = table.concat(text)
            text = {}
        end
    end
    local i = 1
    while i <= #p do
        local c = string.sub(p, i, i)
        if c == "\\" then
            i += 1
            if i > #p then
                return nil, "pattern ends with \\; write \\\\ for a backslash"
            end
            text[#text + 1] = string.sub(p, i, i)
        elseif c == "%" then
            flush()
            pieces[#pieces + 1] = piece
            piece = {}
        elseif c == "_" then
            flush()
            piece[#piece + 1] = ONE
        else
            text[#text + 1] = c
        end
        i += 1
    end
    flush()
    pieces[#pieces + 1] = piece
    return pieces
end

-- The bytes of the UTF-8 character at position i of s, one for a stray byte.
local function char_width(s: string, i: number): number
    local b = string.byte(s, i)
    local width = if b < 0xC0 or b >= 0xF8 then 1 elseif b < 0xE0 then 2 elseif b < 0xF0 then 3 else 4
    for k = 1, width - 1 do
        local c = string.byte(s, i + k)
        if c == nil or c < 0x80 or c >= 0xC0 then return 1 end
    end
    return width
end

-- The position after `piece` when it matches s at position i, or nil.
local function piece_at(piece: any, s: string, i: number): number?
    for _, item in piece do
        if item == ONE then
            if i > #s then return nil end
            i += char_width(s, i)
        else
            if string.sub(s, i, i + #item - 1) ~= item then return nil end
            i += #item
        end
    end
    return i
end

-- The position after the first match of `piece` in s from position i, or nil.
local function piece_after(piece: any, s: string, i: number): number?
    if #piece == 1 and piece[1] ~= ONE then
        local _, e = string.find(s, piece[1], i, true)
        return e and e + 1
    end
    while true do
        local e = piece_at(piece, s, i)
        if e or i > #s then return e end
        i += char_width(s, i)
    end
end

-- Whether s matches. Each `%` takes the first match of the next piece, which
-- leaves the most text for the pieces after it, so no piece is tried twice
-- and the cost stays proportional to the text times the pattern.
local function like_match(s: string, pieces: any): boolean
    local i = piece_at(pieces[1], s, 1)
    local last = pieces[#pieces]
    if i == nil then
        return false
    elseif #pieces == 1 then
        return i == #s + 1
    end
    for k = 2, #pieces - 1 do
        i = piece_after(pieces[k], s, i)
        if i == nil then return false end
    end
    if #last == 0 then
        return true
    elseif #last == 1 and last[1] ~= ONE then
        return #s - #last[1] + 1 >= i and string.sub(s, -#last[1]) == last[1]
    end
    while true do
        if piece_at(last, s, i) == #s + 1 then return true end
        if i > #s then return false end
        i += char_width(s, i)
    end
end

-- The value range of text that like pattern p can match, or nil when p starts
-- with a wildcard. The upper bound is open, and missing when no string
-- follows every string with that start.
local function like_range(p: string): any
    local pieces = like_pieces(p)
    local start = pieces and pieces[1][1]
    if not start then
        return nil
    end
    local top = string.gsub(start, "\xFF+$", "")
    if top == "" then
        return { lo = start }
    end
    local hi = string.sub(top, 1, -2) .. string.char(string.byte(top, -1) + 1)
    return { lo = start, hi = hi, hiOpen = true }
end

local ARITH = {
    ["+"] = function(x, y) return x + y end,
    ["-"] = function(x, y) return x - y end,
    ["*"] = function(x, y) return x * y end,
    ["/"] = function(x, y) return x / y end,
    ["//"] = function(x, y) return x // y end,
    ["%"] = function(x, y) return x % y end,
    ["^"] = function(x, y) return x ^ y end,
}
local ORDER = {
    ["<"] = function(x, y) return x < y end,
    ["<="] = function(x, y) return x <= y end,
    [">"] = function(x, y) return x > y end,
    [">="] = function(x, y) return x >= y end,
}
local FLIP = { ["<"] = ">", ["<="] = ">=", [">"] = "<", [">="] = "<=", ["=="] = "==",
               ["~="] = "~=" }

-- The value type of each lent field kind.
local KIND_TYPE = { int = "number", float = "number", decimal = "number", time = "number",
                    string = "string", enum = "string", bytes = "string", uuid = "string",
                    bool = "boolean", json = "json" }

local function quote(src: string): string
    return string.format("%q", src)
end

local function failer(where: string, src: string)
    return function(at: number?, msg: string)
        if at then
            error(where .. " " .. quote(src) .. " at column " .. at .. ": " .. msg, 0)
        end
        error(where .. " " .. quote(src) .. ": " .. msg, 0)
    end
end

local function read_number(src: string, i: number, bad: any): (number, number)
    local _, e = string.find(src, "^%.?%d[%w_%.]*", i)
    local text = string.sub(src, i, e)
    if string.find(text, "^%d*%.?%d*[eE]$") or string.find(text, "^[%d_]+%.?[%d_]*[eE]$") then
        local _, e2 = string.find(src, "^[+-][%d_]+", e + 1)
        if e2 then
            e = e2
            text = string.sub(src, i, e)
        end
    end
    local clean = string.gsub(text, "_", "")
    local v = tonumber(clean)
    local bits = string.match(clean, "^0[bB]([01]+)$")
    if bits then
        v = tonumber(bits, 2)
    end
    if v == nil then
        bad(i, "has a malformed number " .. text)
    end
    return v :: number, e + 1
end

local function read_string(src: string, i: number, bad: any): (string, number)
    local q = string.sub(src, i, i)
    local out, j = {}, i + 1
    while true do
        local ch = string.sub(src, j, j)
        if ch == "" or ch == "\n" then
            bad(i, "has an unfinished string")
        elseif ch == q then
            return table.concat(out), j + 1
        elseif ch == "\\" then
            local e = string.sub(src, j + 1, j + 1)
            local digits = string.match(src, "^%d%d?%d?", j + 1)
            local hex = e == "x" and string.match(src, "^%x%x", j + 2)
            if ESCAPES[e] then
                out[#out + 1] = ESCAPES[e]
                j += 2
            elseif digits and tonumber(digits) <= 255 then
                out[#out + 1] = string.char(tonumber(digits) :: number)
                j += 1 + #digits
            elseif hex then
                out[#out + 1] = string.char(tonumber(hex, 16) :: number)
                j += 4
            else
                bad(j, "has an invalid escape \\" .. e)
            end
        else
            out[#out + 1] = ch
            j += 1
        end
    end
end

-- The tokens of src: { k, v, text, at }, where k is "const", "name", a
-- keyword or a symbol, and the last token is "eof".
local function tokenize(src: string, bad: any): { any }
    local toks, i, n, slots = {}, 1, #src, 0
    while true do
        i = string.find(src, "[^ \t\r\n]", i) or n + 1
        if i > n then
            break
        end
        local c = string.sub(src, i, i)
        local two = string.sub(src, i, i + 1)
        if string.find(c, "[%a_]") then
            local _, e = string.find(src, "^[%a_][%w_]*", i)
            local word = string.sub(src, i, e)
            if RESERVED[word] then
                bad(i, "takes no " .. word .. "; an expression has values, names and operators")
            end
            local constant = CONSTANTS[word]
            if constant ~= nil then
                toks[#toks + 1] = { k = "const", v = if constant == "nil" then nil else constant,
                                    text = word, at = i }
            elseif KEYWORDS[word] then
                toks[#toks + 1] = { k = word, v = word, text = word, at = i }
            else
                -- a dotted name such as origin.borough names a groupBy key
                while string.find(src, "^%.[%a_]", e + 1) do
                    _, e = string.find(src, "^%.[%a_][%w_]*", e + 1)
                end
                word = string.sub(src, i, e)
                toks[#toks + 1] = { k = "name", v = word, text = word, at = i }
            end
            i = e + 1
        elseif string.find(c, "%d") or string.find(src, "^%.%d", i) then
            local v, j = read_number(src, i, bad)
            toks[#toks + 1] = { k = "const", v = v, text = string.sub(src, i, j - 1), at = i }
            i = j
        elseif c == '"' or c == "'" then
            local v, j = read_string(src, i, bad)
            toks[#toks + 1] = { k = "const", v = v, text = string.sub(src, i, j - 1), at = i }
            i = j
        elseif c == "?" then
            slots += 1
            toks[#toks + 1] = { k = "slot", v = slots, text = c, at = i }
            i += 1
        elseif two == "--" then
            bad(i, "takes no comments")
        elseif SYMBOLS2[two] then
            toks[#toks + 1] = { k = two, text = two, at = i }
            i += 2
        elseif SYMBOLS1[c] then
            toks[#toks + 1] = { k = c, text = c, at = i }
            i += 1
        elseif c == "=" then
            bad(i, "has =; compare with ==")
        elseif two == "!=" then
            bad(i, "has !=; compare with ~=")
        else
            bad(i, "has an unexpected " .. c)
        end
    end
    toks[#toks + 1] = { k = "eof", text = "end", at = n + 1, slots = slots }
    return toks
end

-- The tree of src. Nodes are { k = "const", v }, { k = "name", name },
-- { k = "slot", n } for the nth `?`, { k = "call", name, a, b },
-- { k = "un", op, a } and { k = "bin", op, a, b }, each with its column
-- `at`. The root also holds the number of `?`s in `slots`.
local function parse_tree(src: string, bad: any): any
    local toks = tokenize(src, bad)
    local pos = 1
    local expr

    local function primary(): any
        local t = toks[pos]
        if t.k == "const" then
            pos += 1
            return { k = "const", v = t.v, at = t.at }
        elseif t.k == "name" and toks[pos + 1].k == "(" then
            if CALLS[t.v] == nil then
                bad(t.at, "has no function " .. t.v
                    .. "; expressions call date, year, month, day and like")
            end
            pos += 2
            local node = { k = "call", name = t.v, a = expr(0), at = t.at }
            if CALLS[t.v].two then
                if toks[pos].k ~= "," then
                    bad(t.at, "has a call to " .. t.v .. " without its second value")
                end
                pos += 1
                node.b = expr(0)
            end
            if toks[pos].k ~= ")" then
                bad(t.at, "has a call to " .. t.v .. " without its )")
            end
            pos += 1
            return node
        elseif t.k == "name" then
            pos += 1
            return { k = "name", name = t.v, at = t.at }
        elseif t.k == "slot" then
            pos += 1
            return { k = "slot", n = t.v, at = t.at }
        elseif t.k == "(" then
            pos += 1
            local node = expr(0)
            if toks[pos].k ~= ")" then
                bad(t.at, "has a ( without its )")
            end
            pos += 1
            return node
        elseif t.k == "eof" then
            bad(nil, "ends where a value should come")
        end
        bad(t.at, "has " .. t.text .. " where a value should come")
        return nil
    end

    function expr(limit: number): any
        local t = toks[pos]
        local node
        if t.k == "not" or t.k == "-" or t.k == "#" then
            pos += 1
            node = { k = "un", op = t.k, a = expr(UNARY), at = t.at }
        else
            node = primary()
        end
        while true do
            local op = toks[pos]
            local p = BINARY[op.k]
            if p == nil or p[1] <= limit then
                return node
            end
            pos += 1
            node = { k = "bin", op = op.k, a = node, b = expr(p[2]), at = op.at }
        end
    end

    local tree = expr(0)
    local t = toks[pos]
    if t.k ~= "eof" then
        bad(t.at, "has " .. t.text .. " after the end of the expression")
    end
    tree.slots = t.slots
    return tree
end

local parsed, nparsed = {}, 0
local VALUES_MT = {}

-- The tree of src, from a cache of recent expressions.
function parse(src: string, where: string?): any
    local tree = parsed[src]
    if tree == nil then
        tree = parse_tree(src, failer(where or "EXPR", src))
        if nparsed >= 256 then
            parsed, nparsed = {}, 0
        end
        parsed[src], nparsed = tree, nparsed + 1
    end
    return tree
end

-- How many `?`s src has. Errors start with `where`.
function slots(src: string, where: string?): number
    return parse(src, where).slots
end

-- The values given for an expression's `?`s, in order, nils included, to
-- pass to compile as its params.
function values(...: any): any
    return setmetatable(table.pack(...), VALUES_MT)
end

local function type_of(v: any): string
    local t = type(v)
    if t == "table" then
        return "json"
    end
    return t
end

local function describe(n: any): string
    if n.k == "field" then
        return "field " .. n.name .. " (" .. n.kind .. ")"
    elseif n.k == "const" then
        if type(n.v) == "string" then
            return quote(n.v)
        elseif type(n.v) == "table" then
            return VALUES.json(n.v)
        end
        return tostring(n.v)
    end
    return "a " .. n.t .. " value"
end

-- Parameter value v, checked, named `name` in errors.
local function param(v: any, name: string, bad: any): any
    v = VALUES.number(v)
    local t = type(v)
    if t == "integer" then
        bad(nil, "parameter " .. name .. " wants a whole number from -2^53 to 2^53, got "
            .. tostring(v))
    elseif t == "number" or t == "string" or t == "boolean" then
        return v
    elseif t == "table" then
        local ok, copy = pcall(VALUES.copy_json, v)
        if not ok then
            bad(nil, "parameter " .. name .. " wants JSON: " .. tostring(copy))
        end
        return copy
    end
    bad(nil, "parameter " .. name .. " is a " .. t
        .. "; parameters are numbers, strings, booleans or JSON tables")
    return nil
end

-- A function of the row that answers node n's value. A missing operand
-- makes arithmetic, `..` and `#` answer nil and a range comparison answer
-- false. Operands whose type the check could not settle are checked here.
local function build(n: any, bad: any): (any) -> any
    if n.k == "const" then
        local v = n.v
        return function() return v end
    elseif n.k == "field" then
        local f = n.name
        return function(r) return r[f] end
    end
    local op = n.op
    local fa = build(n.a, bad)
    if n.k == "call" and n.name == "like" then
        local fb = build(n.b, bad)
        local pattern, pieces
        local function compile_pattern(p: string)
            local list, why = like_pieces(p)
            if list == nil then bad(n.at, "like " .. tostring(why)) end
            pattern, pieces = p, list
        end
        if n.b.k == "const" and type(n.b.v) == "string" then
            compile_pattern(n.b.v)
        end
        return function(r)
            local x, y = fa(r), fb(r)
            if x == nil or y == nil then return nil end
            if type(x) ~= "string" or type(y) ~= "string" then
                bad(n.at, "like takes strings, got " .. type(x) .. " and " .. type(y))
            end
            if y ~= pattern then compile_pattern(y) end
            return like_match(x, pieces)
        end
    elseif n.k == "call" then
        local name, at, call = n.name, n.at, CALLS[n.name]
        return function(r)
            local x = fa(r)
            if x == nil then return nil end
            if type(x) ~= call.takes then
                bad(at, name .. " takes a " .. call.takes .. ", got " .. type(x))
            end
            local v, why = call.fn(x)
            if v == nil then bad(at, name .. " " .. tostring(why)) end
            return v
        end
    elseif n.k == "un" then
        local checked = n.a.t == "any"
        if op == "not" then
            return function(r) return not fa(r) end
        elseif op == "-" then
            return function(r)
                local x = fa(r)
                if x == nil then return nil end
                if checked and type(x) ~= "number" then
                    bad(nil, "- takes a number, got " .. type(x))
                end
                return -x
            end
        end
        return function(r)
            local x = fa(r)
            if x == nil then return nil end
            if checked and type(x) ~= "string" then
                bad(nil, "# takes a string, got " .. type(x))
            end
            return #x
        end
    end
    local fb = build(n.b, bad)
    local checked = n.a.t == "any" or n.b.t == "any"
    if op == "and" then
        return function(r) return fa(r) and fb(r) end
    elseif op == "or" then
        return function(r) return fa(r) or fb(r) end
    elseif ARITH[op] then
        local fn = ARITH[op]
        return function(r)
            local x, y = fa(r), fb(r)
            if x == nil or y == nil then return nil end
            if checked and (type(x) ~= "number" or type(y) ~= "number") then
                bad(nil, op .. " takes numbers, got " .. type(x) .. " and " .. type(y))
            end
            return fn(x, y)
        end
    elseif op == ".." then
        return function(r)
            local x, y = fa(r), fb(r)
            if x == nil or y == nil then return nil end
            if checked then
                for _, v in { x, y } do
                    if type(v) ~= "string" and type(v) ~= "number" then
                        bad(nil, ".. takes strings and numbers, got " .. type(v))
                    end
                end
            end
            return x .. y
        end
    elseif ORDER[op] then
        local fn = ORDER[op]
        if n.a.k == "field" and n.b.k == "const" and not checked then
            local f, c = n.a.name, n.b.v
            return function(r)
                local x = r[f]
                if x == nil then return false end
                return fn(x, c)
            end
        end
        return function(r)
            local x, y = fa(r), fb(r)
            if x == nil or y == nil then return false end
            if checked and (type(x) ~= type(y) or (type(x) ~= "number" and type(x) ~= "string")) then
                bad(nil, op .. " compares " .. type(x) .. " with " .. type(y))
            end
            return fn(x, y)
        end
    end
    local same = op == "=="
    if n.a.t == "json" or n.b.t == "json" then
        return function(r) return VALUES.equal_json(fa(r), fb(r)) == same end
    end
    return function(r) return (fa(r) == fb(r)) == same end
end

local function union(a: string, b: string): string
    return if a == b then a else "any"
end

-- Checks that each operand of n's operator has a type the operator takes,
-- and answers the type of n's value.
local function type_op(n: any, bad: any): string
    local op, a, b = n.op, n.a, n.b
    local function want(x: any, types: { [string]: boolean }, what: string)
        if not types[x.t] then
            bad(n.at, op .. " takes " .. what .. ", got " .. describe(x))
        end
    end
    local NUMBER = { number = true, any = true }
    if op == "not" then
        return "boolean"
    elseif op == "and" or op == "or" then
        return union(a.t, b.t)
    elseif op == "#" then
        want(a, { string = true, any = true }, "a string")
        return "number"
    elseif n.k == "un" then
        want(a, NUMBER, "a number")
        return "number"
    elseif ARITH[op] then
        want(a, NUMBER, "numbers")
        want(b, NUMBER, "numbers")
        return "number"
    elseif op == ".." then
        local CONCAT = { string = true, number = true, any = true }
        want(a, CONCAT, "strings and numbers")
        want(b, CONCAT, "strings and numbers")
        return "string"
    elseif ORDER[op] then
        for _, x in { a, b } do
            if x.t ~= "number" and x.t ~= "string" and x.t ~= "any" then
                bad(n.at, describe(x) .. " has no order")
            end
        end
    elseif a.t == "nil" or b.t == "nil" or a.t == "json" or b.t == "json" then
        return "boolean"
    end
    if a.t ~= b.t and a.t ~= "any" and b.t ~= "any" then
        bad(n.at, op .. " compares " .. describe(a) .. " with " .. describe(b))
    end
    return "boolean"
end

-- n with its names resolved to fields and parameters, each node typed, and
-- the operators over constants worked out.
local function resolve(n: any, kindOf: any, params: any, values: any, bad: any): any
    if n.k == "const" then
        return { k = "const", v = n.v, t = type_of(n.v) }
    elseif n.k == "slot" then
        local v = values[n.n]
        if v ~= nil then
            v = param(v, "?" .. n.n, bad)
        end
        return { k = "const", v = v, t = type_of(v) }
    elseif n.k == "name" then
        local kind = kindOf(n.name)
        local given = params ~= nil and params[n.name] ~= nil
        if kind ~= nil and given then
            bad(n.at, n.name .. " names both a field and a parameter")
        elseif kind ~= nil then
            return { k = "field", name = n.name, kind = kind, t = KIND_TYPE[kind] or "any" }
        elseif given then
            local v = param(params[n.name], n.name, bad)
            return { k = "const", v = v, t = type_of(v) }
        end
        bad(n.at, "has no field or parameter " .. n.name)
    end
    local out = { k = n.k, op = n.op, name = n.name, at = n.at,
                  a = resolve(n.a, kindOf, params, values, bad) }
    if n.k == "call" then
        local call = CALLS[n.name]
        out.b = n.b and resolve(n.b, kindOf, params, values, bad)
        for _, x in { out.a, out.b } do
            if x.t ~= call.takes and x.t ~= "any" and x.t ~= "nil" then
                bad(n.at, n.name .. " takes a " .. call.takes .. ", got " .. describe(x))
            end
        end
        out.t = call.gives or "number"
        if out.a.k == "const" and (out.b == nil or out.b.k == "const") then
            local v = build(out, bad)(nil)
            return { k = "const", v = v, t = type_of(v) }
        end
        return out
    end
    if n.b then
        out.b = resolve(n.b, kindOf, params, values, bad)
    end
    -- a constant left operand decides `and` and `or` on its own
    if (n.op == "and" or n.op == "or") and out.a.k == "const" then
        if (n.op == "and") == (not out.a.v) then
            return out.a
        end
        return out.b
    end
    out.t = type_op(out, bad)
    if out.a.k == "const" and (out.b == nil or out.b.k == "const") then
        local v = build(out, bad)(nil)
        return { k = "const", v = v, t = type_of(v) }
    end
    return out
end

local CMP = { ["=="] = "=", ["~="] = "~=", ["<"] = "<", ["<="] = "<=", [">"] = ">",
              [">="] = ">=" }

-- A comparison of a field with a constant as { field, op, value }, or nil.
local function as_cond(n: any): any
    if n.k == "field" and n.kind == "bool" then
        return { field = n.name, op = "=", value = true }
    elseif n.k == "un" and n.op == "not" and n.a.k == "field" and n.a.kind == "bool" then
        return { field = n.a.name, op = "~=", value = true }
    elseif n.k ~= "bin" or CMP[n.op] == nil then
        return nil
    elseif n.a.k == "field" and n.b.k == "const" then
        return { field = n.a.name, op = CMP[n.op], value = n.b.v }
    elseif n.a.k == "const" and n.b.k == "field" then
        return { field = n.b.name, op = CMP[FLIP[n.op]], value = n.a.v }
    end
    return nil
end

-- At most this many value ranges per field; an `and` of `or`s multiplies
-- them.
local MAX_RANGES = 64

-- The value range of a comparison { field, op, value }, or nil when op is
-- ~= or the value is nil or NaN. lo and hi are nil when open-ended; loOpen and
-- hiOpen leave the bound itself out.
local function as_range(c: any): any
    local v = c.value
    if v == nil or v ~= v or c.op == "~=" then
        return nil
    elseif c.op == "=" then
        return { lo = v, hi = v }
    elseif c.op == ">" or c.op == ">=" then
        return { lo = v, loOpen = c.op == ">" }
    end
    return { hi = v, hiOpen = c.op == "<" }
end

-- The values range a and b share, or nil when they share none.
local function overlap(a: any, b: any): any
    local r = { lo = a.lo, loOpen = a.loOpen, hi = a.hi, hiOpen = a.hiOpen }
    if b.lo ~= nil and (r.lo == nil or b.lo > r.lo) then
        r.lo, r.loOpen = b.lo, b.loOpen
    elseif b.lo ~= nil and b.lo == r.lo then
        r.loOpen = r.loOpen or b.loOpen
    end
    if b.hi ~= nil and (r.hi == nil or b.hi < r.hi) then
        r.hi, r.hiOpen = b.hi, b.hiOpen
    elseif b.hi ~= nil and b.hi == r.hi then
        r.hiOpen = r.hiOpen or b.hiOpen
    end
    if r.lo ~= nil and r.hi ~= nil
        and (r.lo > r.hi or (r.lo == r.hi and (r.loOpen or r.hiOpen))) then
        return nil
    end
    return r
end

-- For each field that n holds only within some value ranges, the list of
-- those ranges: a row whose field lies outside every range fails n. Only
-- comparisons of number and string fields with values and like calls on
-- string fields with constant patterns count.
local function ranges_of(n: any): { [string]: { any } }
    if n.k == "bin" and n.op == "or" then
        local a, b = ranges_of(n.a), ranges_of(n.b)
        local out = {}
        for f, list in a do
            if b[f] and #list + #b[f] <= MAX_RANGES then
                out[f] = table.move(b[f], 1, #b[f], #list + 1, table.clone(list))
            end
        end
        return out
    elseif n.k == "bin" and n.op == "and" then
        local a, b = ranges_of(n.a), ranges_of(n.b)
        for f, list in b do
            if a[f] == nil then
                a[f] = list
            elseif #a[f] * #list <= MAX_RANGES then
                local both = {}
                for _, x in a[f] do
                    for _, y in list do
                        both[#both + 1] = overlap(x, y)
                    end
                end
                a[f] = both
            end
        end
        return a
    elseif n.k == "call" and n.name == "like" then
        local r = n.a.k == "field" and n.a.kind == "string" and n.b.k == "const"
            and type(n.b.v) == "string" and like_range(n.b.v)
        return if r then { [n.a.name] = { r } } else {}
    end
    local c = n.k == "bin" and as_cond(n)
    local t = c and type(c.value)
    if c and (t == "number" or t == "string") and (n.a.t == t and n.b.t == t) then
        local r = as_range(c)
        if r then
            return { [c.field] = { r } }
        end
    end
    return {}
end

-- The expression src split at its top-level `and`s, in order: each part is
-- { field, op, value } with op one of = ~= < <= > >=, or { fn } with fn a
-- function of the row. A { fn } part that holds only when some field lies
-- within value ranges also has ranges = { [field] = list }, each range a
-- table { lo, loOpen, hi, hiOpen } whose nil bound is open-ended. A row
-- matches when every part holds.
function compile(src: string, kindOf: (string) -> string?, params: any, where: string): { any }
    local bad = failer(where, src)
    local tree = parse(src, where)
    local values = { n = 0 }
    if getmetatable(params) == VALUES_MT then
        params, values = nil, params
    elseif params ~= nil and type(params) ~= "table" then
        bad(nil, "takes a table of parameters, got " .. type(params))
    end
    if values.n ~= tree.slots then
        bad(nil, "has " .. tree.slots .. " ? and got " .. values.n .. " values for them")
    end
    tree = resolve(tree, kindOf, params, values, bad)
    local parts = {}
    local function split(n: any)
        if n.k == "bin" and n.op == "and" then
            split(n.a)
            split(n.b)
        elseif n.k == "const" then
            if not n.v then
                parts[#parts + 1] = { fn = function() return false end }
            end
        else
            local part = as_cond(n)
            if part == nil then
                part = { fn = build(n, bad) }
                local ranges = ranges_of(n)
                if next(ranges) ~= nil then
                    part.ranges = ranges
                end
            end
            parts[#parts + 1] = part
        end
    end
    split(tree)
    return parts
end

-- What the expression answers for row r, for the self-check.
local function eval(src: string, kinds: any, params: any, r: any): any
    local ok = true
    for _, p in compile(src, function(name) return kinds[name] end, params, "EXPR") do
        if p.fn then
            ok = ok and p.fn(r)
        else
            local v = r[p.field]
            if p.op == "=" then ok = ok and VALUES.equal_json(v, p.value)
            elseif p.op == "~=" then ok = ok and not VALUES.equal_json(v, p.value)
            elseif v == nil then ok = false
            else ok = ok and ORDER[p.op](v, p.value) end
        end
    end
    return ok
end

function call()
    local kinds = { age = "int", salary = "float", name = "string", active = "bool", tags = "json" }
    local function err(fn)
        local ok, msg = pcall(fn)
        return not ok and msg or "no error"
    end
    local parts = compile("age > 10 and 100 >= age and salary < max and active and age + 1 > salary",
                          function(name) return kinds[name] end, { max = 1000 }, "EXPR")
    if #parts ~= 5 or parts[2].op ~= "<=" or parts[3].value ~= 1000 or parts[4].value ~= true
        or parts[5].fn == nil then
        return "failed: split"
    end
    local function ranges(src)
        local out = {}
        for _, p in compile(src, function(name) return kinds[name] end, nil, "EXPR") do
            for f, list in p.ranges or {} do
                for _, r in list do
                    out[#out + 1] = f .. (r.loOpen and "(" or "[") .. tostring(r.lo) .. ","
                        .. tostring(r.hi) .. (r.hiOpen and ")" or "]")
                end
            end
        end
        return table.concat(out, " ")
    end
    local spans = {
        { "age < 20 or age > 100", "age[nil,20) age(100,nil]" },
        { "(age > 1 and age < 5 and salary < 3) or 7 == age", "age(1,5) age[7,7]" },
        { "(age > 1 or name == 'x') and (age < 5 or age >= 9) or age == 2",
          "age[nil,5) age[9,nil] age[2,2]" },
        { "(age < 5 or age > 9) and (age < 3 or age > 4) or age == 1",
          "age[nil,3) age(4,5) age(9,nil] age[1,1]" },
        { "like(name, 'an%') or name == 'bo'", "name[an,ao) name[bo,bo]" },
        { "like(name, 'a\\\\%_b%')", "name[a%,a&)" },
        { "like(name, '\\xFF\\xFF%')", "name[\xFF\xFF,nil]" },
        { "like(name, 'a\\xFF%')", "name[a\xFF,b)" },
        { "like(name, '%an') or like(name, '_b')", "" },
        { "not like(name, 'an%')", "" },
        { "name == 'ann' or age > 3", "" },
        { "age ~= 3 or age == nil", "" },
    }
    for i, c in spans do
        if ranges(c[1]) ~= c[2] then
            return "failed: ranges " .. i .. ": " .. ranges(c[1])
        end
    end
    local dated = compile("at >= date('1995-03-15') and year(at) == 1995",
                          function(name) return name == "at" and "time" or nil end, nil, "EXPR")
    if #dated ~= 2 or dated[1].value ~= 795225600000 or dated[2].fn == nil then
        return "failed: date calls"
    end
    local r = { age = 30, salary = 500, name = "ann", active = true, tags = { "a" },
                at = 795225600000 }
    local cases = {
        { "age > 10 and age <= 100 and salary < 1000", true },
        { "(age or 0) * 2 ^ 2 // 1 % 1000 == 120", true },
        { "-age < 0 and #name == 3 and name .. '!' == \"ann!\"", true },
        { "nope == nil or age > lo + 25", true },
        { "missing > 3", false },
        { "not (missing > 3)", true },
        { "missing + 1 == nil", true },
        { "tags == want", true },
        { "1_000 == 0x3e8 and 1e3 == 1000 and 0b11 == 3 and '\\65\\x42' == 'AB'", true },
        { "name < 'bob' and not active == false", true },
        { "year(at) == 1995 and month(at) == 3 and day(at + 86400000) == 16", true },
        { "at < date('1995-03-15T00:00:00.001Z') and year(missing) == nil", true },
        { "like(name, 'a%') and not like(name, 'b%') and like(name, pat)", true },
        { "like(nope, 'a%') == nil and like(name, nope) == nil and not like(nope, 'a%')", true },
        { "like('ann', 'a_n') == true and like(name .. '!', '%!')", true },
    }
    local matches = {
        { "", "", true }, { "", "%", true }, { "", "_", false }, { "a", "", false },
        { "abc", "abc", true }, { "abc", "ab", false }, { "abc", "abcd", false },
        { "abc", "a%", true }, { "abc", "%c", true }, { "abc", "%b%", true }, { "abc", "%d%", false },
        { "abc", "a_c", true }, { "abc", "___", true }, { "abc", "__", false }, { "abc", "____", false },
        { "abcabc", "%bc", true }, { "abcabd", "a%c%d", true }, { "abab", "ab%ab", true },
        { "aba", "ab%ab", false }, { "abc", "a%%c", true }, { "abc", "%_%", true },
        { "abcd", "%b_", false }, { "abcbd", "%b_", true }, { "xaxb", "%a_b", true },
        { "special packages requests", "%special%requests%", true },
        { "requests special", "%special%requests%", false },
        { "a\nb", "a%b", true }, { "a\nb", "a_b", true }, { "ABC", "abc", false },
        { "50%", "50\\%", true }, { "50x", "50\\%", false }, { "a_b", "a\\_b", true },
        { "axb", "a\\_b", false }, { "a\\b", "a\\\\b", true }, { "ab", "\\a\\b", true },
        { "caf\u{E9}", "caf_", true }, { "\u{65E5}\u{672C}", "__", true },
        { "\u{65E5}", "__", false }, { "\u{65E5}", "%__", false }, { "\u{65E5}", "%_", true },
        { "\u{1F600}x", "_x", true }, { "\xFFx", "_x", true }, { "\xC3", "_", true },
    }
    for i, c in matches do
        if like_match(c[1], (like_pieces(c[2]))) ~= c[3] then
            return "failed: like " .. i
        end
    end
    local extra = { age = "int", missing = "int", nope = "string", salary = "float",
                    name = "string", active = "bool", tags = "json", at = "time" }
    for i, c in cases do
        if eval(c[1], extra, { lo = 4, want = { "a" }, pat = "%nn" }, r) ~= c[2] then
            return "failed: case " .. i
        end
    end
    local errors = {
        { "age >", 'EXPR "age >": ends where a value should come' },
        { "age = 3", 'EXPR "age = 3" at column 5: has =; compare with ==' },
        { "(age > 3", 'EXPR "(age > 3" at column 1: has a ( without its )' },
        { "who > 3", 'EXPR "who > 3" at column 1: has no field or parameter who' },
        { "age > name", 'EXPR "age > name" at column 5: > compares field age (int) with'
            .. ' field name (string)' },
        { "active < true", 'EXPR "active < true" at column 8: field active (bool) has no order' },
        { "name + 1 > 0", 'EXPR "name + 1 > 0" at column 6: + takes numbers, got field name'
            .. " (string)" },
        { "function() end", 'EXPR "function() end" at column 1: takes no function; an expression'
            .. " has values, names and operators" },
        { "age > 3 3", 'EXPR "age > 3 3" at column 9: has 3 after the end of the expression' },
        { "now() > 1", 'EXPR "now() > 1" at column 1: has no function now; expressions call'
            .. " date, year, month, day and like" },
        { "like(age, 'a')", 'EXPR "like(age, \'a\')" at column 1: like takes a string, got field'
            .. " age (int)" },
        { "like(name, 3)", 'EXPR "like(name, 3)" at column 1: like takes a string, got 3' },
        { "like(name)", 'EXPR "like(name)" at column 1: has a call to like without its second'
            .. " value" },
        { "like(name, 'a', 'b')", 'EXPR "like(name, \'a\', \'b\')" at column 1: has a call to like'
            .. " without its )" },
        { "like(name, 'a\\\\')", 'EXPR "like(name, \'a\\\\\\\\\')" at column 1: like pattern ends'
            .. " with \\; write \\\\ for a backslash" },
        { "age, name", 'EXPR "age, name" at column 4: has , after the end of the expression' },
        { "year(name) > 1", 'EXPR "year(name) > 1" at column 1: year takes a number, got field'
            .. " name (string)" },
        { "age > date('1995-02-30')", 'EXPR "age > date(\'1995-02-30\')" at column 7: date wants'
            .. ' a date such as 1995-03-15 or 1995-03-15T10:20:30Z, got "1995-02-30"' },
        { "year(age 1)", 'EXPR "year(age 1)" at column 1: has a call to year without its )' },
    }
    for i, c in errors do
        local got = err(function() eval(c[1], kinds, nil, r) end)
        if got ~= c[2] then
            return "failed: error " .. i .. ": " .. tostring(got)
        end
    end
    if err(function() eval("age > max", kinds, { max = print }, r) end)
        ~= 'EXPR "age > max": parameter max is a function; parameters are numbers, strings,'
            .. " booleans or JSON tables" then
        return "failed: parameter"
    end
    if err(function() eval("(age or 'x') < 3", kinds, nil, { name = "x" }) end)
        ~= 'EXPR "(age or \'x\') < 3": < compares string with number' then
        return "failed: run-time check"
    end
    return "ok"
end
