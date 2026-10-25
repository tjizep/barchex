-- Where lent keeps rows, index entries and edges in a space's store.
--
-- Required, not called: `local lay = require("lent.LAYOUT")`. A function key
-- has to define call(), so this one answers a self-check:
--
--   lent.LAYOUT              -> "ok" or which check failed (from any space)
--
-- Tables, indexes and edges are named by KEYCODEC strings and values are
-- encoded with their field's kind, so each prefix below holds exactly the
-- keys that start with it:
--
--   lent.r<table><pk>                   the row, as ROWCODEC wrote it
--   lent.i<table><index><values><pk>    "" for each row of a plain index
--   lent.u<table><index><values>        the pk, for each row of a unique index
--   lent.e<edge><from pk><to pk>        "" for each edge, read forwards
--   lent.E<edge><to pk><from pk>        "" for each edge, read backwards
--   lent.n<table>                       the last pk given out, for id = "int"
--
-- A pk is encoded with its table's id kind, "uuid" or "int", and takes the
-- same number of bytes in every key of the table, so a key's pk is read
-- from its end. A unique entry's value is the pk as text: the uuid, or the
-- integer's digits.
--
-- A unique index has no entry for a row with a nil in any of its fields, so
-- any number of rows can leave a unique field nil. A plain index keeps those
-- rows, and nil sorts first.

local kc = require("lent.KEYCODEC")

local function name(s: string): string
    return kc.encode("string", s)
end

-- The id kind of table `t`. A catalog written before tables had one holds
-- int ids.
function id_kind(t: any): string
    return t.id or "int"
end

-- The pk at the end of `key`, in a table or edge end of id kind `kind`.
local function tail(kind: string, key: string): any
    return (kc.decode(key, #key - kc.WIDTH[kind] + 1))
end

-- The pk a unique entry's value holds.
function unique_pk(t: any, value: string): any
    return id_kind(t) == "int" and tonumber(value) or value
end

-- The key of row `pk` in table `t`, or with pk nil, the prefix of them all.
function row(t: any, pk: any): string
    local key = "lent.r" .. name(t.key)
    return pk == nil and key or key .. kc.encode(id_kind(t), pk)
end

-- The pk of a row key.
function row_pk(t: any, key: string): any
    return tail(id_kind(t), key)
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
    return (ix.unique and "lent.u" or "lent.i") .. name(t.key) .. name(ix.name), kinds
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

-- Gives `r` the default of each field it lacks, as a row stored before the
-- field was added reads, and answers `r`. Index entries are built from rows
-- filled this way.
function fill(t: any, r: { [string]: any }): { [string]: any }
    for _, f in t.fields do
        if r[f.name] == nil and f.default ~= nil then
            r[f.name] = f.default
        end
    end
    return r
end

-- The index entry for `row` at `pk`: the key and its value. nil for a
-- unique index when one of the row's indexed fields is nil.
function entry(t: any, ix: any, r: { [string]: any }, pk: any): (string?, string?)
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
    return key .. kc.encode(id_kind(t), pk), ""
end

-- The pk at the end of a plain index key, or in a unique entry's value.
function pk_of(t: any, ix: any, key: string, value: string?): any
    if ix.unique then
        return unique_pk(t, value :: string)
    end
    return tail(id_kind(t), key)
end

-- Edge keys take `s`, the edge's record in SCHEMA's graph().edges, for its
-- name and the id kinds of its two ends.

-- The forward key of edge `s` from `from` to `to`; with `to` nil, the prefix
-- of every edge from `from`.
function edge(s: any, from: any, to: any): string
    local key = "lent.e" .. name(s.name) .. kc.encode(s.fromId or "int", from)
    return to == nil and key or key .. kc.encode(s.toId or "int", to)
end

-- The backward key, or with `from` nil the prefix of every edge into `to`.
function edge_back(s: any, to: any, from: any): string
    local key = "lent.E" .. name(s.name) .. kc.encode(s.toId or "int", to)
    return from == nil and key or key .. kc.encode(s.fromId or "int", from)
end

-- The far end of a forward edge key: its `to` pk.
function edge_to(s: any, key: string): any
    return tail(s.toId or "int", key)
end

-- The far end of a backward edge key: its `from` pk.
function edge_from(s: any, key: string): any
    return tail(s.fromId or "int", key)
end

-- The key that holds a table's next pk.
function counter(t: any): string
    return "lent.n" .. name(t.key)
end

-- Every key under `prefix`, `limit` at a time: calls each(key) for each and
-- answers how many there were. `each` may remove the key it is given, here
-- and in scan.
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

-- Calls each(key) for every key from `lo` up to `hi`, a page at a time,
-- until `each` answers true. Answers whether it stopped early.
function scan(lo: string, hi: string, each: (string) -> boolean?, limit: number?): boolean
    local page = limit or 1000
    while true do
        local keys = barch.store.range(lo, hi, page)
        for _, k in keys do
            if each(k) then
                return true
            end
        end
        if #keys < page then
            return false
        end
        lo = keys[#keys] .. "\2"
    end
end

-- scan from `hi` back down to `lo`: calls each(key) for every key in the
-- span, highest first, until `each` answers true. barch counts the span and
-- jumps to each page by offset, so a page costs the same at either end.
-- `each` must not add or remove keys in the span.
function scan_back(lo: string, hi: string, each: (string) -> boolean?, limit: number?): boolean
    local page = limit or 1000
    local pos = barch.store.count(lo, hi)
    while pos > 0 do
        local from = math.max(0, pos - page)
        local keys = barch.store.range(lo, hi, pos - from, from)
        for i = #keys, 1, -1 do
            if each(keys[i]) then
                return true
            end
        end
        pos = from
    end
    return false
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
        or v ~= "" or pk_of(t, plain, k) ~= 7 then
        return false, "plain entry"
    end
    local back = kc.unpack(k, 2, #index(t, plain) + 1)
    if back[1] ~= 41 or back[2] ~= "a b" then
        return false, "plain entry values"
    end
    k, v = entry(t, uniq, r, 7)
    if k ~= index(t, uniq, { "a b" }) or v ~= "7" or pk_of(t, uniq, k, v) ~= 7 then
        return false, "unique entry"
    end
    if entry(t, uniq, { age = 1 }, 8) ~= nil then
        return false, "a unique entry for a nil"
    end
    local filled = fill({ fields = { { name = "n", default = 0 }, { name = "m" } } }, { m = 1 })
    if filled.n ~= 0 or filled.m ~= 1 then
        return false, "fill"
    end
    if entry(t, plain, { email = "x" }, 8) == nil then
        return false, "no plain entry for a nil"
    end
    if string.find(row(t, 1), "[%z\1 ]") or string.sub(row(t, 1), 1, #row(t)) ~= row(t) then
        return false, "row key"
    end
    if row_pk(t, row(t, 7)) ~= 7 then
        return false, "row pk"
    end
    local s = { name = "user_posts", fromId = "int", toId = "uuid" }
    local u = barch.uuid()
    if string.sub(edge(s, 1, u), 1, #edge(s, 1)) ~= edge(s, 1)
        or edge_to(s, edge(s, 1, u)) ~= u or edge_from(s, edge_back(s, u, 1)) ~= 1 then
        return false, "edge keys"
    end
    local ut = { key = "doc", id = "uuid", fields = t.fields }
    k, v = entry(ut, uniq, r, u)
    if row_pk(ut, row(ut, u)) ~= u or pk_of(ut, uniq, k :: string, v) ~= u
        or pk_of(ut, plain, (entry(ut, plain, r, u))) ~= u then
        return false, "uuid pks"
    end
    return true
end

function call()
    local ok, why = selftest()
    return ok and "ok" or ("failed: " .. why)
end
