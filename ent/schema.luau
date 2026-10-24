-- ent's schema language: tables, fields, indexes and edges declared in Luau.
--
-- Required, not called: `local ent = require("ent.SCHEMA")`. A function key
-- has to define call(), so this one answers a self-check:
--
--   ent.SCHEMA              -> "ok" or which check failed (from any space)
--
-- A table is declared with builders named after Go ent's field and edge
-- packages:
--
--   local User = ent.schema "User" {
--       format = "binary",                       -- "json", "text" or "binary"
--       id = "uuid",                             -- or "int"
--       fields = {
--           ent.field.string "email":unique(),
--           ent.field.string "name",
--           ent.field.int "age":optional(),
--       },
--       edges = { ent.edge.to "posts" "Post" },
--       indexes = { ent.index("name", "age") },
--   }
--   local Post = ent.schema "Post" {
--       fields = { ent.field.string "title" },
--       edges = { ent.edge.from "author" "User":ref "posts":unique() },
--   }
--   local app = ent.graph { User, Post }
--
-- A table's ids are barch.uuid() strings by default, which sort by the time
-- they were made. id = "int" numbers the rows 1, 2, 3 from a counter key
-- that every create in the table writes.
--
-- schema() checks one table and graph() checks the tables together: every
-- edge names a declared table, and every edge.from names the edge.to it is
-- the inverse of. Both raise an error naming what is wrong.
--
-- Field ids for ROWCODEC come from ids(), which keeps the ids an earlier
-- version of the table gave out and numbers new fields after the highest id
-- ever used, so a removed field's id is never reused.

local KINDS = { string = true, int = true, float = true, bool = true }
local FORMATS = { json = true, text = true, binary = true }
local IDS = { uuid = true, int = true }
local MAX_INT = 2 ^ 53

local function fail(msg: string)
    error("SCHEMA " .. msg, 0)
end

local function ident(name: any, what: string)
    if type(name) ~= "string" or not string.match(name, "^%a[%w_]*$") then
        fail(what .. " needs a name of letters, digits and _, got " .. tostring(name))
    end
end

-- "UserGroup" -> "user_group": the name a table's keys and catalog use
local function snake(name: string): string
    local s = string.gsub(name, "(%l)(%u)", "%1_%2")
    return string.lower(s)
end

local function fits(kind: string, v: any): boolean
    if kind == "string" then return type(v) == "string" end
    if kind == "bool" then return type(v) == "boolean" end
    if kind == "float" then return type(v) == "number" and v == v end
    return type(v) == "number" and v == math.floor(v) and v <= MAX_INT and v >= -MAX_INT
end

-- fields ----------------------------------------------------------------------

local Field = {}
Field.__index = Field

-- The field may be nil in a row.
function Field:optional()
    self.optional_ = true
    return self
end

-- No two rows hold the same value; adds a unique index "by_<name>".
function Field:unique()
    self.unique_ = true
    return self
end

-- The value create() writes when the row leaves the field nil.
function Field:default(v: any)
    self.default_ = v
    self.hasDefault = true
    return self
end

-- The field's earlier name, so a rename keeps its id and its values.
function Field:was(old: string)
    self.was_ = old
    return self
end

local function builder(kind: string)
    return function(name: string)
        ident(name, kind .. " field")
        return setmetatable({ kind = kind, name = name }, Field)
    end
end

field = {
    string = builder("string"),
    int = builder("int"),
    float = builder("float"),
    bool = builder("bool"),
}

-- indexes ---------------------------------------------------------------------

local Index = {}
Index.__index = Index

function Index:unique()
    self.unique_ = true
    return self
end

-- The index's name; "by_" and the field names joined by "_" by default.
function Index:name(name: string)
    ident(name, "index")
    self.name_ = name
    return self
end

-- An index over the named fields, in order.
function index(...: string)
    local on = { ... }
    if #on == 0 then
        fail("index needs at least one field")
    end
    return setmetatable({ on = on }, Index)
end

-- edges -----------------------------------------------------------------------

local Edge = {}
Edge.__index = Edge

-- Each row on this side has at most one row on the other.
function Edge:unique()
    self.unique_ = true
    return self
end

-- For edge.from: the edge.to on the target table this edge reads backwards.
function Edge:ref(name: string)
    ident(name, "edge ref")
    self.ref_ = name
    return self
end

local function edge_builder(dir: string)
    return function(name: string)
        ident(name, "edge")
        return function(target: string)
            ident(target, "edge " .. name .. " target")
            return setmetatable({ dir = dir, name = name, target = target }, Edge)
        end
    end
end

edge = {
    to = edge_builder("to"),
    from = edge_builder("from"),
}

-- tables ----------------------------------------------------------------------

local OPTIONS = { format = true, id = true, fields = true, edges = true, indexes = true }

-- One table: `ent.schema "Name" { format?, id?, fields, edges?, indexes? }`.
-- The answer is plain data:
--   { name, key, format, id, fields = { { name, kind, optional, unique,
--     default, was } }, indexes = { { name, on, unique } },
--     edges = { { name, dir, target, unique, ref } } }
function schema(name: string)
    ident(name, "table")
    return function(spec: any)
        local where = "table " .. name
        if type(spec) ~= "table" then
            fail(where .. " needs a table of options")
        end
        for k in spec do
            if not OPTIONS[k] then
                fail(where .. " has no option " .. tostring(k))
            end
        end
        local format = spec.format or "binary"
        if not FORMATS[format] then
            fail(where .. " has no format " .. tostring(format))
        end
        local id = spec.id or "uuid"
        if not IDS[id] then
            fail(where .. " ids are uuid or int, got " .. tostring(id))
        end
        local t = { name = name, key = snake(name), format = format, id = id,
                    fields = {}, indexes = {}, edges = {} }

        local byName, was = {}, {}
        for _, f in spec.fields or {} do
            if getmetatable(f) ~= Field then
                fail(where .. " fields must be made with ent.field")
            end
            local fname = f.name
            if fname == "id" then
                fail(where .. " field id is the primary key, which every table has")
            end
            if byName[fname] then
                fail(where .. " field " .. fname .. " is declared twice")
            end
            if f.hasDefault and not fits(f.kind, f.default_) then
                fail(where .. " field " .. fname .. " default is not of kind " .. f.kind)
            end
            if f.was_ then
                if was[f.was_] then
                    fail(where .. " fields " .. was[f.was_] .. " and " .. fname
                        .. " both were " .. f.was_)
                end
                was[f.was_] = fname
            end
            local out = { name = fname, kind = f.kind, optional = f.optional_ == true,
                          unique = f.unique_ == true, default = f.default_, was = f.was_ }
            byName[fname] = out
            t.fields[#t.fields + 1] = out
        end
        if #t.fields == 0 then
            fail(where .. " needs at least one field")
        end
        for old, new in was do
            if byName[old] then
                fail(where .. " field " .. new .. " was " .. old .. ", which is still declared")
            end
        end

        local indexes = {}
        local function add_index(ix: any)
            if indexes[ix.name] then
                fail(where .. " index " .. ix.name .. " is declared twice")
            end
            indexes[ix.name] = ix
            t.indexes[#t.indexes + 1] = ix
        end
        for _, f in t.fields do
            if f.unique then
                add_index({ name = "by_" .. f.name, on = { f.name }, unique = true })
            end
        end
        for _, ix in spec.indexes or {} do
            if getmetatable(ix) ~= Index then
                fail(where .. " indexes must be made with ent.index")
            end
            local seen = {}
            for _, fname in ix.on do
                if byName[fname] == nil then
                    fail(where .. " index on " .. tostring(fname) .. ", which is not a field")
                end
                if seen[fname] then
                    fail(where .. " index names field " .. fname .. " twice")
                end
                seen[fname] = true
            end
            add_index({ name = ix.name_ or ("by_" .. table.concat(ix.on, "_")),
                        on = table.clone(ix.on), unique = ix.unique_ == true })
        end

        local edges = {}
        for _, e in spec.edges or {} do
            if getmetatable(e) ~= Edge then
                fail(where .. " edges must be made with ent.edge")
            end
            if edges[e.name] or byName[e.name] then
                fail(where .. " edge " .. e.name .. " has the name of another edge or field")
            end
            if e.dir == "from" and e.ref_ == nil then
                fail(where .. " edge " .. e.name .. " needs :ref, the edge.to it reads backwards")
            end
            if e.dir == "to" and e.ref_ then
                fail(where .. " edge " .. e.name .. " is an edge.to, which takes no :ref")
            end
            local out = { name = e.name, dir = e.dir, target = e.target,
                          unique = e.unique_ == true, ref = e.ref_ }
            edges[e.name] = out
            t.edges[#t.edges + 1] = out
        end
        return t
    end
end

-- the whole schema ------------------------------------------------------------

-- Checks tables together and answers { tables = { [name] = table },
-- order = { names }, edges = { [store name] = { name, from, to, fromId,
-- toId, unique, inverseUnique } } }, where fromId and toId are the id kinds
-- of the two tables. An edge.to on User named posts is stored as
-- "user_posts"; its edge.from reads the same keys backwards.
function graph(list: { any })
    local tables, order, keys = {}, {}, {}
    for _, t in list do
        if type(t) ~= "table" or type(t.fields) ~= "table" then
            fail("graph takes tables made with ent.schema")
        end
        if tables[t.name] then
            fail("table " .. t.name .. " is declared twice")
        end
        if keys[t.key] then
            fail("tables " .. keys[t.key] .. " and " .. t.name .. " both store as " .. t.key)
        end
        tables[t.name] = t
        keys[t.key] = t.name
        order[#order + 1] = t.name
    end
    local stored = {}
    for _, name in order do
        local t = tables[name]
        for _, e in t.edges do
            local target = tables[e.target]
            if target == nil then
                fail("table " .. name .. " edge " .. e.name .. " names table " .. e.target
                    .. ", which is not declared")
            end
            if e.dir == "to" then
                e.store = t.key .. "_" .. e.name
                stored[e.store] = { name = e.store, from = name, to = e.target,
                                    fromId = t.id, toId = target.id,
                                    unique = e.unique, inverseUnique = false }
            end
        end
    end
    for _, name in order do
        for _, e in tables[name].edges do
            if e.dir == "from" then
                local back
                for _, o in tables[e.target].edges do
                    if o.name == e.ref and o.dir == "to" then
                        back = o
                    end
                end
                if back == nil or back.target ~= name then
                    fail("table " .. name .. " edge " .. e.name .. " refs " .. e.target .. "."
                        .. e.ref .. ", which is not an edge.to " .. name)
                end
                e.store = back.store
                stored[e.store].inverseUnique = e.unique
            end
        end
    end
    return { tables = tables, order = order, edges = stored }
end

-- field ids -------------------------------------------------------------------

-- Field ids for table `t`, given what the previous version gave out:
-- `previous` is nil for a new table, else { ids = { [field name] = id },
-- next = the lowest id never used }. Answers the same shape for this version
-- and a ROWCODEC field list. A field keeps its id under its name, or under
-- the name in its :was.
function ids(t: any, previous: any?)
    local old = previous and previous.ids or {}
    local nextId = previous and previous.next or 1
    local out, list = {}, {}
    for _, f in t.fields do
        local id = old[f.name] or (f.was and old[f.was])
        if id == nil then
            id = nextId
            nextId += 1
        end
        if id > 65535 then
            fail("table " .. t.name .. " has used every field id")
        end
        out[f.name] = id
        list[#list + 1] = { name = f.name, kind = f.kind, id = id, optional = f.optional }
    end
    return { ids = out, next = nextId }, list
end

-- self-check ------------------------------------------------------------------

local function raises(fn: () -> (), want: string): boolean
    local ok, why = pcall(fn)
    return not ok and string.find(tostring(why), want, 1, true) ~= nil
end

function selftest(): (boolean, string?)
    local User = schema "User" {
        format = "json",
        fields = {
            field.string "email":unique(),
            field.string "name",
            field.int "age":optional(),
            field.bool "admin":default(false),
        },
        edges = { edge.to "posts" "Post" },
        indexes = { index("name", "age"), index("age"):name("young"):unique() },
    }
    if User.key ~= "user" or User.format ~= "json" or User.id ~= "uuid" or #User.fields ~= 4 then
        return false, "table"
    end
    local ix = User.indexes
    if #ix ~= 3 or ix[1].name ~= "by_email" or not ix[1].unique or ix[2].name ~= "by_name_age"
        or ix[2].unique or ix[3].name ~= "young" or not ix[3].unique then
        return false, "indexes"
    end
    if User.fields[3].optional ~= true or User.fields[4].default ~= false then
        return false, "field options"
    end
    local Post = schema "BlogPost" {
        fields = { field.string "title" },
        edges = { edge.from "author" "User":ref "posts":unique() },
    }
    if Post.key ~= "blog_post" or Post.format ~= "binary" then
        return false, "table key or default format"
    end
    -- the edge targets "Post", so the graph has to refuse BlogPost
    if not raises(function() graph { User, Post } end, "names table Post") then
        return false, "graph took an edge to a missing table"
    end
    Post = schema "Post" {
        id = "int",
        fields = { field.string "title" },
        edges = { edge.from "author" "User":ref "posts":unique() },
    }
    local g = graph { User, Post }
    local e = g.edges.user_posts
    if e == nil or e.from ~= "User" or e.to ~= "Post" or e.fromId ~= "uuid" or e.toId ~= "int"
        or e.unique or not e.inverseUnique
        or g.tables.Post.edges[1].store ~= "user_posts" then
        return false, "edges"
    end

    local v1, list = ids(User)
    if v1.next ~= 5 or list[1].id ~= 1 or list[4].id ~= 4 or list[3].optional ~= true then
        return false, "first ids"
    end
    -- drop age, rename name to full_name, add nick: nick must not take 3
    local User2 = schema "User" {
        fields = {
            field.string "email":unique(),
            field.string "full_name":was("name"),
            field.bool "admin",
            field.string "nick":optional(),
        },
    }
    local v2, list2 = ids(User2, v1)
    if v2.ids.full_name ~= 2 or v2.ids.admin ~= 4 or v2.ids.nick ~= 5 or v2.next ~= 6
        or list2[2].name ~= "full_name" then
        return false, "later ids"
    end

    local refused = {
        { function() schema "User" { fields = {} } end, "needs at least one field" },
        { function() schema "User" { fields = { field.int "id" } } end, "primary key" },
        { function() schema "User" { fields = { field.int "a", field.int "a" } } end, "declared twice" },
        { function() schema "User" { fields = { field.int "a" }, colour = 1 } end, "no option colour" },
        { function() schema "User" { format = "csv", fields = { field.int "a" } } end, "no format csv" },
        { function() schema "User" { id = "serial", fields = { field.int "a" } } end, "ids are uuid or int" },
        { function() schema "User" { fields = { field.int "a":default(1.5) } } end, "default is not of kind int" },
        { function() schema "User" { fields = { field.int "a" }, indexes = { index("b") } } end, "not a field" },
        { function() schema "User" { fields = { field.int "a", field.int "b":was("a") } } end, "still declared" },
        { function() schema "User" { fields = { field.int "a" }, edges = { edge.from "x" "Y" } } end, "needs :ref" },
        { function() field.int "bad name" end, "letters, digits" },
        { function() graph { User, User } end, "declared twice" },
    }
    for i, case in refused do
        if not raises(case[1], case[2]) then
            local _, why = pcall(case[1])
            return false, "refusal " .. i .. " said " .. tostring(why)
        end
    end
    return true
end

function call()
    local ok, why = selftest()
    return ok and "ok" or ("failed: " .. why)
end
