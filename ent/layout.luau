-- Where ent keeps rows, index entries and edges in a space's store.
--
-- Required, not called: `local lay = require("ent.LAYOUT")`. A function key
-- has to define call(), so this one answers a self-check:
--
--   ent.LAYOUT              -> "ok" or which check failed (from any space)
--
-- Tables, indexes and edges are named by KEYCODEC strings and values are
-- encoded with their field's kind, so each prefix below holds exactly the
-- keys that start with it:
--
--   ent.r<table><pk>                   the row, as ROWCODEC wrote it
--   ent.i<table><index><values><pk>    "" for each row of a plain index
--   ent.u<table><index><values>        the pk, for each row of a unique index
--   ent.e<edge><from pk><to pk>        "" for each edge, read forwards
--   ent.E<edge><to pk><from pk>        "" for each edge, read backwards
--
-- A unique index has no entry for a row with a nil in any of its fields, so
-- any number of rows can leave a unique field nil. A plain index keeps those
-- rows, and nil sorts first.

local kc = require("ent.KEYCODEC")

local function name(s: string): string
    return kc.encode("string", s)
end

-- The key of row `pk` in table `t`, or with pk nil, the prefix of them all.
function row(t: any, pk: number?): string
    local key = "ent.r" .. name(t.key)
    return pk == nil and key or key .. kc.encode("int", pk)
end

-- The prefix of index `ix`'s keys in table `t`, and the value kinds.
local function index_prefix(t: any, ix: any): (string, { string })
    local kinds = table.create(#ix.on)
    for i, fname in ix.on do
        for _, f in t.fields do
            if f.name == fname then
                kinds[i] = f.kind
            end
        end
    end
    return (ix.unique and "ent.u" or "ent.i") .. name(t.key) .. name(ix.name), kinds
end

-- The prefix of every key of index `ix`, or of the keys that start with
-- `values` (the first #values of the index's fields).
function index(t: any, ix: any, values: { any }?): string
    local prefix, kinds = index_prefix(t, ix)
    if values == nil then
        return prefix
    end
    local n = #values
    return prefix .. kc.pack(table.move(kinds, 1, n, 1, {}), values)
end

-- The index entry for `row` at `pk`: the key and its value. nil for a
-- unique index when one of the row's indexed fields is nil.
function entry(t: any, ix: any, r: { [string]: any }, pk: number): (string?, string?)
    local prefix, kinds = index_prefix(t, ix)
    local values = table.create(#ix.on)
    for i, fname in ix.on do
        values[i] = r[fname]
        if ix.unique and values[i] == nil then
            return nil, nil
        end
    end
    local key = prefix .. kc.pack(kinds, values)
    if ix.unique then
        return key, tostring(pk)
    end
    return key .. kc.encode("int", pk), ""
end

-- The pk at the end of a plain index key, or in a unique entry's value.
function pk_of(ix: any, key: string, value: string?): number
    if ix.unique then
        return tonumber(value) :: number
    end
    return (kc.decode(key, #key - 16))
end

-- The forward and backward keys of edge `store` from `from` to `to`; with
-- `to` nil, the prefix of every edge from `from`.
function edge(store: string, from: number, to: number?): string
    local key = "ent.e" .. name(store) .. kc.encode("int", from)
    return to == nil and key or key .. kc.encode("int", to)
end

-- The backward key, or with `from` nil the prefix of every edge into `to`.
function edge_back(store: string, to: number, from: number?): string
    local key = "ent.E" .. name(store) .. kc.encode("int", to)
    return from == nil and key or key .. kc.encode("int", from)
end

-- The key that holds a table's next pk.
function counter(t: any): string
    return "ent.n" .. name(t.key)
end

-- Every key under `prefix`, `limit` at a time: calls each(key) for each and
-- answers how many there were. `each` may remove the key it is given.
function walk(prefix: string, each: (string) -> (), limit: number?): number
    local hi = kc.after(prefix)
    local lo, n, page = prefix, 0, limit or 1000
    while true do
        local keys = barch.store.range(lo, hi, page)
        for _, k in keys do
            each(k)
        end
        n += #keys
        if #keys < page then
            return n
        end
        -- no key here holds a NUL or a \1, so this is the next key there can be
        lo = keys[#keys] .. "\2"
    end
end

function selftest(): (boolean, string?)
    local t = {
        key = "user",
        fields = { { name = "email", kind = "string" }, { name = "age", kind = "int" } },
    }
    local plain = { name = "by_age_email", on = { "age", "email" }, unique = false }
    local uniq = { name = "by_email", on = { "email" }, unique = true }
    local r = { email = "a b", age = 41 }

    local k, v = entry(t, plain, r, 7)
    if k == nil or string.sub(k, 1, #index(t, plain)) ~= index(t, plain)
        or string.sub(k, 1, #index(t, plain, { 41 })) ~= index(t, plain, { 41 })
        or v ~= "" or pk_of(plain, k) ~= 7 then
        return false, "plain entry"
    end
    local back = kc.unpack(k, 2, #index(t, plain) + 1)
    if back[1] ~= 41 or back[2] ~= "a b" then
        return false, "plain entry values"
    end
    k, v = entry(t, uniq, r, 7)
    if k ~= index(t, uniq, { "a b" }) or v ~= "7" or pk_of(uniq, k, v) ~= 7 then
        return false, "unique entry"
    end
    if entry(t, uniq, { age = 1 }, 8) ~= nil then
        return false, "a unique entry for a nil"
    end
    if entry(t, plain, { email = "x" }, 8) == nil then
        return false, "no plain entry for a nil"
    end
    if string.find(row(t, 1), "[%z\1 ]") or string.sub(row(t, 1), 1, #row(t)) ~= row(t) then
        return false, "row key"
    end
    if string.sub(edge("user_posts", 1, 2), 1, #edge("user_posts", 1)) ~= edge("user_posts", 1)
        or edge_back("user_posts", 2, 1) == edge("user_posts", 2, 1) then
        return false, "edge keys"
    end
    return true
end

function call()
    local ok, why = selftest()
    return ok and "ok" or ("failed: " .. why)
end
