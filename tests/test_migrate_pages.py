import json
import subprocess
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

import pytest

from .helpers import connect, wait_for_tcp
from .test_client import setup

redis = pytest.importorskip("redis")

APP = """
local lent = require("lent.SCHEMA")
local client = require("lent.CLIENT")
local m = require("lent.MIGRATE")
local lay = require("lent.LAYOUT")
local kc = require("lent.KEYCODEC")

local function app(stage, ids, format, unique)
    local value = stage == "float" and lent.field.float "value" or lent.field.int "value"
    value:optional()
    if stage == "default" then value:default(42) end
    local indexes = {}
    if stage ~= "base" then
        local ix = lent.index(stage == "replace" and "note" or "value"):name("work")
        if unique == "unique" then ix:unique() end
        indexes[#indexes + 1] = ix
    end
    if stage == "multi" then indexes[#indexes + 1] = lent.index("note") end
    return lent.graph {
        lent.schema "Item" {
            id = ids, format = format,
            fields = { lent.field.string "name":unique(), value, lent.field.string "note":optional() },
            indexes = indexes,
        },
        lent.schema "Aux" { id = "int", fields = { lent.field.string "name" } },
    }
end

local function report(r)
    return { version = r.version, changed = r.changed, done = r.done,
             processed = r.processed, steps = r.steps }
end

local function status()
    return barch.tx.run(function()
        local c = m.load()
        local t = c.tables.item
        local out = { version = c.version, pending = c.migration ~= nil,
                      states = {}, specs = {}, entries = {}, values = {},
                      at = c.migration and c.migration.at, cursor = c.migration and c.migration.cursor }
        for _, ix in t.indexes do
            out.states[ix.name] = ix.state or "ready"
            out.entries[ix.name] = lay.walk(lay.index(t, ix), function() end)
            local spec = simdjson.parse(barch.graph.get("/lent/tables/item/indexes/" .. ix.name .. "/spec"))
            out.specs[ix.name] = spec.state or "ready"
        end
        local prefix = kc.encode("string", "item") .. kc.encode("string", "work")
        out.raw_i = lay.walk("lent.i" .. prefix, function() end)
        out.raw_u = lay.walk("lent.u" .. prefix, function() end)
        for _, r in client.client().Item:query():order("name"):all() do
            out.values[r.name] = r.value == nil and "nil" or r.value
        end
        return out
    end)
end

local function page_value(page)
    if page == "nil" then return nil end
    if page == "false" then return false end
    if page == "nan" then return 0 / 0 end
    if page == "inf" then return math.huge end
    return tonumber(page) or page
end

function call(step, stage, mode, ids, format, unique, page, arg)
    local graph = app(stage, ids, format, unique)
    if step == "migrate" then return simdjson.encode(report(m.migrate(graph, page_value(page)))) end
    if step == "interrupt" or step == "timeout" then
        m.migrate(graph, 1)
        if step == "interrupt" then error("interrupted after a committed page", 0) end
        while true do end
    end
    if step == "status" then return simdjson.encode(status()) end
    if step == "inside" then
        return barch.tx.run(function() return m.migrate(graph, 2) end)
    end
    if step == "apply_outside" then return m.apply(m.plan(m.load(), graph)) end
    return simdjson.encode(client.tx(function(c)
        if step == "seed" then
            for i, name in { "a", "b", "c", "d", "e", "f", "g" } do
                local value = i <= 6 and i or nil
                if arg == "duplicate" and name == "b" then value = 1 end
                c.Item:create { name = name, value = value, note = name }
            end
            return true
        elseif step == "bulk_seed" then
            local rows = {}
            for i = tonumber(arg), math.min(tonumber(arg) + 249, 1105) do
                rows[#rows + 1] = { name = string.format("r%04d", i), value = i, note = "note" }
            end
            return #c.Item:createMany(rows)
        elseif step == "query" or step == "using" or step == "query_write" then
            local q = c.Item:query():where("value", ">=", 2):order("value")
            if step == "using" then q:using("work") end
            local names = {}
            for _, r in q:all() do names[#names + 1] = r.name end
            if step == "query_write" then barch.store.set("touched", "yes") end
            return { names = names, plan = q:explain() }
        elseif step == "by" then
            return c.Item:by("work", 1).name
        elseif step == "upsert" then
            return c.Item:upsert("work", { value = 1, name = "a" }).name
        elseif step == "mutate" then
            c.Item:update(c.Item:by("name", "a").id, { value = 20 })
            c.Item:update(c.Item:by("name", "e").id, { value = 50 })
            c.Item:delete(c.Item:by("name", "b").id)
            c.Item:delete(c.Item:by("name", "f").id)
            c.Item:create { name = "z", value = 90, note = "z" }
            return true
        elseif step == "duplicate" then
            if arg == "create" then return c.Item:create { name = "x", value = 5 } end
            return c.Item:update(c.Item:by("name", "a").id, { value = 5 })
        elseif step == "fix" then
            if arg == "update" then
                c.Item:update(c.Item:by("name", "b").id, { value = 20 })
            else
                c.Item:delete(c.Item:by("name", arg == "owner_delete" and "a" or "b").id)
            end
            return true
        elseif step == "write" then
            if arg == "create" then c.Item:create { name = "x", value = 99 }
            elseif arg == "update" then c.Item:update(c.Item:by("name", "a").id, { value = 99 })
            else c.Item:delete(c.Item:by("name", "a").id) end
            return true
        elseif step == "aux" then
            return c.Aux:create({ name = "ok" }).id
        elseif step == "shape" then
            return m.plan(m.load(), graph).changed
        elseif step == "apply" then
            m.apply(m.plan(m.load(), graph))
            return true
        end
        error("unknown step " .. step)
    end, mode == "pessimistic"))
end
"""


def app(client, space, mode="optimistic", ids="int", format="binary", unique="plain", seed=True,
        duplicate=False):
    setup(client)
    client.execute_command("USE", space)
    client.execute_command("SETF", "MIGPAGES", APP)

    def run(step, stage="build", page=2, arg="", conn=client, function="MIGPAGES"):
        return json.loads(conn.execute_command("CALLF", function, step, stage, mode, ids, format,
                                               unique, str(page), arg))

    assert run("migrate", "base")["done"] is True
    if seed:
        assert run("seed", "base", arg="duplicate" if duplicate else "") is True
    return run


def finish(run, stage="build", page=2):
    reports = []
    for _ in range(100):
        r = run("migrate", stage, page)
        reports.append(r)
        assert r["processed"] <= page
        if r["done"]:
            return reports
    pytest.fail("migration did not finish within 100 calls")


@pytest.mark.parametrize("ids", ["int", "uuid"])
@pytest.mark.parametrize("format", ["binary", "text", "json"])
@pytest.mark.parametrize("unique", ["plain", "unique"])
def test_index_build_pages_are_bounded_resumable_and_hidden_until_ready(client, ids, format, unique):
    run = app(client, f"migration_pages_{ids}_{format}_{unique}", ids=ids, format=format, unique=unique)
    first = run("migrate")
    assert first == {"version": 2, "changed": True, "done": False, "processed": 2,
                     "steps": ["build Item.work"]}
    s = run("status")
    assert s["pending"] and s["cursor"]
    assert s["states"]["work"] == s["specs"]["work"] == "building"
    assert s["entries"]["work"] == 2
    assert run("shape") is False
    assert run("query") == {"names": ["b", "c", "d", "e", "f"], "plan": "id then sort"}
    with pytest.raises(redis.ResponseError, match="index work is building"):
        run("using")
    if unique == "unique":
        for method in ("by", "upsert"):
            with pytest.raises(redis.ResponseError, match="index work is building"):
                run(method)
    rest = finish(run)
    assert [r["processed"] for r in rest] == [2, 2, 1]
    assert all(r["version"] == 2 and r["changed"] for r in rest)
    s = run("status")
    assert not s["pending"]
    assert s["states"]["work"] == s["specs"]["work"] == "ready"
    assert s["entries"]["work"] == (6 if unique == "unique" else 7)
    q = run("query")
    assert q["names"] == ["b", "c", "d", "e", "f"]
    assert q["plan"] == ("id then sort" if unique == "unique" else "work range value")
    if unique == "unique":
        assert run("by") == run("upsert") == "a"
    assert run("migrate") == {"version": 2, "changed": False, "done": True, "processed": 0, "steps": {}}


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("ids", ["int", "uuid"])
@pytest.mark.parametrize("unique", ["plain", "unique"])
def test_writes_keep_building_indexes_current_and_builds_accept_their_entries(client, mode, ids, unique):
    run = app(client, f"migration_live_{mode}_{ids}_{unique}", mode, ids, unique=unique)
    assert not run("migrate")["done"]
    assert run("mutate") is True
    assert run("query")["names"] == ["c", "d", "a", "e", "z"]
    finish(run)
    s = run("status")
    assert s["values"] == {"a": 20, "c": 3, "d": 4, "e": 50, "g": "nil", "z": 90}
    assert s["entries"]["work"] == (5 if unique == "unique" else 6)
    assert run("query")["names"] == ["c", "d", "a", "e", "z"]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("operation", ["create", "update"])
def test_building_unique_index_checks_rows_beyond_its_cursor(client, mode, operation):
    run = app(client, f"migration_unique_check_{mode}_{operation}", mode, unique="unique")
    run("migrate", page=1)
    before = run("status")
    with pytest.raises(redis.ResponseError, match="index work is unique"):
        run("duplicate", arg=operation)
    assert run("status") == before


@pytest.mark.parametrize("operation", ["update", "delete", "owner_delete"])
def test_failed_unique_page_keeps_progress_and_can_resume_after_data_is_fixed(client, operation):
    run = app(client, "migration_fix_" + operation, unique="unique", duplicate=True)
    run("migrate", page=1)
    before = run("status")
    with pytest.raises(redis.ResponseError, match="MIGRATE table Item index work is unique"):
        run("migrate", page=2)
    assert run("status") == before
    with pytest.raises(redis.ResponseError, match="a migration is in progress"):
        run("migrate", "base")
    assert run("fix", arg=operation) is True
    # Removing an unscanned duplicate must preserve the built row's entry.
    assert run("status")["entries"]["work"] == (2 if operation == "update" else 0 if operation == "owner_delete" else 1)
    finish(run, page=1)
    s = run("status")
    assert s["entries"]["work"] == (6 if operation == "update" else 5)
    assert run("by") == ("b" if operation == "owner_delete" else "a")


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("unique", ["plain", "unique"])
def test_replacing_an_index_pages_its_drop_and_blocks_only_affected_row_writes(client, mode, unique):
    run = app(client, f"migration_replace_{mode}_{unique}", mode, unique=unique)
    finish(run)
    first = run("migrate", "replace")
    assert not first["done"] and first["processed"] == 2
    assert first["steps"] == ["drop Item.work", "build Item.work"]
    for operation in ("create", "update", "delete"):
        with pytest.raises(redis.ResponseError, match="indexes are being replaced"):
            run("write", "replace", arg=operation)
    assert run("aux", "replace") == 1
    assert len(run("status", "replace")["values"]) == 7
    reports = []
    for _ in range(7):
        if run("status", "replace")["at"] == 2:
            break
        reports.append(run("migrate", "replace"))
    s = run("status", "replace")
    assert s["at"] == 2 and s["states"]["work"] == "building"
    assert run("write", "replace", arg="update") is True
    reports += finish(run, "replace")
    assert sum(r["processed"] for r in [first] + reports) == (13 if unique == "unique" else 14)
    assert run("status", "replace")["entries"]["work"] == 7
    assert run("write", "replace", arg="update") is True


@pytest.mark.parametrize("stage", ["float", "default"])
@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_encoding_and_default_changes_rebuild_existing_indexes(client, stage, format):
    run = app(client, f"migration_encoding_{stage}_{format}", format=format)
    finish(run)
    reports = finish(run, stage)
    assert reports[0]["steps"] == ["drop Item.work", "build Item.work"]
    assert reports[-1]["version"] == 3
    s = run("status", stage)
    assert s["entries"]["work"] == 7
    if stage == "default":
        assert s["values"]["g"] == 42
        assert run("query", stage)["names"] == ["b", "c", "d", "e", "f", "g"]
    else:
        assert run("query", stage)["names"] == ["b", "c", "d", "e", "f"]


def test_page_budget_is_shared_across_indexes_and_index_removal_is_paged(client):
    run = app(client, "migration_multi")
    first = run("migrate", "multi", page=3)
    assert first["processed"] == 3 and not first["done"]
    reports = finish(run, "multi", page=3)
    assert sum(r["processed"] for r in [first] + reports) == 14
    reports = finish(run, "base", page=3)
    assert sum(r["processed"] for r in reports) == 14
    s = run("status", "base")
    assert s["states"] == {"by_name": "ready"}
    assert s["raw_i"] == s["raw_u"] == 0


def test_default_page_size_limits_each_function_call(client):
    run = app(client, "migration_default_budget", seed=False)
    for start in range(1, 1106, 250):
        assert run("bulk_seed", "base", arg=start) == min(250, 1106 - start)
    assert run("migrate", page="nil")["processed"] == 1000
    assert run("status")["states"]["work"] == "building"
    final = run("migrate", page="nil")
    assert final["done"] and final["processed"] == 105


@pytest.mark.parametrize("page", [0, -1, 1.5, 10001, "bad", "false", "nan", "inf"])
def test_invalid_page_sizes_leave_the_catalog_unchanged(client, page):
    run = app(client, "migration_bad_page_" + str(page).replace("-", "minus").replace(".", "_"))
    before = run("status", "base")
    with pytest.raises(redis.ResponseError, match="page size must be a whole number from 1 to 10000"):
        run("migrate", page=page)
    assert run("status", "base") == before


def test_migrate_refuses_an_outer_transaction(client):
    run = app(client, "migration_outer")
    with pytest.raises(redis.ResponseError, match="migrate needs its own transaction"):
        run("inside")
    assert not run("status", "base")["pending"]


def test_low_level_apply_requires_a_transaction_and_preserves_pending_builds(client):
    run = app(client, "migration_apply")
    with pytest.raises(redis.ResponseError, match="apply needs an open transaction"):
        run("apply_outside")
    run("migrate", page=1)
    before = run("status")
    with pytest.raises(redis.ResponseError, match="use migrate to resume it"):
        run("apply")
    assert run("status") == before


@pytest.mark.parametrize("kind", ["interrupt", "timeout"])
def test_committed_pages_survive_a_function_error_or_timeout(client, kind):
    run = app(client, "migration_interrupted_" + kind)
    function = "MIGPAGES_TIMEOUT" if kind == "timeout" else "MIGPAGES"
    if kind == "timeout":
        client.execute_command("SETF", function, '--@barch {"deadline_ms": 1000}\n' + APP)
    with pytest.raises(redis.ResponseError, match="FUNCTION timeout" if kind == "timeout" else "interrupted"):
        run(kind, function=function)
    assert run("status")["entries"]["work"] == 1
    assert run("status")["pending"]
    finish(run)
    assert run("status")["states"]["work"] == "ready"


def test_concurrent_resumers_advance_the_same_build_without_losing_pages(server, client):
    space = "migration_concurrent"
    run = app(client, space)
    assert not run("migrate", page=1)["done"]
    barrier = Barrier(3)

    def resume(_):
        conn = connect(server.port)
        try:
            conn.execute_command("USE", space)
            barrier.wait(timeout=10)
            return run("migrate", page=1, conn=conn)
        finally:
            conn.close()

    with ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(resume, range(3)))
    assert all(r["processed"] == 1 and r["version"] == 2 for r in results)
    assert run("status")["entries"]["work"] == 4
    finish(run, page=1)
    assert run("status")["entries"]["work"] == 7


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("unique", ["plain", "unique"])
def test_a_build_page_can_race_with_row_writes(server, client, mode, unique):
    space = f"migration_race_{mode}_{unique}"
    run = app(client, space, mode, unique=unique)
    run("migrate")
    barrier = Barrier(2)

    def call(step):
        conn = connect(server.port)
        try:
            conn.execute_command("USE", space)
            barrier.wait(timeout=10)
            return run(step, page=4, conn=conn)
        finally:
            conn.close()

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(call, ["migrate", "mutate"]))
    assert results[0]["processed"] <= 4
    assert results[1] is True
    finish(run)
    s = run("status")
    assert s["values"] == {"a": 20, "c": 3, "d": 4, "e": 50, "g": "nil", "z": 90}
    assert s["entries"]["work"] == (5 if unique == "unique" else 6)


def test_build_progress_conflicts_with_clients_even_when_the_version_stays_the_same(server, client):
    space = "migration_page_conflict"
    run = app(client, space)
    run("migrate", page=1)
    other = connect(server.port)
    try:
        other.execute_command("USE", space)
        client.execute_command("BEGINTX")
        assert run("query_write")["names"] == ["b", "c", "d", "e", "f"]
        assert run("migrate", page=1, conn=other)["version"] == 2
        with pytest.raises(redis.ResponseError, match="TXCONFLICT"):
            client.execute_command("COMMITTX")
    finally:
        other.close()
    finish(run)


def test_progress_survives_a_saved_server_restart(fresh_server):
    server = fresh_server
    space = "migration_restart"
    run = app(server.client, space)
    run("migrate", page=1)
    before = run("status")
    server.client.execute_command("SAVE")
    server.client.close()
    server.process.terminate()
    server.process.wait(timeout=10)
    with open(server.log_path, "ab") as log:
        server.process = subprocess.Popen(
            [str(server.binary), "--port", str(server.port), "--bind", "127.0.0.1", "--dir", server.data],
            stdout=log, stderr=subprocess.STDOUT,
        )
    wait_for_tcp(server.port, timeout=30)
    conn = connect(server.port)
    server.client = conn
    setup(conn)
    conn.execute_command("USE", space)
    conn.execute_command("SETF", "MIGPAGES", APP)
    assert run("status", conn=conn) == before
    resumed = lambda step, stage="build", page=2: run(step, stage, page, conn=conn)
    finish(resumed)
    assert resumed("status")["states"]["work"] == "ready"
