-- Creates, reads, updates and deletes the rows of the tables MIGRATE put in
-- a space, and keeps their indexes current in the same transaction.
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
local mig = require("ent.MIGRATE")

local function fail(msg: string)
    error("ENT " .. msg, 0)
end

local Table = {}
Table.__index = Table

local function bind(t: any, version: number, pessimistic: boolean?): any
    local byName = {}
    for _, f in t.fields do
        byName[f.name] = f
    end
    return setmetatable({
        t = t, fields = rc.fields(t.fields), byName = byName, version = version,
        lock = pessimistic == true, where = "table " .. t.name,
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

-- Adds a row and answers it with its new id.
function Table:create(values: { [string]: any }): any
    local r = {}
    set_fields(self, r, values)
    lay.fill(self.t, r)
    local counter = lay.counter(self.t)
    local pk = (tonumber(get(self, counter, true)) or 0) + 1
    return store(self, pk, nil, r, counter)
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

-- Removes the row and its index entries. Answers false if there was none.
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
    barch.store.remove(lay.row(self.t, pk))
    return true
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
    mig.apply(mig.plan(nil, ent.graph { ent.schema "T" {
        fields = { ent.field.string "k":unique(), ent.field.int "n":default(5) },
        indexes = { ent.index("n") },
    } }))
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
