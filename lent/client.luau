-- Creates, reads, updates, deletes and queries the rows of the tables MIGRATE
-- put in a space, with their indexes and edges, in the caller's transaction.
--
-- Required, not called: `local lent = require("lent.CLIENT")`. A function key
-- has to define call(), so this one answers a self-check, which migrates and
-- writes rows inside a transaction it then rolls back:
--
--   lent.CLIENT              -> "ok" or which check failed
--
-- From the application's space, after MIGRATE:
--
--   lent.tx(function(c)
--       local u = c.User:create { email = "a@b", name = "ann" }  -- u.id, a uuid
--       c.User:get(u.id)                     -- the row, or nil
--       c.User:by("email", "a@b")            -- the row, through by_email
--       c.User:update(u.id, { name = "bo" }, { "age" })  -- sets name, clears age
--       c.User:delete(u.id)                  -- true, or false if it was gone
--       c.User:createMany { { email = "c@d", name = "cy" },
--                           { email = "e@f", name = "eve" } }
--       local row, created = c.User:upsert("email", { email = "a@b", name = "al" })
--
--       local p = c.Post:create { title = "hi", author = u }    -- links the edge
--       c.User:link("posts", u.id, p.id)     -- or unlink
--       c.User:link("likes", u.id, p.id, { weight = 3 })  -- an edge with fields
--       c.User:edge("likes", u.id, p.id)     -- the link's values, or nil
--       c.User:query():where("name", "=", "ann")
--           :queryPosts():order("title", "desc"):limit(10):all()
--       c.User:query():hasPostsWith(function(q) q:where("title", "=", "hi") end)
--           :withPosts():all()             -- each u.posts holds u's posts
--       c.Post:query():follow("author.posts"):all()  -- edge after edge
--       c.Post:query():sum("stars")        -- also min and max
--       c.Post:query():groupBy("author"):aggregate {
--           posts = { fn = "count" }, stars = { fn = "sum", field = "stars" } }
--       c.Post:query():aggregate {      -- or over a value worked out per row
--           words = { fn = "sum", value = function(p) return #p.body end } }
--   end)
--
-- lent.tx(fn, pessimistic) runs fn(c) in barch.tx.run, which retries on a
-- conflict. lent.open(app).tx(fn, pessimistic) does the same and also runs
-- the graph's function defaults, validate functions and hooks; the value
-- rules stored in the catalog apply either way. Inside a transaction the caller already runs, lent.client(p)
-- answers the same `c`. Each answers rows as tables of field values with
-- the row's `id`: a barch.uuid() string, or an integer for a table declared
-- with id = "int". A field the row lacks reads as its default.
--
-- Errors start with LENT, or ROWCODEC for a value of the wrong kind or a
-- missing field that is not optional.

local rc = require("lent.ROWCODEC")
local lay = require("lent.LAYOUT")
local kc = require("lent.KEYCODEC")
local mig = require("lent.MIGRATE")
local SCHEMA = require("lent.SCHEMA")
local VALUES = require("lent.VALUES")

local function fail(msg: string)
    error("LENT " .. msg, 0)
end

local Table = {}
Table.__index = Table

local NO_HOOKS = { create = {}, update = {}, delete = {} }

-- `decl` is the table as lent.schema declared it, for the parts that stay in
-- code: function defaults, validate functions, hooks and computed fields.
-- nil leaves them out.
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
        if f.computed ~= byName[f.name].computed then
            local function rev(n: any): string
                return n and "stored revision " .. n or "no stored revision"
            end
            fail("table " .. t.name .. " field " .. f.name .. " is declared with "
                .. rev(f.computed) .. ", and this space's catalog has "
                .. rev(byName[f.name].computed) .. "; run MIGRATE")
        end
        code[f.name] = f.code
    end
    -- stored computed fields, in catalog order
    local stored, storedByName = {}, {}
    for _, f in t.fields do
        if f.computed then
            stored[#stored + 1] = f
            storedByName[f.name] = f
        end
    end
    local computed = decl and decl.computed or {}
    local computedByName = {}
    for _, f in computed do
        computedByName[f.name] = f
    end
    return setmetatable({
        t = t, fields = rc.fields(t.fields), byName = byName, edgeByName = edgeByName,
        code = code, hooks = decl and decl.hooks or NO_HOOKS,
        computed = computed, computedByName = computedByName,
        stored = stored, storedByName = storedByName,
        version = version, lock = pessimistic == true, where = "table " .. t.name,
    }, Table)
end

local function get(self: any, key: string, exclusive: boolean?): string?
    if exclusive and self.lock then
        return barch.store.get(key, true)
    end
    return barch.store.get(key)
end

local function writable(self: any)
    if self.dropping then
        fail(self.where .. " indexes are being replaced; resume MIGRATE before writing rows")
    end
end

local function ready(self: any, ix: any)
    if ix.state == "building" then
        fail(self.where .. " index " .. ix.name .. " is building; run MIGRATE until it completes")
    end
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

local function fits_kind(f: any, v: any): boolean
    if f.kind == "int" then
        return type(v) == "number" and v == math.floor(v)
    elseif f.kind == "float" then
        return type(v) == "number" and v == v
    elseif f.kind == "bool" then
        return type(v) == "boolean"
    elseif f.kind == "time" or f.kind == "enum" or f.kind == "json" then
        return SCHEMA.broken(f, v) == nil
    end
    return type(v) == "string"
end

-- Sets stored computed field f of row r to its function's value.
local function compute_stored(self: any, f: any, r: any)
    local code = self.code[f.name]
    if code == nil or code.computed == nil then
        fail(self.where .. " field " .. f.name .. " is computed and stored, so writing"
            .. " rows needs its function; open the client with lent.open(app)")
    end
    local v = code.computed(table.clone(r))
    local why = SCHEMA.computed_broken(f, v)
    if why then
        fail(self.where .. " field " .. f.name .. " " .. why)
    end
    r[f.name] = v
end

-- Sets each computed field of row r to fn(r), in declaration order, so a
-- computed field sees the ones declared before it. A stored computed field
-- that MIGRATE has not yet filled is computed here too.
local function compute(self: any, r: any): any
    for _, f in self.stored do
        if f.state == "filling" and self.code[f.name] then
            local id = r.id
            r.id = nil
            compute_stored(self, f, r)
            r.id = id
        end
    end
    for _, f in self.computed do
        local v = f.fn(r)
        if v ~= nil and not fits_kind(f, v) then
            fail(self.where .. " field " .. f.name .. " is a computed " .. f.kind
                .. ", and its function answered " .. tostring(v))
        end
        r[f.name] = v
    end
    return r
end

-- The row at pk, filled with defaults and computed fields, or nil. A pessimistic caller about
-- to write the row reads it with the exclusive lock.
local function read(self: any, pk: any, exclusive: boolean?): any
    local v = get(self, lay.row(self.t, pk), exclusive)
    if v == nil then
        return nil
    end
    local r = lay.fill(self.t, (rc.decode(self.fields, v)))
    r.id = pk
    return compute(self, r)
end

local function no_field(self: any, k: any)
    if self.computedByName[k] or self.storedByName[k] then
        fail(self.where .. " field " .. k .. " is computed, so a row cannot set it")
    end
    if self.byName[k] == nil then
        fail(self.where .. " has no field " .. tostring(k))
    end
end

-- Answers edge `e`, raising an error for an edge.through, whose links are
-- the links of the edges it follows.
local function linkable(self: any, e: any): any
    if e.dir == "through" then
        fail(self.where .. " edge " .. e.name .. " goes through " .. table.concat(e.via, ".")
            .. ", so its links change through those edges")
    end
    return e
end

local function set_fields(self: any, r: any, values: any)
    for k, v in values do
        if k == "id" then
            fail(self.where .. " gives out ids itself, so a row cannot set id")
        end
        if self.edgeByName[k] then
            linkable(self, self.edgeByName[k])
            fail(self.where .. " edge " .. k .. " changes with link and unlink")
        end
        no_field(self, k)
        r[k] = v
    end
end

local function clone_row(self: any, row: any): any
    local copy = table.clone(row)
    for _, f in self.t.fields do
        if f.kind == "json" and copy[f.name] ~= nil then
            local ok, value = pcall(VALUES.copy_json, copy[f.name])
            if not ok then fail(self.where .. " field " .. f.name .. " wants JSON: " .. tostring(value)) end
            copy[f.name] = value
        end
    end
    return copy
end

local function same_value(f: any, a: any, b: any): boolean
    if f.kind == "json" then return VALUES.equal_json(a, b) end
    return a == b
end

local function describe(f: any, v: any): string
    if f.kind == "bytes" and type(v) == "string" then return "0x" .. VALUES.hex(v) end
    if f.kind == "json" then return VALUES.json(v) end
    return string.format("%q", tostring(v))
end

-- Checks row `r` before it is stored over `old` (nil for a new row): every
-- key is a field, an immutable field keeps its value, and each value that
-- changed keeps its field's rules and validate functions.
local function check_row(self: any, r: any, old: any)
    for k in r do
        if not self.storedByName[k] then
            no_field(self, k)
        end
    end
    for _, f in self.t.fields do
        local v = r[f.name]
        if f.kind == "json" and v ~= nil then
            local why = SCHEMA.broken(f, v)
            if why then fail(self.where .. " field " .. f.name .. " " .. why) end
        end
        if old == nil or not same_value(f, v, old[f.name]) then
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
                        fail(where .. " refuses " .. describe(f, v)
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

local function duplicate(self: any, ix: any, other: any, r: any)
    local parts = {}
    for i, f in ix.on do
        local value = self.byName[f].kind == "bytes" and describe(self.byName[f], r[f]) or tostring(r[f])
        parts[i] = f .. "=" .. value
    end
    fail(self.where .. " index " .. ix.name .. " is unique, and row " .. other
        .. " already has " .. table.concat(parts, " "))
end

-- A building unique index also checks rows its build has not reached yet.
local function check_free(self: any, ix: any, key: string, pk: any, r: any)
    local other = get(self, key, true)
    if other ~= nil and lay.unique_pk(self.t, other) ~= pk then
        duplicate(self, ix, other, r)
    end
    if ix.state == "building" then
        lay.walk(lay.row(self.t), function(k)
            local otherPk = lay.row_pk(self.t, k)
            if otherPk ~= pk then
                local row = read(self, otherPk)
                if row and lay.entry(self.t, ix, row, otherPk) == key then
                    duplicate(self, ix, tostring(otherPk), r)
                end
            end
        end)
    end
end

-- Pre-existing duplicates can share a key while a unique build is pending.
local function owns_entry(self: any, ix: any, key: string, pk: any): boolean
    return not ix.unique or ix.state ~= "building" or get(self, key, true) == tostring(pk)
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
            if was and not owns_entry(self, ix, was, pk) then was = nil end
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
    if e.dir == "through" then
        return e.unique == true
    end
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

-- The stored edges that edge `e` of table `tbl` follows, as { tbl, e } in
-- order: `e` itself, or the hops of each edge an edge.through goes through.
-- A stored edge.through whose store is filled is read as one edge.to.
local function hops(tbl: any, e: any, out: { any }?): { any }
    local list = out or {}
    if e.dir ~= "through" then
        list[#list + 1] = { tbl = tbl, e = e }
        return list
    end
    local s = e.store and tbl.allEdges[e.store]
    if s and s.state == nil then
        list[#list + 1] = { tbl = tbl, e = { name = e.name, dir = "to", target = e.target,
                                             store = e.store } }
        return list
    end
    for _, name in e.via do
        local h = find_edge(tbl, name)
        hops(tbl, h, list)
        tbl = tbl.peers[h.target]
    end
    return list
end

-- The ids that the rows in `ids` reach through edge `e`, each once, in id
-- order. Each hop scans the edges of the distinct rows the hop before
-- reached. `backward` walks the hops in reverse from the far table and
-- answers the rows of `tbl` that reach the rows in `ids`.
local function reach(tbl: any, e: any, ids: { any }, backward: boolean?): { any }
    local path = hops(tbl, e)
    local first, last, step = 1, #path, 1
    if backward then
        first, last, step = #path, 1, -1
    end
    for i = first, last, step do
        local h = path[i]
        local s = h.tbl.allEdges[h.e.store]
        local forward = (h.e.dir == "to") ~= (backward == true)
        local seen, found = {}, {}
        for _, pk in ids do
            linked(s, forward, pk, function(other)
                if not seen[other] then
                    seen[other] = true
                    found[#found + 1] = other
                end
                return false
            end)
        end
        ids = found
    end
    table.sort(ids)
    return ids
end

-- Calls each(other) for the rows that row pk reaches through edge `e`,
-- until `each` answers true, and answers whether it did. A row reached by
-- two paths is passed once, and a hop row reached before is skipped.
local function reaches(tbl: any, e: any, pk: any, each: (any) -> boolean?): boolean
    local path = hops(tbl, e)
    local seen = {}
    for i in path do
        seen[i] = {}
    end
    local function walk(i: number, at: any): boolean
        local h = path[i]
        return linked(h.tbl.allEdges[h.e.store], h.e.dir == "to", at, function(other)
            if seen[i][other] then
                return false
            end
            seen[i][other] = true
            if i == #path then
                return each(other) == true
            end
            return walk(i + 1, other)
        end, 100)
    end
    return walk(1, pk)
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

-- The values on the link from row pk to row `other` through edge `e`,
-- filled with defaults: an empty table for an edge without fields, and nil
-- when the rows are not linked.
local function link_values(self: any, e: any, pk: any, other: any, exclusive: boolean?): any
    local s = self.allEdges[e.store]
    local from, to = ends(e, pk, other)
    local v = get(self, lay.edge(s, from, to), exclusive)
    if v == nil then
        return nil
    end
    local es = self.links[e.store]
    if es == nil then
        return {}
    end
    -- a link stored before its edge had fields holds ""
    return lay.fill(es.t, v == "" and {} or (rc.decode(es.fields, v)))
end

-- The stored value of a link through edge `e` that sets `values` over the
-- link's `old` values (nil for a new link), and the values it holds.
local function link_value(self: any, e: any, values: any, old: any): (string, any)
    local es = self.links[e.store]
    if values ~= nil and type(values) ~= "table" then
        fail(self.where .. " edge " .. e.name .. " values must be a table, got "
            .. tostring(values))
    end
    if es == nil then
        if values ~= nil and next(values) ~= nil then
            fail(self.where .. " edge " .. e.name .. " has no fields")
        end
        return "", {}
    end
    local r = old and table.clone(old) or {}
    values = values or {}
    set_fields(es, r, values)
    for name, code in es.code do
        if old == nil and r[name] == nil and code.default then
            r[name] = code.default()
        elseif old and code.update and values[name] == nil then
            r[name] = code.update()
        end
    end
    lay.fill(es.t, r)
    r = clone_row(es, r)
    check_row(es, r, old)
    return rc.encode(es.fields, "binary", es.version, r), r
end

-- Adds `d` to the number of paths from row `from` to row `to` in the store
-- of stored edge.through `p`. Its forward key holds the number, and both
-- keys go when it reaches 0. A pessimistic transaction locks the number.
local function bump(self: any, p: any, from: any, to: any, d: number)
    if d == 0 then
        return
    end
    local key = lay.edge(p, from, to)
    local n = (tonumber(get(self, key, true)) or 0) + d
    if n > 0 then
        barch.store.set(key, tostring(n))
        barch.store.set(lay.edge_back(p, to, from), "")
    else
        barch.store.remove(key)
        barch.store.remove(lay.edge_back(p, to, from))
    end
end

-- Runs apply(), which adds (sign 1) or removes (sign -1) the link from row
-- `from` to row `to` in edge store `s`, and updates the stores of the stored
-- edge.through paths that follow `s`. A path through the link at hop i
-- changes by the paths that reach `from` through the hops before i, after
-- the change, times the paths from `to` through the hops after i, before
-- it; summed over each hop that follows `s`, that is the exact change even
-- when a path follows `s` more than once.
local function change_link(self: any, s: any, from: any, to: any, sign: number,
                           apply: () -> ())
    local uses = self.pathUses[s.name]
    if uses == nil then
        apply()
        return
    end
    local right = {}
    for j, u in uses do
        local path = u.p.path
        local start = path[u.i].forward and to or from
        right[j] = lay.path_counts(self.allEdges, path, { [start] = 1 }, u.i + 1, #path)
    end
    apply()
    for j, u in uses do
        local path = u.p.path
        local start = path[u.i].forward and from or to
        local left = lay.path_counts(self.allEdges, path, { [start] = 1 }, u.i - 1, 1, true)
        for a, l in left do
            for b, r in right[j] do
                bump(self, u.p, a, b, sign * l * r)
            end
        end
    end
end

local function write_link(self: any, e: any, pk: any, other: any, value: string?)
    local s = self.allEdges[e.store]
    local from, to = ends(e, pk, other)
    change_link(self, s, from, to, 1, function()
        barch.store.set(lay.edge(s, from, to), value or "")
        barch.store.set(lay.edge_back(s, to, from), "")
    end)
end

-- Links row pk to row `other` through edge `name` and answers the link's
-- values. `values` sets the edge's fields: a new link fills the rest with
-- defaults, and an existing link keeps the rest. Linking again without
-- values leaves the link as it is.
function Table:link(name: string, pk: any, other: any, values: { [string]: any }?): any
    local e = linkable(self, find_edge(self, name))
    if not exists(self, pk) then
        fail(self.where .. " has no row " .. pk)
    end
    check_link(self, e, pk, other)
    local old = link_values(self, e, pk, other, true)
    if old and values == nil then
        return old
    end
    local value, r = link_value(self, e, values, old)
    if old then
        local from, to = ends(e, pk, other)
        barch.store.set(lay.edge(self.allEdges[e.store], from, to), value)
    else
        write_link(self, e, pk, other, value)
    end
    return r
end

-- The values on the link from row pk to row `other` through edge `name`,
-- or nil when the rows are not linked.
function Table:edge(name: string, pk: any, other: any): any
    local e = linkable(self, find_edge(self, name))
    check_pk(self, pk)
    check_pk(self.peers[e.target], other)
    return link_values(self, e, pk, other)
end

-- Removes the link from row pk to row `other`. Answers whether there was one.
function Table:unlink(name: string, pk: any, other: any): boolean
    local e = linkable(self, find_edge(self, name))
    local s = self.allEdges[e.store]
    check_pk(self, pk)
    check_pk(self.peers[e.target], other)
    local from, to = ends(e, pk, other)
    local key = lay.edge(s, from, to)
    if not barch.store.exists(key) then
        return false
    end
    change_link(self, s, from, to, -1, function()
        barch.store.remove(key)
        barch.store.remove(lay.edge_back(s, to, from))
    end)
    return true
end

-- Removes every edge into or out of row pk, including edges declared only
-- by the table at the other end. The paths of stored edge.through edges
-- through row pk go with the links they follow.
local function unlink_all(self: any, pk: any)
    local name = self.t.name
    for _, s in self.allEdges do
        if s.path == nil and s.from == name then
            lay.walk(lay.edge(s, pk), function(k)
                local to = lay.edge_to(s, k)
                change_link(self, s, pk, to, -1, function()
                    barch.store.remove(k)
                    barch.store.remove(lay.edge_back(s, to, pk))
                end)
            end)
        end
        if s.path == nil and s.to == name then
            lay.walk(lay.edge_back(s, pk), function(k)
                local from = lay.edge_from(s, k)
                change_link(self, s, from, pk, -1, function()
                    barch.store.remove(k)
                    barch.store.remove(lay.edge(s, from, pk))
                end)
            end)
        end
    end
end

-- rows -------------------------------------------------------------------------

-- Adds a row and answers it with its new id. A value under an edge's name
-- links the row: an id or a row, or a list of them.
function Table:create(values: { [string]: any }): any
    writable(self)
    local r, plain, links = {}, {}, {}
    for k, v in values do
        local e = self.edgeByName[k]
        if e then
            links[#links + 1] = { linkable(self, e), ids_in(self, e, v) }
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
    r = clone_row(self, r)
    run_hooks(self, "create", r)
    for _, f in self.stored do
        compute_stored(self, f, r)
    end
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
        l[3] = {}
        for i, other in l[2] do
            check_link(self, l[1], pk, other)
            l[3][i] = (link_value(self, l[1], nil, nil))
        end
    end
    store(self, pk, nil, r, counter)
    for _, l in links do
        for i, other in l[2] do
            write_link(self, l[1], pk, other, l[3][i])
        end
    end
    return compute(self, r)
end

-- Creates each row in input order in the caller's transaction. If the caller
-- catches an error, earlier rows and the hooks' writes stay in the transaction.
function Table:createMany(rows: { any }): { any }
    local where = self.where .. " createMany"
    if type(rows) ~= "table" then
        fail(where .. " takes a list of rows")
    end
    local n = 0
    for i in rows do
        if type(i) ~= "number" or i < 1 or i ~= math.floor(i) then
            fail(where .. " takes a list of rows")
        end
        n += 1
    end
    for i = 1, n do
        if type(rows[i]) ~= "table" then
            fail(where .. " row " .. i .. " must be a table of values")
        end
    end
    local out = table.create(n)
    for i = 1, n do
        out[i] = self:create(rows[i])
    end
    return out
end

-- The row with this id, or nil.
function Table:get(pk: any): any
    check_pk(self, pk)
    return read(self, pk)
end

local function unique_index(self: any, name: string): any
    local ix
    for _, i in self.t.indexes do
        if i.name == name or i.name == "by_" .. name then
            ix = i
        end
    end
    if ix == nil or not ix.unique then
        fail(self.where .. " has no unique index " .. tostring(name))
    end
    ready(self, ix)
    return ix
end

-- The row whose values match a unique index, or nil. `name` is the index's
-- name, or a field name whose `by_<field>` index is unique.
function Table:by(name: string, ...: any): any
    local ix = unique_index(self, name)
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
    writable(self)
    check_pk(self, pk)
    local old = read(self, pk, true)
    if old == nil then
        fail(self.where .. " has no row " .. pk)
    end
    local r = table.clone(old)
    r.id = nil
    for _, f in self.computed do
        r[f.name] = nil
    end
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
    r = clone_row(self, r)
    run_hooks(self, "update", pk, r, clone_row(self, old))
    for _, f in self.stored do
        compute_stored(self, f, r)
    end
    check_row(self, r, old)
    return compute(self, store(self, pk, old, r))
end

-- Creates a row or updates the row selected by the unique fields in values.
-- All indexed fields must be supplied before defaults and hooks run. The
-- unique key is locked exclusively in a pessimistic transaction.
function Table:upsert(name: string, values: { [string]: any }): (any, boolean)
    local ix = unique_index(self, name)
    if type(values) ~= "table" then
        fail(self.where .. " upsert takes a table of values")
    end
    local on = table.create(#ix.on)
    for i, fname in ix.on do
        if values[fname] == nil then
            fail(self.where .. " upsert index " .. ix.name .. " needs a value for " .. fname)
        end
        on[i] = values[fname]
    end
    local pk = get(self, lay.index(self.t, ix, on), true)
    if pk == nil then
        return self:create(values), true
    end
    return self:update(lay.unique_pk(self.t, pk), values), false
end

-- Removes the row, its index entries and its edges. Answers false if there
-- was no row.
function Table:delete(pk: any): boolean
    writable(self)
    check_pk(self, pk)
    local old = read(self, pk, true)
    if old == nil then
        return false
    end
    run_hooks(self, "delete", pk, clone_row(self, old))
    for _, ix in self.t.indexes do
        local key = lay.entry(self.t, ix, old, pk)
        if key and owns_entry(self, ix, key, pk) then
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
    local f = tbl.byName[field] or tbl.computedByName[field]
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
    if kind == "enum" or kind == "bytes" then return type(v) == "string" end
    return type(v) == (kind == "string" and "string" or "boolean")
end

-- Starts a query over this table's rows.
function Table:query(): any
    return setmetatable({ tbl = self, conds = {}, preds = {}, checks = {}, loads = {}, skip = 0 },
        Query)
end

-- Keeps the rows where `field op value` holds, op being one of = ~= < <= >
-- >=. A missing value equals nil, differs from non-nil values and fails
-- range comparisons. where(fn) keeps rows for which fn(row) answers true.
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
    if RANGE[op] and (kind == "bool" or kind == "json") then
        fail(tbl.where .. " field " .. field .. " is " .. kind .. ", which has no order")
    end
    if kind == "json" and value ~= nil then
        local ok, copy = pcall(VALUES.copy_json, value)
        if not ok then fail(tbl.where .. " field " .. field .. " wants JSON: " .. tostring(copy)) end
        value = copy
    elseif (value ~= nil or RANGE[op]) and not fits(kind, value) then
        fail(tbl.where .. " field " .. field .. " is " .. kind .. ", got " .. tostring(value))
    end
    self.conds[#self.conds + 1] = { field = field, op = op, value = value, kind = kind }
    return self
end

-- Orders the rows by `field`, "asc" (the default) or "desc". Rows with the
-- same value come in id order, and a field without a value sorts first.
function Query:order(field: string, dir: string?): any
    if kind_of(self.tbl, field) == "json" then
        fail(self.tbl.where .. " field " .. field .. " is json, which has no order")
    end
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
        if c.kind == "json" then return VALUES.equal_json(v, w) end
        return v == w
    elseif c.op == "~=" then
        if c.kind == "json" then return not VALUES.equal_json(v, w) end
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

-- Whether the link from row pk to row `other` through edge `e` matches the
-- whereEdge conditions in `edgeOf` (a sub query's edge, or nil).
local function link_ok(tbl: any, e: any, edgeOf: any, pk: any, other: any): boolean
    if edgeOf == nil or edgeOf.q == nil then
        return true
    end
    local values = link_values(tbl, e, pk, other)
    return values ~= nil and matches(edgeOf.q, values)
end

-- Whether row pk has a link through check h, and when h has a filter, one
-- to a row that matches it.
local function has_link(q: any, h: any, pk: any): boolean
    if h.set then
        return h.set[pk] == true
    end
    local target = q.tbl.peers[h.e.target]
    local function match(other: any): boolean
        if h.sub == nil then
            return true
        end
        local m = h.memo[other]
        if m == nil then
            local r = read(target, other)
            m = r ~= nil and matches(h.sub, r)
            h.memo[other] = m
        end
        return m
    end
    if h.e.dir == "through" then
        return reaches(q.tbl, h.e, pk, match)
    end
    local s = q.tbl.allEdges[h.e.store]
    local forward = h.e.dir == "to"
    if h.sub == nil then
        return first_key(edge_prefix(s, forward, pk)) ~= nil
    end
    return linked(s, forward, pk, function(other)
        if not link_ok(q.tbl, h.e, h.sub.edgeOf, pk, other) then
            return false
        end
        return match(other)
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
        if ix.state == "building" then
            if q.use == ix.name then ready(tbl, ix) end
        elseif q.use == nil or q.use == ix.name then
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
        if h.drive and h.e.dir == "through" then
            -- walk the hops back from the matching rows
            local set = {}
            for _, pk in reach(q.tbl, h.e, h.sub:ids(), true) do
                set[pk] = true
            end
            h.set = set
        elseif h.drive then
            local set = {}
            local s = q.tbl.allEdges[h.e.store]
            for _, other in h.sub:ids() do
                linked(s, h.e.dir ~= "to", other, function(pk)
                    if link_ok(q.tbl, h.e, h.sub.edgeOf, pk, other) then
                        set[pk] = true
                    end
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
        local fielded = tbl.links[w.e.store] ~= nil
        for _, r in list do
            local sub = target:query()
            sub.edgeOf = { tbl = tbl, e = w.e }
            if w.fn then
                sub = w.fn(sub) or sub
            end
            local ids = {}
            if w.e.dir == "through" then
                ids = reach(tbl, w.e, { r.id })
            else
                linked(s, forward, r.id, function(other)
                    if link_ok(tbl, w.e, sub.edgeOf, r.id, other) then
                        ids[#ids + 1] = other
                    end
                    return false
                end)
            end
            sub.idset, sub.via = ids, w.e.store or w.e.name
            local got = single and { sub:first() } or sub:all()
            if fielded then
                for _, x in got do
                    x._edge = link_values(tbl, w.e, r.id, x.id)
                end
            end
            r[w.e.name] = if single then got[1] else got
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

-- aggregates -------------------------------------------------------------------

local AGGREGATES = { count = true, sum = true, min = true, max = true }

-- Checks the aggregate `name` = { fn, field? } or { fn, value }.
local function aggregate_spec(tbl: any, name: any, spec: any): any
    if type(name) ~= "string" or type(spec) ~= "table" then
        fail(tbl.where .. " query aggregate takes a table of name = { fn = ..., field = ... }")
    end
    local at = tbl.where .. " query aggregate " .. name
    for k in spec do
        if k ~= "fn" and k ~= "field" and k ~= "value" then
            fail(at .. " has no option " .. tostring(k))
        end
    end
    local fn, field, value = spec.fn, spec.field, spec.value
    if not AGGREGATES[fn] then
        fail(at .. " has no function " .. tostring(fn) .. "; use count, sum, min or max")
    end
    if value ~= nil then
        if field ~= nil then
            fail(at .. " has both field and value; give one")
        end
        if type(value) ~= "function" then
            fail(at .. " value must be a function, got " .. tostring(value))
        end
        return { name = name, fn = fn, value = value, at = at }
    end
    if field == nil then
        if fn ~= "count" then
            fail(at .. " needs a field or value for " .. fn)
        end
        return { name = name, fn = fn }
    end
    local kind = kind_of(tbl, field)
    if fn == "sum" and kind ~= "int" and kind ~= "float" then
        fail(tbl.where .. " field " .. field .. " is " .. kind .. ", so sum needs int or float")
    end
    if (fn == "min" or fn == "max") and kind == "json" then
        fail(tbl.where .. " field " .. field .. " is json, which has no order")
    end
    return { name = name, fn = fn, field = field }
end

local ORDERED = { number = true, string = true, boolean = true }

-- The value aggregate a reads from row r: the field's value, or what the
-- value function answers, checked against the earlier values in acc.
local function fold_value(a: any, acc: any, r: any): any
    if a.value == nil then
        return r[a.field]
    end
    local v = a.value(r)
    if v == nil or a.fn == "count" then
        return v
    end
    local t = type(v)
    if a.fn == "sum" then
        if t ~= "number" then
            fail(a.at .. " value answered " .. tostring(v) .. ", so sum needs a number")
        end
    elseif not ORDERED[t] then
        fail(a.at .. " value answered a " .. t .. ", which has no order")
    elseif acc ~= nil and type(acc) ~= t then
        fail(a.at .. " value answered a " .. t .. " after a " .. type(acc))
    end
    return v
end

-- Adds row r to aggregate a's running value acc. Rows without a value for
-- the field, or whose value function answers nil, are skipped.
local function fold(a: any, acc: any, r: any): any
    if a.fn == "count" then
        if (a.field == nil and a.value == nil) or fold_value(a, acc, r) ~= nil then
            return (acc or 0) + 1
        end
        return acc
    end
    local v = fold_value(a, acc, r)
    if v == nil then
        return acc
    elseif a.fn == "sum" then
        return (acc or 0) + v
    elseif acc == nil then
        return v
    elseif a.fn == "min" then
        if less(v, acc) then return v end
        return acc
    end
    if less(acc, v) then return v end
    return acc
end

-- Checks a groupBy key: a field, or an edge with one row at its far end,
-- which groups by the linked row's id.
local function group_key(tbl: any, name: any): any
    if type(name) ~= "string" then
        fail(tbl.where .. " query groupBy takes field or edge names, got " .. tostring(name))
    end
    if name == "id" or tbl.byName[name] or tbl.computedByName[name] then
        local kind = kind_of(tbl, name)
        if kind == "json" then
            fail(tbl.where .. " field " .. name .. " is json, so groupBy cannot use it")
        end
        return { name = name, kind = kind }
    end
    local e = tbl.edgeByName[name]
    if e == nil then
        fail(tbl.where .. " has no field or edge " .. name)
    end
    if not one(tbl, e) then
        fail(tbl.where .. " edge " .. name .. " can link a row to many rows, so groupBy"
            .. " cannot use it")
    end
    return { name = name, kind = lay.id_kind(tbl.peers[e.target].t), e = e }
end

-- The id that row pk links to through edge e, or nil.
local function linked_id(tbl: any, e: any, pk: any): any
    local out
    reaches(tbl, e, pk, function(other)
        out = other
        return true
    end)
    return out
end

-- One row per group of q's rows, in the order of the group keys, with the
-- keys' values and each aggregate of spec.
local function aggregate(q: any, keys: { any }, spec: any): { any }
    local tbl = q.tbl
    if type(spec) ~= "table" then
        fail(tbl.where .. " query aggregate takes a table of name = { fn = ..., field = ... }")
    end
    local aggs = {}
    for name, s in spec do
        aggs[#aggs + 1] = aggregate_spec(tbl, name, s)
    end
    local kinds = {}
    for i, k in keys do
        if spec[k.name] ~= nil then
            fail(tbl.where .. " query aggregate " .. k.name .. " has the name of a groupBy key")
        end
        kinds[i] = k.kind
    end
    local groups, list = {}, {}
    for _, r in rows(q) do
        local values = {}
        for i, k in keys do
            if k.e then
                values[i] = linked_id(tbl, k.e, r.id)
            else
                values[i] = r[k.name]
            end
        end
        -- key text sorts groups the way an index sorts their values
        local key = kc.pack(kinds, values)
        local g = groups[key]
        if g == nil then
            g = { key = key, values = values, acc = {} }
            groups[key] = g
            list[#list + 1] = g
        end
        for _, a in aggs do
            g.acc[a.name] = fold(a, g.acc[a.name], r)
        end
    end
    if #keys == 0 and #list == 0 then
        list[1] = { key = "", values = {}, acc = {} }
    end
    table.sort(list, function(a, b)
        return a.key < b.key
    end)
    local out = {}
    for i, g in list do
        local row = {}
        for j, k in keys do
            row[k.name] = g.values[j]
        end
        for _, a in aggs do
            local v = g.acc[a.name]
            if v == nil and (a.fn == "count" or a.fn == "sum") then
                v = 0
            end
            row[a.name] = v
        end
        out[i] = row
    end
    return out
end

-- One row with each aggregate of spec over the matching rows, such as
-- { posts = { fn = "count" }, stars = { fn = "sum", field = "stars" } }.
function Query:aggregate(spec: { [string]: any }): any
    return aggregate(self, {}, spec)[1]
end

-- The sum of `field` over the matching rows, 0 when none has a value.
function Query:sum(field: string): number
    return self:aggregate({ sum = { fn = "sum", field = field } }).sum
end

-- The least value of `field` among the matching rows, or nil.
function Query:min(field: string): any
    return self:aggregate({ min = { fn = "min", field = field } }).min
end

-- The greatest value of `field` among the matching rows, or nil.
function Query:max(field: string): any
    return self:aggregate({ max = { fn = "max", field = field } }).max
end

local Grouped = {}
Grouped.__index = Grouped

-- Groups the matching rows by the values of fields, or by the row linked
-- through an edge with one row at its far end. Call aggregate(spec) on the
-- result.
function Query:groupBy(...: string): any
    local names = { ... }
    if #names == 0 then
        fail(self.tbl.where .. " query groupBy takes at least one field or edge")
    end
    local keys = {}
    for i, name in names do
        keys[i] = group_key(self.tbl, name)
    end
    return setmetatable({ q = self, keys = keys }, Grouped)
end

-- One row per group, in the order of the group keys, with the keys and
-- each aggregate of spec.
function Grouped:aggregate(spec: { [string]: any }?): { any }
    return aggregate(self.q, self.keys, spec or {})
end

-- Updates the selected rows in query order, with the same values and clear
-- list as Table:update. Select every id before writes can move index entries
-- or change which rows match. Answers how many rows were updated.
function Query:update(values: { [string]: any }?, clear: { string }?): number
    local tbl = self.tbl
    if values ~= nil and type(values) ~= "table" then
        fail(tbl.where .. " query update takes a table of values")
    end
    if clear ~= nil and type(clear) ~= "table" then
        fail(tbl.where .. " query update clear takes a list of fields")
    end
    set_fields(tbl, {}, values or {})
    for _, name in clear or {} do
        set_fields(tbl, {}, { [name] = true })
    end
    local ids = self:ids()
    for _, id in ids do
        tbl:update(id, values, clear)
    end
    return #ids
end

-- Deletes the selected rows in query order and answers how many were removed.
-- Capture all ids before deleting rows or their edges changes the selection.
function Query:delete(): number
    local ids, n = self:ids(), 0
    for _, id in ids do
        if self.tbl:delete(id) then
            n += 1
        end
    end
    return n
end

-- How the query reads: the index, the fields it matches with = and the
-- range field, and "then sort" when the rows are sorted after reading.
function Query:explain(): string
    return plan(self).name
end

-- A query over the rows that the matching rows reach through the edges
-- named, hop by hop: follow("orders", "lines", "product") or
-- follow("orders.lines.product"). Each hop reads each distinct row once.
function Query:follow(...: string): any
    local tbl = self.tbl
    local names = {}
    for _, part in { ... } do
        if type(part) ~= "string" then
            fail(tbl.where .. " query follow takes edge names, got " .. tostring(part))
        end
        for name in string.gmatch(part .. ".", "([^.]*)%.") do
            names[#names + 1] = name
        end
    end
    if #names == 0 then
        fail(tbl.where .. " query follow takes at least one edge name")
    end
    local ids, stores = self:ids(), {}
    for _, name in names do
        local e = find_edge(tbl, name)
        for _, h in hops(tbl, e) do
            stores[#stores + 1] = h.e.store
        end
        ids = reach(tbl, e, ids)
        tbl = tbl.peers[e.target]
    end
    local q = tbl:query()
    q.idset, q.via = ids, table.concat(stores, "/")
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
        sub.edgeOf = { tbl = tbl, e = e }
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

-- Inside has(name, fn) and with(name, fn): keeps the linked rows whose link
-- through that edge holds `field op value`, as where does for a row's
-- fields. whereEdge(fn) keeps the links for which fn(values) answers true.
function Query:whereEdge(field: any, op: string?, value: any): any
    local l = self.edgeOf
    if l == nil then
        fail(self.tbl.where .. " query whereEdge works inside the function given to has or with")
    end
    local es = l.tbl.links[l.e.store]
    if es == nil then
        fail(l.tbl.where .. " edge " .. l.e.name .. " has no fields")
    end
    l.q = l.q or es:query()
    l.q:where(field, op, value)
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
    local c, dropping = {}, {}
    if compiled.migration then
        local work = compiled.migration
        for i = work.at, #work.steps do
            local step = work.steps[i]
            if step.op == "drop" and step.index then dropping[step.table] = true end
        end
    end
    for _, t in compiled.tables do
        c[t.name] = bind(t, compiled.version, pessimistic, app and app.tables[t.name])
        c[t.name].dropping = dropping[t.key]
    end
    for name in app and app.tables or {} do
        if c[name] == nil then
            fail("table " .. name .. " is declared, and this space's catalog lacks it;"
                .. " run MIGRATE")
        end
    end
    -- each edge with fields reads and checks its values as a table does
    local links = {}
    for store, s in compiled.edges do
        if s.fields then
            local es = bind({ name = store, key = store, format = "binary", id = "int",
                              fields = s.fields, indexes = {}, edges = {} }, compiled.version,
                            pessimistic, app and app.edges[store])
            for _, e in c[s.from].t.edges do
                if e.store == store then es.where = c[s.from].where .. " edge " .. e.name end
            end
            links[store] = es
        end
    end
    -- for each edge store, the stored edge.through paths that follow it, as
    -- { p = the path's store, i = the hop }
    local pathUses = {}
    for _, s in compiled.edges do
        for i, h in s.path or {} do
            pathUses[h.store] = pathUses[h.store] or {}
            table.insert(pathUses[h.store], { p = s, i = i })
        end
    end
    for _, b in c do
        b.peers = c
        b.allEdges = compiled.edges
        b.links = links
        b.pathUses = pathUses
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
        fail("open takes the graph from lent.graph")
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
    local lent = require("lent.SCHEMA")
    if mig.load() ~= nil then
        return nil -- this space has a schema of its own; leave it alone
    end
    mig.apply(mig.plan(nil, lent.graph {
        lent.schema "T" {
            id = "int",
            fields = { lent.field.string "k":unique(), lent.field.int "n":default(5) },
            indexes = { lent.index("n") },
            edges = { lent.edge.to "us" "U" },
        },
        lent.schema "U" {
            fields = { lent.field.int "v" },
            edges = { lent.edge.from "t" "T":ref "us":unique() },
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
    local groups = c.U:query():groupBy("t"):aggregate { n = { fn = "count" } }
    if c.U:query():sum("v") ~= 3 or c.U:query():max("v") ~= 2 or #groups ~= 1
        or groups[1].t ~= 1 or groups[1].n ~= 2 then
        return "aggregates"
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
