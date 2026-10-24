-- Creates, reads, updates, deletes and queries the rows of the tables MIGRATE
-- put in a space, with their indexes and edges, in the caller's transaction.
--
-- Required, not called: `local ent = require("ent.CLIENT")`. A function key
-- has to define call(), so this one answers a self-check, which migrates and
-- writes rows inside a transaction it then rolls back:
--
--   ent.CLIENT              -> "ok" or which check failed
--
-- From the application's space, after MIGRATE:
--
--   ent.tx(function(c)
--       local u = c.User:create { email = "a@b", name = "ann" }  -- u.id = 1
--       c.User:get(u.id)                     -- the row, or nil
--       c.User:by("email", "a@b")            -- the row, through by_email
--       c.User:update(u.id, { name = "bo" }, { "age" })  -- sets name, clears age
--       c.User:delete(u.id)                  -- true, or false if it was gone
--
--       local p = c.Post:create { title = "hi", author = u }    -- links the edge
--       c.User:link("posts", u.id, p.id)     -- or unlink
--       c.User:query():where("name", "=", "ann")
--           :queryPosts():order("title", "desc"):limit(10):all()
--   end)
--
-- ent.tx(fn, pessimistic) runs fn(c) in barch.tx.run, which retries on a
-- conflict. Inside a transaction the caller already runs, ent.client(p)
-- answers the same `c`. Each answers rows as tables of field values with
-- the row's integer `id`; a field the row lacks reads as its default.
--
-- Errors start with ENT, or ROWCODEC for a value of the wrong kind or a
-- missing field that is not optional.

local rc = require("ent.ROWCODEC")
local lay = require("ent.LAYOUT")
local kc = require("ent.KEYCODEC")
local mig = require("ent.MIGRATE")

local function fail(msg: string)
    error("ENT " .. msg, 0)
end

local Table = {}
Table.__index = Table

local function bind(t: any, version: number, pessimistic: boolean?): any
    local byName, edgeByName = {}, {}
    for _, f in t.fields do
        byName[f.name] = f
    end
    for _, e in t.edges do
        edgeByName[e.name] = e
    end
    return setmetatable({
        t = t, fields = rc.fields(t.fields), byName = byName, edgeByName = edgeByName,
        version = version, lock = pessimistic == true, where = "table " .. t.name,
    }, Table)
end

local function get(self: any, key: string, exclusive: boolean?): string?
    if exclusive and self.lock then
        return barch.store.get(key, true)
    end
    return barch.store.get(key)
end

local function check_pk(self: any, pk: any)
    if type(pk) ~= "number" or pk < 1 or pk ~= math.floor(pk) then
        fail(self.where .. " wants an integer id, got " .. tostring(pk))
    end
end

-- The row at pk, filled with defaults, or nil. A pessimistic caller about
-- to write the row reads it with the exclusive lock.
local function read(self: any, pk: number, exclusive: boolean?): any
    local v = get(self, lay.row(self.t, pk), exclusive)
    if v == nil then
        return nil
    end
    local r = lay.fill(self.t, (rc.decode(self.fields, v)))
    r.id = pk
    return r
end

local function set_fields(self: any, r: any, values: any)
    for k, v in values do
        if k == "id" then
            fail(self.where .. " gives out ids itself, so a row cannot set id")
        end
        if self.edgeByName[k] then
            fail(self.where .. " edge " .. k .. " changes with link and unlink")
        end
        if self.byName[k] == nil then
            fail(self.where .. " has no field " .. tostring(k))
        end
        r[k] = v
    end
end

-- Raises an error if another row holds the unique entry `key`.
local function check_free(self: any, ix: any, key: string, pk: number, r: any)
    local other = get(self, key, true)
    if other ~= nil and tonumber(other) ~= pk then
        local parts = {}
        for i, f in ix.on do
            parts[i] = f .. "=" .. tostring(r[f])
        end
        fail(self.where .. " index " .. ix.name .. " is unique, and row " .. other
            .. " already has " .. table.concat(parts, " "))
    end
end

-- Stores row `r` at pk, given the row it replaces (nil for a new row), and
-- moves each index entry whose values changed. Everything is checked
-- before the first write, so an error leaves the store as it was.
local function store(self: any, pk: number, old: any, r: any, counter: string?): any
    local value = rc.encode(self.fields, self.t.format, self.version, r)
    local moves = {}
    for _, ix in self.t.indexes do
        local was = old and (lay.entry(self.t, ix, old, pk))
        local key, v = lay.entry(self.t, ix, r, pk)
        if was ~= key then
            if key and ix.unique then
                check_free(self, ix, key, pk, r)
            end
            moves[#moves + 1] = { was, key, v }
        end
    end
    if counter then
        barch.store.set(counter, tostring(pk))
    end
    for _, m in moves do
        if m[1] then
            barch.store.remove(m[1])
        end
    end
    for _, m in moves do
        if m[2] then
            barch.store.set(m[2], m[3])
        end
    end
    barch.store.set(lay.row(self.t, pk), value)
    r.id = pk
    return r
end

-- edges ----------------------------------------------------------------------

local function find_edge(self: any, name: string): any
    local e = self.edgeByName[name]
    if e == nil then
        fail(self.where .. " has no edge " .. tostring(name))
    end
    return e
end

-- The from and to pks of edge `e`'s store, given this table's pk and the
-- other table's.
local function ends(e: any, pk: number, other: number): (number, number)
    if e.dir == "to" then
        return pk, other
    end
    return other, pk
end

-- Whether a row of this table has at most one row at the far end of `e`.
local function one(self: any, e: any): boolean
    local s = self.allEdges[e.store]
    if e.dir == "to" then
        return s.unique == true
    end
    return s.inverseUnique == true
end

-- The ids in an edge's value: an id, a row, or a list of either.
local function ids_in(self: any, e: any, v: any): { number }
    if type(v) == "number" or (type(v) == "table" and v.id ~= nil) then
        v = { v }
    end
    if type(v) ~= "table" then
        fail(self.where .. " edge " .. e.name .. " takes ids or rows, got " .. tostring(v))
    end
    local list = {}
    for i, x in v do
        list[i] = type(x) == "table" and x.id or x
    end
    return list
end

local function exists(self: any, pk: number): boolean
    check_pk(self, pk)
    return barch.store.exists(lay.row(self.t, pk))
end

local function first_key(prefix: string): string?
    return barch.store.range(prefix, kc.after(prefix), 1)[1]
end

-- Raises an error unless `from` -> `to` can be added to edge `e`.
local function check_link(self: any, e: any, pk: number, other: number)
    local target = self.peers[e.target]
    if not exists(target, other) then
        fail(target.where .. " has no row " .. other)
    end
    local s = self.allEdges[e.store]
    local from, to = ends(e, pk, other)
    local k = s.unique and first_key(lay.edge(e.store, from))
    if k and k ~= lay.edge(e.store, from, to) then
        fail("edge " .. e.store .. " allows one " .. s.to .. " per " .. s.from .. ", and "
            .. s.from .. " row " .. from .. " has one")
    end
    k = s.inverseUnique and first_key(lay.edge_back(e.store, to))
    if k and k ~= lay.edge_back(e.store, to, from) then
        fail("edge " .. e.store .. " allows one " .. s.from .. " per " .. s.to .. ", and "
            .. s.to .. " row " .. to .. " has one")
    end
end

local function write_link(e: any, pk: number, other: number)
    local from, to = ends(e, pk, other)
    barch.store.set(lay.edge(e.store, from, to), "")
    barch.store.set(lay.edge_back(e.store, to, from), "")
end

-- Links row pk to row `other` through edge `name`. Linking twice is
-- harmless.
function Table:link(name: string, pk: number, other: number)
    local e = find_edge(self, name)
    if not exists(self, pk) then
        fail(self.where .. " has no row " .. pk)
    end
    check_link(self, e, pk, other)
    write_link(e, pk, other)
end

-- Removes the link from row pk to row `other`. Answers whether there was one.
function Table:unlink(name: string, pk: number, other: number): boolean
    local e = find_edge(self, name)
    local from, to = ends(e, pk, other)
    local key = lay.edge(e.store, from, to)
    if not barch.store.exists(key) then
        return false
    end
    barch.store.remove(key)
    barch.store.remove(lay.edge_back(e.store, to, from))
    return true
end

-- Removes every edge into or out of row pk, including edges declared only
-- by the table at the other end.
local function unlink_all(self: any, pk: number)
    local name = self.t.name
    for store, s in self.allEdges do
        if s.from == name then
            lay.walk(lay.edge(store, pk), function(k)
                local to = kc.decode(k, #k - 16)
                barch.store.remove(k)
                barch.store.remove(lay.edge_back(store, to, pk))
            end)
        end
        if s.to == name then
            lay.walk(lay.edge_back(store, pk), function(k)
                local from = kc.decode(k, #k - 16)
                barch.store.remove(k)
                barch.store.remove(lay.edge(store, from, pk))
            end)
        end
    end
end

-- rows -------------------------------------------------------------------------

-- Adds a row and answers it with its new id. A value under an edge's name
-- links the row: an id or a row, or a list of them.
function Table:create(values: { [string]: any }): any
    local r, plain, links = {}, {}, {}
    for k, v in values do
        local e = self.edgeByName[k]
        if e then
            links[#links + 1] = { e, ids_in(self, e, v) }
        else
            plain[k] = v
        end
    end
    set_fields(self, r, plain)
    lay.fill(self.t, r)
    local counter = lay.counter(self.t)
    local pk = (tonumber(get(self, counter, true)) or 0) + 1
    for _, l in links do
        if #l[2] > 1 and one(self, l[1]) then
            fail(self.where .. " edge " .. l[1].name .. " links one row, got " .. #l[2])
        end
        for _, other in l[2] do
            check_link(self, l[1], pk, other)
        end
    end
    store(self, pk, nil, r, counter)
    for _, l in links do
        for _, other in l[2] do
            write_link(l[1], pk, other)
        end
    end
    return r
end

-- The row with this id, or nil.
function Table:get(pk: number): any
    check_pk(self, pk)
    return read(self, pk)
end

-- The row whose values match a unique index, or nil. `name` is the index's
-- name, or a field name whose `by_<field>` index is unique.
function Table:by(name: string, ...: any): any
    local ix
    for _, i in self.t.indexes do
        if i.name == name or i.name == "by_" .. name then
            ix = i
        end
    end
    if ix == nil or not ix.unique then
        fail(self.where .. " has no unique index " .. tostring(name))
    end
    local values = { ... }
    if select("#", ...) ~= #ix.on then
        fail(self.where .. " index " .. ix.name .. " takes " .. #ix.on .. " values, got "
            .. select("#", ...))
    end
    local pk = barch.store.get(lay.index(self.t, ix, values))
    return pk and read(self, tonumber(pk) :: number)
end

-- Sets the fields in `values` and clears the fields named in `clear`, then
-- answers the stored row. Raises an error if there is no row with this id.
function Table:update(pk: number, values: { [string]: any }?, clear: { string }?): any
    check_pk(self, pk)
    local old = read(self, pk, true)
    if old == nil then
        fail(self.where .. " has no row " .. pk)
    end
    local r = table.clone(old)
    r.id = nil
    set_fields(self, r, values or {})
    for _, k in clear or {} do
        set_fields(self, r, { [k] = true })
        r[k] = nil
    end
    return store(self, pk, old, r)
end

-- Removes the row, its index entries and its edges. Answers false if there
-- was no row.
function Table:delete(pk: number): boolean
    check_pk(self, pk)
    local old = read(self, pk, true)
    if old == nil then
        return false
    end
    for _, ix in self.t.indexes do
        local key = lay.entry(self.t, ix, old, pk)
        if key then
            barch.store.remove(key)
        end
    end
    unlink_all(self, pk)
    barch.store.remove(lay.row(self.t, pk))
    return true
end

-- queries ----------------------------------------------------------------------

local Query = {}
Query.__index = function(_, k)
    local m = Query[k]
    if m ~= nil or type(k) ~= "string" or #k < 6 or string.sub(k, 1, 5) ~= "query" then
        return m
    end
    -- queryPosts() follows the edge posts
    local name = string.lower(string.sub(k, 6, 6)) .. string.sub(k, 7)
    return function(self)
        return self:follow(name)
    end
end

local RANGE = { ["<"] = true, ["<="] = true, [">"] = true, [">="] = true }
local OPS = { ["="] = true, ["~="] = true, ["<"] = true, ["<="] = true, [">"] = true,
              [">="] = true }
local PRIMARY = { name = "id", on = { "id" }, unique = true, primary = true }

local function kind_of(tbl: any, field: string): string
    if field == "id" then
        return "int"
    end
    local f = tbl.byName[field]
    if f == nil then
        fail(tbl.where .. " has no field " .. tostring(field))
    end
    return f.kind
end

local function fits(kind: string, v: any): boolean
    if kind == "int" or kind == "float" then
        return type(v) == "number" and v == v
    end
    return type(v) == (kind == "string" and "string" or "boolean")
end

-- Starts a query over this table's rows.
function Table:query(): any
    return setmetatable({ tbl = self, conds = {}, preds = {}, skip = 0 }, Query)
end

-- Keeps the rows where `field op value` holds, op being one of = ~= < <= >
-- >=. A field without a value only matches `= nil`. where(fn) keeps the
-- rows for which fn(row) answers true.
function Query:where(field: any, op: string?, value: any): any
    if type(field) == "function" then
        self.preds[#self.preds + 1] = field
        return self
    end
    local tbl = self.tbl
    local kind = kind_of(tbl, field)
    if not OPS[op] then
        fail(tbl.where .. " query has no operator " .. tostring(op))
    end
    if RANGE[op] and kind == "bool" then
        fail(tbl.where .. " field " .. field .. " is bool, which has no order")
    end
    if (value ~= nil or RANGE[op]) and not fits(kind, value) then
        fail(tbl.where .. " field " .. field .. " is " .. kind .. ", got " .. tostring(value))
    end
    self.conds[#self.conds + 1] = { field = field, op = op, value = value, kind = kind }
    return self
end

-- Orders the rows by `field`, "asc" (the default) or "desc". Rows with the
-- same value come in id order, and a field without a value sorts first.
function Query:order(field: string, dir: string?): any
    kind_of(self.tbl, field)
    if dir ~= nil and dir ~= "asc" and dir ~= "desc" then
        fail(self.tbl.where .. " query order takes asc or desc, got " .. tostring(dir))
    end
    self.sortField, self.desc = field, dir == "desc"
    return self
end

local function count_arg(self: any, what: string, n: any): number
    if type(n) ~= "number" or n < 0 or n ~= math.floor(n) then
        fail(self.tbl.where .. " query " .. what .. " takes a whole number, got " .. tostring(n))
    end
    return n
end

function Query:limit(n: number): any
    self.lim = count_arg(self, "limit", n)
    return self
end

function Query:offset(n: number): any
    self.skip = count_arg(self, "offset", n)
    return self
end

-- Reads through the index named `name`, or "id" for the table itself.
function Query:using(name: string): any
    self.use = name
    return self
end

local function holds(c: any, v: any): boolean
    local w = c.value
    if c.op == "=" then
        return v == w
    elseif c.op == "~=" then
        return v ~= w
    elseif v == nil then
        return false
    elseif c.op == "<" then
        return v < w
    elseif c.op == "<=" then
        return v <= w
    elseif c.op == ">" then
        return v > w
    end
    return v >= w
end

local function matches(q: any, r: any): boolean
    for _, c in q.conds do
        if not holds(c, r[c.field]) then
            return false
        end
    end
    for _, fn in q.preds do
        if not fn(r) then
            return false
        end
    end
    return true
end

local function less(a: any, b: any): boolean
    if a == nil or b == nil then
        return a == nil and b ~= nil
    end
    if type(a) == "boolean" then
        return not a and b
    end
    return a < b
end

-- How to read q: which index, the key span, and whether the keys come in
-- the order q asks for.
local function plan(q: any): any
    local tbl, t = q.tbl, q.tbl.t
    if q.idset then
        local ordered = q.sortField == nil or q.sortField == "id"
        return { name = "edge " .. q.via .. (ordered and "" or " then sort"), ordered = ordered }
    end
    local eq, ranges = {}, {}
    for _, c in q.conds do
        if c.op == "=" and c.value ~= nil and (c.kind ~= "int" or c.value == math.floor(c.value)) then
            eq[c.field] = c.value
        elseif RANGE[c.op] then
            ranges[c.field] = ranges[c.field] or {}
            table.insert(ranges[c.field], c)
        end
    end
    local best, bestScore = nil, -1
    local sources = { PRIMARY }
    for _, ix in t.indexes do
        sources[#sources + 1] = ix
    end
    for _, ix in sources do
        if q.use == nil or q.use == ix.name then
            local values = {}
            for i, f in ix.on do
                if eq[f] == nil then
                    break
                end
                values[i] = eq[f]
            end
            local n = #values
            local point = ix.unique and n == #ix.on
            local next = ix.on[n + 1]
            local ordered = point or q.sortField == nil
                or (n == #ix.on and q.sortField == "id")
                or (not ix.unique and n + 1 == #ix.on and q.sortField == next)
                or (ix.primary and q.sortField == "id")
            -- a unique index leaves out rows with a nil in its fields
            local usable = ix.primary or point or not ix.unique
            local score = point and 1000 or n * 4 + (ranges[next] and 2 or 0) + (ordered and 1 or 0)
            if not usable then
                if q.use then
                    fail(tbl.where .. " index " .. ix.name .. " is unique, so a query using it"
                        .. " needs = on each of its fields")
                end
            elseif score > bestScore then
                best, bestScore = { ix = ix, values = values, next = next, ordered = ordered }, score
            end
        end
    end
    if best == nil then
        fail(tbl.where .. " has no index " .. tostring(q.use))
    end
    local ix = best.ix
    local prefix
    if ix.primary then
        prefix = best.values[1] and lay.row(t, best.values[1]) or lay.row(t)
    else
        prefix = lay.index(t, ix, best.values)
    end
    best.lo, best.hi = prefix, kc.after(prefix)
    local parts = { ix.name }
    if #best.values > 0 then
        parts[#parts + 1] = "= " .. table.concat(ix.on, ",", 1, #best.values)
    end
    local span = best.next and ranges[best.next]
    if span then
        local kind = kind_of(tbl, best.next)
        local lo, hi
        for _, c in span do
            local v = c.value
            if c.op == ">" or c.op == ">=" then
                v = kind == "int" and math.floor(v) or v
                lo = (lo == nil or v > lo) and v or lo
            else
                v = kind == "int" and math.ceil(v) or v
                hi = (hi == nil or v < hi) and v or hi
            end
        end
        -- the bounds may let in more keys than the filters keep; every row
        -- is checked against them
        if lo ~= nil and math.abs(lo) ~= math.huge then
            best.lo = prefix .. kc.encode(kind, lo)
        end
        if hi ~= nil and math.abs(hi) ~= math.huge then
            best.hi = kc.after(prefix .. kc.encode(kind, hi))
        end
        parts[#parts + 1] = "range " .. best.next
    end
    if not best.ordered then
        parts[#parts + 1] = "then sort"
    end
    best.name = table.concat(parts, " ")
    return best
end

-- The matching rows, in order, after offset and limit.
local function rows(q: any): { any }
    local tbl = q.tbl
    local p = plan(q)
    local want = q.lim and q.skip + q.lim
    local early = p.ordered and not q.desc and want ~= nil
    local out = {}
    local function consider(pk: number): boolean
        local r = read(tbl, pk)
        if r and matches(q, r) then
            out[#out + 1] = r
            return early and #out >= want
        end
        return false
    end
    if q.idset then
        for _, pk in q.idset do
            if consider(pk) then
                break
            end
        end
    elseif want ~= 0 then
        lay.scan(p.lo, p.hi, function(k)
            if p.ix.unique and not p.ix.primary then
                return consider(tonumber(barch.store.get(k)) :: number)
            end
            return consider((kc.decode(k, #k - 16)))
        end)
    end
    if not p.ordered then
        local f = q.sortField
        table.sort(out, function(a, b)
            if a[f] == b[f] then
                return a.id < b.id
            end
            return less(a[f], b[f])
        end)
    end
    if q.desc then
        local n = #out
        for i = 1, n // 2 do
            out[i], out[n + 1 - i] = out[n + 1 - i], out[i]
        end
    end
    if q.skip == 0 and (want == nil or #out <= want) then
        return out
    end
    return table.move(out, q.skip + 1, math.min(#out, want or #out), 1, {})
end

-- The rows the query matches.
function Query:all(): { any }
    return rows(self)
end

-- The first row the query matches, or nil.
function Query:first(): any
    local lim = self.lim
    self.lim = 1
    local r = rows(self)[1]
    self.lim = lim
    return r
end

-- The ids of the rows the query matches.
function Query:ids(): { number }
    local list = rows(self)
    for i, r in list do
        list[i] = r.id
    end
    return list
end

-- How many rows the query matches.
function Query:count(): number
    return #rows(self)
end

-- How the query reads: the index, the fields it matches with = and the
-- range field, and "then sort" when the rows are sorted after reading.
function Query:explain(): string
    return plan(self).name
end

-- A query over the rows that the matching rows link to through edge `name`.
function Query:follow(name: string): any
    local tbl = self.tbl
    local e = find_edge(tbl, name)
    local seen, list = {}, {}
    for _, pk in self:ids() do
        local prefix = e.dir == "to" and lay.edge(e.store, pk) or lay.edge_back(e.store, pk)
        lay.walk(prefix, function(k)
            local other = kc.decode(k, #k - 16)
            if not seen[other] then
                seen[other] = true
                list[#list + 1] = other
            end
        end)
    end
    table.sort(list)
    local q = tbl.peers[e.target]:query()
    q.idset, q.via = list, e.store
    return q
end

-- The tables of this space's schema, by name, for a transaction the caller
-- runs. Reading the catalog makes the transaction conflict with a migration
-- that commits before it does.
function client(pessimistic: boolean?): any
    local compiled = mig.load()
    if compiled == nil then
        fail("this space has no schema; run MIGRATE first")
    end
    local c = {}
    for _, t in compiled.tables do
        c[t.name] = bind(t, compiled.version, pessimistic)
    end
    for _, b in c do
        b.peers = c
        b.allEdges = compiled.edges
    end
    return setmetatable(c, {
        __index = function(_, name)
            fail("this space's schema has no table " .. tostring(name))
        end,
    })
end

-- Runs fn(c) in a transaction and answers what it answers.
function tx(fn: (any) -> any, pessimistic: boolean?): any
    return barch.tx.run(function()
        return fn(client(pessimistic))
    end, pessimistic == true)
end

local ROLLBACK = "CLIENT selftest rollback"

local function check(): string?
    local ent = require("ent.SCHEMA")
    if mig.load() ~= nil then
        return nil -- this space has a schema of its own; leave it alone
    end
    mig.apply(mig.plan(nil, ent.graph {
        ent.schema "T" {
            fields = { ent.field.string "k":unique(), ent.field.int "n":default(5) },
            indexes = { ent.index("n") },
            edges = { ent.edge.to "us" "U" },
        },
        ent.schema "U" {
            fields = { ent.field.int "v" },
            edges = { ent.edge.from "t" "T":ref "us":unique() },
        },
    }))
    local c = client(false)
    local a = c.T:create { k = "a" }
    local b = c.T:create { k = "b", n = 1 }
    if a.id ~= 1 or b.id ~= 2 or a.n ~= 5 then
        return "create"
    end
    if not pcall(c.T.create, c.T, { k = "a" }) then
        c.T:update(1, { k = "c" })
        if c.T:by("k", "a") ~= nil or c.T:by("k", "c").id ~= 1 or c.T:get(1).n ~= 5 then
            return "update"
        end
    else
        return "a second row with k=a"
    end
    if not c.T:delete(2) or c.T:delete(2) or c.T:by("k", "b") ~= nil then
        return "delete"
    end
    local t = mig.load().tables.t
    local entries = lay.walk(lay.index(t, t.indexes[1]), function() end)
        + lay.walk(lay.index(t, t.indexes[2]), function() end)
    if entries ~= 2 then
        return "index entries " .. entries
    end
    local u1 = c.U:create { v = 1, t = 1 }
    local u2 = c.U:create { v = 2, t = a }
    local got = c.T:query():where("k", "=", "c"):queryUs():order("v", "desc"):ids()
    if #got ~= 2 or got[1] ~= u2.id or got[2] ~= u1.id then
        return "edge query"
    end
    if c.T:query():where("n", ">=", 5):explain() ~= "by_n range n"
        or c.T:query():where("n", ">=", 5):count() ~= 1 then
        return "plan " .. c.T:query():where("n", ">=", 5):explain()
    end
    c.T:delete(1)
    if c.U:query():where("id", "=", u1.id):queryT():count() ~= 0 then
        return "edges left by delete"
    end
    return nil
end

function selftest(): (boolean, string?)
    local why
    local ok, err = pcall(barch.tx.run, function()
        why = check()
        error(ROLLBACK, 0)
    end)
    if ok or err ~= ROLLBACK then
        return false, tostring(err)
    end
    return why == nil, why
end

function call()
    local ok, why = selftest()
    return ok and "ok" or ("failed: " .. why)
end
