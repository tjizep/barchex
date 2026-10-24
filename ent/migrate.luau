-- Puts a declared ent schema into a space: the catalog in the graph, and the
-- index entries a change of indexes needs, in one transaction.
--
-- Required, not called: `local m = require("ent.MIGRATE")`. A function key
-- has to define call(), so this one answers a self-check of plan():
--
--   ent.MIGRATE             -> "ok" or which check failed (from any space)
--
-- From the application's space, with the tables SCHEMA's graph() checked:
--
--   local report = m.migrate(app)   -- { version = 2, changed = true,
--                                   --   steps = { "build User.by_email" } }
--
-- migrate() runs in barch.tx.run, so it retries on a conflict and leaves
-- nothing behind when it raises an error. A run that changes nothing writes
-- nothing and answers the current version.
--
-- The catalog, in the space's graph:
--
--   /ent/version                           the version, bumped by each change
--   /ent/compiled                          the whole schema as JSON, which
--                                          load() reads: one GRAPH GET
--   /ent/tables/<table>/table              name, format, id kind and next
--                                          field id
--   /ent/tables/<table>/fields/<field>     kind, id, optional, unique, default
--                                          and the value rules: immutable,
--                                          min, max, minLen, maxLen, match
--   /ent/tables/<table>/indexes/<ix>/spec  unique
--   /ent/tables/<table>/indexes/<ix>/on/1  a link to the first field's node
--   /ent/edges/<edge>/from, /to            links to the two tables' nodes
--
-- plan() refuses a change that would leave stored rows unreadable or wrong:
--   - dropping a table;
--   - changing a table's id kind, which its stored keys are written in;
--   - a new field that is neither optional nor has a default;
--   - changing a field's kind, except int to float and int to or from time;
--   - renaming a field of a table that has ever stored json rows, since
--     those rows name their fields;
--   - two tables that store under one key.
-- apply() refuses a unique index that two rows' values already break.

local SCHEMA = require("ent.SCHEMA")
local rc = require("ent.ROWCODEC")
local lay = require("ent.LAYOUT")

local function fail(msg: string)
    error("MIGRATE " .. msg, 0)
end

-- the numeric value rules a catalog field may carry
local RULES = { "min", "max", "minLen", "maxLen" }

-- kind changes that read stored values as they are
local SAME_STORE = { ["int>float"] = true, ["int>time"] = true, ["time>int"] = true }

local function num(v: any): any
    return type(v) == "integer" and integer.tonumber(v) or v
end

-- A string that two equal schemas share, whatever order their keys came in.
local function canon(v: any): string
    v = num(v)
    if type(v) == "string" then
        return string.format("%q", v)
    end
    if type(v) ~= "table" then
        return tostring(v)
    end
    local keys = {}
    for k in v do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    local parts = table.create(#keys)
    for i, k in keys do
        parts[i] = tostring(k) .. "=" .. canon(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function same_index(a: any, b: any): boolean
    if (a.unique == true) ~= (b.unique == true) or #a.on ~= #b.on then
        return false
    end
    for i, f in a.on do
        if b.on[i] ~= f then
            return false
        end
    end
    return true
end

-- The compiled schema in this space's catalog, or nil before the first
-- migration.
function load(): any
    local s = barch.graph.get("/ent/compiled")
    if s == nil then
        return nil
    end
    local c = simdjson.parse(s)
    c.version = num(c.version)
    for _, t in c.tables do
        t.next = num(t.next)
        for _, f in t.fields do
            f.id = num(f.id)
            f.default = num(f.default)
            for _, k in RULES do
                f[k] = num(f[k])
            end
        end
        for k, id in t.ids do
            t.ids[k] = num(id)
        end
    end
    return c
end

-- What a migration from `prev` (load()'s answer, or nil) to `app` would do:
-- { version, changed, compiled, steps = { { op = "build" | "drop", table,
-- index } } }. Raises an error for a change it refuses.
function plan(prev: any, app: any): any
    prev = prev or { version = 0, tables = {}, edges = {} }
    local tables, steps = {}, {}
    for _, name in app.order do
        local t = app.tables[name]
        local where = "table " .. name
        local old = prev.tables[t.key]
        if old and old.name ~= name then
            fail(where .. " stores as " .. t.key .. ", which table " .. old.name .. " uses")
        end
        -- a catalog from before tables had an id kind holds int ids
        if old and (old.id or "int") ~= t.id then
            fail(where .. " has " .. (old.id or "int") .. " ids, so its schema needs id = \""
                .. (old.id or "int") .. "\"; a table keeps the id kind its rows were stored with")
        end
        local before = {}
        if old then
            for _, f in old.fields do
                before[f.name] = f
            end
        end
        for _, f in t.fields do
            local was = before[f.name] or (f.was and before[f.was])
            if old and was == nil and not f.optional and f.default == nil then
                fail(where .. " field " .. f.name .. " is new, so rows stored before it have"
                    .. " no value; make it :optional() or give it a :default() value"
                    .. " (a function default fills only new rows)")
            end
            if was and was.kind ~= f.kind and not SAME_STORE[was.kind .. ">" .. f.kind] then
                fail(where .. " field " .. f.name .. " changes kind from " .. was.kind
                    .. " to " .. f.kind)
            end
            if was and was.name ~= f.name and old.jsonRows then
                fail(where .. " field " .. f.name .. " renames " .. was.name .. ", but the"
                    .. " table has stored json rows, which name their fields")
            end
        end

        local ver, list = SCHEMA.ids(t, old and { ids = old.ids, next = old.next })
        local fields = {}
        for i, f in t.fields do
            fields[i] = { name = f.name, kind = f.kind, id = list[i].id, optional = f.optional,
                          unique = f.unique, default = f.default, immutable = f.immutable,
                          match = f.match }
            for _, k in RULES do
                fields[i][k] = f[k]
            end
        end
        local c = {
            name = name, key = t.key, format = t.format, id = t.id, next = ver.next, ids = ver.ids,
            jsonRows = (old and old.jsonRows) or t.format == "json",
            fields = fields, indexes = t.indexes, edges = {},
        }
        for i, e in t.edges do
            c.edges[i] = { name = e.name, dir = e.dir, target = e.target, unique = e.unique,
                           store = e.store }
        end
        tables[t.key] = c

        local had = {}
        if old then
            for _, ix in old.indexes do
                had[ix.name] = ix
            end
        end
        for _, ix in t.indexes do
            local o = had[ix.name]
            if o == nil or not same_index(o, ix) then
                if o then
                    steps[#steps + 1] = { op = "drop", table = old, index = o }
                end
                steps[#steps + 1] = { op = "build", table = c, index = ix }
            end
            had[ix.name] = nil
        end
        for _, ix in old and old.indexes or {} do
            if had[ix.name] then
                steps[#steps + 1] = { op = "drop", table = old, index = ix }
            end
        end
    end
    for key, old in prev.tables do
        if tables[key] == nil then
            fail("table " .. old.name .. " is missing from the schema; dropping a table"
                .. " is not supported yet")
        end
    end
    -- drops first, so an index rebuilt under its own name starts empty
    table.sort(steps, function(a, b)
        return a.op == "drop" and b.op == "build"
    end)

    local compiled = { tables = tables, edges = app.edges }
    local prevShape = { tables = prev.tables, edges = prev.edges }
    local changed = canon(compiled) ~= canon(prevShape)
    compiled.version = changed and prev.version + 1 or prev.version
    return { version = compiled.version, changed = changed, compiled = compiled, steps = steps }
end

local function row_fields(t: any): any
    return rc.fields(t.fields)
end

local function drop(t: any, ix: any)
    lay.walk(lay.index(t, ix), function(k)
        barch.store.remove(k)
    end)
end

local function build(t: any, ix: any)
    local fields = row_fields(t)
    lay.walk(lay.row(t), function(k)
        local pk = lay.row_pk(t, k)
        local r = lay.fill(t, rc.decode(fields, barch.store.get(k)))
        local key, value = lay.entry(t, ix, r, pk)
        if key == nil then
            return
        end
        if ix.unique then
            local other = barch.store.get(key)
            if other ~= nil then
                fail("table " .. t.name .. " index " .. ix.name .. " is unique, but rows "
                    .. other .. " and " .. pk .. " hold the same values")
            end
        end
        barch.store.set(key, value)
    end)
end

local function mkdir(path: string)
    if barch.graph.stat(path) == nil then
        barch.graph.mkdir(path)
    end
end

local function write_catalog(c: any)
    local g = barch.graph
    mkdir("/ent")
    for _, dir in { "/ent/tables", "/ent/edges" } do
        if g.stat(dir) then
            g.remove(dir, true)
        end
        g.mkdir(dir)
    end
    local nodes = {}
    for key, t in c.tables do
        local base = "/ent/tables/" .. key
        g.mkdir(base)
        g.put(base .. "/table", simdjson.encode({ name = t.name, format = t.format, id = t.id,
                                                  next = t.next }), "json")
        nodes[t.name] = g.stat(base .. "/table").id
        g.mkdir(base .. "/fields")
        local fieldNode = {}
        for _, f in t.fields do
            local path = base .. "/fields/" .. f.name
            g.put(path, simdjson.encode(f), "json")
            fieldNode[f.name] = g.stat(path).id
        end
        g.mkdir(base .. "/indexes")
        for _, ix in t.indexes do
            local dir = base .. "/indexes/" .. ix.name
            g.mkdir(dir)
            g.put(dir .. "/spec", simdjson.encode({ unique = ix.unique }), "json")
            g.mkdir(dir .. "/on")
            for i, fname in ix.on do
                g.link(fieldNode[fname], dir .. "/on/" .. i)
            end
        end
    end
    for store, e in c.edges do
        local dir = "/ent/edges/" .. store
        g.mkdir(dir)
        g.link(nodes[e.from], dir .. "/from")
        g.link(nodes[e.to], dir .. "/to")
    end
    g.put("/ent/compiled", simdjson.encode(c), "json")
    g.put("/ent/version", tostring(c.version))
end

-- Writes the plan: index drops and builds, then the catalog.
function apply(p: any)
    for _, s in p.steps do
        if s.op == "drop" then
            drop(s.table, s.index)
        else
            build(s.table, s.index)
        end
    end
    write_catalog(p.compiled)
end

-- Migrates this space to `app` in one transaction.
function migrate(app: any): any
    return barch.tx.run(function()
        local p = plan(load(), app)
        local steps = {}
        for i, s in p.steps do
            steps[i] = s.op .. " " .. s.table.name .. "." .. s.index.name
        end
        if p.changed then
            apply(p)
        end
        return { version = p.version, changed = p.changed, steps = steps }
    end)
end

local function raises(fn: () -> (), want: string): boolean
    local ok, why = pcall(fn)
    return not ok and string.find(tostring(why), want, 1, true) ~= nil
end

function selftest(): (boolean, string?)
    local ent = SCHEMA
    local function v1()
        return ent.graph { ent.schema "User" {
            format = "json",
            fields = { ent.field.string "email":unique(), ent.field.string "name",
                       ent.field.int "age":optional() },
            indexes = { ent.index("name") },
        } }
    end
    local p1 = plan(nil, v1())
    if p1.version ~= 1 or not p1.changed or #p1.steps ~= 2 then
        return false, "first plan"
    end
    local c1 = p1.compiled
    -- through JSON and back, as load() would see it
    local stored = simdjson.parse(simdjson.encode(c1))
    if plan(stored, v1()).changed then
        return false, "an unchanged schema planned a change"
    end
    local p2 = plan(stored, ent.graph { ent.schema "User" {
        fields = { ent.field.string "email", ent.field.string "name",
                   ent.field.float "age":optional(), ent.field.bool "admin":default(false) },
        indexes = { ent.index("name", "age") },
    } })
    local ops = {}
    for _, s in p2.steps do
        ops[#ops + 1] = s.op .. " " .. s.index.name
    end
    table.sort(ops)
    if p2.version ~= 2 or table.concat(ops, ",") ~= "build by_name_age,drop by_email,drop by_name"
        or p2.steps[#p2.steps].op ~= "build" or not p2.compiled.tables.user.jsonRows
        or p2.compiled.tables.user.ids.admin ~= 4 then
        return false, "second plan " .. table.concat(ops, ",")
    end

    local refused = {
        { { ent.field.string "email", ent.field.string "name", ent.field.int "age":optional(),
            ent.field.int "score" }, "is new" },
        { { ent.field.string "email", ent.field.int "name", ent.field.int "age":optional() },
          "changes kind from string to int" },
        { { ent.field.string "email", ent.field.string "full":was("name"),
            ent.field.int "age":optional() }, "has stored json rows" },
    }
    for i, case in refused do
        local app = ent.graph { ent.schema "User" { fields = case[1] } }
        if not raises(function() plan(stored, app) end, case[2]) then
            return false, "refusal " .. i
        end
    end
    local ints = ent.graph { ent.schema "User" { id = "int", fields = {
        ent.field.string "email", ent.field.string "name", ent.field.int "age":optional() } } }
    if not raises(function() plan(stored, ints) end, "needs id = \"uuid\"") then
        return false, "changed the id kind"
    end
    local legacy = simdjson.parse(simdjson.encode(c1))
    legacy.tables.user.id = nil
    if not raises(function() plan(legacy, v1()) end, "has int ids") then
        return false, "read a catalog without id kinds as uuid"
    end
    local other = ent.graph { ent.schema "Post" { fields = { ent.field.string "t" } } }
    if not raises(function() plan(stored, other) end, "dropping a table") then
        return false, "dropped a table"
    end
    return true
end

function call()
    local ok, why = selftest()
    return ok and "ok" or ("failed: " .. why)
end
