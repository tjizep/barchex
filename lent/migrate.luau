-- Puts a declared lent schema into a space: the catalog in the graph, and the
-- index entries a change of indexes needs, in resumable transaction pages.
--
-- Required, not called: `local m = require("lent.MIGRATE")`. A function key
-- has to define call(), so this one answers a self-check of plan():
--
--   lent.MIGRATE             -> "ok" or which check failed (from any space)
--
-- From the application's space, with the tables SCHEMA's graph() checked:
--
--   local report = m.migrate(app, 1000) -- repeat in later calls until report.done
--
-- Each migrate() call runs one page in barch.tx.run. Completed pages survive
-- an error in a later page. A run that changes nothing writes nothing and
-- answers the current version. Call migrate() outside an open transaction.
--
-- The catalog, in the space's graph:
--
--   /lent/version                           the version, bumped by each change
--   /lent/compiled                          the whole schema as JSON, which
--                                          load() reads: one GRAPH GET
--   /lent/tables/<table>/table              name, format, id kind and next
--                                          field id
--   /lent/tables/<table>/fields/<field>     kind, id, optional, unique, default
--                                          and the value rules: immutable,
--                                          min, max, minLen, maxLen, match
--                                          ; a stored computed field adds its
--                                          revision in computed, and state =
--                                          "filling" until its rows are filled
--   /lent/tables/<table>/indexes/<ix>/spec  unique, state = "building" until ready
--   /lent/tables/<table>/indexes/<ix>/on/1  a link to the first field's node
--   /lent/edges/<edge>/from, /to            links to the two tables' nodes
--   /lent/edges/<edge>/fields/<field>       an edge field, as a table's field
--
-- plan() refuses a change that would leave stored rows unreadable or wrong:
--   - dropping a table;
--   - changing a table's id kind, which its stored keys are written in;
--   - a new field that is neither optional nor has a default;
--   - changing a field's kind, except int to float and int to or from time;
--   - renaming a field of a table that has ever stored json rows, since
--     those rows name their fields;
--   - two tables that store under one key.
-- A new stored computed field, or a new revision of one, adds a fill step
-- that computes it for every stored row with the function in `app`, after
-- the drops and before the builds.
-- apply() refuses a unique index that two rows' values already break, and
-- a fill whose function answers a value that does not fit its field.

local SCHEMA = require("lent.SCHEMA")
local rc = require("lent.ROWCODEC")
local lay = require("lent.LAYOUT")
local kc = require("lent.KEYCODEC")
local VALUES = require("lent.VALUES")

local function fail(msg: string)
    error("MIGRATE " .. msg, 0)
end

-- the numeric value rules a catalog field may carry
local RULES = { "min", "max", "minLen", "maxLen" }

-- kind changes that read stored values as they are
local SAME_STORE = { ["int>float"] = true, ["int>time"] = true, ["time>int"] = true,
                     ["enum>string"] = true }

local function num(v: any): any
    return type(v) == "integer" and integer.tonumber(v) or v
end

-- Preserve byte defaults and JSON array/object distinctions in the catalog.
local function field_data(f: any): any
    local out = table.clone(f)
    if f.default ~= nil then
        if f.kind == "json" then
            out.default, out.defaultEncoding = VALUES.json(f.default), "json"
        elseif f.kind == "bytes" or (type(f.default) == "string" and utf8.len(f.default) == nil) then
            out.default, out.defaultEncoding = VALUES.hex(f.default), "hex"
        end
    end
    return out
end

local function logical_edges(edges: any): any
    local out = {}
    for store, e in edges do
        local copy = table.clone(e)
        if e.fields then
            copy.fields = {}
            for i, f in e.fields do copy.fields[i] = field_data(f) end
        end
        out[store] = copy
    end
    return out
end

local function catalog_data(c: any): any
    local out = table.clone(c)
    out.tables = {}
    for key, t in c.tables do
        local copy = table.clone(t)
        copy.fields = {}
        for i, f in t.fields do copy.fields[i] = field_data(f) end
        out.tables[key] = copy
    end
    out.edges = logical_edges(c.edges)
    return out
end

local function key_kind(kind: string): string
    if kind == "enum" or kind == "bytes" then return "string" end
    return kind == "time" and "int" or kind
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

local function same_index(a: any, b: any, before: any, after: any): boolean
    if (a.unique == true) ~= (b.unique == true) or #a.on ~= #b.on then
        return false
    end
    for i, f in a.on do
        if b.on[i] ~= f then
            return false
        end
        local old, new = before[f], after[f]
        local oldKind = old and key_kind(old.kind)
        local newKind = new and key_kind(new.kind)
        if oldKind ~= newKind or canon(old and old.default) ~= canon(new and new.default) then
            return false
        end
    end
    return true
end

local function index_spec(ix: any): any
    return { name = ix.name, on = table.clone(ix.on), unique = ix.unique }
end

-- Progress and readiness do not change a schema's logical shape.
local function logical_tables(tables: any): any
    local out = {}
    for key, t in tables do
        local copy = table.clone(t)
        copy.fields = {}
        for i, f in t.fields do
            copy.fields[i] = field_data(f)
            copy.fields[i].state = nil
        end
        copy.indexes = {}
        for i, ix in t.indexes do copy.indexes[i] = index_spec(ix) end
        out[key] = copy
    end
    return out
end

-- Gives the fields of catalog table or edge `t` their Luau values back.
local function load_fields(t: any)
    t.next = num(t.next)
    for _, f in t.fields or {} do
        f.id = num(f.id)
        f.computed = num(f.computed)
        f.default = num(f.default)
        if f.defaultEncoding == "json" then
            f.default = VALUES.parse_json(f.default)
        elseif f.defaultEncoding == "hex" then
            f.default = VALUES.unhex(f.default)
        elseif f.defaultEncoding ~= nil then
            fail("field " .. f.name .. " has unknown default encoding " .. tostring(f.defaultEncoding))
        end
        f.defaultEncoding = nil
        for _, k in RULES do
            f[k] = num(f[k])
        end
    end
    for k, id in t.ids do
        t.ids[k] = num(id)
    end
end

-- The compiled schema in this space's catalog, or nil before the first
-- migration.
function load(): any
    local s = barch.graph.get("/lent/compiled")
    if s == nil then
        return nil
    end
    local c = simdjson.parse(s)
    c.version = num(c.version)
    if c.migration then c.migration.at = num(c.migration.at) end
    for _, t in c.tables do
        load_fields(t)
    end
    for _, e in c.edges do
        if e.ids then load_fields(e) end
    end
    return c
end

local function by_name(list: { any }?): any
    local out = {}
    for _, f in list or {} do
        out[f.name] = f
    end
    return out
end

-- Checks the change from `old` (the catalog's table or edge, or nil when it
-- is new) to the declared `t`, and answers the catalog's fields for `t` and
-- the field ids SCHEMA.ids gave out.
local function check_fields(where: string, old: any, t: any, before: any): (any, any)
    for _, f in t.fields do
        local was = before[f.name] or (f.was and before[f.was])
        if old and was == nil and not f.optional and f.default == nil then
            fail(where .. " field " .. f.name .. " is new, so " .. (t.dir and "links" or "rows")
                .. " stored before it have no value; make it :optional() or give it a"
                .. " :default() value (a function default fills only new "
                .. (t.dir and "links" or "rows") .. ")")
        end
        if was and was.kind ~= f.kind and not SAME_STORE[was.kind .. ">" .. f.kind] then
            fail(where .. " field " .. f.name .. " changes kind from " .. was.kind
                .. " to " .. f.kind)
        end
        if was and was.kind == "enum" and f.kind == "enum" then
            local allowed = {}
            for _, value in f.values do allowed[value] = true end
            for _, value in was.values do
                if not allowed[value] then
                    fail(where .. " field " .. f.name .. " removes enum value " .. VALUES.json(value))
                end
            end
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
                      match = f.match, values = f.values and table.clone(f.values),
                      computed = f.computed }
        for _, k in RULES do
            fields[i][k] = f[k]
        end
    end
    return fields, ver
end

-- The catalog's record of edge store `s` from the graph, with field ids
-- when the edge stores fields. `old` is the catalog's previous record.
local function edge_record(s: any, old: any): any
    local c = { name = s.name, from = s.from, to = s.to, fromId = s.fromId, toId = s.toId,
                unique = s.unique, inverseUnique = s.inverseUnique }
    if s.fields then
        local decl = { name = s.name, dir = "to", fields = s.fields }
        local fields, ver = check_fields("edge " .. s.name, old, decl,
                                          by_name(old and old.fields))
        c.fields, c.ids, c.next = fields, ver.ids, ver.next
    elseif old and old.ids then
        -- links keep the values of removed fields, so their ids stay used
        c.ids, c.next = old.ids, old.next
    end
    return c
end

-- What a migration from `prev` (load()'s answer, or nil) to `app` would do:
-- { version, changed, compiled, steps = { { op = "build" | "drop", table,
-- index } | { op = "fill", table, fields, fns } } }. Raises an error for a
-- change it refuses.
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
        local before = by_name(old and old.fields)
        local fields, ver = check_fields(where, old, t, before)
        local after = by_name(fields)
        -- stored computed fields that rows stored before need computed:
        -- new ones, and ones whose revision changed
        local fill, fns, refill = {}, {}, {}
        for i, f in fields do
            local d = t.fields[i]
            local was = before[d.name] or (d.was and before[d.was])
            if old and f.computed and (was == nil or num(was.computed) ~= f.computed) then
                fill[#fill + 1] = f.name
                fns[f.name] = d.code.computed
                if was then refill[f.name] = true end
            end
        end
        local c = {
            name = name, key = t.key, format = t.format, id = t.id, next = ver.next, ids = ver.ids,
            jsonRows = (old and old.jsonRows) or t.format == "json",
            fields = fields, indexes = {}, edges = {},
        }
        for i, ix in t.indexes do c.indexes[i] = index_spec(ix) end
        for i, e in t.edges do
            c.edges[i] = { name = e.name, dir = e.dir, target = e.target, unique = e.unique,
                           store = e.store, via = e.via }
        end
        tables[t.key] = c

        local had = {}
        if old then
            for _, ix in old.indexes do
                had[ix.name] = ix
            end
        end
        if #fill > 0 then
            steps[#steps + 1] = { op = "fill", table = c, fields = fill, fns = fns }
        end
        for _, ix in c.indexes do
            local o = had[ix.name]
            local stale = false
            for _, fname in ix.on do
                if refill[fname] then stale = true end
            end
            if o == nil or stale or not same_index(o, ix, before, after) then
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
    -- drops first, so an index rebuilt under its own name starts empty, and
    -- fills before builds, so a build reads the computed values
    local rank = { drop = 1, fill = 2, build = 3 }
    table.sort(steps, function(a, b)
        return rank[a.op] < rank[b.op]
    end)

    local edges = {}
    for store, s in app.edges do
        edges[store] = edge_record(s, prev.edges[store])
    end
    local compiled = { tables = tables, edges = edges }
    local prevShape = { tables = logical_tables(prev.tables), edges = logical_edges(prev.edges) }
    local changed = canon({ tables = logical_tables(tables), edges = logical_edges(edges) })
        ~= canon(prevShape)
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

local function build_row(t: any, ix: any, fields: any, k: string)
    local stored = barch.store.get(k)
    if stored == nil then return end
    local pk = lay.row_pk(t, k)
    local r = lay.fill(t, rc.decode(fields, stored))
    local key, value = lay.entry(t, ix, r, pk)
    if key == nil then return end
    if ix.unique then
        local other = barch.store.get(key, true)
        if other ~= nil and other ~= value then
            fail("table " .. t.name .. " index " .. ix.name .. " is unique, but rows "
                .. other .. " and " .. pk .. " hold the same values")
        end
    end
    barch.store.set(key, value)
end

-- Computes the stored computed fields `names` of the row at key k with
-- their functions `fns`, and stores the row again.
local function fill_row(t: any, names: { string }, fns: any, fields: any, version: number,
                        k: string)
    local stored = barch.store.get(k)
    if stored == nil then return end
    local r = lay.fill(t, (rc.decode(fields, stored)))
    for _, name in names do
        local v = fns[name](table.clone(r))
        for _, f in t.fields do
            local why = f.name == name and SCHEMA.computed_broken(f, v)
            if why then
                fail("table " .. t.name .. " field " .. name .. " " .. why .. " for row "
                    .. tostring(lay.row_pk(t, k)))
            end
        end
        r[name] = v
    end
    barch.store.set(k, rc.encode(fields, t.format, version, r))
end

-- The functions of the stored computed fields `names` of catalog table t,
-- from the graph `app`.
local function fill_fns(app: any, t: any, names: { string }): any
    local fns = {}
    for _, f in app.tables[t.name].fields do
        if table.find(names, f.name) then fns[f.name] = f.code.computed end
    end
    return fns
end

local function build(t: any, ix: any)
    local fields = row_fields(t)
    lay.walk(lay.row(t), function(k)
        build_row(t, ix, fields, k)
    end)
end

local function mkdir(path: string)
    if barch.graph.stat(path) == nil then
        barch.graph.mkdir(path)
    end
end

local function write_catalog(c: any)
    local g = barch.graph
    mkdir("/lent")
    for _, dir in { "/lent/tables", "/lent/edges" } do
        if g.stat(dir) then
            g.remove(dir, true)
        end
        g.mkdir(dir)
    end
    local nodes = {}
    for key, t in c.tables do
        local base = "/lent/tables/" .. key
        g.mkdir(base)
        g.put(base .. "/table", simdjson.encode({ name = t.name, format = t.format, id = t.id,
                                                  next = t.next }), "json")
        nodes[t.name] = g.stat(base .. "/table").id
        g.mkdir(base .. "/fields")
        local fieldNode = {}
        for _, f in t.fields do
            local path = base .. "/fields/" .. f.name
            g.put(path, simdjson.encode(field_data(f)), "json")
            fieldNode[f.name] = g.stat(path).id
        end
        g.mkdir(base .. "/indexes")
        for _, ix in t.indexes do
            local dir = base .. "/indexes/" .. ix.name
            g.mkdir(dir)
            g.put(dir .. "/spec", simdjson.encode({ unique = ix.unique, state = ix.state }), "json")
            g.mkdir(dir .. "/on")
            for i, fname in ix.on do
                g.link(fieldNode[fname], dir .. "/on/" .. i)
            end
        end
    end
    for store, e in c.edges do
        local dir = "/lent/edges/" .. store
        g.mkdir(dir)
        g.link(nodes[e.from], dir .. "/from")
        g.link(nodes[e.to], dir .. "/to")
        if e.fields then
            g.mkdir(dir .. "/fields")
            for _, f in e.fields do
                g.put(dir .. "/fields/" .. f.name, simdjson.encode(field_data(f)), "json")
            end
        end
    end
    g.put("/lent/compiled", simdjson.encode(catalog_data(c)), "json")
    g.put("/lent/version", tostring(c.version))
end

-- Writes the plan: index drops and builds, then the catalog.
function apply(p: any)
    if not barch.tx.open() then
        fail("apply needs an open transaction; use migrate for paged migrations")
    end
    local previous = load()
    if previous and previous.migration then
        fail("a migration is in progress; use migrate to resume it")
    end
    for _, s in p.steps do
        if s.op == "drop" then
            drop(s.table, s.index)
        elseif s.op == "fill" then
            local fields = row_fields(s.table)
            lay.walk(lay.row(s.table), function(k)
                fill_row(s.table, s.fields, s.fns, fields, p.compiled.version, k)
            end)
        else
            build(s.table, s.index)
        end
    end
    write_catalog(p.compiled)
end

local function find_index(t: any, name: string): any
    for _, ix in t.indexes do
        if ix.name == name then return ix end
    end
    fail("table " .. t.name .. " has no index " .. name .. " to resume")
end

-- Drops consume entries from the start; fills and builds remember the last
-- row key. The last page's writes and its readiness change commit together.
-- Fills take their functions from the graph `app`.
local function advance(c: any, budget: number, app: any): number
    local work, processed = c.migration, 0
    while work.at <= #work.steps and processed < budget do
        local step = work.steps[work.at]
        local t = c.tables[step.table]
        local rows = step.op ~= "drop"
        local ix = step.op == "build" and find_index(t, step.index.name) or step.index
        local prefix = rows and lay.row(t) or lay.index(t, ix)
        local lo = rows and work.cursor and work.cursor .. "\2" or prefix
        local hi = kc.after(prefix)
        local limit = budget - processed
        local keys = barch.store.range(lo, hi, limit)
        local fields = rows and row_fields(t)
        local fns = step.op == "fill" and fill_fns(app, t, step.fields)
        for _, k in keys do
            if step.op == "drop" then
                barch.store.remove(k)
            elseif step.op == "fill" then
                fill_row(t, step.fields, fns, fields, c.version, k)
            else
                build_row(t, ix, fields, k)
            end
        end
        processed += #keys
        local nextKey = rows and keys[#keys] and keys[#keys] .. "\2" or prefix
        local done = #keys < limit or #barch.store.range(nextKey, hi, 1) == 0
        if done then
            if step.op == "build" then ix.state = nil end
            if step.op == "fill" then
                for _, f in t.fields do
                    if table.find(step.fields, f.name) then f.state = nil end
                end
            end
            work.at += 1
            work.cursor = nil
        elseif rows then
            work.cursor = keys[#keys]
        end
    end
    if work.at > #work.steps then c.migration = nil end
    return processed
end

local function write_progress(c: any)
    for key, t in c.tables do
        for _, f in t.fields do
            barch.graph.put("/lent/tables/" .. key .. "/fields/" .. f.name,
                simdjson.encode(field_data(f)), "json")
        end
        for _, ix in t.indexes do
            barch.graph.put("/lent/tables/" .. key .. "/indexes/" .. ix.name .. "/spec",
                simdjson.encode({ unique = ix.unique, state = ix.state }), "json")
        end
    end
    barch.graph.put("/lent/compiled", simdjson.encode(catalog_data(c)), "json")
end

-- One committed page toward `app`, with a shared budget for row reads and
-- dropped index entries. Call again with the same app until done is true.
function migrate(app: any, pageSize: number?): any
    pageSize = pageSize == nil and 1000 or pageSize
    if type(pageSize) ~= "number" or pageSize < 1 or pageSize > 10000
        or pageSize ~= math.floor(pageSize) then
        fail("page size must be a whole number from 1 to 10000")
    end
    if barch.tx.open() then
        fail("migrate needs its own transaction; call it outside a transaction")
    end
    return barch.tx.run(function()
        local prev = load()
        local p = plan(prev, app)
        local resuming = prev and prev.migration ~= nil
        if resuming and p.changed then
            fail("a migration is in progress; resume with the same schema until done")
        end
        if not resuming and not p.changed then
            return { version = p.version, changed = false, steps = {}, done = true, processed = 0 }
        end
        local c = resuming and prev or p.compiled
        if not resuming then
            local work = { steps = {}, at = 1 }
            for i, s in p.steps do
                if s.op == "fill" then
                    work.steps[i] = { op = s.op, table = s.table.key, fields = s.fields }
                    for _, f in s.table.fields do
                        if table.find(s.fields, f.name) then f.state = "filling" end
                    end
                else
                    work.steps[i] = { op = s.op, table = s.table.key, index = index_spec(s.index) }
                end
                if s.op == "build" then s.index.state = "building" end
            end
            c.migration = work
        end
        local steps = {}
        for i, s in c.migration.steps do
            local what = s.op == "fill" and table.concat(s.fields, ",") or s.index.name
            steps[i] = s.op .. " " .. c.tables[s.table].name .. "." .. what
        end
        local processed = advance(c, pageSize, app)
        if resuming then write_progress(c) else write_catalog(c) end
        return { version = c.version, changed = true, steps = steps,
                 done = c.migration == nil, processed = processed }
    end)
end

local function raises(fn: () -> (), want: string): boolean
    local ok, why = pcall(fn)
    return not ok and string.find(tostring(why), want, 1, true) ~= nil
end

function selftest(): (boolean, string?)
    local lent = SCHEMA
    local function v1()
        return lent.graph { lent.schema "User" {
            format = "json",
            fields = { lent.field.string "email":unique(), lent.field.string "name",
                       lent.field.int "age":optional() },
            indexes = { lent.index("name") },
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
    local p2 = plan(stored, lent.graph { lent.schema "User" {
        fields = { lent.field.string "email", lent.field.string "name",
                   lent.field.float "age":optional(), lent.field.bool "admin":default(false) },
        indexes = { lent.index("name", "age") },
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
        { { lent.field.string "email", lent.field.string "name", lent.field.int "age":optional(),
            lent.field.int "score" }, "is new" },
        { { lent.field.string "email", lent.field.int "name", lent.field.int "age":optional() },
          "changes kind from string to int" },
        { { lent.field.string "email", lent.field.string "full":was("name"),
            lent.field.int "age":optional() }, "has stored json rows" },
    }
    for i, case in refused do
        local app = lent.graph { lent.schema "User" { fields = case[1] } }
        if not raises(function() plan(stored, app) end, case[2]) then
            return false, "refusal " .. i
        end
    end
    local ints = lent.graph { lent.schema "User" { id = "int", fields = {
        lent.field.string "email", lent.field.string "name", lent.field.int "age":optional() } } }
    if not raises(function() plan(stored, ints) end, "needs id = \"uuid\"") then
        return false, "changed the id kind"
    end
    local legacy = simdjson.parse(simdjson.encode(c1))
    legacy.tables.user.id = nil
    if not raises(function() plan(legacy, v1()) end, "has int ids") then
        return false, "read a catalog without id kinds as uuid"
    end
    local function liked(fields)
        return lent.graph { lent.schema "U" { fields = { lent.field.int "a" }, edges = {
            lent.edge.to "likes" "U":fields(fields) } } }
    end
    local l1 = plan(nil, liked { lent.field.time "at":default(lent.now) })
    local likes = l1.compiled.edges.u_likes
    if likes.fields[1].id ~= 1 or likes.next ~= 2 then
        return false, "edge field ids"
    end
    local linked = simdjson.parse(simdjson.encode(l1.compiled))
    if plan(linked, liked { lent.field.time "at":default(lent.now) }).changed then
        return false, "unchanged edge fields planned a change"
    end
    if not raises(function() plan(linked, liked { lent.field.time "at", lent.field.int "n" }) end,
        "edge u_likes field n is new, so links stored before it have no value") then
        return false, "added a required edge field"
    end

    local function counted(rev, fn)
        return lent.graph { lent.schema "U" { fields = { lent.field.int "a",
            lent.field.int "b":computed(fn):stored(rev) }, indexes = { lent.index("b") } } }
    end
    local double = function(r) return r.a * 2 end
    local plainU = simdjson.parse(simdjson.encode(plan(nil, lent.graph { lent.schema "U" {
        fields = { lent.field.int "a" } } }).compiled))
    local function shape(p)
        local out = {}
        for _, s in p.steps do
            out[#out + 1] = s.op .. " " .. (s.index and s.index.name or table.concat(s.fields, ","))
        end
        return table.concat(out, ",")
    end
    local sp = plan(plainU, counted(1, double))
    if shape(sp) ~= "fill b,build by_b" or sp.compiled.tables.u.fields[2].computed ~= 1
        or sp.steps[1].fns.b({ a = 2 }) ~= 4 then
        return false, "stored computed field plan " .. shape(sp)
    end
    local filled = simdjson.parse(simdjson.encode(sp.compiled))
    if plan(filled, counted(1, function() return 0 end)).changed then
        return false, "a changed function without a new revision planned a change"
    end
    if shape(plan(filled, counted(2, double))) ~= "drop by_b,fill b,build by_b" then
        return false, "stored computed revision plan"
    end
    if #plan(nil, counted(1, double)).steps ~= 1 then
        return false, "a new table planned a fill"
    end

    local other = lent.graph { lent.schema "Post" { fields = { lent.field.string "t" } } }
    if not raises(function() plan(stored, other) end, "dropping a table") then
        return false, "dropped a table"
    end
    return true
end

function call()
    local ok, why = selftest()
    return ok and "ok" or ("failed: " .. why)
end
