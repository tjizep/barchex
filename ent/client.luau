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
--       local u = c.User:create { email = "a@b", name = "ann" }  -- u.id, a uuid
--       c.User:get(u.id)                     -- the row, or nil
--       c.User:by("email", "a@b")            -- the row, through by_email
--       c.User:update(u.id, { name = "bo" }, { "age" })  -- sets name, clears age
--       c.User:delete(u.id)                  -- true, or false if it was gone
--
--       local p = c.Post:create { title = "hi", author = u }    -- links the edge
--       c.User:link("posts", u.id, p.id)     -- or unlink
--       c.User:query():where("name", "=", "ann")
--           :queryPosts():order("title", "desc"):limit(10):all()
--       c.User:query():hasPostsWith(function(q) q:where("title", "=", "hi") end)
--           :withPosts():all()             -- each u.posts holds u's posts
--   end)
--
-- ent.tx(fn, pessimistic) runs fn(c) in barch.tx.run, which retries on a
-- conflict. ent.open(app).tx(fn, pessimistic) does the same and also runs
-- the graph's function defaults, validate functions and hooks; the value
-- rules stored in the catalog apply either way. Inside a transaction the caller already runs, ent.client(p)
-- answers the same `c`. Each answers rows as tables of field values with
-- the row's `id`: a barch.uuid() string, or an integer for a table declared
-- with id = "int". A field the row lacks reads as its default.
--
-- Errors start with ENT, or ROWCODEC for a value of the wrong kind or a
-- missing field that is not optional.

local rc = require("ent.ROWCODEC")
local lay = require("ent.LAYOUT")
local kc = require("ent.KEYCODEC")
local mig = require("ent.MIGRATE")
local SCHEMA = require("ent.SCHEMA")

local function fail(msg: string)
    error("ENT " .. msg, 0)
end

local Table = {}
Table.__index = Table

local NO_HOOKS = { create = {}, update = {}, delete = {} }

-- `decl` is the table as ent.schema declared it, for the parts that stay in
-- code: function defaults, validate functions and hooks. nil leaves them out.
local function bind(t: any, version: number, pessimistic: boolean?, decl: any?): any
    local byName, edgeByName, code = {}, {}, {}
    for _, f in t.fields do
        byName[f.name] = f
    end
    for _, e in t.edges do
        edgeByName[e.name] = e
    end
    for _, f in decl and decl.fields or {} do
        if byName[f.name] == nil then
            fail("table " .. t.name .. " field " .. f.name .. " is declared, and this"
                .. " space's catalog lacks it; run MIGRATE")
        end
        code[f.name] = f.code
    end
    return setmetatable({
        t = t, fields = rc.fields(t.fields), byName = byName, edgeByName = edgeByName,
        code = code, hooks = decl and decl.hooks or NO_HOOKS,
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
    if lay.id_kind(self.t) == "uuid" then
        if not kc.is_uuid(pk) then
            fail(self.where .. " wants a uuid id, got " .. tostring(pk))
        end
    elseif type(pk) ~= "number" or pk < 1 or pk ~= math.floor(pk) then
        fail(self.where .. " wants an integer id, got " .. tostring(pk))
    end
end

-- The row at pk, filled with defaults, or nil. A pessimistic caller about
-- to write the row reads it with the exclusive lock.
local function read(self: any, pk: any, exclusive: boolean?): any
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

-- Checks row `r` before it is stored over `old` (nil for a new row): every
-- key is a field, an immutable field keeps its value, and each value that
-- changed keeps its field's rules and validate functions.
local function check_row(self: any, r: any, old: any)
    for k in r do
        if self.byName[k] == nil then
            fail(self.where .. " has no field " .. tostring(k))
        end
    end
    for _, f in self.t.fields do
        local v = r[f.name]
        if old == nil or v ~= old[f.name] then
            local where = self.where .. " field " .. f.name
            if old and f.immutable then
                fail(where .. " is immutable, so update cannot change it")
            end
            if v ~= nil then
                local why = SCHEMA.broken(f, v)
                if why then
                    fail(where .. " " .. why)
                end
                for _, fn in self.code[f.name] and self.code[f.name].validate or {} do
                    local ok = fn(v)
                    if ok == false or type(ok) == "string" then
                        fail(where .. " refuses " .. string.format("%q", tostring(v))
                            .. (type(ok) == "string" and ": " .. ok or ""))
                    end
                end
            end
        end
    end
end

local function run_hooks(self: any, op: string, ...: any)
    for _, fn in self.hooks[op] do
        fn(self.peers, ...)
    end
end

-- Raises an error if another row holds the unique entry `key`.
local function check_free(self: any, ix: any, key: string, pk: any, r: any)
    local other = get(self, key, true)
    if other ~= nil and lay.unique_pk(self.t, other) ~= pk then
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
local function store(self: any, pk: any, old: any, r: any, counter: string?): any
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
local function ends(e: any, pk: any, other: any): (any, any)
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
local function ids_in(self: any, e: any, v: any): { any }
    if type(v) == "number" or type(v) == "string" or (type(v) == "table" and v.id ~= nil) then
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

local function exists(self: any, pk: any): boolean
    check_pk(self, pk)
    return barch.store.exists(lay.row(self.t, pk))
end

local function first_key(prefix: string): string?
    return barch.store.range(prefix, kc.after(prefix), 1)[1]
end

-- The key prefix of the edges of edge store `s` at row pk: its forward edges
-- when `forward`, else its reverse edges.
local function edge_prefix(s: any, forward: boolean, pk: any): string
    return forward and lay.edge(s, pk) or lay.edge_back(s, pk)
end

-- Calls each(other) for the rows that row pk links to through edge store
-- `s`, in id order, until `each` answers true. Answers whether it did.
local function linked(s: any, forward: boolean, pk: any, each: (any) -> boolean?,
                      page: number?): boolean
    local prefix = edge_prefix(s, forward, pk)
    local pick = forward and lay.edge_to or lay.edge_from
    return lay.scan(prefix, kc.after(prefix), function(k)
        return each(pick(s, k))
    end, page)
end

-- Raises an error unless `from` -> `to` can be added to edge `e`.
local function check_link(self: any, e: any, pk: any, other: any)
    local target = self.peers[e.target]
    if not exists(target, other) then
        fail(target.where .. " has no row " .. other)
    end
    local s = self.allEdges[e.store]
    local from, to = ends(e, pk, other)
    local k = s.unique and first_key(lay.edge(s, from))
    if k and k ~= lay.edge(s, from, to) then
        fail("edge " .. e.store .. " allows one " .. s.to .. " per " .. s.from .. ", and "
            .. s.from .. " row " .. from .. " has one")
    end
    k = s.inverseUnique and first_key(lay.edge_back(s, to))
    if k and k ~= lay.edge_back(s, to, from) then
        fail("edge " .. e.store .. " allows one " .. s.from .. " per " .. s.to .. ", and "
            .. s.to .. " row " .. to .. " has one")
    end
end

local function write_link(self: any, e: any, pk: any, other: any)
    local s = self.allEdges[e.store]
    local from, to = ends(e, pk, other)
    barch.store.set(lay.edge(s, from, to), "")
    barch.store.set(lay.edge_back(s, to, from), "")
end

-- Links row pk to row `other` through edge `name`. Linking twice is
-- harmless.
function Table:link(name: string, pk: any, other: any)
    local e = find_edge(self, name)
    if not exists(self, pk) then
        fail(self.where .. " has no row " .. pk)
    end
    check_link(self, e, pk, other)
    write_link(self, e, pk, other)
end

-- Removes the link from row pk to row `other`. Answers whether there was one.
function Table:unlink(name: string, pk: any, other: any): boolean
    local e = find_edge(self, name)
    local s = self.allEdges[e.store]
    check_pk(self, pk)
    check_pk(self.peers[e.target], other)
    local from, to = ends(e, pk, other)
    local key = lay.edge(s, from, to)
    if not barch.store.exists(key) then
        return false
    end
    barch.store.remove(key)
    barch.store.remove(lay.edge_back(s, to, from))
    return true
end

-- Removes every edge into or out of row pk, including edges declared only
-- by the table at the other end.
local function unlink_all(self: any, pk: any)
    local name = self.t.name
    for _, s in self.allEdges do
        if s.from == name then
            lay.walk(lay.edge(s, pk), function(k)
                local to = lay.edge_to(s, k)
                barch.store.remove(k)
                barch.store.remove(lay.edge_back(s, to, pk))
            end)
        end
        if s.to == name then
            lay.walk(lay.edge_back(s, pk), function(k)
                local from = lay.edge_from(s, k)
                barch.store.remove(k)
                barch.store.remove(lay.edge(s, from, pk))
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
    for name, code in self.code do
        if r[name] == nil and code.default then
            r[name] = code.default()
        end
    end
    lay.fill(self.t, r)
    run_hooks(self, "create", r)
    check_row(self, r, nil)
    -- a uuid needs no shared key, so creates in one table do not conflict
    local counter, pk
    if lay.id_kind(self.t) == "uuid" then
        pk = barch.uuid()
    else
        counter = lay.counter(self.t)
        pk = (tonumber(get(self, counter, true)) or 0) + 1
    end
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
            write_link(self, l[1], pk, other)
        end
    end
    return r
end

-- The row with this id, or nil.
function Table:get(pk: any): any
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
    return pk and read(self, lay.unique_pk(self.t, pk))
end

-- Sets the fields in `values` and clears the fields named in `clear`, then
-- answers the stored row. Raises an error if there is no row with this id.
function Table:update(pk: any, values: { [string]: any }?, clear: { string }?): any
    check_pk(self, pk)
    local old = read(self, pk, true)
    if old == nil then
        fail(self.where .. " has no row " .. pk)
    end
    local r = table.clone(old)
    r.id = nil
    values = values or {}
    set_fields(self, r, values)
    local cleared = {}
    for _, k in clear or {} do
        set_fields(self, r, { [k] = true })
        r[k] = nil
        cleared[k] = true
    end
    for name, code in self.code do
        if code.update and values[name] == nil and not cleared[name] then
            r[name] = code.update()
        end
    end
    run_hooks(self, "update", pk, r, table.clone(old))
    check_row(self, r, old)
    return store(self, pk, old, r)
end

-- Removes the row, its index entries and its edges. Answers false if there
-- was no row.
function Table:delete(pk: any): boolean
    check_pk(self, pk)
    local old = read(self, pk, true)
    if old == nil then
        return false
    end
    run_hooks(self, "delete", pk, table.clone(old))
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

local function edge_name(rest: string): string
    return string.lower(string.sub(rest, 1, 1)) .. string.sub(rest, 2)
end

-- queryPosts(), hasPosts(), hasPostsWith(fn) and withPosts(fn) name the edge
-- posts in the method name.
Query.__index = function(_, k)
    local m = Query[k]
    if m ~= nil or type(k) ~= "string" then
        return m
    end
    local rest = string.match(k, "^query(%u.*)$")
    if rest then
        return function(self)
            return self:follow(edge_name(rest))
        end
    end
    rest = string.match(k, "^has(%u.*)With$")
    if rest then
        return function(self, fn)
            if type(fn) ~= "function" then
                fail(self.tbl.where .. " query " .. k .. " takes a function, got " .. tostring(fn))
            end
            return self:has(edge_name(rest), fn)
        end
    end
    rest = string.match(k, "^has(%u.*)$")
    if rest then
        return function(self)
            return self:has(edge_name(rest))
        end
    end
    rest = string.match(k, "^with(%u.*)$")
    if rest then
        return function(self, fn)
            return self:with(edge_name(rest), fn)
        end
    end
    return nil
end

local RANGE = { ["<"] = true, ["<="] = true, [">"] = true, [">="] = true }
local OPS = { ["="] = true, ["~="] = true, ["<"] = true, ["<="] = true, [">"] = true,
              [">="] = true }
local PRIMARY = { name = "id", on = { "id" }, unique = true, primary = true }

local function kind_of(tbl: any, field: string): string
    if field == "id" then
        return lay.id_kind(tbl.t)
    end
    local f = tbl.byName[field]
    if f == nil then
        fail(tbl.where .. " has no field " .. tostring(field))
    end
    return f.kind
end

local function fits(kind: string, v: any): boolean
    if kind == "int" or kind == "float" or kind == "time" then
        return type(v) == "number" and v == v
    end
    if kind == "uuid" then
        return kc.is_uuid(v)
    end
    return type(v) == (kind == "string" and "string" or "boolean")
end

-- Starts a query over this table's rows.
function Table:query(): any
    return setmetatable({ tbl = self, conds = {}, preds = {}, checks = {}, loads = {}, skip = 0 },
        Query)
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

local function less(a: any, b: any): boolean
    if a == nil or b == nil then
        return a == nil and b ~= nil
    end
    if type(a) == "boolean" then
        return not a and b
    end
    return a < b
end

-- The order a cursor follows: the sort field, or id, and its direction.
local function cursor_order(q: any): (string, string)
    return q.sortField or "id", q.desc and "desc" or "asc"
end

-- A cursor for the rows after `row` in this query's order. Pass it to
-- after() on the same query to read the next page.
function Query:cursor(row: any): string
    local tbl = self.tbl
    if type(row) ~= "table" or row.id == nil then
        fail(tbl.where .. " query cursor takes a row, got " .. tostring(row))
    end
    local field, dir = cursor_order(self)
    local raw = kc.pack({ "string", "string", kind_of(tbl, field), lay.id_kind(tbl.t) },
                        { field, dir, row[field], row.id })
    return (string.gsub(raw, ".", function(ch)
        return string.format("%02x", string.byte(ch))
    end))
end

-- Keeps the rows after the cursor's row in the query's order, which is id
-- order when the query sets none. The cursor comes from cursor().
function Query:after(cursor: string): any
    local tbl = self.tbl
    local ok, values = false, nil
    if type(cursor) == "string" and #cursor % 2 == 0 and not string.find(cursor, "[^0-9a-f]") then
        local raw = string.gsub(cursor, "..", function(h)
            return string.char(tonumber(h, 16) :: number)
        end)
        ok, values = pcall(kc.unpack, raw, 4)
    end
    if not ok or type(values[1]) ~= "string" or type(values[2]) ~= "string" then
        fail(tbl.where .. " query after takes a cursor from cursor(), got " .. tostring(cursor))
    end
    self.cur = { field = values[1], dir = values[2], value = values[3], id = values[4] }
    return self
end

-- Whether row r comes after the cursor in q's order.
local function beyond(q: any, r: any): boolean
    local c = q.cur
    local v = r[c.field]
    if v ~= c.value then
        if q.desc then
            return less(v, c.value)
        end
        return less(c.value, v)
    end
    if q.desc then
        return r.id < c.id
    end
    return r.id > c.id
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

local matches

-- Whether row pk has a link through check h, and when h has a filter, one
-- to a row that matches it.
local function has_link(q: any, h: any, pk: any): boolean
    if h.set then
        return h.set[pk] == true
    end
    local s = q.tbl.allEdges[h.e.store]
    local forward = h.e.dir == "to"
    if h.sub == nil then
        return first_key(edge_prefix(s, forward, pk)) ~= nil
    end
    local target = q.tbl.peers[h.e.target]
    return linked(s, forward, pk, function(other)
        local m = h.memo[other]
        if m == nil then
            local r = read(target, other)
            m = r ~= nil and matches(h.sub, r)
            h.memo[other] = m
        end
        return m
    end, 100)
end

function matches(q: any, r: any): boolean
    for _, c in q.conds do
        if not holds(c, r[c.field]) then
            return false
        end
    end
    if q.cur and not beyond(q, r) then
        return false
    end
    for _, h in q.checks do
        if not has_link(q, h, r.id) then
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

-- How to read q: which index, the key span, and whether the keys come in
-- the order q asks for.
local function index_plan(q: any): any
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
    best.full = #best.values == 0
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
        if lo ~= nil and (type(lo) ~= "number" or math.abs(lo) ~= math.huge) then
            best.lo = prefix .. kc.encode(kind, lo)
            best.full = false
        end
        if hi ~= nil and (type(hi) ~= "number" or math.abs(hi) ~= math.huge) then
            best.hi = kc.after(prefix .. kc.encode(kind, hi))
            best.full = false
        end
        parts[#parts + 1] = "range " .. best.next
    end
    if not best.ordered then
        parts[#parts + 1] = "then sort"
    end
    best.name = table.concat(parts, " ")
    return best
end

-- index_plan, plus how each has() check runs. A check whose filter reads
-- part of its table drives: it reads the matching rows first and collects
-- the rows that link to them. Other checks probe each candidate row's
-- edges. When q itself would read its whole table, the first driving check
-- supplies its rows.
-- Validates q's cursor and, when the read comes in cursor order, starts it
-- at the cursor's key.
local function from_cursor(q: any, p: any, parts: { string })
    local c = q.cur
    if c == nil then
        return
    end
    local tbl = q.tbl
    local field, dir = cursor_order(q)
    if c.field ~= field or c.dir ~= dir then
        fail(tbl.where .. " query cursor follows order " .. c.field .. " " .. c.dir
            .. ", and the query orders by " .. field .. " " .. dir)
    end
    local key
    if p.ordered and p.ix and not p.via then
        if p.ix.primary then
            key = lay.row(tbl.t, c.id)
        elseif not p.ix.unique then
            local r = { [c.field] = c.value }
            for i, v in p.values do
                r[p.ix.on[i]] = v
            end
            key = lay.entry(tbl.t, p.ix, r, c.id)
        end
    end
    if key == nil then
        parts[#parts + 1] = "after cursor"
        return
    end
    if q.desc then
        if p.hi == nil or key < p.hi then
            p.hi = key
        end
    else
        local lo = kc.after(key) :: string
        if lo > p.lo then
            p.lo = lo
        end
    end
    parts[1] = parts[1] .. " from cursor"
end

local function plan(q: any): any
    if q.cur then
        -- a cursor pages in id order when the query sets no order
        q.sortField = q.sortField or "id"
    end
    local p = index_plan(q)
    local parts = { p.name }
    for _, h in q.checks do
        local sp = h.sub and plan(h.sub)
        h.drive = sp ~= nil and not sp.full
        local part = "has " .. h.e.name .. (h.drive and " from (" .. sp.name .. ")" or "")
        if h.drive and p.full and p.via == nil then
            p.via, p.full = h, false
            p.ordered = q.sortField == nil or q.sortField == "id"
            parts[1] = part .. (p.ordered and "" or " then sort")
        else
            parts[#parts + 1] = part
        end
    end
    from_cursor(q, p, parts)
    p.name = table.concat(parts, ", ")
    return p
end

-- Resets the has() checks of q for a run, and reads the rows of each
-- driving one.
local function prepare(q: any)
    for _, h in q.checks do
        h.memo, h.set = {}, nil
        if h.drive then
            local set = {}
            local s = q.tbl.allEdges[h.e.store]
            for _, other in h.sub:ids() do
                linked(s, h.e.dir ~= "to", other, function(pk)
                    set[pk] = true
                    return false
                end)
            end
            h.set = set
        elseif h.sub then
            prepare(h.sub)
        end
    end
end

-- Fills each row's eager-loaded edges.
local function load(q: any, list: { any })
    local tbl = q.tbl
    for _, w in q.loads do
        local s = tbl.allEdges[w.e.store]
        local forward = w.e.dir == "to"
        local single = one(tbl, w.e)
        local target = tbl.peers[w.e.target]
        for _, r in list do
            local ids = {}
            linked(s, forward, r.id, function(other)
                ids[#ids + 1] = other
                return false
            end)
            local sub = target:query()
            sub.idset, sub.via = ids, w.e.store
            if w.fn then
                sub = w.fn(sub) or sub
            end
            if single then
                r[w.e.name] = sub:first()
            else
                r[w.e.name] = sub:all()
            end
        end
    end
end

-- The matching rows, in order, after offset and limit, with their eager
-- loaded edges when `loading`.
local function rows(q: any, loading: boolean?): { any }
    local tbl = q.tbl
    local p = plan(q)
    prepare(q)
    local idset = q.idset
    if p.via then
        idset = {}
        for pk in p.via.set do
            idset[#idset + 1] = pk
        end
        table.sort(idset)
    end
    local want = q.lim and q.skip + q.lim
    local early = p.ordered and want ~= nil
    -- an ordered read in desc order reads from the end, so it can stop early
    local back = p.ordered and q.desc
    local out = {}
    local function consider(pk: number): boolean
        local r = read(tbl, pk)
        if r and matches(q, r) then
            out[#out + 1] = r
            return early and #out >= want
        end
        return false
    end
    if idset then
        local n = #idset
        for i = 1, n do
            if consider(idset[back and n + 1 - i or i]) then
                break
            end
        end
    elseif want ~= 0 then
        local scan = back and lay.scan_back or lay.scan
        scan(p.lo, p.hi, function(k)
            if p.ix.primary then
                return consider(lay.row_pk(tbl.t, k))
            end
            return consider(lay.pk_of(tbl.t, p.ix, k, p.ix.unique and barch.store.get(k) or nil))
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
    if q.desc and not back then
        local n = #out
        for i = 1, n // 2 do
            out[i], out[n + 1 - i] = out[n + 1 - i], out[i]
        end
    end
    if q.skip ~= 0 or (want ~= nil and #out > want) then
        out = table.move(out, q.skip + 1, math.min(#out, want or #out), 1, {})
    end
    if loading then
        load(q, out)
    end
    return out
end

-- The rows the query matches.
function Query:all(): { any }
    return rows(self, true)
end

-- The first row the query matches, or nil.
function Query:first(): any
    local lim = self.lim
    self.lim = 1
    local r = rows(self, true)[1]
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
    local s = tbl.allEdges[e.store]
    local seen, list = {}, {}
    for _, pk in self:ids() do
        linked(s, e.dir == "to", pk, function(other)
            if not seen[other] then
                seen[other] = true
                list[#list + 1] = other
            end
            return false
        end)
    end
    table.sort(list)
    local q = tbl.peers[e.target]:query()
    q.idset, q.via = list, e.store
    return q
end

-- Keeps the rows that link to at least one row through edge `name`. With
-- fn, the linked row must also match the query fn(q) builds, from where,
-- has and using calls; fn may answer q or nothing.
function Query:has(name: string, fn: ((any) -> any)?): any
    local tbl = self.tbl
    local e = find_edge(tbl, name)
    local sub
    if fn ~= nil then
        if type(fn) ~= "function" then
            fail(tbl.where .. " query has takes a function, got " .. tostring(fn))
        end
        sub = tbl.peers[e.target]:query()
        sub = fn(sub) or sub
        if sub.sortField or sub.lim or sub.skip ~= 0 or #sub.loads > 0 or sub.cur then
            fail(tbl.where .. " query has " .. name .. " filters rows with where, has and"
                .. " using; order, limit, offset, after and with have no effect there")
        end
    end
    self.checks[#self.checks + 1] = { e = e, sub = sub }
    return self
end

-- Loads the rows each answered row links to through edge `name` into
-- row[name]: a row or nil for an edge with one row at its far end, else a
-- list. fn(q) may filter, order and limit each row's list.
function Query:with(name: string, fn: ((any) -> any)?): any
    local e = find_edge(self.tbl, name)
    if fn ~= nil and type(fn) ~= "function" then
        fail(self.tbl.where .. " query with takes a function, got " .. tostring(fn))
    end
    self.loads[#self.loads + 1] = { e = e, fn = fn }
    return self
end

-- The tables of this space's schema, by name, for a transaction the caller
-- runs. Reading the catalog makes the transaction conflict with a migration
-- that commits before it does.
function client(pessimistic: boolean?, app: any?): any
    local compiled = mig.load()
    if compiled == nil then
        fail("this space has no schema; run MIGRATE first")
    end
    local c = {}
    for _, t in compiled.tables do
        c[t.name] = bind(t, compiled.version, pessimistic, app and app.tables[t.name])
    end
    for name in app and app.tables or {} do
        if c[name] == nil then
            fail("table " .. name .. " is declared, and this space's catalog lacks it;"
                .. " run MIGRATE")
        end
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
function tx(fn: (any) -> any, pessimistic: boolean?, app: any?): any
    return barch.tx.run(function()
        return fn(client(pessimistic, app))
    end, pessimistic == true)
end

-- A client bound to `app`, the graph the space was migrated with, so its
-- function defaults, validate functions and hooks run: db.tx(fn,
-- pessimistic) and db.client(pessimistic) work as tx and client do.
function open(app: any): any
    if type(app) ~= "table" or type(app.tables) ~= "table" then
        fail("open takes the graph from ent.graph")
    end
    return {
        tx = function(fn: (any) -> any, pessimistic: boolean?): any
            return tx(fn, pessimistic, app)
        end,
        client = function(pessimistic: boolean?): any
            return client(pessimistic, app)
        end,
    }
end

local ROLLBACK = "CLIENT selftest rollback"

local function check(): string?
    local ent = require("ent.SCHEMA")
    if mig.load() ~= nil then
        return nil -- this space has a schema of its own; leave it alone
    end
    mig.apply(mig.plan(nil, ent.graph {
        ent.schema "T" {
            id = "int",
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
    if not kc.is_uuid(u1.id) or not (u1.id < u2.id) or c.U:get(u2.id).v ~= 2 then
        return "uuid ids"
    end
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
