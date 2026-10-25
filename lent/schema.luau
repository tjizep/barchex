-- lent's schema language: tables, fields, indexes and edges declared in Luau.
--
-- Required, not called: `local lent = require("lent.SCHEMA")`. A function key
-- has to define call(), so this one answers a self-check:
--
--   lent.SCHEMA              -> "ok" or which check failed (from any space)
--
-- A table is declared with builders named after Go ent's field and edge
-- packages:
--
--   local User = lent.schema "User" {
--       format = "binary",                       -- "json", "text" or "binary"
--       id = "uuid",                             -- or "int"
--       fields = {
--           lent.field.string "email":unique(),
--           lent.field.string "name",
--           lent.field.int "age":optional(),
--       },
--       edges = { lent.edge.to "posts" "Post" },
--       indexes = { lent.index("name", "age") },
--   }
--   local Post = lent.schema "Post" {
--       fields = { lent.field.string "title" },
--       edges = { lent.edge.from "author" "User":ref "posts":unique() },
--   }
--   local app = lent.graph { User, Post }
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

local KINDS = { string = true, int = true, float = true, bool = true, time = true }
local NUMERIC = { int = true, float = true, time = true }
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

-- The time now in Unix milliseconds, for a time field: barch.time(). In a
-- call replayed from a Raft log it is the time the entry was logged, so
-- every member writes the same value.
function now(): number
    return barch.time()
end

-- Why value `v` breaks a rule of compiled field `f`, or nil when it keeps
-- them all. lent.CLIENT checks every value it writes with this.
function broken(f: any, v: any): string?
    if f.kind == "time" and not fits("int", v) then
        return "wants a time in Unix milliseconds, got " .. tostring(v)
    end
    if type(v) == "number" then
        if f.min ~= nil and v < f.min then
            return "wants at least " .. f.min .. ", got " .. v
        end
        if f.max ~= nil and v > f.max then
            return "wants at most " .. f.max .. ", got " .. v
        end
    elseif type(v) == "string" then
        if f.minLen ~= nil and #v < f.minLen then
            return "wants at least " .. f.minLen .. " bytes, got " .. #v
        end
        if f.maxLen ~= nil and #v > f.maxLen then
            return "wants at most " .. f.maxLen .. " bytes, got " .. #v
        end
        if f.match ~= nil and string.find(v, f.match) == nil then
            return "wants a value matching " .. string.format("%q", f.match) .. ", got "
                .. string.format("%q", v)
        end
    end
    return nil
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

-- The value create() writes when the row leaves the field nil. A function
-- is called for each create, as in :default(lent.now); a value is also what
-- older rows read for a field added later.
function Field:default(v: any)
    self.default_ = v
    self.hasDefault = true
    return self
end

-- A function update() calls for the field's value when the update leaves
-- it unchanged, as in :updateDefault(lent.now) for an updated_at field.
function Field:updateDefault(fn: () -> any)
    self.updateDefault_ = fn
    return self
end

-- update() refuses to change the field once create() has set it.
function Field:immutable()
    self.immutable_ = true
    return self
end

-- Bounds for an int, float or time field's value, inclusive.
function Field:min(n: number)
    self.min_ = n
    return self
end

function Field:max(n: number)
    self.max_ = n
    return self
end

-- Bounds for a string field's length in bytes, inclusive.
function Field:minLen(n: number)
    self.minLen_ = n
    return self
end

function Field:maxLen(n: number)
    self.maxLen_ = n
    return self
end

-- Shorthand for :minLen(1).
function Field:notEmpty()
    self.minLen_ = 1
    return self
end

-- A Luau string pattern that a string field's value has to contain; anchor
-- it with ^ and $ to match the whole value.
function Field:match(pattern: string)
    self.match_ = pattern
    return self
end

-- A function that checks each value written to the field. fn(value)
-- refuses the value by answering false or a message, or by raising an
-- error. A field may have several.
function Field:validate(fn: (any) -> any)
    self.validate_ = self.validate_ or {}
    table.insert(self.validate_, fn)
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
    -- Unix milliseconds, stored as an int
    time = builder("time"),
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

-- hooks -----------------------------------------------------------------------

local Hook = {}
Hook.__index = Hook

local function hook_builder(op: string)
    return function(fn: any)
        if type(fn) ~= "function" then
            fail("hook." .. op .. " takes a function, got " .. type(fn))
        end
        return setmetatable({ op = op, fn = fn }, Hook)
    end
end

-- Functions lent.CLIENT calls inside the transaction before it writes:
--   hook.create(function(c, row) end)        row: the new row's fields
--   hook.update(function(c, id, row, old) end)
--   hook.delete(function(c, id, old) end)
-- A hook may change `row` and may read and write through `c`. An error it
-- raises refuses the write.
hook = {
    create = hook_builder("create"),
    update = hook_builder("update"),
    delete = hook_builder("delete"),
}

-- tables ----------------------------------------------------------------------

-- plain tables ----------------------------------------------------------------

-- A field, index or edge may also be a plain table of its options, such as
-- { dir = "from", name = "author", target = "User", ref = "posts" }. Each is
-- made with the builders, so both forms get the same checks.

local function plain(where: string, what: string, t: any, keys: { [string]: string })
    if type(t) ~= "table" then
        fail(where .. " " .. what .. " must be a table or made with lent." .. what
            .. ", got " .. tostring(t))
    end
    for k, v in t do
        local want = keys[k]
        if want == nil then
            fail(where .. " " .. what .. " " .. tostring(t.name) .. " has no option " .. tostring(k))
        end
        if want ~= "any" and type(v) ~= want then
            fail(where .. " " .. what .. " " .. tostring(t.name) .. " option " .. k .. " takes a "
                .. want .. ", got " .. tostring(v))
        end
    end
end

local FIELD_KEYS = {
    kind = "string", name = "string", optional = "boolean", unique = "boolean",
    default = "any", was = "string", immutable = "boolean", min = "number",
    max = "number", minLen = "number", maxLen = "number", notEmpty = "boolean",
    match = "string", validate = "any", updateDefault = "function",
}

local function plain_field(where: string, t: any): any
    if getmetatable(t) == Field then
        return t
    end
    plain(where, "field", t, FIELD_KEYS)
    if not KINDS[t.kind] then
        fail(where .. " field " .. tostring(t.name) .. " has no kind " .. tostring(t.kind))
    end
    local f = field[t.kind](t.name)
    if t.optional then f:optional() end
    if t.unique then f:unique() end
    if t.immutable then f:immutable() end
    if t.notEmpty then f:notEmpty() end
    if t.default ~= nil then f:default(t.default) end
    if t.was then f:was(t.was) end
    if t.updateDefault then f:updateDefault(t.updateDefault) end
    for _, k in { "min", "max", "minLen", "maxLen", "match" } do
        if t[k] ~= nil then
            f[k](f, t[k])
        end
    end
    -- one function, or a list of them
    local fns = type(t.validate) == "table" and t.validate or { t.validate }
    for _, fn in fns do
        f:validate(fn)
    end
    return f
end

local function plain_index(where: string, t: any): any
    if getmetatable(t) == Index then
        return t
    end
    plain(where, "index", t, { on = "table", unique = "boolean", name = "string" })
    if t.on == nil then
        fail(where .. " index needs on, the list of its fields")
    end
    local ix = index(table.unpack(t.on))
    if t.unique then ix:unique() end
    if t.name then ix:name(t.name) end
    return ix
end

local function plain_edge(where: string, t: any): any
    if getmetatable(t) == Edge then
        return t
    end
    plain(where, "edge", t, { dir = "string", name = "string", target = "string",
                              ref = "string", unique = "boolean" })
    if t.dir ~= "to" and t.dir ~= "from" then
        fail(where .. " edge " .. tostring(t.name) .. " dir is \"to\" or \"from\", got "
            .. tostring(t.dir))
    end
    local e = edge[t.dir](t.name)(t.target)
    if t.ref then e:ref(t.ref) end
    if t.unique then e:unique() end
    return e
end

local OPTIONS = { format = true, id = true, fields = true, edges = true, indexes = true,
                  hooks = true }

-- Checks the value rules of field `f` and copies them into `out`.
local function rules(where: string, f: any, out: any)
    for _, k in { "min", "max", "minLen", "maxLen" } do
        local n = f[k .. "_"]
        if n ~= nil then
            if type(n) ~= "number" or n ~= n then
                fail(where .. " " .. k .. " takes a number, got " .. tostring(n))
            end
            local numeric = k == "min" or k == "max"
            if numeric and not NUMERIC[f.kind] or not numeric and f.kind ~= "string" then
                fail(where .. " is a " .. f.kind .. " field, which takes no " .. k)
            end
            out[k] = n
        end
    end
    if f.match_ ~= nil then
        if f.kind ~= "string" then
            fail(where .. " is a " .. f.kind .. " field, which takes no match")
        end
        if type(f.match_) ~= "string" or not pcall(string.find, "", f.match_) then
            fail(where .. " match takes a Luau string pattern, got " .. tostring(f.match_))
        end
        out.match = f.match_
    end
    for _, fn in f.validate_ or {} do
        if type(fn) ~= "function" then
            fail(where .. " validate takes a function, got " .. type(fn))
        end
    end
    if f.updateDefault_ ~= nil and type(f.updateDefault_) ~= "function" then
        fail(where .. " updateDefault takes a function, got " .. type(f.updateDefault_))
    end
    if f.immutable_ and f.updateDefault_ then
        fail(where .. " is immutable, so it takes no updateDefault")
    end
    out.immutable = f.immutable_ == true
end

-- One table:
-- `lent.schema "Name" { format?, id?, fields, edges?, indexes?, hooks? }`.
-- The answer is plain data:
--   { name, key, format, id, fields = { { name, kind, optional, unique,
--     default, was, immutable, min?, max?, minLen?, maxLen?, match? } },
--     indexes = { { name, on, unique } },
--     edges = { { name, dir, target, unique, ref } } }
-- plus the parts that stay in code, which lent.CLIENT reads from the graph
-- given to lent.open: each field's `code` = { default?, update?, validate }
-- and the table's `hooks` = { create, update, delete } lists of functions.
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
            f = plain_field(where, f)
            local fname = f.name
            if fname == "id" then
                fail(where .. " field id is the primary key, which every table has")
            end
            if byName[fname] then
                fail(where .. " field " .. fname .. " is declared twice")
            end
            local fn = type(f.default_) == "function"
            if f.hasDefault and not fn and not fits(f.kind, f.default_) then
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
                          unique = f.unique_ == true, was = f.was_,
                          code = { update = f.updateDefault_,
                                   validate = table.clone(f.validate_ or {}) } }
            if fn then
                out.code.default = f.default_
            else
                out.default = f.default_
            end
            rules(where .. " field " .. fname, f, out)
            if out.default ~= nil then
                local why = broken(out, out.default)
                if why then
                    fail(where .. " field " .. fname .. " default " .. why)
                end
            end
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
            ix = plain_index(where, ix)
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
            e = plain_edge(where, e)
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

        t.hooks = { create = {}, update = {}, delete = {} }
        for _, h in spec.hooks or {} do
            if getmetatable(h) ~= Hook then
                fail(where .. " hooks must be made with lent.hook")
            end
            table.insert(t.hooks[h.op], h.fn)
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
            fail("graph takes tables made with lent.schema")
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

    local Doc = schema "Doc" {
        fields = {
            field.string "title":notEmpty():maxLen(5):match("^%u"),
            field.int "rank":min(1):max(9):default(5),
            field.time "at":default(now):immutable(),
        },
        hooks = { hook.create(function() end), hook.update(function() end) },
    }
    local title, rank, at = Doc.fields[1], Doc.fields[2], Doc.fields[3]
    if title.minLen ~= 1 or title.maxLen ~= 5 or rank.min ~= 1 or not at.immutable
        or at.default ~= nil or at.code.default ~= now or #Doc.hooks.create ~= 1
        or #Doc.hooks.delete ~= 0 then
        return false, "rules"
    end
    if broken(title, "Hi") or not broken(title, "hi") or not broken(title, "Hello!")
        or not broken(title, "") or broken(rank, 9) or not broken(rank, 10)
        or not broken(at, 1.5) or broken(at, now()) then
        return false, "broken"
    end
    local t1 = now()
    if t1 < 1.7e12 or t1 ~= math.floor(t1) then
        return false, "now " .. t1
    end

    -- plain tables compile to what the builders do
    local Plain = schema "Post" {
        id = "int",
        fields = {
            { kind = "string", name = "title", notEmpty = true, maxLen = 5 },
            { kind = "int", name = "rank", min = 1, default = 2, was = "score" },
        },
        indexes = { { on = { "rank", "title" }, unique = true, name = "by_both" } },
        edges = { { dir = "from", name = "author", target = "User", ref = "posts", unique = true } },
    }
    local Built = schema "Post" {
        id = "int",
        fields = { field.string "title":notEmpty():maxLen(5),
                   field.int "rank":min(1):default(2):was("score") },
        indexes = { index("rank", "title"):unique():name("by_both") },
        edges = { edge.from "author" "User":ref "posts":unique() },
    }
    local function shape(t)
        local out = {}
        for i, f in t.fields do
            out[#out + 1] = string.format("%s %s %s %s %s %s %s", f.name, f.kind, tostring(f.min),
                tostring(f.minLen), tostring(f.maxLen), tostring(f.default), tostring(f.was))
        end
        for _, ix in t.indexes do
            out[#out + 1] = ix.name .. " " .. table.concat(ix.on, ",") .. " " .. tostring(ix.unique)
        end
        for _, e in t.edges do
            out[#out + 1] = e.name .. " " .. e.dir .. " " .. e.target .. " " .. e.ref .. " "
                .. tostring(e.unique)
        end
        return table.concat(out, "; ")
    end
    if shape(Plain) ~= shape(Built) then
        return false, "plain tables: " .. shape(Plain) .. " vs " .. shape(Built)
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
        { function() schema "User" { fields = { field.string "a":min(1) } } end, "takes no min" },
        { function() schema "User" { fields = { field.int "a":match("x") } } end, "takes no match" },
        { function() schema "User" { fields = { field.string "a":match("[") } } end, "string pattern" },
        { function() schema "User" { fields = { field.int "a":min(2):default(1) } } end, "at least 2" },
        { function() schema "User" { fields = { field.time "a":immutable():updateDefault(now) } } end,
          "takes no updateDefault" },
        { function() schema "User" { fields = { field.int "a" }, hooks = { 1 } } end, "lent.hook" },
        { function() hook.create(nil) end, "takes a function" },
        { function() schema "U" { fields = { { kind = "int", name = "a", uniqe = true } } } end,
          "field a has no option uniqe" },
        { function() schema "U" { fields = { { kind = "date", name = "a" } } } end, "no kind date" },
        { function() schema "U" { fields = { { kind = "int", name = "a", min = "1" } } } end,
          "option min takes a number" },
        { function() schema "U" { fields = { field.int "a" }, edges = {
            { dir = "back", name = "x", target = "Y" } } } end, "dir is \"to\" or \"from\"" },
        { function() schema "U" { fields = { field.int "a" }, edges = {
            { dir = "from", name = "x", target = "Y" } } } end, "needs :ref" },
        { function() schema "U" { fields = { field.int "a" }, indexes = { { unique = true } } } end,
          "index needs on" },
        { function() schema "U" { fields = { "a" } } end, "field must be a table" },
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
