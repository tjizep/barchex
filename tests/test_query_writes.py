import pytest

from .helpers import connect
from .test_client import setup

redis = pytest.importorskip("redis")

APP = """
local lent = require("lent.SCHEMA")
local client = require("lent.CLIENT")
local m = require("lent.MIGRATE")
local lay = require("lent.LAYOUT")
local kc = require("lent.KEYCODEC")

local function app(ids, format)
    return lent.graph {
        lent.schema "Item" {
            id = ids, format = format,
            fields = {
                lent.field.string "name":unique():immutable(),
                lent.field.string "code":unique():optional(),
                lent.field.int "score":min(0):default(0),
                lent.field.string "tag":default("old"),
                lent.field.string "note":optional(),
                lent.field.int "revision":default(0),
                lent.field.int "stamp":default(1):updateDefault(function() return 2 end),
                lent.field.int "created":default(7):immutable(),
            },
            indexes = { lent.index("tag", "score"), lent.index("score"), lent.index("note") },
            edges = { lent.edge.from "group" "Group":ref "items":unique(),
                      lent.edge.to "friends" "Item" },
            hooks = {
                update = { function(c, id, r, old)
                    r.revision = old.revision + 1
                    c.Log:create { msg = "update " .. old.name }
                    if r.tag == "refuse" and old.name == "b" then error("update hook refused", 0) end
                    if r.tag == "spawn" and old.name == "a" then
                        c.Item:create { name = "new", score = 5 }
                    end
                    if r.tag == "remove_next" and old.name == "a" then
                        c.Item:delete(c.Item:by("name", "b").id)
                    end
                end },
                delete = { function(c, id, old)
                    c.Log:create { msg = "delete " .. old.name }
                    if old.tag == "delete_refuse" and old.name == "b" then error("delete hook refused", 0) end
                    if old.tag == "cascade" and old.name == "a" then
                        c.Item:delete(c.Item:by("name", "b").id)
                    end
                end },
            },
        },
        lent.schema "Group" {
            id = "int", fields = { lent.field.string "name":unique() },
            edges = { lent.edge.to "items" "Item" },
        },
        lent.schema "Log" { id = "int", fields = { lent.field.string "msg" } },
    }
end

local function names(q)
    local out = {}
    for _, r in q:all() do out[#out + 1] = r.name end
    return table.concat(out, ",")
end

local function logs(c)
    local out = {}
    for _, r in c.Log:query():all() do out[#out + 1] = r.msg end
    return table.concat(out, "; ")
end

local function entries()
    local out = {}
    local compiled = m.load()
    local t = compiled.tables.item
    for _, ix in t.indexes do
        out[#out + 1] = ix.name .. "=" .. lay.walk(lay.index(t, ix), function() end)
    end
    for name in compiled.edges do
        local suffix = kc.encode("string", name)
        out[#out + 1] = name .. "=" .. lay.walk("lent.e" .. suffix, function() end)
            .. "/" .. lay.walk("lent.E" .. suffix, function() end)
    end
    table.sort(out)
    return table.concat(out, " ")
end

local function state(c)
    local out = {}
    for _, r in c.Item:query():order("name"):all() do
        out[#out + 1] = r.name .. ":" .. r.score .. ":" .. r.tag .. ":" .. tostring(r.note)
            .. ":" .. r.revision .. ":" .. r.stamp .. ":" .. tostring(r.code)
    end
    return table.concat(out, " ")
end

local steps = {}

function steps.seed(c)
    local g = c.Group:create { name = "g" }
    local h = c.Group:create { name = "h" }
    local a = c.Item:create { name = "a", code = "ca", score = 1, note = "memo", group = g }
    c.Item:create { name = "b", code = "cb", score = 2, group = g }
    local third = c.Item:create { name = "c", code = "cc", score = 3, note = "memo", group = h }
    local d = c.Item:create { name = "d", code = "cd", score = 4 }
    c.Item:link("friends", a.id, third.id)
    c.Item:link("friends", third.id, d.id)
    return "ok"
end

function steps.inspect(c) return { state(c), entries(), logs(c) } end

function steps.update(c)
    local values, clear = { tag = "new", score = 8 }, { "note" }
    local q = c.Item:query():where("tag", "=", "old"):where("score", ">=", 2)
        :where(function(r) return r.score <= 3 end):using("by_tag_score"):order("score", "desc")
        :withGroup(function() error("write loaded edges", 0) end)
    local n = q:update(values, clear)
    return { n, state(c), entries(), logs(c), q:count(),
             c.Item:query():where("score", "=", 8):count(),
             c.Item:query():where("note", "=", "memo"):count(),
             tostring(values.revision == nil and values.stamp == nil and clear[1] == "note") }
end

function steps.delete(c)
    local n = c.Item:query():where("tag", "=", "old"):where("score", ">=", 2)
        :where("score", "<=", 3):order("score", "desc"):delete()
    return { n, names(c.Item:query():order("name")), entries(), logs(c), c.Group:query():count(),
             c.Item:query():where("name", "=", "a"):queryFriends():count() }
end

local selectors = {
    window = function(c) return c.Item:query():order("score", "desc"):offset(1):limit(2) end,
    sorted = function(c) return c.Item:query():order("name", "desc"):offset(1):limit(2) end,
    cursor = function(c)
        local q = c.Item:query():order("score")
        return q:after(q:cursor(c.Item:by("name", "b"))):limit(1)
    end,
    predicate = function(c) return c.Item:query():where(function(r) return r.score % 2 == 0 end) end,
    follow = function(c) return c.Group:query():where("name", "=", "g"):queryItems():where("score", ">", 1) end,
    driving = function(c) return c.Item:query():hasGroupWith(function(q) q:where("name", "=", "g") end) end,
    probing = function(c) return c.Item:query():hasFriends() end,
    unique = function(c) return c.Item:query():where("name", "=", "b") end,
    all = function(c) return c.Item:query() end,
    zero = function(c) return c.Item:query():limit(0) end,
    empty = function(c) return c.Item:query():where("name", "=", "missing") end,
}

function steps.choose(c, which, op)
    local q = selectors[which](c)
    local n = op == "update" and q:update({ tag = "chosen" }) or q:delete()
    local changed = op == "update" and c.Item:query():where("tag", "=", "chosen") or c.Item:query()
    return { n, names(changed:order("name")), logs(c) }
end

function steps.defaults(c)
    return { c.Item:query():update(), state(c), logs(c) }
end

local bad = {
    values = function(c) c.Item:query():update(false) end,
    clear = function(c) c.Item:query():update({}, false) end,
    field = function(c) c.Item:query():limit(0):update({ unknown = 1 }) end,
    clearfield = function(c) c.Item:query():limit(0):update({}, { "unknown" }) end,
    id = function(c) c.Item:query():update({ id = 1 }) end,
    edge = function(c) c.Item:query():update({ group = 1 }) end,
    rule = function(c) c.Item:query():update({ score = -1 }) end,
    kind = function(c) c.Item:query():update({ score = "x" }) end,
    immutable = function(c) c.Item:query():update({ created = 8 }) end,
    required = function(c) c.Item:query():update({}, { "tag" }) end,
    unique = function(c) c.Item:query():order("name"):update({ code = "same" }) end,
    update_hook = function(c) c.Item:query():order("name"):update({ tag = "refuse" }) end,
    missing = function(c) c.Item:query():order("name"):update({ tag = "remove_next" }) end,
    delete_hook = function(c)
        c.Item:update(c.Item:by("name", "b").id, { tag = "delete_refuse" })
        c.Item:query():order("name"):delete()
    end,
    plan = function(c) c.Item:query():using("missing"):delete() end,
}

function steps.bad(c, which) return bad[which](c) end

function steps.caught(c, which)
    local ok, err = pcall(bad[which], c)
    return { tostring(ok), err, state(c), logs(c) }
end

function steps.snapshot(c)
    local seen = 0
    local n = c.Item:query():where("tag", "=", "old"):where(function()
        if c.Log:query():count() ~= 0 then error("selection interleaved with writes", 0) end
        seen += 1
        return true
    end):update({ tag = "spawn" })
    return { n, seen, c.Item:query():count(), c.Item:by("name", "new").revision,
             c.Item:query():where("tag", "=", "spawn"):count(), logs(c) }
end

function steps.cascade(c)
    c.Item:update(c.Item:by("name", "a").id, { tag = "cascade" })
    c.Log:query():delete()
    local n = c.Item:query():order("name"):delete()
    return { n, c.Item:query():count(), entries(), logs(c) }
end

function steps.page_seed(c, start)
    local input = {}
    for i = tonumber(start), math.min(tonumber(start) + 199, 1005) do
        input[#input + 1] = { name = string.format("r%04d", i), score = i }
    end
    return #c.Item:createMany(input)
end

function steps.pages(c)
    local updated = c.Item:query():where("score", ">", 0):order("score"):update({ score = 2000 })
    local repeated = c.Item:query():where("revision", "~=", 1):count()
    local moved = c.Item:query():where("score", "=", 2000):count()
    local deleted = c.Item:query():where("score", "=", 2000):order("score", "desc"):delete()
    return { updated, repeated, moved, deleted, c.Item:query():count(), entries(), c.Log:query():count() }
end

function steps.insert(c) return c.Item:create({ name = "e", score = 5 }).id end

function steps.apply(c, op)
    local q = c.Item:query():where("tag", "=", "old"):order("score")
    return op == "update" and q:update({ tag = "new" }) or q:delete()
end

function call(step, mode, ids, format, arg, op)
    local graph = app(ids, format)
    if step == "migrate" then return m.migrate(graph).version end
    if step == "plain" then
        return client.tx(function(c)
            local before = state(c)
            local n = c.Item:query():where("name", "=", "a"):update({ score = 1 })
            return { n, tostring(state(c) == before), logs(c) }
        end, mode == "pessimistic")
    end
    local db = client.open(graph)
    if step == "external" then return steps.apply(db.client(), arg) end
    return db.tx(function(c) return steps[step](c, arg, op) end, mode == "pessimistic")
end
"""

BASE_ROWS = [
    "a:1:old:memo:0:1:ca", "b:2:old:nil:0:1:cb",
    "c:3:old:memo:0:1:cc", "d:4:old:nil:0:1:cd",
]
ZERO_ENTRIES = ("by_code=0 by_name=0 by_note=0 by_score=0 by_tag_score=0 "
                "group_items=0/0 item_friends=0/0")


def app(client, space, mode="optimistic", ids="int", format="binary", seed=True):
    setup(client)
    client.execute_command("USE", space)
    client.execute_command("SETF", "QUERYWRITES", APP)

    def run(step, arg="", op=""):
        return client.execute_command("CALLF", "QUERYWRITES", step, mode, ids, format, arg, op)

    assert run("migrate") == 1
    if seed:
        assert run("seed") == "ok"
    return run


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("ids", ["int", "uuid"])
@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_query_update_runs_row_rules_hooks_and_index_upkeep(client, mode, ids, format):
    run = app(client, f"query_update_{mode}_{ids}_{format}", mode, ids, format)
    assert run("update") == [
        2, " ".join([BASE_ROWS[0], "b:8:new:nil:1:2:cb", "c:8:new:nil:1:2:cc", BASE_ROWS[3]]),
        "by_code=4 by_name=4 by_note=4 by_score=4 by_tag_score=4 group_items=3/3 item_friends=2/2",
        "update c; update b", 0, 2, 1, "true",
    ]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("ids", ["int", "uuid"])
@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_query_delete_removes_indexes_and_both_edge_directions(client, mode, ids, format):
    run = app(client, f"query_delete_{mode}_{ids}_{format}", mode, ids, format)
    assert run("delete") == [
        2, "a,d",
        "by_code=2 by_name=2 by_note=2 by_score=2 by_tag_score=2 group_items=1/1 item_friends=0/0",
        "delete c; delete b", 2, 0,
    ]


SELECTIONS = {
    "window": ["c", "b"], "sorted": ["c", "b"], "cursor": ["c"],
    "predicate": ["b", "d"], "follow": ["b"], "driving": ["a", "b"],
    "probing": ["a", "c"], "unique": ["b"], "all": ["a", "b", "c", "d"],
    "zero": [], "empty": [],
}


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("op", ["update", "delete"])
@pytest.mark.parametrize("which, selected", SELECTIONS.items())
def test_query_writes_honor_the_query_selection(client, mode, op, which, selected):
    run = app(client, f"query_write_{mode}_{op}_{which}", mode)
    remaining = sorted(selected) if op == "update" else [n for n in "abcd" if n not in selected]
    assert run("choose", which, op) == [
        len(selected), ",".join(remaining), "; ".join(f"{op} {n}" for n in selected),
    ]


def test_query_update_without_values_runs_update_defaults(client):
    run = app(client, "query_write_defaults")
    assert run("defaults") == [
        4, " ".join(row.replace(":0:1:", ":1:2:") for row in BASE_ROWS),
        "update a; update b; update c; update d",
    ]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_query_update_without_graph_counts_unchanged_rows(client, mode):
    run = app(client, "query_write_plain_" + mode, mode)
    assert run("plain") == [1, "true", ""]


ERRORS = {
    "values": "query update takes a table of values",
    "clear": "query update clear takes a list of fields",
    "field": "has no field unknown",
    "clearfield": "has no field unknown",
    "id": "gives out ids itself",
    "edge": "edge group changes with link and unlink",
    "rule": "field score wants at least 0, got -1",
    "kind": "field score wants int, got x",
    "immutable": "field created is immutable",
    "required": "field tag is not optional",
    "unique": "index by_code is unique",
    "update_hook": "update hook refused",
    "missing": "table Item has no row 2",
    "delete_hook": "delete hook refused",
    "plan": "has no index missing",
}


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("which, error", ERRORS.items())
def test_query_write_errors_roll_back_rows_indexes_edges_and_hooks(client, mode, which, error):
    run = app(client, f"query_write_error_{mode}_{which}", mode)
    before = run("inspect")
    with pytest.raises(redis.ResponseError, match=error):
        run("bad", which)
    assert run("inspect") == before


@pytest.mark.parametrize("which", ["unique", "update_hook", "delete_hook"])
def test_caught_query_write_errors_keep_completed_writes(client, which):
    run = app(client, "query_write_caught_" + which)
    ok, err, state, log = run("caught", which)
    assert ok == "false"
    assert ERRORS[which] in err
    rows = BASE_ROWS.copy()
    if which == "delete_hook":
        rows.pop(0)
        rows[0] = "b:2:delete_refuse:nil:1:2:cb"
        assert log == "update b; delete a; delete b"
    else:
        rows[0] = "a:1:old:memo:1:2:same" if which == "unique" else "a:1:refuse:memo:1:2:ca"
        assert log == "update a; update b"
    assert state == " ".join(rows)


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_query_selects_all_targets_before_hooks_can_add_matches(client, mode):
    run = app(client, "query_write_snapshot_" + mode, mode)
    assert run("snapshot") == [4, 4, 5, 0, 4, "update a; update b; update c; update d"]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_query_delete_counts_only_rows_it_removes_directly(client, mode):
    run = app(client, "query_write_cascade_" + mode, mode)
    assert run("cascade") == [3, 0, ZERO_ENTRIES, "delete a; delete b; delete c; delete d"]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
def test_query_writes_across_index_scan_pages_process_each_row_once(client, mode):
    run = app(client, "query_write_pages_" + mode, mode, seed=False)
    for start in range(1, 1006, 200):
        assert run("page_seed", start) == min(200, 1006 - start)
    assert run("pages") == [1005, 0, 1005, 1005, 0, ZERO_ENTRIES, 2010]


@pytest.mark.parametrize("op", ["update", "delete"])
def test_query_write_conflicts_with_a_new_matching_row(server, client, op):
    space = "query_write_phantom_" + op
    run = app(client, space)
    other = connect(server.port)
    try:
        other.execute_command("USE", space)
        client.execute_command("BEGINTX")
        assert run("external", op) == 4
        other.execute_command("CALLF", "QUERYWRITES", "insert", "optimistic", "int", "binary", "", "")
        with pytest.raises(redis.ResponseError, match="TXCONFLICT"):
            client.execute_command("COMMITTX")
    finally:
        other.close()
    assert run("inspect")[2] == ""
    assert run("apply", op) == 5
