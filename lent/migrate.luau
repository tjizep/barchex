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
--   /lent/tables/<table>/table              name, format, id kind, next
--                                          field id, and a column table's
--                                          block, rows and store
--   /lent/tables/<table>/fields/<field>     kind, id, optional, unique, default
--                                          and the value rules: immutable,
--                                          min, max, minLen, maxLen, match
--                                          ; a stored computed field adds its
--                                          revision in computed, and state =
--                                          "filling" until its rows are filled
--   /lent/tables/<table>/indexes/<ix>/spec  unique, state = "building" until
--                                          ready, and edges, the names of the
--                                          index's edges
--   /lent/tables/<table>/indexes/<ix>/on/1  a link to the first field's node
--   /lent/edges/<edge>/from, /to            links to the two tables' nodes
--   /lent/edges/<edge>/fields/<field>       an edge field, as a table's field
--
-- The store of a stored edge.through is an edge whose compiled record holds
-- its path, and state = "filling" until its links are filled.
--
-- plan() refuses a change that would leave stored rows unreadable or wrong:
--   - a table missing from the schema that lent.drop does not name;
--   - changing a table's id kind, which its stored keys are written in;
--   - a new field that is neither optional nor has a default;
--   - changing a field's kind, except int to float, int to or from time,
--     enum to string and decimal to float;
--   - changing a decimal field's scale;
--   - two tables that store under one key.
--   - turning a stored edge.through into an edge.to or edge.from of the same
--     name, since links added while its paths are dropped would go too.
-- A new stored computed field, or a new revision of one, adds a fill step
-- that computes it for every stored row with the function in `app`, after
-- the drops and before the builds. A new stored edge.through, or one whose
-- path changed, adds a drop step for its store and a fill step that counts
-- each row's paths; one that is removed or no longer stored adds a drop.
-- An enum choice removed with :replaces adds a fill step that rewrites the
-- rows that hold it. Until the fill ends, the catalog field keeps the
-- `replaces` map, so the rows not yet rewritten stay readable. A field
-- renamed in a table that has stored json rows adds a fill step that
-- rewrites those rows with the new name; until it ends, the catalog field
-- keeps the old name in `renames`.
-- A change of format to or from column, or of a column table's block, adds
-- a copy step after the others and then a drop step. The copy writes each
-- row in the new format, and new column blocks go under a new store. The
-- drop removes the old rows or the old store's blocks. Until the copy
-- ends, the catalog table keeps the format, block, rows and store it reads
-- and holds the new ones in `rebuild`, with `upto`, the last row copied:
-- CLIENT writes rows up to it to both copies. The copy's last page switches
-- the table to the new copy.
-- A table that lent.drop names adds a drop step for its rows, column
-- blocks, index entries, counter and statistics, and one for each edge
-- store to or from it. The catalog loses the table at once.
-- apply() refuses a unique index that two rows' values already break, and
-- a fill whose function answers a value that does not fit its field.

local SCHEMA = require("lent.SCHEMA")
local rc = require("lent.ROWCODEC")
local lay = require("lent.LAYOUT")
local col = require("lent.COLUMNS")
local kc = require("lent.KEYCODEC")
local VALUES = require("lent.VALUES")

local function fail(msg: string)
    error("MIGRATE " .. msg, 0)
end

-- the numeric value rules a catalog field may carry
local RULES = { "min", "max", "minLen", "maxLen" }

-- kind changes that read stored values as they are
local SAME_STORE = { ["int>float"] = true, ["int>time"] = true, ["time>int"] = true,
                     ["enum>string"] = true, ["decimal>float"] = true }

local num = VALUES.number

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
    if kind == "decimal" then return "float" end
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
    if (a.unique == true) ~= (b.unique == true) or #a.on ~= #b.on
        or canon(a.links) ~= canon(b.links) then
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
    local links
    for i, l in ix.links or {} do
        links = links or {}
        links[i] = table.clone(l)
    end
    return { name = ix.name, on = table.clone(ix.on), edges = ix.edges and table.clone(ix.edges),
             links = links, unique = ix.unique }
end

-- The JSON of an index's spec node in the catalog.
local function spec_data(ix: any): string
    return simdjson.encode({ unique = ix.unique, state = ix.state, edges = ix.edges })
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
    t.block, t.rows = num(t.block), num(t.rows)
    local m = t.rebuild
    if m then
        -- a block change started before format changes copies into blocks
        m.format = m.format or "column"
        m.block, m.rows, m.upto = num(m.block), num(m.rows), num(m.upto)
        m.fields = m.fields or {}
        for i, rows in m.fields do
            m.fields[i] = num(rows)
        end
    end
    for _, f in t.fields or {} do
        f.id = num(f.id)
        f.rows = num(f.rows)
        f.computed = num(f.computed)
        f.scale = num(f.scale)
        f.since, f.renamesSince = num(f.since), num(f.renamesSince)
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
local function check_fields(where: string, old: any, t: any, before: any,
                            version: number?): (any, any)
    local replaced, renamed, since = {}, {}, {}
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
        if was and was.kind == "decimal" and f.kind == "decimal" and was.scale ~= f.scale then
            fail(where .. " field " .. f.name .. " changes scale from " .. was.scale .. " to "
                .. f.scale)
        end
        if was and was.kind == "enum" and f.kind == "enum" then
            local allowed = {}
            for _, value in f.values do allowed[value] = true end
            -- a removal whose fill is still running keeps its replacements
            local map = was.replaces and table.clone(was.replaces)
            for _, value in was.values do
                local to = not t.dir and f.replaces and f.replaces[value]
                if not allowed[value] and not to then
                    fail(where .. " field " .. f.name .. " removes enum value " .. VALUES.json(value)
                        .. (if t.dir then ", which stored links may hold"
                            else "; name the choice its rows take with :replaces"))
                elseif not allowed[value] then
                    map = map or {}
                    map[value] = to
                end
            end
            replaced[f.name] = map
        end
        -- stored json rows name their fields, so a fill rewrites them with
        -- the new name, and a rename whose fill is still running keeps it.
        -- A value under a field's name in a json row older than the field's
        -- `since` version belongs to a dropped field.
        renamed[f.name] = was and was.renames and { was.renames, was.renamesSince }
        since[f.name] = was and was.since
        if old and old.jsonRows and (was == nil or was.name ~= f.name) then
            since[f.name] = version
            if was then renamed[f.name] = { was.name, was.since } end
        end
    end
    local ver, list = SCHEMA.ids(t, old and { ids = old.ids, next = old.next })
    local fields = {}
    for i, f in t.fields do
        fields[i] = { name = f.name, kind = f.kind, id = list[i].id, optional = f.optional,
                      unique = f.unique, default = f.default, immutable = f.immutable,
                      match = f.match, values = f.values and table.clone(f.values),
                      replaces = replaced[f.name], since = since[f.name],
                      renames = renamed[f.name] and renamed[f.name][1],
                      renamesSince = renamed[f.name] and renamed[f.name][2],
                      scale = f.scale, computed = f.computed }
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
    if s.path then
        c.edge, c.path = s.edge, s.path
        if old and old.path and canon(old.path) == canon(s.path) then
            c.state = old.state
        end
    end
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

-- The fill function of enum field `f`, which answers a row's value with
-- each removed choice replaced.
local function replacer(f: any): (any) -> any
    return function(r)
        local v = r[f.name]
        return if v ~= nil and f.replaces[v] then f.replaces[v] else v
    end
end

-- The fill function of renamed field `f`, which answers the row's value.
local function keeper(f: any): (any) -> any
    return function(r)
        return r[f.name]
    end
end

-- The keys of map `m`, in order.
local function sorted(m: any): { string }
    local keys = {}
    for k in m do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

-- "Table.edge", the edge of catalog `c` that edge store `store` holds.
local function edge_label(c: any, store: string): string
    local s = c.edges[store]
    if s.path then
        return s.from .. "." .. s.edge
    end
    for _, t in c.tables do
        for _, e in t.edges do
            if e.store == store and e.dir == "to" then
                return t.name .. "." .. e.name
            end
        end
    end
    return store
end

-- What a migration from `prev` (load()'s answer, or nil) to `app` would do:
-- { version, changed, compiled, steps = { { op = "build" | "drop", table,
-- index } | { op = "fill", table, fields, fns } | { op = "drop", edge, label }
-- | { op = "fill", table, edge, label } | { op = "drop", gone = { key, name,
-- store } } } }. Raises an error for a change it refuses.
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
        -- a table whose format changes to or from column, or a column table
        -- whose block changes, keeps reading its stored rows until a copy
        -- step has copied every row into the new format or blocks
        local moving = old and (old.rebuild ~= nil
            or (old.format == "column") ~= (t.format == "column")
            or (t.format == "column" and old.block ~= t.block))
        local format = if moving then old.format else t.format
        local block = if moving then old.block else t.block
        local before = by_name(old and old.fields)
        local fields, ver = check_fields(where, old, t, before, num(prev.version) + 1)
        -- a field keeps the block rows its values were stored with
        if block then
            for i, f in fields do
                local d = t.fields[i]
                local was = before[d.name] or (d.was and before[d.was])
                f.rows = if was and was.rows then was.rows else col.block_rows(block, f)
            end
        end
        local rebuild
        if moving and old.rebuild and old.rebuild.format == t.format
            and old.rebuild.block == t.block then
            rebuild = old.rebuild
        elseif moving then
            -- the version this migration gives the catalog names a new store
            -- of column blocks
            local store = t.format == "column" and t.key .. "@" .. (prev.version + 1) or nil
            rebuild = { format = t.format, store = store, block = t.block,
                        rows = t.block and col.block_rows(t.block), fields = {} }
            for i, f in fields do
                rebuild.fields[i] = t.block and col.block_rows(t.block, f)
            end
        end
        local after = by_name(fields)
        -- stored computed fields that rows stored before need computed:
        -- new ones, and ones whose revision changed, and enum fields whose
        -- rows need a removed choice replaced
        local fill, fns, refill = {}, {}, {}
        for i, f in fields do
            local d = t.fields[i]
            local was = before[d.name] or (d.was and before[d.was])
            if old and f.computed and (was == nil or num(was.computed) ~= f.computed) then
                fill[#fill + 1] = f.name
                fns[f.name] = d.code.computed
                if was then refill[f.name] = true end
            end
            -- removed enum choices that rows take a replacement for
            if f.replaces and not was.replaces then
                fill[#fill + 1] = f.name
                fns[f.name] = replacer(f)
                refill[f.name] = true
            end
            -- a renamed field that json rows name by its old name
            if f.renames and not was.renames then
                fill[#fill + 1] = f.name
                fns[f.name] = keeper(f)
            end
        end
        local c = {
            name = name, key = t.key, format = format, id = t.id, next = ver.next, ids = ver.ids,
            jsonRows = (old and old.jsonRows) or t.format == "json",
            block = block, rows = if old then old.rows else block and col.block_rows(block),
            store = old and old.store, rebuild = rebuild,
            fields = fields, indexes = {}, edges = {},
        }
        for i, ix in t.indexes do c.indexes[i] = index_spec(ix) end
        for i, e in t.edges do
            c.edges[i] = { name = e.name, dir = e.dir, target = e.target, unique = e.unique,
                           store = e.store, via = e.via }
        end
        tables[t.key] = c
        if rebuild and rebuild ~= (old and old.rebuild) then
            steps[#steps + 1] = { op = "copy", table = c, format = t.format }
            if format == "column" then
                steps[#steps + 1] = { op = "drop", table = c, store = c.store or c.key }
            else
                steps[#steps + 1] = { op = "drop", table = c, rows = true }
            end
        end

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
        -- field ids are never given out again, so a dropped field's column
        -- blocks would stay unread
        if old and c.format == "column" then
            local kept = {}
            for _, f in fields do kept[f.id] = true end
            for _, f in old.fields do
                if not kept[f.id] then
                    steps[#steps + 1] = { op = "drop", table = old,
                                          field = { id = f.id, name = f.name } }
                end
            end
        end
    end
    -- a table leaves the catalog only when lent.drop names it, so a table
    -- left out by mistake keeps its rows. Drops go in key order.
    local gone = {}
    for _, key in sorted(prev.tables) do
        local old = prev.tables[key]
        if tables[key] == nil then
            if not (app.dropped and app.dropped[old.name]) then
                fail("table " .. old.name .. " is missing from the schema; declare it, or"
                    .. " name it with lent.drop to drop it and its rows")
            end
            gone[old.name] = true
            steps[#steps + 1] = { op = "drop",
                                  gone = { key = old.key, name = old.name, store = old.store } }
        end
    end
    local edges = {}
    for store, s in app.edges do
        local old = prev.edges[store]
        edges[store] = edge_record(s, old)
        local label = s.path and s.from .. "." .. s.edge
        if old and old.path and not s.path then
            fail("edge " .. store .. " was the store of table " .. old.from .. " edge "
                .. old.edge .. ", a stored edge.through; migrate once without the edge"
                .. " before declaring it again")
        end
        if s.path and (old == nil or old.path == nil or canon(old.path) ~= canon(s.path)) then
            steps[#steps + 1] = { op = "drop", edge = store, label = label }
            steps[#steps + 1] = { op = "fill", table = tables[app.tables[s.from].key],
                                  edge = store, label = label }
        end
    end
    for _, store in sorted(prev.edges) do
        local old = prev.edges[store]
        if edges[store] == nil and (old.path or gone[old.from] or gone[old.to]) then
            steps[#steps + 1] = { op = "drop", edge = store, label = edge_label(prev, store) }
        end
    end
    -- drops first, so an index rebuilt under its own name starts empty,
    -- fills before builds, so a build reads the computed values, and copies
    -- last, followed by the drops of the rows or blocks they copied. Steps
    -- of one rank keep the order they were planned in.
    local rank = { drop = 1, fill = 2, build = 3, copy = 4 }
    local planned = {}
    for i, s in steps do planned[s] = i end
    local function order(s: any): number
        return if s.store or s.rows then 5 else rank[s.op]
    end
    table.sort(steps, function(a, b)
        if order(a) ~= order(b) then return order(a) < order(b) end
        return planned[a] < planned[b]
    end)

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

-- Calls each(key, stored) for each row of table t: its key, or a column
-- table's place for it in key order, and what the store holds for it.
local function each_row(t: any, each: (string, any) -> ())
    local fields, rows = row_fields(t), lay.row(t)
    if t.format == "column" then
        col.scan(t, fields, rows, kc.after(rows), function(pk, r)
            each(lay.row(t, pk), r)
            return false
        end)
    else
        lay.scan_values(rows, kc.after(rows), function(k, v)
            each(k, v)
            return false
        end)
    end
end

-- Up to `limit` row keys of t from lo up to hi, with what the store holds
-- for each.
local function row_page(t: any, lo: string, hi: string, limit: number): ({ string }, { any })
    if t.format == "column" then
        return col.page(t, row_fields(t), lo, hi, limit)
    end
    return barch.store.rangeValues(lo, hi, limit)
end

-- The fields of a stored row.
local function decoded(fields: any, stored: any): any
    return if type(stored) == "table" then stored else (rc.decode(fields, stored))
end

-- Removes the keys under prefix.
local function drop(prefix: string)
    lay.walk(prefix, function(k)
        barch.store.remove(k)
    end)
end

-- The keys a drop step removes: an index's entries, the column blocks of a
-- dropped field, or the rows or blocks a copy step copied, the presence
-- blocks first.
local function drop_prefix(t: any, step: any): string
    if step.rows then
        return lay.row(t)
    end
    if step.store then
        local from = { key = t.key, store = step.store }
        local prefix = lay.present(from)
        if #barch.store.range(prefix, kc.after(prefix), 1) > 0 then
            return prefix
        end
        return lay.columns(from)
    end
    return if step.field then lay.column(t, step.field.id) else lay.index(t, step.index)
end

-- Copies the row at key k of table t, which `stored` holds, into the
-- format or blocks of t.rebuild, a row format marked with `version`.
local function copy_row(t: any, fields: any, version: number, k: string, stored: any)
    col.copy(t, fields, version, lay.row_pk(t, k), nil, decoded(fields, stored))()
end

-- Stores index ix's entry for the row at key k, whose value is `stored`.
-- `edges` are the catalog's edge stores, which the index's edges read.
local function build_row(t: any, ix: any, edges: any, fields: any, k: string, stored: any)
    local pk = lay.row_pk(t, k)
    local r = lay.fill(t, decoded(fields, stored))
    local key, value = lay.entry(t, ix, r, pk, lay.linked(edges, ix, pk))
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

-- Computes the fields `names` of the row at key k, whose value is
-- `stored`, with their functions `fns`, and stores the row again when a
-- value changed or a json row names one of them by its old name.
local function fill_row(t: any, names: { string }, fns: any, fields: any, version: number,
                        k: string, stored: any)
    local old = if type(stored) == "table" then table.clone(stored) else nil
    local r = lay.fill(t, decoded(fields, stored))
    local json = type(stored) == "string" and string.sub(stored, 1, 1) == "{"
    local same = true
    for _, name in names do
        local v = fns[name](table.clone(r))
        for _, f in t.fields do
            local why = f.name == name and SCHEMA.computed_broken(f, v)
            if why then
                fail("table " .. t.name .. " field " .. name .. " " .. why .. " for row "
                    .. tostring(lay.row_pk(t, k)))
            end
            if f.name == name and f.renames and json then same = false end
        end
        same = same and v == r[name]
        r[name] = v
    end
    if same then
        return
    end
    if t.format == "column" then
        col.write(t, fields, lay.row_pk(t, k), old, r)()
    else
        barch.store.set(k, rc.encode(fields, t.format, version, r))
    end
end

-- The functions of the stored computed fields `names` of catalog table t,
-- from the graph `app`, and of the enum fields among them whose removed
-- choices are replaced and the fields among them that were renamed.
local function fill_fns(app: any, t: any, names: { string }): any
    local fns = {}
    for _, f in app.tables[t.name].fields do
        if table.find(names, f.name) then fns[f.name] = f.code.computed end
    end
    for _, f in t.fields do
        if f.replaces and table.find(names, f.name) then fns[f.name] = replacer(f)
        elseif f.renames and table.find(names, f.name) then fns[f.name] = keeper(f) end
    end
    return fns
end

-- Removes up to `limit` keys under `prefixes`, in their order, and answers
-- how many it removed.
local function drop_keys(prefixes: { string }, limit: number): number
    local n = 0
    for _, prefix in prefixes do
        for _, k in barch.store.range(prefix, kc.after(prefix), limit - n) do
            barch.store.remove(k)
            n += 1
        end
        if n == limit then break end
    end
    return n
end

-- Removes up to `limit` keys of edge store `store`, forward keys first, and
-- answers how many it removed.
local function drop_edge(store: string, limit: number): number
    return drop_keys({ lay.edge_store({ name = store }) }, limit)
end

-- The prefixes of the keys of dropped table `t`, a { key, name, store }:
-- its rows, column blocks, index entries, counter and statistics. A single
-- key is its own prefix.
local function table_prefixes(t: any): { string }
    local unique, plain = lay.indexes(t)
    return { lay.row(t), lay.present(t), lay.columns(t), unique, plain,
             lay.counter(t), lay.stats(t) }
end

-- Writes the links of stored edge.through `p` from the row at key k of
-- table t: one to each row its paths reach, holding how many paths do.
-- `edges` are the catalog's edge stores, which the path names.
local function fill_paths(t: any, p: any, edges: any, k: string)
    local pk = lay.row_pk(t, k)
    lay.walk(lay.edge(p, pk), function(key)
        barch.store.remove(key)
        barch.store.remove(lay.edge_back(p, lay.edge_to(p, key), pk))
    end)
    for to, n in lay.path_counts(edges, p.path, { [pk] = 1 }, 1, #p.path) do
        barch.store.set(lay.edge(p, pk, to), tostring(n))
        barch.store.set(lay.edge_back(p, to, pk), "")
    end
end

local function build(t: any, ix: any, edges: any)
    local fields = row_fields(t)
    each_row(t, function(k, v)
        build_row(t, ix, edges, fields, k, v)
    end)
end

local function mkdir(path: string)
    if barch.graph.stat(path) == nil then
        barch.graph.mkdir(path)
    end
end

-- The record at /lent/tables/<table>/table.
local function table_data(t: any): string
    return simdjson.encode({ name = t.name, format = t.format, id = t.id, next = t.next,
                             block = t.block, rows = t.rows, store = t.store })
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
        g.put(base .. "/table", table_data(t), "json")
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
            g.put(dir .. "/spec", spec_data(ix), "json")
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
        if s.gone then
            while drop_keys(table_prefixes(s.gone), 1000) == 1000 do end
        elseif s.edge and s.op == "drop" then
            while drop_edge(s.edge, 1000) == 1000 do end
        elseif s.edge then
            local store = p.compiled.edges[s.edge]
            each_row(s.table, function(k)
                fill_paths(s.table, store, p.compiled.edges, k)
            end)
        elseif s.op == "drop" then
            drop(drop_prefix(s.table, s))
            -- a store drop's prefix moves on to the column blocks
            if s.store then drop(drop_prefix(s.table, s)) end
        elseif s.op == "fill" then
            local fields = row_fields(s.table)
            each_row(s.table, function(k, v)
                fill_row(s.table, s.fields, s.fns, fields, p.compiled.version, k, v)
            end)
            for _, f in s.table.fields do
                if table.find(s.fields, f.name) then
                    f.replaces, f.renames, f.renamesSince = nil, nil, nil
                end
            end
        elseif s.op == "copy" then
            local fields = row_fields(s.table)
            each_row(s.table, function(k, v)
                copy_row(s.table, fields, p.compiled.version, k, v)
            end)
            p.compiled.tables[s.table.key] = col.target(s.table)
        else
            build(s.table, s.index, p.compiled.edges)
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
        if step.gone then
            local limit = budget - processed
            local n = drop_keys(table_prefixes(step.gone), limit)
            processed += n
            if n < limit then work.at += 1 end
            continue
        end
        if step.edge then
            local limit = budget - processed
            local n, done
            if step.op == "drop" then
                n = drop_edge(step.edge, limit)
                done = n < limit
            else
                local store, prefix = c.edges[step.edge], lay.row(t)
                local keys = row_page(t, work.cursor and work.cursor .. "\2" or prefix,
                                      kc.after(prefix), limit)
                for _, k in keys do
                    fill_paths(t, store, c.edges, k)
                end
                n, done = #keys, #keys < limit
                if done then store.state = nil else work.cursor = keys[#keys] end
            end
            processed += n
            if done then
                work.at += 1
                work.cursor = nil
            end
            continue
        end
        local rows = step.op ~= "drop"
        local ix = step.op == "build" and find_index(t, step.index.name) or step.index
        local prefix = rows and lay.row(t) or drop_prefix(t, step)
        local lo = rows and work.cursor and work.cursor .. "\2" or prefix
        local hi = kc.after(prefix)
        local limit = budget - processed
        -- the row steps read each row with its key
        local keys, values
        if rows then
            keys, values = row_page(t, lo, hi, limit)
        else
            keys = barch.store.range(lo, hi, limit)
        end
        -- writes to rows the copy has reached go to both copies
        if step.op == "copy" and keys[1] then
            t.rebuild.upto = lay.row_pk(t, keys[#keys])
        end
        local fields = rows and row_fields(t)
        local fns = step.op == "fill" and fill_fns(app, t, step.fields)
        for i, k in keys do
            if step.op == "drop" then
                barch.store.remove(k)
            elseif step.op == "fill" then
                fill_row(t, step.fields, fns, fields, c.version, k, values[i])
            elseif step.op == "copy" then
                copy_row(t, fields, c.version, k, values[i])
            else
                build_row(t, ix, c.edges, fields, k, values[i])
            end
        end
        processed += #keys
        local done
        if rows then
            local nextKey = keys[#keys] and keys[#keys] .. "\2" or prefix
            done = #keys < limit or #row_page(t, nextKey, hi, 1) == 0
        else
            -- a store drop moves on to the column blocks once the presence
            -- blocks are gone
            local rest = drop_prefix(t, step)
            done = #barch.store.range(rest, kc.after(rest), 1) == 0
        end
        if done then
            if step.op == "build" then ix.state = nil end
            if step.op == "fill" then
                for _, f in t.fields do
                    if table.find(step.fields, f.name) then
                        f.state, f.replaces, f.renames, f.renamesSince = nil, nil, nil, nil
                    end
                end
            end
            -- the table reads the new blocks from the commit of this page
            if step.op == "copy" then c.tables[step.table] = col.target(t) end
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
        -- a copy step's last page switches the table to its new blocks
        barch.graph.put("/lent/tables/" .. key .. "/table", table_data(t), "json")
        for _, f in t.fields do
            barch.graph.put("/lent/tables/" .. key .. "/fields/" .. f.name,
                simdjson.encode(field_data(f)), "json")
        end
        for _, ix in t.indexes do
            barch.graph.put("/lent/tables/" .. key .. "/indexes/" .. ix.name .. "/spec",
                spec_data(ix), "json")
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
                if s.gone then
                    work.steps[i] = { op = s.op, gone = s.gone }
                elseif s.edge then
                    work.steps[i] = { op = s.op, table = s.table and s.table.key, edge = s.edge,
                                      label = s.label }
                    if s.op == "fill" then c.edges[s.edge].state = "filling" end
                elseif s.op == "fill" then
                    work.steps[i] = { op = s.op, table = s.table.key, fields = s.fields }
                    for _, f in s.table.fields do
                        if table.find(s.fields, f.name) then f.state = "filling" end
                    end
                else
                    work.steps[i] = { op = s.op, table = s.table.key, field = s.field,
                                      store = s.store, rows = s.rows, format = s.format,
                                      index = s.index and index_spec(s.index) }
                end
                if s.op == "build" then s.index.state = "building" end
            end
            c.migration = work
        end
        local steps = {}
        for i, s in c.migration.steps do
            if s.gone then
                steps[i] = "drop " .. s.gone.name
            elseif s.edge then
                steps[i] = s.op .. " " .. s.label
            else
                local name = c.tables[s.table].name
                -- a copy step from before format changes copies into blocks
                if s.op == "copy" then
                    local into = if (s.format or "column") == "column" then " blocks" else " rows"
                    steps[i] = "copy " .. name .. into
                elseif s.store then
                    steps[i] = "drop " .. name .. " old blocks"
                elseif s.rows then
                    steps[i] = "drop " .. name .. " old rows"
                else
                    local what = if s.op == "fill" then table.concat(s.fields, ",")
                        elseif s.field then s.field.name .. " blocks" else s.index.name
                    steps[i] = s.op .. " " .. name .. "." .. what
                end
            end
        end
        local processed = advance(c, pageSize, app)
        if resuming then write_progress(c) else write_catalog(c) end
        return { version = c.version, changed = true, steps = steps,
                 done = c.migration == nil, processed = processed }
    end)
end

-- Planner statistics ----------------------------------------------------------
--
-- analyze() reads one table's sources in pages: its row keys, or a column
-- table's presence blocks, then each ready index's keys. For each source it
-- stores under lay.stats(t) the number of keys, the number of distinct
-- values of each leading run of an index's values, and up to SAMPLES keys
-- spread evenly through the source, cut to SAMPLE_BYTES after its prefix.
-- CLIENT estimates how many keys a key span holds from them.
--
-- The record is key-encoded values: STATS, the number of sources, and for
-- each its name, signature, key count, the time it was read, the number of
-- distinct counts and each count, then the number of samples and each
-- sample's text after the prefix. A state is hex text of key-encoded values:
-- ANALYZE, the mark, the source's place in the list, the last key read, the
-- keys the source held when the run reached it, the keys read, the next
-- sample's number, the last index key read, the distinct counts and the
-- samples.

local STATS, ANALYZE = "lent.stats.1", "lent.analyze.1"
local SAMPLES, SAMPLE_BYTES = 100, 48
local ANALYZE_PAGE, ANALYZE_MAX = 10000, 1000000
-- the most keys one barch.store.range call answers
local RANGE_MAX = 10000
local PRIMARY = { name = "id", on = { "id" }, unique = true, primary = true }

local function value_text(v: any): string
    if type(v) == "number" then
        return kc.encode("float", v)
    elseif type(v) == "string" then
        return kc.encode("string", v)
    end
    return "-"
end

-- A reader of the key-encoded values in `raw`: each call of the first
-- function answers the next value, and the second answers how many bytes
-- are left.
local function reader(raw: string): (() -> any, () -> number)
    local pos = 1
    local function value(): any
        local v
        v, pos = kc.decode(raw, pos)
        return v
    end
    return value, function()
        return #raw + 1 - pos
    end
end

-- The text that tells whether stored statistics still describe index ix:
-- whether it is unique, its fields and its edges.
function index_sig(ix: any): string
    if ix.primary then
        return "id"
    end
    return (ix.unique and "unique " or "") .. table.concat(ix.on, ",") .. " "
        .. table.concat(ix.edges or {}, ",")
end

-- The sources analyze() reads in table t: the rows, then each index.
local function stat_sources(t: any): { any }
    local list = { PRIMARY }
    for _, ix in t.indexes do
        list[#list + 1] = ix
    end
    return list
end

local function source_prefix(t: any, ix: any): string
    return if ix.primary then lay.row(t) else lay.index(t, ix)
end

-- The records stored for table t, in the stored order, or {}.
local function read_records(t: any): { any }
    local raw = barch.store.get(lay.stats(t))
    if type(raw) ~= "string" then
        return {}
    end
    local value = reader(raw)
    assert(value() == STATS)
    local out = {}
    for i = 1, value() do
        local r = { name = value(), sig = value(), keys = value(), at = value(),
                    distinct = {}, samples = {} }
        for j = 1, value() do
            r.distinct[j] = value()
        end
        for j = 1, value() do
            r.samples[j] = value()
        end
        out[i] = r
    end
    return out
end

local function write_records(t: any, records: { any })
    local parts = { value_text(STATS), value_text(#records) }
    for _, r in records do
        for _, v in { r.name, r.sig, r.keys, r.at, #r.distinct } do
            parts[#parts + 1] = value_text(v)
        end
        for _, d in r.distinct do
            parts[#parts + 1] = value_text(d)
        end
        parts[#parts + 1] = value_text(#r.samples)
        for _, s in r.samples do
            parts[#parts + 1] = value_text(s)
        end
    end
    barch.store.set(lay.stats(t), table.concat(parts))
end

-- Each current source of t whose stored record still describes it, keyed
-- by name.
local function current(t: any, records: { any }): { [string]: any }
    local sigs = {}
    for _, ix in stat_sources(t) do
        if ix.state ~= "building" then
            sigs[ix.name] = { ix = ix, sig = index_sig(ix) }
        end
    end
    local out = {}
    for _, r in records do
        local s = sigs[r.name]
        if s and s.sig == r.sig then
            out[r.name] = { ix = s.ix, record = r }
        end
    end
    return out
end

-- The planner statistics of table t, as { [source name] = { keys, distinct,
-- samples, at } } with each sample a whole key, or nil when t has none. The
-- decoded statistics are kept while the record and t's sources stay the
-- same.
local decoded = {}
function planner_stats(t: any): any
    local raw = barch.store.get(lay.stats(t))
    if type(raw) ~= "string" then
        return nil
    end
    local shape = {}
    for _, ix in stat_sources(t) do
        shape[#shape + 1] = ix.name .. " " .. index_sig(ix) .. " " .. tostring(ix.state)
    end
    local sources = table.concat(shape, "\n")
    local hit = decoded[t.key]
    if hit and hit.raw == raw and hit.sources == sources then
        return hit.stats
    end
    local stats = {}
    for name, s in current(t, read_records(t)) do
        local prefix, r = source_prefix(t, s.ix), s.record
        local samples = table.create(#r.samples)
        for i, text in r.samples do
            samples[i] = prefix .. text
        end
        stats[name] = { keys = r.keys, distinct = r.distinct, samples = samples, at = r.at }
    end
    decoded[t.key] = { raw = raw, sources = sources, stats = stats }
    return stats
end

-- The place, counted from 0, of sample k among n keys: every key when n
-- is SAMPLES or fewer, else the middle of each of SAMPLES equal runs.
local function sample_at(k: number, n: number): number
    if n <= SAMPLES then
        return k - 1
    end
    return math.floor((k - 0.5) * n / SAMPLES)
end

local function take_sample(run: any, prefix: string, key: string)
    run.samples[#run.samples + 1] = string.sub(key, #prefix + 1, #prefix + SAMPLE_BYTES)
    run.next += 1
end

-- Counts the value runs that index key k starts: from the first of its w
-- values, read from `start`, that differs from the last key's, each longer
-- run is new too.
local function count_distinct(run: any, k: string, start: number, w: number)
    local prev, pos = run.prev, start
    for i = 1, w do
        local _, after = kc.decode(k, pos)
        if prev == nil or string.sub(prev, 1, after - 1) ~= string.sub(k, 1, after - 1) then
            for j = i, w do
                run.distinct[j] += 1
            end
            break
        end
        pos = after
    end
    run.prev = k
end

-- Reads up to `limit` keys of source ix of table t into run, at most
-- RANGE_MAX, and answers how many keys it read and whether the source has
-- no more. A column table's rows are read a presence block at a time, each
-- one key.
local function analyze_page(t: any, ix: any, run: any, limit: number): (number, boolean)
    limit = math.min(limit, RANGE_MAX)
    local prefix = source_prefix(t, ix)
    local hi = kc.after(prefix) :: string
    local column = ix.primary and t.format == "column"
    if run.last == nil and run.pos == 0 then
        run.total = if column then col.count(t, prefix, hi) else barch.store.count(prefix, hi)
        local w = if ix.primary then 0 else #ix.on + (ix.links and #ix.links or 0)
        for i = 1, w do
            run.distinct[i] = 0
        end
    end
    local wanted = math.min(SAMPLES, run.total)
    if column then
        local all = lay.present(t)
        local keys, values = barch.store.rangeValues(run.last and run.last .. "\2" or all,
                                                     kc.after(all), limit)
        for i, k in keys do
            local rows = col.rows_in(t, values[i])
            while run.next <= wanted do
                local at = sample_at(run.next, run.total)
                if at >= run.pos + rows then
                    break
                end
                local id = col.nth_id(t, lay.present_block(k), values[i], at - run.pos)
                if id ~= nil then
                    take_sample(run, prefix, lay.row(t, id))
                else
                    run.next += 1
                end
            end
            run.pos += rows
        end
        run.last = keys[#keys] or run.last
        return #keys, #keys < limit
    end
    local keys = barch.store.range(run.last and run.last .. "\2" or prefix, hi, limit)
    local w, start = #run.distinct, #prefix + 1
    for _, k in keys do
        if run.next <= wanted and sample_at(run.next, run.total) == run.pos then
            take_sample(run, prefix, k)
        end
        if w > 0 then
            count_distinct(run, k, start, w)
        end
        run.pos += 1
    end
    run.last = keys[#keys] or run.last
    return #keys, #keys < limit
end

local function new_run(): any
    return { at = 1, pos = 0, total = 0, next = 1, distinct = {}, samples = {} }
end

local function encode_run(mark: string, run: any): string
    local parts = { value_text(ANALYZE), value_text(mark), value_text(run.at),
                    value_text(run.last), value_text(run.total), value_text(run.pos),
                    value_text(run.next), value_text(run.prev), value_text(#run.distinct) }
    for _, d in run.distinct do
        parts[#parts + 1] = value_text(d)
    end
    parts[#parts + 1] = value_text(#run.samples)
    for _, s in run.samples do
        parts[#parts + 1] = value_text(s)
    end
    return VALUES.hex(table.concat(parts))
end

local function decode_run(text: any, mark: string): any
    local ok, run = pcall(function()
        assert(type(text) == "string" and #text % 2 == 0 and not string.find(text, "[^0-9a-f]"))
        local value, left = reader(VALUES.unhex(text))
        assert(value() == ANALYZE)
        local m = value()
        if m ~= mark then
            return { mark = m }
        end
        local run = { mark = m, at = value(), last = value(), total = value(), pos = value(),
                      next = value(), prev = value(), distinct = {}, samples = {} }
        for i = 1, value() do
            run.distinct[i] = value()
        end
        for i = 1, value() do
            run.samples[i] = value()
        end
        assert(left() == 0)
        return run
    end)
    if not ok then
        fail("analyze takes a state that an earlier analyze answered, or nil to start")
    end
    if run.mark ~= mark then
        fail("analyze state comes from another table or schema version; start again without"
            .. " a state")
    end
    return run
end

-- Stores what run read of source ix in t's statistics, and drops the
-- records of sources t no longer has.
local function save_source(t: any, ix: any, run: any)
    local records = {}
    for name, s in current(t, read_records(t)) do
        if name ~= ix.name then
            records[#records + 1] = s.record
        end
    end
    records[#records + 1] = { name = ix.name, sig = index_sig(ix), keys = run.pos,
                              at = barch.time(), distinct = run.distinct,
                              samples = run.samples }
    table.sort(records, function(a, b) return a.name < b.name end)
    write_records(t, records)
end

-- The catalog table named `name`.
local function stat_table(name: any): any
    local c = load()
    for _, t in (c and c.tables) or {} do
        if t.name == name then
            return t, c
        end
    end
    fail("analyze has no table " .. tostring(name) .. "; migrate a schema with it first")
    return nil
end

-- One committed page of the statistics of table `name`, which reads up to
-- pageSize keys. Answers { done, processed, state }; pass the state to the
-- next call until done is true.
function analyze(name: string, state: string?, pageSize: number?): any
    pageSize = pageSize == nil and ANALYZE_PAGE or pageSize
    if type(pageSize) ~= "number" or pageSize < 1 or pageSize > ANALYZE_MAX
        or pageSize ~= math.floor(pageSize) then
        fail("analyze page size must be a whole number from 1 to " .. ANALYZE_MAX)
    end
    if barch.tx.open() then
        fail("analyze needs its own transaction; call it outside a transaction")
    end
    return barch.tx.run(function()
        local t, c = stat_table(name)
        local mark = tostring(c.version) .. " " .. t.key
        local run = if state == nil then new_run() else decode_run(state, mark)
        local list = stat_sources(t)
        local processed = 0
        while run.at <= #list and processed < pageSize do
            local ix = list[run.at]
            local done = true
            if ix.state ~= "building" then
                local n
                n, done = analyze_page(t, ix, run, pageSize - processed)
                processed += n
                if done then
                    save_source(t, ix, run)
                end
            end
            if done then
                local at = run.at
                run = new_run()
                run.at = at + 1
            end
        end
        if run.at > #list then
            return { done = true, processed = processed }
        end
        return { done = false, processed = processed, state = encode_run(mark, run) }
    end)
end

-- What analyze() stored for table `name`: { [source name] = { keys,
-- distinct, analyzed } } for each source it still describes, or nil when
-- the table has no statistics.
function statistics(name: string): any
    local t = stat_table(name)
    if barch.store.get(lay.stats(t)) == nil then
        return nil
    end
    local out = {}
    for source, s in current(t, read_records(t)) do
        out[source] = { keys = s.record.keys, distinct = table.clone(s.record.distinct),
                        analyzed = s.record.at }
    end
    return out
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
    }
    for i, case in refused do
        local app = lent.graph { lent.schema "User" { fields = case[1] } }
        if not raises(function() plan(stored, app) end, case[2]) then
            return false, "refusal " .. i
        end
    end
    -- a rename rewrites the json rows, which name their fields
    local renamed = plan(stored, lent.graph { lent.schema "User" { format = "json", fields = {
        lent.field.string "email":unique(), lent.field.string "full":was("name"),
        lent.field.int "age":optional() },
        indexes = { lent.index("full"):name("by_name") } } })
    local ops = {}
    for _, s in renamed.steps do
        ops[#ops + 1] = s.op .. " " .. (s.index and s.index.name or table.concat(s.fields, ","))
    end
    if table.concat(ops, ",") ~= "drop by_name,fill full,build by_name"
        or renamed.compiled.tables.user.fields[2].renames ~= "name"
        or renamed.compiled.tables.user.fields[2].since ~= 2
        or renamed.compiled.tables.user.fields[1].since ~= nil then
        return false, "a json rename planned " .. table.concat(ops, ",")
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
    if not raises(function() plan(stored, other) end, "name it with lent.drop") then
        return false, "dropped a table lent.drop did not name"
    end
    local dropped = plan(stored, lent.graph {
        lent.schema "Post" { fields = { lent.field.string "t" } }, lent.drop "User" })
    if not dropped.changed or dropped.compiled.tables.user ~= nil
        or dropped.steps[1].gone == nil or dropped.steps[1].gone.name ~= "User" then
        return false, "lent.drop planned no drop"
    end
    return true
end

function call()
    local ok, why = selftest()
    return ok and "ok" or ("failed: " .. why)
end
