import pytest

from .conftest import install

redis = pytest.importorskip("redis")

# A Post table with value rules, a time kind, function defaults and hooks.
# The hooks log to a Log table, so each step can show what they did.
APP = """
local ent = require("ent.SCHEMA")
local m = require("ent.MIGRATE")
local client = require("ent.CLIENT")

local function slug(title)
    return (string.gsub(string.lower(title), "%s+", "-"))
end

local function log(c, msg)
    c.Log:create { msg = msg }
end

local function app(extra)
    local fields = {
        ent.field.string "title":notEmpty():maxLen(20):match("^%u"),
        ent.field.string "slug":unique():immutable(),
        ent.field.int "stars":min(0):max(5):default(0),
        ent.field.string "body":optional():validate(function(v)
            return not string.find(v, "spam") or "no spam"
        end):validate(function(v)
            return #v < 100
        end),
        ent.field.time "created":default(ent.now):immutable(),
        ent.field.time "updated":default(ent.now):updateDefault(ent.now),
    }
    if extra then
        fields[#fields + 1] = extra
    end
    return ent.graph {
        ent.schema "Post" {
            fields = fields,
            indexes = { ent.index("created") },
            hooks = {
                ent.hook.create(function(c, r)
                    r.slug = r.slug or slug(r.title)
                    log(c, "create " .. r.slug)
                end),
                ent.hook.update(function(c, id, r, old)
                    log(c, "update " .. old.title .. " -> " .. r.title)
                end),
                ent.hook.delete(function(c, id, old)
                    log(c, "delete " .. old.slug)
                end),
            },
        },
        ent.schema "Log" { id = "int", fields = { ent.field.string "msg" } },
    }
end

local db = client.open(app())

local function logs(c)
    local out = {}
    for _, r in c.Log:query():all() do
        out[#out + 1] = r.msg
    end
    return table.concat(out, "; ")
end

local steps = {}

function steps.rows(c)
    local t0 = ent.now()
    local a = c.Post:create { title = "Hello world", stars = 5 }
    local b = c.Post:create { title = "Second", slug = "two", body = "short" }
    local t1 = ent.now()
    local made = c.Post:get(a.id)
    local u = c.Post:update(a.id, { title = "Hello again" })
    local u2 = c.Post:update(a.id, { updated = 7 })
    c.Post:delete(b.id)
    return {
        made.slug .. " " .. made.stars .. " " .. b.stars .. " " .. tostring(made.body),
        tostring(made.created >= t0 and made.created <= t1 and made.updated >= made.created),
        u.slug .. " " .. tostring(u.created == made.created) .. " "
            .. tostring(u.updated >= made.updated),
        tostring(u2.updated),
        tostring(c.Post:query():where("created", ">=", t0):count()),
        logs(c),
    }
end

-- a client without the graph keeps the catalog's rules, and has no
-- function defaults or hooks
function steps.plain(c)
    local ok, err = pcall(c.Post.create, c.Post, { title = "Plain", slug = "p" })
    local r = c.Post:create { title = "Plain", slug = "p", created = 1, updated = 2 }
    local bad = select(2, pcall(c.Post.create, c.Post,
        { title = "Plain", slug = "q", created = 1, updated = 2, stars = 6 }))
    return { tostring(ok) .. " " .. string.match(err, "ROWCODEC.*"), r.created .. " " .. r.updated, bad, logs(c) }
end

local errors = {
    empty = function(c) c.Post:create { title = "" } end,
    long = function(c) c.Post:create { title = string.rep("A", 21) } end,
    lower = function(c) c.Post:create { title = "lower" } end,
    stars = function(c) c.Post:create { title = "S", stars = -1 } end,
    spam = function(c) c.Post:create { title = "S", body = "buy spam" } end,
    huge = function(c) c.Post:create { title = "S", body = string.rep("x", 100) } end,
    time = function(c) c.Post:create { title = "S", created = 1.5 } end,
    slug = function(c) c.Post:update(c.Post:create({ title = "S" }).id, { slug = "t" }) end,
    created = function(c)
        local r = c.Post:create { title = "S" }
        c.Post:update(r.id, { created = r.created + 1 })
    end,
    updstars = function(c) c.Post:update(c.Post:create({ title = "S" }).id, { stars = 9 }) end,
    kind = function(c) c.Post:create { title = "S", slug = 3 } end,
}

function call(step, mode)
    if step == "migrate" then
        return m.migrate(app()).version
    end
    if step == "newtime" then
        return m.migrate(app(ent.field.time "published":default(ent.now))).version
    end
    if step == "inttime" then
        -- stars, an int, read as a time: the stored values stay as they are
        local g = app()
        g.tables.Post.fields[3].kind = "time"
        local v = m.migrate(g).version
        return client.tx(function(c)
            return v .. " " .. c.Post:query():where("stars", "=", 5):count()
        end)
    end
    if step == "unmigrated" then
        return client.open(app(ent.field.int "extra":optional())).tx(function() end)
    end
    if step == "plain" then
        return client.tx(steps.plain, mode == "pessimistic")
    end
    return db.tx(function(c)
        if errors[step] then
            errors[step](c)
            return "no error"
        end
        return steps[step](c)
    end, mode == "pessimistic")
end
"""


def setup(client, space):
    for name, path in [("KEYCODEC", "ent/keycodec.luau"), ("ROWCODEC", "ent/rowcodec.luau"),
                       ("SCHEMA", "ent/schema.luau"), ("LAYOUT", "ent/layout.luau"),
                       ("MIGRATE", "ent/migrate.luau"), ("CLIENT", "ent/client.luau")]:
        install(client, "ent", name, path)
    client.execute_command("USE", space)
    client.execute_command("SETF", "RULES", APP)
    assert client.execute_command("CALLF", "RULES", "migrate") == 1


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_rules_defaults_and_hooks(client, mode):
    setup(client, "rules_" + mode)
    assert client.execute_command("CALLF", "RULES", "rows", mode) == [
        # the create hook made the slug; stars took its default
        "hello-world 5 0 nil",
        "true",
        # update kept slug and created, and updateDefault set updated
        "hello-world true true",
        # a value the update sets wins over updateDefault
        "7",
        "1",
        "create hello-world; create two; update Hello world -> Hello again; "
        "update Hello again -> Hello again; delete two",
    ]
    assert client.execute_command("CALLF", "RULES", "plain", mode) == [
        "false ROWCODEC field created is not optional",
        "1 2",
        "ENT table Post field stars wants at most 5, got 6",
        # the Log rows are the rows step's; this client ran no hooks
        "create hello-world; create two; update Hello world -> Hello again; "
        "update Hello again -> Hello again; delete two",
    ]


ERRORS = {
    "empty": "ENT table Post field title wants at least 1 bytes, got 0",
    "long": "ENT table Post field title wants at most 20 bytes, got 21",
    "lower": 'ENT table Post field title wants a value matching "^%u", got "lower"',
    "stars": "ENT table Post field stars wants at least 0, got -1",
    "spam": 'ENT table Post field body refuses "buy spam": no spam',
    "huge": 'ENT table Post field body refuses "' + "x" * 100 + '"',
    "time": "ENT table Post field created wants a time in Unix milliseconds, got 1.5",
    "slug": "ENT table Post field slug is immutable, so update cannot change it",
    "created": "ENT table Post field created is immutable, so update cannot change it",
    "updstars": "ENT table Post field stars wants at most 5, got 9",
    "kind": "ROWCODEC field slug wants string, got 3",
}


def test_rule_errors(client):
    setup(client, "rules_errors")
    for step, message in ERRORS.items():
        with pytest.raises(redis.ResponseError) as err:
            client.execute_command("CALLF", "RULES", step)
        assert message in str(err.value), step
    # nothing a refused write began was kept, the logs included
    assert client.execute_command("CALLF", "RULES", "plain")[3] == ""
    with pytest.raises(redis.ResponseError) as err:
        client.execute_command("CALLF", "RULES", "unmigrated")
    assert ("ENT table Post field extra is declared, and this space's catalog lacks it;"
            " run MIGRATE") in str(err.value)


def test_migrate_rules(client):
    setup(client, "rules_migrate")
    client.execute_command("CALLF", "RULES", "rows")
    with pytest.raises(redis.ResponseError) as err:
        client.execute_command("CALLF", "RULES", "newtime")
    assert ("field published is new, so rows stored before it have no value; make it"
            " :optional() or give it a :default() value (a function default fills only"
            " new rows)") in str(err.value)
    assert client.execute_command("CALLF", "RULES", "inttime") == "2 1"
