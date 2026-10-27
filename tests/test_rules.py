import pytest

from .conftest import install

redis = pytest.importorskip("redis")

# A Post table with value rules, a time kind, function defaults and hooks.
# The hooks log to a Log table, so each step can show what they did.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

local function slug(title)
    return (string.gsub(string.lower(title), "%s+", "-"))
end

local function log(c, msg)
    c.Log:create { msg = msg }
end

local function app(extra, form)
    local fields = {
        lent.field.string "title":notEmpty():maxLen(20):match("^%u"),
        lent.field.string "slug":unique():immutable(),
        lent.field.int "stars":min(0):max(5):default(0),
        lent.field.string "body":optional():validate(function(v)
            return not string.find(v, "spam") or "no spam"
        end):validate(function(v)
            return #v < 100
        end),
        lent.field.time "created":default(lent.now):immutable(),
        lent.field.time "updated":default(lent.now):updateDefault(lent.now),
    }
    if extra then
        fields[#fields + 1] = extra
    end
    local hooks = {
        create = {
            function(c, r)
                r.slug = r.slug or slug(r.title)
            end,
            function(c, r)
                log(c, "create " .. r.slug)
            end,
        },
        update = { function(c, id, r, old)
            log(c, "update " .. old.title .. " -> " .. r.title)
        end },
        delete = { function(c, id, old)
            log(c, "delete " .. old.slug)
        end },
    }
    if form == "builders" then
        local built = {}
        for op, fns in hooks do
            for _, fn in fns do
                built[#built + 1] = lent.hook[op](fn)
            end
        end
        hooks = built
    elseif form == "mixed" then
        hooks = {
            lent.hook.create(hooks.create[1]),
            create = { hooks.create[2] },
            update = hooks.update,
            delete = hooks.delete,
        }
    end
    return lent.graph {
        lent.schema "Post" {
            fields = fields,
            indexes = { lent.index("created") },
            hooks = hooks,
        },
        -- a plain table works where a builder does
        lent.schema "Log" { id = "int", fields = { { kind = "string", name = "msg", notEmpty = true } } },
    }
end

local function logs(c)
    local out = {}
    for _, r in c.Log:query():all() do
        out[#out + 1] = r.msg
    end
    return table.concat(out, "; ")
end

local steps = {}

function steps.rows(c)
    local t0 = lent.now()
    local a = c.Post:create { title = "Hello world", stars = 5 }
    local b = c.Post:create { title = "Second", slug = "two", body = "short" }
    local t1 = lent.now()
    local made = c.Post:get(a.id)
    local u = c.Post:update(a.id, { title = "Hello again" })
    local u2 = c.Post:update(a.id, { updated = 7 })
    c.Post:delete(b.id)
    return {
        made.slug .. " " .. made.stars .. " " .. b.stars .. " " .. tostring(made.body),
        -- Function defaults may run in either field order.
        tostring(made.created >= t0 and made.created <= t1
            and made.updated >= t0 and made.updated <= t1),
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

-- A refused call takes back its hooks' writes. A call that returned keeps
-- its writes when a later call in the same function is refused.
function steps.caught(c)
    local a = c.Post:create { title = "Kept" }
    local function refused(fn, ...)
        return tostring((pcall(fn, ...)))
    end
    local got = {
        refused(c.Post.create, c.Post, { title = "S", stars = -1 }),
        refused(c.Post.update, c.Post, a.id, { title = "Changed", stars = 9 }),
        refused(function()
            c.Post:create { title = "Also kept" }
            c.Post:create { title = "lower" }
        end),
    }
    local titles = {}
    for _, p in c.Post:query():order("slug"):all() do
        titles[#titles + 1] = p.title
    end
    return { table.concat(got, " "), table.concat(titles, ","), logs(c) }
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

function call(step, mode, form)
    if step == "migrate" then
        return m.migrate(app()).version
    end
    if step == "newtime" then
        return m.migrate(app(lent.field.time "published":default(lent.now))).version
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
        return client.open(app(lent.field.int "extra":optional())).tx(function() end)
    end
    if step == "plain" then
        return client.tx(steps.plain, mode == "pessimistic")
    end
    return client.open(app(nil, form)).tx(function(c)
        if errors[step] then
            errors[step](c)
            return "no error"
        end
        return steps[step](c)
    end, mode == "pessimistic")
end
"""


def setup(client, space):
    for name, path in [("VALUES", "lent/values.luau"),
                       ("KEYCODEC", "lent/keycodec.luau"), ("ROWCODEC", "lent/rowcodec.luau"),
                       ("SCHEMA", "lent/schema.luau"), ("LAYOUT", "lent/layout.luau"),
                       ("MIGRATE", "lent/migrate.luau"), ("CLIENT", "lent/client.luau")]:
        install(client, "lent", name, path)
    client.execute_command("USE", space)
    client.execute_command("SETF", "RULES", APP)
    assert client.execute_command("CALLF", "RULES", "migrate") == 1


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("form", ["plain", "builders", "mixed"])
def test_rules_defaults_and_hooks(client, mode, form):
    setup(client, "rules_" + mode + "_" + form)
    assert client.execute_command("CALLF", "RULES", "rows", mode, form) == [
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
        "LENT table Post field stars wants at most 5, got 6",
        # the Log rows are the rows step's; this client ran no hooks
        "create hello-world; create two; update Hello world -> Hello again; "
        "update Hello again -> Hello again; delete two",
    ]


ERRORS = {
    "empty": "LENT table Post field title wants at least 1 bytes, got 0",
    "long": "LENT table Post field title wants at most 20 bytes, got 21",
    "lower": 'LENT table Post field title wants a value matching "^%u", got "lower"',
    "stars": "LENT table Post field stars wants at least 0, got -1",
    "spam": 'LENT table Post field body refuses "buy spam": no spam',
    "huge": 'LENT table Post field body refuses "' + "x" * 100 + '"',
    "time": "LENT table Post field created wants a time in Unix milliseconds, got 1.5",
    "slug": "LENT table Post field slug is immutable, so update cannot change it",
    "created": "LENT table Post field created is immutable, so update cannot change it",
    "updstars": "LENT table Post field stars wants at most 5, got 9",
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
    assert ("LENT table Post field extra is declared, and this space's catalog lacks it;"
            " run MIGRATE") in str(err.value)


def test_caught_refusals_take_back_hook_writes(client):
    setup(client, "rules_caught")
    assert client.execute_command("CALLF", "RULES", "caught") == [
        "false false false",
        "Also kept,Kept",
        "create kept; create also-kept",
    ]


def test_migrate_rules(client):
    setup(client, "rules_migrate")
    client.execute_command("CALLF", "RULES", "rows")
    with pytest.raises(redis.ResponseError) as err:
        client.execute_command("CALLF", "RULES", "newtime")
    assert ("field published is new, so rows stored before it have no value; make it"
            " :optional() or give it a :default() value (a function default fills only"
            " new rows)") in str(err.value)
    assert client.execute_command("CALLF", "RULES", "inttime") == "2 1"
