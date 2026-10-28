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
--       c.User:query():where("age >= lo and name ~= 'bo'", { lo = 18 }):all()
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
-- conflict. lent.open(app).tx(fn, pessimistic, viewer) does the same and
-- also runs the graph's function defaults, validate functions, hooks and
-- policy rules, which get `viewer`; the value rules stored in the catalog
-- apply either way. Inside a transaction the caller already runs, lent.client(p)
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
-- a Luau integer within 2^53 as a number; see VALUES.number
local num = VALUES.number
local EXPR = require("lent.EXPR")

local function fail(msg: string)
    error("LENT " .. msg, 0)
end

local Table = {}
Table.__index = Table

local NO_HOOKS = { create = {}, update = {}, delete = {} }

-- `decl` is the table as lent.schema declared it, for the parts that stay in
-- code: function defaults, validate functions, hooks, policy rules and
-- computed fields. nil leaves them out, and `free` leaves out the rules.
local function bind(t: any, version: number, pessimistic: boolean?, decl: any?,
                    free: boolean?): any
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
    local policy = not free and decl and decl.policy
    return setmetatable({
        queryRules = policy and #policy.query > 0 and policy.query or nil,
        mutationRules = policy and #policy.mutation > 0 and policy.mutation or nil,
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
    elseif type(pk) ~= "number" or pk < 1 or pk > 2 ^ 53 or pk ~= math.floor(pk) then
        fail(self.where .. " wants an integer id, got " .. tostring(pk))
    end
end

local function fits_kind(f: any, v: any): boolean
    if f.kind == "int" then
        return type(v) == "number" and v == math.floor(v)
    elseif f.kind == "float" then
        return type(v) == "number" and v == v
    elseif f.kind == "decimal" then
        return VALUES.decimal(v, f.scale) ~= nil
    elseif f.kind == "bool" then
        return type(v) == "boolean"
    elseif f.kind == "time" or f.kind == "enum" or f.kind == "json" then
        return SCHEMA.broken(f, v) == nil
    end
    return type(v) == "string"
end

-- Value `v` of field `f`, rounded to the field's scale when it is a
-- decimal that fits.
local function rounded(f: any, v: any): any
    if f.kind == "decimal" and v ~= nil then
        return VALUES.decimal(v, f.scale) or v
    end
    return v
end

-- Sets stored computed field f of row r to its function's value.
local function compute_stored(self: any, f: any, r: any)
    local code = self.code[f.name]
    if code == nil or code.computed == nil then
        fail(self.where .. " field " .. f.name .. " is computed and stored, so writing"
            .. " rows needs its function; open the client with lent.open(app)")
    end
    local v = num(code.computed(table.clone(r)))
    local why = SCHEMA.computed_broken(f, v)
    if why then
        fail(self.where .. " field " .. f.name .. " " .. why)
    end
    r[f.name] = rounded(f, v)
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
        local v = num(f.fn(r))
        if v ~= nil and not fits_kind(f, v) then
            fail(self.where .. " field " .. f.name .. " is a computed " .. f.kind
                .. ", and its function answered " .. tostring(v))
        end
        r[f.name] = rounded(f, v)
    end
    return r
end

-- The row at pk, filled with defaults and computed fields, or nil. A pessimistic caller about
-- to write the row reads it with the exclusive lock.
-- The row at pk, from `v`, the value stored at its key.
local function row_of(self: any, pk: any, v: string): any
    local r = lay.fill(self.t, (rc.decode(self.fields, v)))
    r.id = pk
    return compute(self, r)
end

local function read(self: any, pk: any, exclusive: boolean?): any
    local v = get(self, lay.row(self.t, pk), exclusive)
    if v == nil then
        return nil
    end
    return row_of(self, pk, v)
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
            fail(self.where .. " keeps each row's id; only create takes an id")
        end
        if self.edgeByName[k] then
            linkable(self, self.edgeByName[k])
            fail(self.where .. " edge " .. k .. " changes with link and unlink")
        end
        no_field(self, k)
        r[k] = num(v)
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
        -- a hook may have set a Luau integer
        local v = num(r[f.name])
        r[f.name] = v
        -- a decimal is stored rounded to its scale; one that does not fit
        -- stays as it is for broken() to refuse
        if f.kind == "decimal" and v ~= nil and (old == nil or v ~= old[f.name]) then
            v = rounded(f, v)
            r[f.name] = v
        end
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

-- How deep hooks may nest unless open sets hookDepth: a hook's write runs
-- the written table's hooks, and those may write again.
local HOOK_DEPTH = 16

-- Runs the table's `op` hooks. A run that would nest more than the
-- client's hookDepth raises an error naming the operations on the way.
local function run_hooks(self: any, op: string, ...: any)
    local list = self.hooks[op]
    if #list == 0 then
        return
    end
    local stack, limit = self.hookStack, self.hookDepth
    if #stack >= limit then
        local names, seen = {}, {}
        for _, name in stack do
            if not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
        fail(self.where .. " " .. op .. " hooks nest more than " .. limit
            .. " deep; each write from a hook runs hooks again, here through "
            .. table.concat(names, ", "))
    end
    stack[#stack + 1] = self.where .. " " .. op
    local ok, err = pcall(function(...)
        for _, fn in list do
            fn(self.peers, ...)
        end
    end, ...)
    table.remove(stack)
    if not ok then
        error(err, 0)
    end
end

-- Runs the table's policy rules `part` as fn(rules client, viewer, arg)
-- until one answers lent.allow or lent.deny. A deny raises an error that
-- names `what`; when every rule answers nil the call goes ahead.
local function decide(self: any, part: string, what: string, arg: any)
    local rules = if part == "query" then self.queryRules else self.mutationRules
    local rc = self.rulesClient()
    for i, fn in rules do
        local d = fn(rc, self.viewer, arg)
        if d ~= nil then
            local kind = type(d) == "table" and d.decision
            if kind ~= "allow" and kind ~= "deny" then
                fail(self.where .. " policy." .. part .. " rule " .. i .. " answered "
                    .. tostring(d) .. "; a rule answers lent.allow, lent.deny or nil")
            end
            if kind == "deny" then
                fail(self.where .. " policy denies " .. what
                    .. (d.reason and ": " .. tostring(d.reason) or ""))
            end
            return
        end
    end
end

-- Runs the mutation rules for a link or unlink of row pk and row `other`.
local function decide_link(self: any, op: string, e: any, pk: any, other: any, values: any)
    if self.mutationRules then
        decide(self, "mutation", op .. " " .. e.name .. " from row " .. tostring(pk) .. " to row "
            .. tostring(other), { op = op, edge = e.name, id = pk, other = other, values = values })
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
        local rows = lay.row(self.t)
        lay.scan_values(rows, kc.after(rows), function(k, v)
            local otherPk = lay.row_pk(self.t, k)
            if otherPk ~= pk and lay.entry(self.t, ix, row_of(self, otherPk, v), otherPk) == key then
                duplicate(self, ix, tostring(otherPk), r)
            end
            return false
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
    v = num(v)
    if type(v) == "number" or type(v) == "string" or (type(v) == "table" and v.id ~= nil) then
        v = { v }
    end
    if type(v) ~= "table" then
        fail(self.where .. " edge " .. e.name .. " takes ids or rows, got " .. tostring(v))
    end
    local list = {}
    for i, x in v do
        list[i] = num(type(x) == "table" and x.id or x)
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
            r[name] = num(code.default())
        elseif old and code.update and values[name] == nil then
            r[name] = num(code.update())
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
    pk, other = num(pk), num(other)
    local e = linkable(self, find_edge(self, name))
    if not exists(self, pk) then
        fail(self.where .. " has no row " .. pk)
    end
    check_link(self, e, pk, other)
    decide_link(self, "link", e, pk, other, values)
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
    pk, other = num(pk), num(other)
    local e = linkable(self, find_edge(self, name))
    local target = self.peers[e.target]
    check_pk(self, pk)
    check_pk(target, other)
    -- a row the viewer cannot read has no links to read
    if self.queryRules and self:get(pk) == nil or target.queryRules and target:get(other) == nil then
        return nil
    end
    return link_values(self, e, pk, other)
end

-- Removes the link from row pk to row `other`. Answers whether there was one.
function Table:unlink(name: string, pk: any, other: any): boolean
    pk, other = num(pk), num(other)
    local e = linkable(self, find_edge(self, name))
    local s = self.allEdges[e.store]
    check_pk(self, pk)
    check_pk(self.peers[e.target], other)
    decide_link(self, "unlink", e, pk, other, nil)
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
    local given = num(values.id)
    for k, v in values do
        local e = self.edgeByName[k]
        if e then
            links[#links + 1] = { linkable(self, e), ids_in(self, e, v) }
        elseif k ~= "id" then
            plain[k] = v
        end
    end
    if given ~= nil then
        check_pk(self, given)
        if get(self, lay.row(self.t, given), true) ~= nil then
            fail(self.where .. " already has a row " .. tostring(given))
        end
    end
    set_fields(self, r, plain)
    for name, code in self.code do
        if r[name] == nil and code.default then
            r[name] = num(code.default())
        end
    end
    lay.fill(self.t, r)
    r = clone_row(self, r)
    if self.mutationRules then
        decide(self, "mutation", "create", { op = "create", row = r })
    end
    run_hooks(self, "create", r)
    for _, f in self.stored do
        compute_stored(self, f, r)
    end
    check_row(self, r, nil)
    -- a uuid needs no shared key, so creates in one table do not conflict
    local counter, pk
    if given ~= nil then
        pk = given
        -- automatic ids continue above the greatest given id
        if lay.id_kind(self.t) == "int" then
            local key = lay.counter(self.t)
            if pk > (tonumber(get(self, key, true)) or 0) then
                counter = key
            end
        end
    elseif lay.id_kind(self.t) == "uuid" then
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
            decide_link(self, "link", l[1], pk, other, nil)
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

-- Creates each row in input order in the caller's transaction. An error
-- takes back every row it created, with the hooks' writes.
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
    pk = num(pk)
    check_pk(self, pk)
    if self.queryRules then
        return self:query():where("id", "=", pk):first()
    end
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
    for i, v in values do
        values[i] = num(v)
    end
    if select("#", ...) ~= #ix.on then
        fail(self.where .. " index " .. ix.name .. " takes " .. #ix.on .. " values, got "
            .. select("#", ...))
    end
    local pk = barch.store.get(lay.index(self.t, ix, values))
    return pk and self:get(lay.unique_pk(self.t, pk))
end

-- Sets the fields in `values` and clears the fields named in `clear`, then
-- answers the stored row. Raises an error if there is no row with this id.
function Table:update(pk: any, values: { [string]: any }?, clear: { string }?): any
    pk = num(pk)
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
            r[name] = num(code.update())
        end
    end
    r = clone_row(self, r)
    if self.mutationRules then
        decide(self, "mutation", "update of row " .. tostring(pk),
            { op = "update", id = pk, row = r, old = clone_row(self, old) })
    end
    run_hooks(self, "update", pk, r, clone_row(self, old))
    for _, f in self.stored do
        compute_stored(self, f, r)
    end
    check_row(self, r, old)
    return compute(self, store(self, pk, old, r))
end

-- Creates a row or updates the row selected by the unique fields in values.
-- All indexed fields must be supplied before defaults and hooks run. The
-- unique key is locked exclusively in a pessimistic transaction. The name
-- "id" selects the row by values.id.
function Table:upsert(name: string, values: { [string]: any }): (any, boolean)
    if type(values) ~= "table" then
        fail(self.where .. " upsert takes a table of values")
    end
    if name == "id" then
        local pk = num(values.id)
        if pk == nil then
            fail(self.where .. " upsert by id needs a value for id")
        end
        check_pk(self, pk)
        if read(self, pk, true) == nil then
            return self:create(values), true
        end
        local rest = table.clone(values)
        rest.id = nil
        return self:update(pk, rest), false
    end
    local ix = unique_index(self, name)
    local on = table.create(#ix.on)
    for i, fname in ix.on do
        if values[fname] == nil then
            fail(self.where .. " upsert index " .. ix.name .. " needs a value for " .. fname)
        end
        on[i] = num(values[fname])
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
    pk = num(pk)
    writable(self)
    check_pk(self, pk)
    local old = read(self, pk, true)
    if old == nil then
        return false
    end
    if self.mutationRules then
        decide(self, "mutation", "delete of row " .. tostring(pk),
            { op = "delete", id = pk, old = clone_row(self, old) })
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

-- The kind of tbl's field, or nil when tbl has no such field.
local function field_kind(tbl: any, field: any): string?
    if field == "id" and tbl.linksOf == nil then
        return lay.id_kind(tbl.t)
    end
    local f = tbl.byName[field] or tbl.computedByName[field]
    return f and f.kind
end

local function kind_of(tbl: any, field: string): string
    local kind = field_kind(tbl, field)
    if kind == nil then
        fail(tbl.where .. " has no field " .. tostring(field))
    end
    return kind :: string
end

local function fits(kind: string, v: any): boolean
    if kind == "int" or kind == "float" or kind == "decimal" or kind == "time" then
        return type(v) == "number" and v == v
    end
    if kind == "uuid" then
        return kc.is_uuid(v)
    end
    if kind == "enum" or kind == "bytes" then return type(v) == "string" end
    return type(v) == (kind == "string" and "string" or "boolean")
end

local function new_query(tbl: any): any
    return setmetatable({ tbl = tbl, conds = {}, ors = {}, preds = {}, checks = {}, loads = {},
                          skip = 0 }, Query)
end

-- Starts a query over this table's rows that the policy's query rules let
-- the viewer read.
function Table:query(): any
    local q = new_query(self)
    if self.queryRules then
        decide(self, "query", "query", q)
    end
    return q
end

-- Raises an error when q is a links query, whose rows are links.
local function rows_only(q: any, what: string)
    if q.tbl.linksOf then
        fail(q.tbl.where .. " query " .. what .. " reads table rows; a links query takes where,"
            .. " order, limit, offset, groupBy and aggregates")
    end
end

-- Keeps the rows where `field op value` holds, op being one of = ~= < <= >
-- >=. A missing value equals nil, differs from non-nil values and fails
-- range comparisons. where(fn) keeps rows for which fn(row) answers true.
-- where(expr, params) keeps the rows for which the Luau expression string
-- expr answers true; see EXPR. Its top-level `and` parts that compare a
-- field with a value become conditions an index can serve, and an index can
-- read just the value ranges of a part that holds only within them, such as
-- `age < 20 or age > 100`.
function Query:where(field: any, op: any, value: any): any
    if type(field) == "function" then
        self.preds[#self.preds + 1] = field
        return self
    end
    if type(field) == "string" and value == nil and (op == nil or type(op) == "table") then
        local tbl = self.tbl
        local parts = EXPR.compile(field, function(name) return field_kind(tbl, name) end, op,
                                   "LENT " .. tbl.where .. " query where")
        for _, p in parts do
            if p.fn then
                self.preds[#self.preds + 1] = p.fn
                for f, list in p.ranges or {} do
                    self.ors[#self.ors + 1] = { field = f, ranges = list }
                end
            else
                self:where(p.field, p.op, p.value)
            end
        end
        return self
    end
    local tbl = self.tbl
    local kind = kind_of(tbl, field)
    value = num(value)
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
    n = num(n)
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
    rows_only(self, "cursor")
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
    rows_only(self, "after")
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
    rows_only(self, "using")
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

-- The key that starts (or, when `upper`, ends) the index keys after
-- `prefix` whose next value is v, open-ended when v is nil. `open` leaves out
-- the keys of v itself. Answers false when no key qualifies, and the
-- open-ended key when v has no key text.
local function bound(kind: string, prefix: string, v: any, open: boolean?, upper: boolean?): any
    if kind == "int" and v ~= nil and v ~= math.floor(v) and math.abs(v) ~= math.huge then
        v, open = if upper then math.floor(v) else math.ceil(v), false
    end
    if v == (if upper then -math.huge else math.huge) then
        return false
    end
    local ok, enc = pcall(kc.encode, kind, v)
    if v == nil or v == -math.huge or v == math.huge or not ok then
        return if upper then kc.after(prefix) else prefix
    end
    local key = prefix .. enc
    return if (open == true) == (upper == true) then key else kc.after(key)
end

-- The key spans of `list`, value ranges of the next value after `prefix`,
-- within lo..hi, in key order with overlapping spans merged.
local function spans_of(kind: string, prefix: string, list: { any }, lo: string,
                        hi: string): { any }
    local spans = {}
    for _, r in list do
        local a = bound(kind, prefix, r.lo, r.loOpen)
        local b = bound(kind, prefix, r.hi, r.hiOpen, true)
        if a and b then
            a, b = if a > lo then a else lo, if b < hi then b else hi
            if a < b then
                spans[#spans + 1] = { lo = a, hi = b }
            end
        end
    end
    table.sort(spans, function(x, y) return x.lo < y.lo end)
    local out = {}
    for _, sp in spans do
        local last = out[#out]
        if last and sp.lo <= last.hi then
            last.hi = if sp.hi > last.hi then sp.hi else last.hi
        else
            out[#out + 1] = sp
        end
    end
    return out
end

-- How to read q: which index, the key span, and whether the keys come in
-- the order q asks for. A plan with spans reads only those key spans of
-- lo..hi, in order.
local function index_plan(q: any, keys: boolean?): any
    local tbl, t = q.tbl, q.tbl.t
    if q.idset and not keys then
        local ordered = q.sortField == nil or q.sortField == "id"
        local p = { name = "edge " .. q.via .. (ordered and "" or " then sort"), ordered = ordered }
        -- an index that narrows the read, or one in the query's order that a
        -- limit stops early, can find the linked rows by their index keys
        local ix = index_plan(q, true)
        local sorted = q.sortField ~= nil and q.sortField ~= "id"
        if q.use or not ix.full or (sorted and ix.ordered and q.lim) then
            p.within = ix
            p.name = "edge " .. q.via .. " in (" .. ix.name .. ")"
        end
        return p
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
    local within = {}
    for _, o in q.ors do
        within[o.field] = within[o.field] or o.ranges
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
                or (n + 1 == #ix.on and q.sortField == next)
                or (ix.primary and q.sortField == "id")
            -- a unique index leaves out rows with a nil in its fields, which
            -- fail the comparisons on its last field
            local bounded = ranges[next] or within[next]
            local usable = ix.primary or point or not ix.unique or (n + 1 == #ix.on and bounded)
            local score = point and 1000 or n * 4 + (bounded and 2 or 0) + (ordered and 1 or 0)
            if not usable then
                if q.use then
                    fail(tbl.where .. " index " .. ix.name .. " is unique, so a query using it"
                        .. " needs = on each of its fields, or on each before the last and a"
                        .. " range on the last")
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
    end
    local list = best.next and within[best.next]
    if list then
        -- only rows whose value lies in one of the ranges can match
        best.spans = spans_of(kind_of(tbl, best.next), prefix, list, best.lo, best.hi)
        best.full = false
    end
    if span or list then
        local n = best.spans and #best.spans or 1
        parts[#parts + 1] = (n == 1 and "range " or n .. " ranges ") .. best.next
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

-- The rows of links query q, one per link from the rows of the query it
-- came from, in from then to id order unless q orders them, after offset
-- and limit. Without an order the read stops at the limit.
local function link_rows(q: any): { any }
    local l = q.tbl.linksOf
    local tbl, e = l.tbl, l.e
    local s = tbl.allEdges[e.store]
    local forward = e.dir == "to"
    local want = q.lim and q.skip + q.lim
    local early = q.sortField == nil and want ~= nil
    local from = l.q:ids()
    table.sort(from)
    local out = {}
    for _, pk in from do
        if want == 0 or (early and #out >= want) then
            break
        end
        linked(s, forward, pk, function(other)
            local r = link_values(tbl, e, pk, other)
            r.from, r.to = pk, other
            if matches(q, r) then
                out[#out + 1] = r
            end
            return early and #out >= want
        end)
    end
    local f = q.sortField
    if f then
        table.sort(out, function(a, b)
            if a[f] ~= b[f] then
                return less(a[f], b[f])
            elseif a.from ~= b.from then
                return a.from < b.from
            end
            return a.to < b.to
        end)
        if q.desc then
            local n = #out
            for i = 1, n // 2 do
                out[i], out[n + 1 - i] = out[n + 1 - i], out[i]
            end
        end
    end
    if q.skip ~= 0 or (want ~= nil and #out > want) then
        out = table.move(out, q.skip + 1, math.min(#out, want or #out), 1, {})
    end
    return out
end

-- The matching rows, in order, after offset and limit, with their eager
-- loaded edges when `loading`.
local function rows(q: any, loading: boolean?): { any }
    if q.tbl.linksOf then
        return link_rows(q)
    end
    local tbl = q.tbl
    local p = plan(q)
    prepare(q)
    local idset = q.idset
    local l = q.edgeOf
    if idset and l and l.from and l.q then
        -- after follow, whereEdge keeps the rows that a matching link of the
        -- last edge reaches
        local s, forward, seen = l.tbl.allEdges[l.e.store], l.e.dir == "to", {}
        idset = {}
        for _, pk in l.from do
            linked(s, forward, pk, function(other)
                if not seen[other] and link_ok(l.tbl, l.e, l, pk, other) then
                    seen[other] = true
                    idset[#idset + 1] = other
                end
                return false
            end)
        end
        table.sort(idset)
    end
    if p.via then
        idset = {}
        for pk in p.via.set do
            idset[#idset + 1] = pk
        end
        table.sort(idset)
    end
    local want = q.lim and q.skip + q.lim
    local ordered, early, back = p.ordered, false, false
    local out = {}
    -- `v` is the row's stored value when the scan read it with the key
    local function consider(pk: number, v: string?): boolean
        local r = if v then row_of(tbl, pk, v) else read(tbl, pk)
        if r and matches(q, r) then
            out[#out + 1] = r
            return early and #out >= want
        end
        return false
    end
    -- An ordered read can stop at the limit, and one in desc order reads
    -- from the end to do so.
    local function order_by(o: boolean)
        ordered, early, back = o, o and want ~= nil, o and q.desc
    end
    -- Reads the rows of index plan ix's keys, only those in `only` when
    -- given, span by span when the plan has spans. Answers false when it
    -- gave up after `budget` keys. A scan of
    -- the rows themselves reads each row with its key, and one of a unique
    -- index reads each pk with its key; one that stops at a limit starts
    -- with a page of that many keys.
    local function scan_index(ix: any, only: any, budget: number?): boolean
        local seen, over = 0, false
        local primary, unique = ix.ix.primary, ix.ix.unique
        local rowValues = primary and only == nil
        local function each(k: string, v: string?): boolean
            seen += 1
            if budget and seen > budget then
                over = true
                return true
            end
            local pk = if primary then lay.row_pk(tbl.t, k) else lay.pk_of(tbl.t, ix.ix, k, v)
            if only and not only[pk] then
                return false
            end
            return consider(pk, if rowValues then v else nil)
        end
        local scan, first
        if rowValues or (unique and not primary) then
            first = if early then math.max(want, 16) elseif budget then budget + 1 else nil
            scan = back and lay.scan_back_values or lay.scan_values
        else
            scan = back and lay.scan_back or lay.scan
        end
        local spans = ix.spans or { ix }
        local n = #spans
        for i = 1, n do
            -- a cursor may have moved the plan's ends into its spans
            local s = spans[if back then n + 1 - i else i]
            local lo = if s.lo > ix.lo then s.lo else ix.lo
            local hi = if s.hi < ix.hi then s.hi else ix.hi
            if lo < hi and scan(lo, hi, each, first) then
                break
            end
        end
        return not over
    end
    local done = false
    if idset and p.within and #idset > 0 and want ~= 0 then
        -- reading more index keys than there are linked rows would cost
        -- more than reading the rows, unless using() named the index
        order_by(p.within.ordered)
        local only = {}
        for _, pk in idset do
            only[pk] = true
        end
        done = scan_index(p.within, only, if q.use then nil else #idset)
        if not done then
            out = {}
        end
    end
    if not done then
        order_by(p.ordered)
        if idset then
            local n = #idset
            for i = 1, n do
                if consider(idset[back and n + 1 - i or i]) then
                    break
                end
            end
        elseif want ~= 0 then
            scan_index(p)
        end
    end
    if not ordered then
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
    rows_only(self, "ids")
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

local AGGREGATES = { count = true, sum = true, avg = true, min = true, max = true }
local DISTINCT = { count = true, sum = true, avg = true }

-- Checks the aggregate `name` = { fn, field?, distinct? } or { fn, value,
-- distinct? }. Its kind is the lent kind of its result, or "any" when only
-- the rows can tell.
local function aggregate_spec(tbl: any, name: any, spec: any): any
    if type(name) ~= "string" or type(spec) ~= "table" then
        fail(tbl.where .. " query aggregate takes a table of name = { fn = ..., field = ... }")
    end
    local at = tbl.where .. " query aggregate " .. name
    for k in spec do
        if k ~= "fn" and k ~= "field" and k ~= "value" and k ~= "distinct" then
            fail(at .. " has no option " .. tostring(k))
        end
    end
    local fn, field, value, distinct = spec.fn, spec.field, spec.value, spec.distinct
    if not AGGREGATES[fn] then
        fail(at .. " has no function " .. tostring(fn) .. "; use count, sum, avg, min or max")
    end
    if distinct ~= nil and type(distinct) ~= "boolean" then
        fail(at .. " distinct must be true or false, got " .. tostring(distinct))
    end
    if distinct and not DISTINCT[fn] then
        fail(at .. " is " .. fn .. ", which takes no distinct; use it with count, sum or avg")
    end
    distinct = distinct or nil
    if value ~= nil then
        if field ~= nil then
            fail(at .. " has both field and value; give one")
        end
        if type(value) ~= "function" then
            fail(at .. " value must be a function, got " .. tostring(value))
        end
        local kind = fn == "count" and "int" or (fn == "min" or fn == "max") and "any" or "float"
        return { name = name, fn = fn, value = value, at = at, distinct = distinct, kind = kind }
    end
    if field == nil then
        if fn ~= "count" then
            fail(at .. " needs a field or value for " .. fn)
        end
        if distinct then
            fail(at .. " counts distinct values, so it needs a field or value")
        end
        return { name = name, fn = fn, kind = "int" }
    end
    local kind = kind_of(tbl, field)
    if (fn == "sum" or fn == "avg") and kind ~= "int" and kind ~= "float" and kind ~= "decimal" then
        fail(tbl.where .. " field " .. field .. " is " .. kind
            .. ", so " .. fn .. " needs int, float or decimal")
    end
    if (fn == "min" or fn == "max") and kind == "json" then
        fail(tbl.where .. " field " .. field .. " is json, which has no order")
    end
    local f = tbl.byName[field] or tbl.computedByName[field]
    -- a decimal sum adds whole units of its scale, so it is exact
    local scale = (fn == "sum" or fn == "avg") and kind == "decimal" and f.scale or nil
    local result = fn == "count" and "int" or fn == "avg" and "float" or kind
    return { name = name, fn = fn, field = field, scale = scale, distinct = distinct,
             kind = result }
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
    if a.fn == "sum" or a.fn == "avg" then
        if t ~= "number" then
            fail(a.at .. " value answered " .. tostring(v) .. ", so " .. a.fn .. " needs a number")
        end
    elseif not ORDERED[t] then
        fail(a.at .. " value answered a " .. t .. ", which has no order")
    elseif acc ~= nil and type(acc) ~= t then
        fail(a.at .. " value answered a " .. t .. " after a " .. type(acc))
    end
    return v
end

-- Whether value v is new to `seen`, the values a distinct aggregate has
-- read so far, which it then joins. JSON values compare by their text.
local function first_time(seen: any, v: any): boolean
    local t = type(v)
    local key = v
    if t == "table" then
        key = VALUES.json(v)
    elseif v ~= v then
        key = "nan"
    end
    local set = seen[t]
    if set == nil then
        set = {}
        seen[t] = set
    end
    if set[key] then
        return false
    end
    set[key] = true
    return true
end

-- Adds row r to aggregate a's running value acc. Rows without a value for
-- the field, or whose value function answers nil, are skipped, and so are
-- values already in `seen` for a distinct aggregate. An avg runs as
-- { sum, n }.
local function fold(a: any, acc: any, r: any, seen: any): any
    if a.fn == "count" and a.field == nil and a.value == nil then
        return (acc or 0) + 1
    end
    local v = fold_value(a, acc, r)
    if v == nil or (seen and not first_time(seen, v)) then
        return acc
    elseif a.fn == "count" then
        return (acc or 0) + 1
    elseif a.fn == "sum" or a.fn == "avg" then
        if a.scale then
            v = VALUES.decimal_units(v, a.scale)
        end
        if a.fn == "sum" then
            return (acc or 0) + v
        end
        acc = acc or { sum = 0, n = 0 }
        acc.sum += v
        acc.n += 1
        return acc
    elseif acc == nil then
        return v
    elseif a.fn == "min" then
        if less(v, acc) then return v end
        return acc
    end
    if less(acc, v) then return v end
    return acc
end

-- Aggregate a's answer from its running value acc.
local function result(a: any, acc: any): any
    if a.fn == "avg" then
        if acc == nil then
            return nil
        end
        local v = acc.sum / acc.n
        return a.scale and v / 10 ^ a.scale or v
    end
    if acc == nil and (a.fn == "count" or a.fn == "sum") then
        acc = 0
    end
    if a.scale then
        return acc / 10 ^ a.scale
    end
    return acc
end

-- Checks a groupBy key: a field, or an edge with one row at its far end,
-- which groups by the linked row's id.
local function group_key(tbl: any, name: any): any
    if type(name) ~= "string" then
        fail(tbl.where .. " query groupBy takes field or edge names, got " .. tostring(name))
    end
    if (name == "id" and tbl.linksOf == nil) or tbl.byName[name] or tbl.computedByName[name] then
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

-- The test of a having(cond, params) call for the group rows of keys and
-- aggs: a function of a group row, which an expression string compiles to.
local function group_test(tbl: any, keys: { any }, aggs: { any }, h: any): (any) -> boolean
    if type(h.cond) == "function" then
        return h.cond
    end
    local kinds = {}
    for _, k in keys do
        kinds[k.name] = k.kind
    end
    for _, a in aggs do
        kinds[a.name] = a.kind
    end
    local parts = EXPR.compile(h.cond, function(name) return kinds[name] end, h.params,
                               "LENT " .. tbl.where .. " query groupBy having")
    return function(row)
        for _, p in parts do
            if p.fn then
                if not p.fn(row) then return false end
            elseif not holds({ op = p.op, value = p.value, kind = kinds[p.field] }, row[p.field]) then
                return false
            end
        end
        return true
    end
end

-- Group rows `out` in the order of the order(name, dir) calls in `orders`,
-- with ties in the order they come.
local function order_groups(tbl: any, keys: { any }, aggs: { any }, orders: { any },
                            out: { any })
    local known = {}
    for _, k in keys do
        known[k.name] = true
    end
    for _, a in aggs do
        known[a.name] = a.kind ~= "json"
    end
    for _, o in orders do
        if not known[o.name] then
            fail(tbl.where .. " query groupBy order has no group key or aggregate "
                .. tostring(o.name))
        end
    end
    local at = {}
    for i, row in out do
        at[row] = i
    end
    table.sort(out, function(a, b)
        for _, o in orders do
            local x, y = a[o.name], b[o.name]
            if x ~= y then
                if o.desc then
                    return less(y, x)
                end
                return less(x, y)
            end
        end
        return at[a] < at[b]
    end)
end

-- One row per group of q's rows, with the keys' values and each aggregate
-- of spec. `shape` holds the having, order, offset and limit calls of a
-- groupBy; without order calls, groups come in the order of their keys.
local function aggregate(q: any, keys: { any }, spec: any, shape: any?): { any }
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
    local tests = {}
    for i, h in shape and shape.tests or {} do
        tests[i] = group_test(tbl, keys, aggs, h)
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
            g = { key = key, values = values, acc = {}, seen = {} }
            groups[key] = g
            list[#list + 1] = g
        end
        for _, a in aggs do
            local seen
            if a.distinct then
                seen = g.seen[a.name] or {}
                g.seen[a.name] = seen
            end
            g.acc[a.name] = fold(a, g.acc[a.name], r, seen)
        end
    end
    if #keys == 0 and #list == 0 then
        list[1] = { key = "", values = {}, acc = {} }
    end
    table.sort(list, function(a, b)
        return a.key < b.key
    end)
    local out = {}
    for _, g in list do
        local row = {}
        for j, k in keys do
            row[k.name] = g.values[j]
        end
        for _, a in aggs do
            row[a.name] = result(a, g.acc[a.name])
        end
        local keep = true
        for _, test in tests do
            if not test(row) then
                keep = false
                break
            end
        end
        if keep then
            out[#out + 1] = row
        end
    end
    if shape == nil then
        return out
    end
    if #shape.orders > 0 then
        order_groups(tbl, keys, aggs, shape.orders, out)
    end
    if shape.skip > 0 or shape.lim ~= nil then
        local first = shape.skip + 1
        local last = shape.lim and math.min(#out, shape.skip + shape.lim) or #out
        out = first <= last and table.move(out, first, last, 1, {}) or {}
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
-- result, after any having, order, offset and limit calls.
function Query:groupBy(...: string): any
    local names = { ... }
    if #names == 0 then
        fail(self.tbl.where .. " query groupBy takes at least one field or edge")
    end
    local keys = {}
    for i, name in names do
        keys[i] = group_key(self.tbl, name)
    end
    return setmetatable({ q = self, keys = keys, tests = {}, orders = {}, skip = 0 }, Grouped)
end

-- Keeps the groups for which fn(group) answers true, or for which the
-- expression string answers true; it reads the group's keys and aggregates
-- by name, and `params` by name, as where does. Each call adds a test.
function Grouped:having(cond: any, params: any?): any
    if type(cond) ~= "function" and type(cond) ~= "string" then
        fail(self.q.tbl.where .. " query groupBy having takes a function or an expression"
            .. " string, got " .. tostring(cond))
    end
    if type(cond) == "function" and params ~= nil then
        fail(self.q.tbl.where .. " query groupBy having takes parameters with an expression"
            .. " string only")
    end
    self.tests[#self.tests + 1] = { cond = cond, params = params }
    return self
end

-- Orders the groups by a group key or aggregate, "asc" (the default) or
-- "desc". Each call adds a sort key after the earlier ones; groups that tie
-- on every one come in key order.
function Grouped:order(name: string, dir: string?): any
    if dir ~= nil and dir ~= "asc" and dir ~= "desc" then
        fail(self.q.tbl.where .. " query groupBy order direction must be asc or desc, got "
            .. tostring(dir))
    end
    self.orders[#self.orders + 1] = { name = name, desc = dir == "desc" }
    return self
end

function Grouped:limit(n: number): any
    self.lim = count_arg(self.q, "groupBy limit", n)
    return self
end

function Grouped:offset(n: number): any
    self.skip = count_arg(self.q, "groupBy offset", n)
    return self
end

-- One row per group with the keys and each aggregate of spec, after the
-- having, order, offset and limit calls.
function Grouped:aggregate(spec: { [string]: any }?): { any }
    return aggregate(self.q, self.keys, spec or {}, self)
end

-- Updates the selected rows in query order, with the same values and clear
-- list as Table:update. Select every id before writes can move index entries
-- or change which rows match. Answers how many rows were updated.
function Query:update(values: { [string]: any }?, clear: { string }?): number
    local tbl = self.tbl
    rows_only(self, "update")
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
    rows_only(self, "delete")
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
    local l = self.tbl.linksOf
    if l then
        return "links " .. l.e.store .. " from (" .. l.q:explain() .. ")"
    end
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
    rows_only(self, "follow")
    local ids, stores, last = self:ids(), {}, nil
    for i, name in names do
        local e = find_edge(tbl, name)
        for _, h in hops(tbl, e) do
            stores[#stores + 1] = h.e.store
        end
        -- whereEdge on the answer filters the links of the last edge
        last = { tbl = tbl, e = e, from = ids }
        ids = reach(tbl, e, ids)
        tbl = tbl.peers[e.target]
        if tbl.queryRules and i < #names then
            -- the next hop starts from the rows the viewer can read
            local q = tbl:query()
            q.idset, q.via = ids, table.concat(stores, "/")
            ids = q:ids()
        end
    end
    local q = tbl:query()
    q.idset, q.via, q.edgeOf = ids, table.concat(stores, "/"), last
    return q
end

-- A query over the links through edge `name` from the matching rows, one
-- row per link: the matching row's id in `from`, the linked row's id in
-- `to`, and the link's values filled with defaults. where, order, limit,
-- offset, groupBy and the aggregates work on these rows.
function Query:links(name: string): any
    local tbl = self.tbl
    rows_only(self, "links")
    local e = find_edge(tbl, name)
    if e.dir == "through" then
        fail(tbl.where .. " edge " .. name .. " is an edge.through; links reads the links of an"
            .. " edge.to or edge.from")
    end
    local byName = {
        from = { name = "from", kind = lay.id_kind(tbl.t) },
        to = { name = "to", kind = lay.id_kind(tbl.peers[e.target].t) },
    }
    local es = tbl.links[e.store]
    for fname, f in es and es.byName or {} do
        byName[fname] = f
    end
    return new_query({ where = tbl.where .. " links " .. name, byName = byName,
                         computedByName = {}, edgeByName = {}, t = tbl.t,
                         linksOf = { tbl = tbl, e = e, q = self } })
end

-- Keeps the rows that link to at least one row through edge `name`. With
-- fn, the linked row must also match the query fn(q) builds, from where,
-- has and using calls; fn may answer q or nothing.
function Query:has(name: string, fn: ((any) -> any)?): any
    local tbl = self.tbl
    rows_only(self, "has")
    local e = find_edge(tbl, name)
    local sub
    if fn ~= nil then
        if type(fn) ~= "function" then
            fail(tbl.where .. " query has takes a function, got " .. tostring(fn))
        end
        -- the far table's query rules leave has alone, as Go ent's edge
        -- predicates do, so rules may filter with has
        sub = new_query(tbl.peers[e.target])
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
    rows_only(self, "with")
    local e = find_edge(self.tbl, name)
    if fn ~= nil and type(fn) ~= "function" then
        fail(self.tbl.where .. " query with takes a function, got " .. tostring(fn))
    end
    self.loads[#self.loads + 1] = { e = e, fn = fn }
    return self
end

-- Inside has(name, fn) and with(name, fn), and on the answer of follow:
-- keeps the linked rows whose link through that edge holds `field op
-- value`, as where does for a row's fields. After follow, a row stays when
-- one of the links of the last edge that reach it matches. whereEdge(fn)
-- keeps the links for which fn(values) answers true.
function Query:whereEdge(field: any, op: string?, value: any): any
    local l = self.edgeOf
    if l == nil then
        fail(self.tbl.where .. " query whereEdge works inside the function given to has or"
            .. " with, and after follow")
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
function client(pessimistic: boolean?, app: any?, viewer: any?, free: boolean?,
                hookDepth: number?): any
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
        c[t.name] = bind(t, compiled.version, pessimistic, app and app.tables[t.name], free)
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
    -- policy rules read and write through a client that has no rules, and
    -- whose hooks count toward the same depth
    local rules
    local hookStack = {}
    local function rulesClient(): any
        if rules == nil then
            rules = client(pessimistic, app, nil, true)
            for _, b in rules do
                b.hookStack, b.hookDepth = hookStack, hookDepth or HOOK_DEPTH
            end
        end
        return rules
    end
    for _, b in c do
        b.peers = c
        b.allEdges = compiled.edges
        b.links = links
        b.pathUses = pathUses
        b.viewer = viewer
        b.rulesClient = rulesClient
        b.hookStack, b.hookDepth = hookStack, hookDepth or HOOK_DEPTH
    end
    return setmetatable(c, {
        __index = function(_, name)
            fail("this space's schema has no table " .. tostring(name))
        end,
    })
end

-- Each write call runs in a savepoint: when it raises, every key it wrote,
-- its hooks' writes included, goes back to what the transaction held before
-- the call, and the error comes out as it was. Outside a transaction the
-- call runs as it is.
local function atomic(write: (...any) -> ...any): (...any) -> ...any
    return function(...)
        if barch.tx.open() then
            return barch.tx.savepoint(write, ...)
        end
        return write(...)
    end
end

for _, name in { "create", "createMany", "update", "upsert", "delete", "link", "unlink" } do
    Table[name] = atomic(Table[name])
end
Query.update = atomic(Query.update)
Query.delete = atomic(Query.delete)

-- Runs fn(c) in a transaction and answers what it answers.
function tx(fn: (any) -> any, pessimistic: boolean?, app: any?, viewer: any?,
            hookDepth: number?): any
    return barch.tx.run(function()
        return fn(client(pessimistic, app, viewer, nil, hookDepth))
    end, pessimistic == true)
end

-- A client bound to `app`, the graph the space was migrated with, so its
-- function defaults, validate functions, hooks and policy rules run:
-- db.tx(fn, pessimistic, viewer) and db.client(pessimistic, viewer) work as
-- tx and client do, and the rules get `viewer`. options.hookDepth sets how
-- deep hooks may nest, 16 when left out.
function open(app: any, options: any?): any
    if type(app) ~= "table" or type(app.tables) ~= "table" then
        fail("open takes the graph from lent.graph")
    end
    if options ~= nil and type(options) ~= "table" then
        fail("open takes a table of options, got " .. type(options))
    end
    local hookDepth
    for k, v in options or {} do
        if k ~= "hookDepth" then
            fail("open has no option " .. tostring(k) .. "; it takes hookDepth")
        elseif type(v) ~= "number" or v < 1 or v ~= math.floor(v) then
            fail("open option hookDepth takes a whole number of at least 1, got " .. tostring(v))
        end
        hookDepth = v
    end
    return {
        tx = function(fn: (any) -> any, pessimistic: boolean?, viewer: any?): any
            return tx(fn, pessimistic, app, viewer, hookDepth)
        end,
        client = function(pessimistic: boolean?, viewer: any?): any
            return client(pessimistic, app, viewer, nil, hookDepth)
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
