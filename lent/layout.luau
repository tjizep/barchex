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
--   lent.p<store><block>                which rows of a column block exist
--   lent.c<store><field id><block>      one field of a column block's rows
--   lent.c<store><field id>x<pk>        a column text value longer than its
--                                       block keeps, whole
--   lent.i<table><index><values><pk>    "" for each row of a plain index
--   lent.u<table><index><values>        the pk, for each row of a unique index
--   lent.e<edge><from pk><to pk>        "" for each edge, read forwards
--   lent.E<edge><to pk><from pk>        "" for each edge, read backwards
--   lent.l<edge><from pk>               never stored: a pessimistic link
--   lent.L<edge><to pk>                 locks it before it checks a unique
--                                       edge's links from or to the row
--   lent.n<table>                       the last pk given out, for id = "int"
--   lent.a<run><part>                   a paged aggregate's spilled groups,
--                                       which CLIENT writes and removes
--   lent.s<table>                       the planner statistics that MIGRATE's
--                                       analyze() writes
--   lent.v<view><group values>          a stored view's group: its row count
--                                       and each aggregate's running values
--   lent.m<view><group values><agg><value>
--                                       how many of the group's rows hold
--                                       this value, for a min or max
--
-- A column table's <store> is its table name, or after a change of block
-- size or a change of format to column, the name and "@" and the schema
-- version that started the change.
-- Table names are snake case, so no other table's keys start with it.
--
-- A pk is encoded with its table's id kind, "uuid" or "int", and takes the
-- same number of bytes in every key of the table, so a key's pk is read
-- from its end. A unique entry's value is the pk as text: the uuid, or the
-- integer's digits.
--
-- An index with edges adds, after the field values, the id of the row each
-- edge links to, encoded with that table's id kind.
--
-- A unique index has no entry for a row with a nil in any of its fields or
-- edges, so any number of rows can leave a unique field nil or an edge
-- unlinked. A plain index keeps those rows, and nil sorts first.

local kc = require("lent.KEYCODEC")
local VALUES = require("lent.VALUES")

local function name(s: string): string
    return kc.encode("string", s)
end

-- The id kind of table `t`. A catalog written before tables had one holds
-- int ids.
function id_kind(t: any): string
    return t.id or "int"
end

-- A table of format "column" stores no key per row: COLUMNS keeps its rows in
-- blocks, and row() and row_pk() name its rows' places in key order, for
-- cursors, paged reads and index plans.

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

-- The name a column table's blocks are stored under.
local function store(t: any): string
    return name(t.store or t.key)
end

-- The key of a column block's presence, or with block nil, the prefix of
-- them all.
function present(t: any, block: number?): string
    local key = "lent.p" .. store(t)
    return block == nil and key or key .. kc.encode("int", block)
end

-- The block number of a presence key.
function present_block(key: string): number
    return tail("int", key)
end

-- The prefix of the blocks of the field with id `field`, which a block's
-- encoded number completes.
function column(t: any, field: number): string
    return columns(t) .. kc.encode("int", field)
end

-- The prefix of the blocks of every field of a column table.
function columns(t: any): string
    return "lent.c" .. store(t)
end

-- The key of the whole value of field `field` at row `pk` of a column table,
-- for a text value longer than its block keeps, or with pk nil, the prefix
-- of them all. It shares the field's column prefix, so dropping the field
-- drops these too.
function overflow(t: any, field: number, pk: number?): string
    local key = column(t, field) .. "x"
    return pk == nil and key or key .. kc.encode("int", pk)
end

-- The pk of a row key.
function row_pk(t: any, key: string): any
    return tail(id_kind(t), key)
end

-- The prefix of index `ix`'s keys in table `t`, and the value kinds: the
-- fields', then the id kinds of the edges' tables.
local function index_prefix(t: any, ix: any): (string, { string })
    local kinds = table.create(#ix.on)
    for i, fname in ix.on do
        for _, f in t.fields do
            if f.name == fname then
                kinds[i] = f.kind
            end
        end
    end
    for _, l in ix.links or {} do
        kinds[#kinds + 1] = l.id
    end
    return (ix.unique and "lent.u" or "lent.i") .. name(t.key) .. name(ix.name), kinds
end

-- The prefix of every key of index `ix`, or of the keys that start with
-- `values` (the first #values of the index's fields, then its edges' ids).
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
            if f.kind == "json" then r[f.name] = VALUES.copy_json(f.default)
            else r[f.name] = f.default end
        end
    end
    return r
end

-- The index entry for `row` at `pk`: the key and its value. `ids` holds
-- the id each of the index's edges links the row to, by edge name, as
-- linked() answers. nil for a unique index when one of the row's indexed
-- fields is nil or one of its edges links no row.
function entry(t: any, ix: any, r: { [string]: any }, pk: any,
               ids: { [string]: any }?): (string?, string?)
    local prefix, kinds = index_prefix(t, ix)
    local values = table.create(#kinds)
    local n = #ix.on
    for i = 1, #kinds do
        if i <= n then
            values[i] = r[ix.on[i]]
        else
            values[i] = ids and ids[ix.links[i - n].name]
        end
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

-- The key a pessimistic link locks before it checks the links of unique
-- edge `s` from row `from`, or with `back` the links into row `from`. No
-- range read covers it, so a transaction that has read the links waits for
-- nobody on it.
function edge_lock(s: any, from: any, back: boolean?): string
    if back then
        return "lent.L" .. name(s.name) .. kc.encode(s.toId or "int", from)
    end
    return "lent.l" .. name(s.name) .. kc.encode(s.fromId or "int", from)
end

-- The prefixes of every forward and every backward key of edge store `s`.
function edge_store(s: any): (string, string)
    return "lent.e" .. name(s.name), "lent.E" .. name(s.name)
end

-- The far end of a forward edge key: its `to` pk.
function edge_to(s: any, key: string): any
    return tail(s.toId or "int", key)
end

-- The far end of a backward edge key: its `from` pk.
function edge_from(s: any, key: string): any
    return tail(s.fromId or "int", key)
end

-- The prefixes of every unique and every other index key of table `t`.
function indexes(t: any): (string, string)
    return "lent.u" .. name(t.key), "lent.i" .. name(t.key)
end

-- The key that holds a table's next pk.
function counter(t: any): string
    return "lent.n" .. name(t.key)
end

-- The prefix of the scratch keys of paged aggregate run `id`.
function scratch(id: string): string
    return "lent.a" .. name(id)
end

-- The key that holds table `t`'s planner statistics.
function stats(t: any): string
    return "lent.s" .. name(t.key)
end

-- The key of stored view `view`'s group whose values `group` packs, or with
-- group nil, the prefix of every group of the view.
function view(view: string, group: string?): string
    return "lent.v" .. name(view) .. (group or "")
end

-- The key that counts the rows of stored view `view`'s group `group` whose
-- aggregate `agg` reads value `v`, encoded with kind `kind`. With v nil it
-- is the prefix of those keys, and with group nil, of the view's.
function view_value(view: string, group: string?, agg: string?, kind: string?, v: any): string
    local key = "lent.m" .. name(view)
    if group == nil then
        return key
    end
    key ..= group .. name(agg :: string)
    return if v == nil then key else key .. kc.encode(kind :: string, v)
end

-- Counts the paths from the rows in `start`, a map of pk to count, through
-- hops first to last of `path`, a list of { store, forward } naming stores
-- in `edges`, and answers them as a map of the pk each path ends at to the
-- number of paths. `backward` walks the hops from last down to first
-- against their direction. With first past last it answers `start`.
function path_counts(edges: any, path: { any }, start: any, first: number, last: number,
                     backward: boolean?): any
    local at = start
    for i = first, last, backward and -1 or 1 do
        local h = path[i]
        local s = edges[h.store]
        local forward = h.forward ~= (backward == true)
        local pick = forward and edge_to or edge_from
        local found = {}
        for pk, n in at do
            walk(forward and edge(s, pk) or edge_back(s, pk), function(k)
                local other = pick(s, k)
                found[other] = (found[other] or 0) + n
            end)
        end
        at = found
    end
    return at
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

-- The ids that row pk links to through the edges of index `ix`, by edge
-- name, read from `edges`, the edge stores by name. nil for an index
-- without edges.
function linked(edges: any, ix: any, pk: any): { [string]: any }?
    if ix.links == nil then
        return nil
    end
    local out = {}
    for _, l in ix.links do
        local s = edges[l.store]
        local prefix = l.forward and edge(s, pk) or edge_back(s, pk)
        local k = barch.store.range(prefix, kc.after(prefix), 1)[1]
        if k then
            out[l.name] = l.forward and edge_to(s, k) or edge_from(s, k)
        end
    end
    return out
end

-- The page size after `page`: twice as many keys, up to 1000.
local function grow(page: number): number
    return math.min(page * 2, 1000)
end

-- scan with each key's value: calls each(key, value) for every key from
-- `lo` up to `hi`, until `each` answers true, and answers whether it stopped
-- early. Each page reads keys and values together. The first page holds
-- `first` keys, 1000 by default, and each later page twice as many up to
-- 1000, so a scan that stops after a few keys reads few values.
function scan_values(lo: string, hi: string, each: (string, string) -> boolean?,
                     first: number?): boolean
    local page = math.clamp(first or 1000, 1, 1000)
    while true do
        local keys, values = barch.store.rangeValues(lo, hi, page)
        for i, k in keys do
            if each(k, values[i]) then
                return true
            end
        end
        if #keys < page then
            return false
        end
        lo = keys[#keys] .. "\2"
        page = grow(page)
    end
end

-- scan_back with each key's value, paged as scan_values is.
function scan_back_values(lo: string, hi: string, each: (string, string) -> boolean?,
                          first: number?): boolean
    local page = math.clamp(first or 1000, 1, 1000)
    local pos = barch.store.count(lo, hi)
    while pos > 0 do
        local from = math.max(0, pos - page)
        local keys, values = barch.store.rangeValues(lo, hi, pos - from, from)
        for i = #keys, 1, -1 do
            if each(keys[i], values[i]) then
                return true
            end
        end
        pos = from
        page = grow(page)
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
    -- an edge's id follows the fields, and a unique entry needs it
    local linkedIx = { name = "by_age_owner", on = { "age" }, unique = true,
                       links = { { name = "owner", store = "x", forward = false, id = "int" } } }
    k, v = entry(t, linkedIx, r, 7, { owner = 3 })
    if k ~= index(t, linkedIx, { 41, 3 }) or v ~= "7"
        or entry(t, linkedIx, r, 7, {}) ~= nil or entry(t, linkedIx, r, 7) ~= nil then
        return false, "edge entry"
    end
    -- a store keeps its blocks apart from the table's first ones
    local moved = { key = "user", store = "user@3" }
    if string.sub(present(moved, 1), 1, #present(t)) == present(t)
        or string.sub(column(moved, 2), 1, #columns(t)) == columns(t)
        or string.sub(column(moved, 2), 1, #columns(moved)) ~= columns(moved) then
        return false, "column stores"
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
