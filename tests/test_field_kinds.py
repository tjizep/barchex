import json

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

RAW = bytes([0, 1, 2, 9, 10, 13, 31, 32, 92, 255])

APP = r'''
local lent = require("lent.SCHEMA")
local client = require("lent.CLIENT")
local m = require("lent.MIGRATE")
local rc = require("lent.ROWCODEC")
local lay = require("lent.LAYOUT")
local v = require("lent.VALUES")
local kc = require("lent.KEYCODEC")
local RAW = string.char(0, 1, 2, 9, 10, 13, 31, 32, 92, 255)

local function app(ids, format, stage)
    local shared = { phase = "create", nested = { n = 0 }, empty = lent.jsonArray() }
    local status = lent.field.enum "status":values("review", "draft", "published"):default("draft")
    if stage == "expand" then
        status = lent.field.enum "status":values("review", "draft", "published", "archived"):default("draft")
    elseif stage == "narrow" then
        status = lent.field.enum "status":values("draft", "published"):default("draft")
    elseif stage == "enum_string" then
        status = lent.field.string "status":default("draft")
    end
    local blob = stage == "byte_change" and lent.field.string "blob" or lent.field.bytes "blob"
    blob:optional():unique():maxLen(512)
    local payload = stage == "json_change" and lent.field.string "payload" or lent.field.json "payload"
    local default = stage == "array_default" and lent.jsonArray()
        or { nested = { n = 0 }, empty = lent.jsonArray(), object = {} }
    if stage == "false_default" then default = false
    elseif stage == "null_default" then default = simdjson.null
    elseif stage == "big_default" then default = lent.parseJson("9223372036854775807")
    elseif stage == "object_default" then default = {} end
    if stage == "json_change" then default = "changed" end
    payload:default(default):validate(function(value)
        return type(value) ~= "table" or not value.invalid or "invalid payload"
    end)
    local fields = {
        lent.field.string "name":unique(), status, blob, payload,
        lent.field.enum "mode":values("image", "note"):optional():unique(),
        lent.field.json "extra":optional(),
        lent.field.json "fixed":default({ deep = { n = 0 }, list = lent.jsonArray(), object = {} }):immutable(),
        lent.field.json "dynamic":optional():default(function() return shared end)
            :updateDefault(function() return { phase = "update", nested = { n = 0 }, empty = lent.jsonArray() } end),
        lent.field.bytes "seed":minLen(2):default(string.char(0, 255)):immutable(),
        lent.field.int "touch":default(0),
    }
    local indexes = { lent.index("status"), lent.index("blob"):name("blob_order") }
    if stage == "add" then
        fields[#fields + 1] = { kind = "enum", name = "tier", values = { "free", "pro" }, default = "free" }
        fields[#fields + 1] = { kind = "json", name = "settings", default = { targets = lent.jsonArray(), object = {} } }
        fields[#fields + 1] = { kind = "bytes", name = "legacy", default = string.char(255, 0) }
        indexes[#indexes + 1] = lent.index("tier")
    end
    return lent.graph {
        lent.schema "Doc" {
            id = ids, format = format, fields = fields, indexes = indexes,
            hooks = {
                create = { function(c, row)
                    if type(row.payload) == "table" and row.payload.nested then row.payload.nested.n += 1 end
                    if row.dynamic then row.dynamic.nested.n += 1 end
                end },
                update = { function(c, id, row, old)
                    c.Log:create { msg = v.json(old.payload) }
                    if row.touch == 1 then row.payload.nested.n += 1
                    elseif row.touch == 2 then row.fixed.deep.n += 1
                    elseif row.touch == 3 then
                        old.fixed.deep.n = 999
                        old.payload.nested.n = 999
                    elseif row.touch == 4 then row.payload = function() end end
                end },
            },
        },
        lent.schema "Log" { id = "int", fields = { lent.field.string "msg" } },
    }
end

local function show(row)
    return { name = row.name, status = row.status, payload = v.json(row.payload),
             fixed = v.json(row.fixed), dynamic = row.dynamic and v.json(row.dynamic),
             extra = row.extra ~= nil and v.json(row.extra) or "missing",
             blob = row.blob ~= nil and v.hex(row.blob) or "missing", seed = v.hex(row.seed),
             tier = row.tier, settings = row.settings and v.json(row.settings),
             legacy = row.legacy and v.hex(row.legacy) }
end

local function snapshot(c)
    local rows = {}
    for _, row in c.Doc:query():order("name"):all() do rows[#rows + 1] = show(row) end
    return rows
end

local function page_names(c, field)
    local names, cursor = {}, nil
    repeat
        local q = c.Doc:query():order(field):limit(1)
        if cursor then q:after(cursor) end
        local row = q:first()
        if row == nil then break end
        names[#names + 1] = row.name
        cursor = q:cursor(row)
    until false
    return table.concat(names, ",")
end

local steps = {}

function steps.rows(c)
    local input = { nested = { n = 7 }, empty = lent.jsonArray(), object = {} }
    local a = c.Doc:create { name = "a", status = "published", mode = "image", blob = RAW .. "a", payload = input }
    local b = c.Doc:create { name = "b", mode = "note", blob = RAW .. "b", extra = simdjson.null }
    c.Doc:create { name = "c", status = "review", payload = input, extra = {} }
    c.Doc:create { name = "d", blob = "", payload = simdjson.null, extra = lent.jsonArray() }
    local matched = c.Doc:query():where("payload", "=", { object = {}, empty = lent.jsonArray(), nested = { n = 8 } }):count()
    local predicates = c.Doc:query():where(function(row)
        return type(row.payload) == "table" and row.payload.nested and row.payload.nested.n == 8
    end):count()
    local aa, madeA = c.Doc:upsert("mode", { mode = "image", status = "review" })
    local bb, madeB = c.Doc:upsert("blob", { blob = RAW .. "b", status = "published" })
    return {
        rows = snapshot(c), input = input.nested.n, matched = matched, predicates = predicates,
        sameIds = a.id == aa.id and b.id == bb.id, created = { madeA, madeB },
        bytesOrder = page_names(c, "blob"), enumOrder = page_names(c, "status"),
        missing = c.Doc:query():where("extra", "=", nil):count(),
        null = c.Doc:query():where("extra", "=", simdjson.null):count(),
        object = c.Doc:query():where("extra", "=", {}):count(),
        array = c.Doc:query():where("extra", "=", lent.jsonArray()):count(),
        notObject = c.Doc:query():where("extra", "~=", {}):count(),
        blobLookup = c.Doc:by("blob", RAW .. "a").name,
        raw = v.hex(barch.store.get(lay.row(c.Doc.t, a.id))),
    }
end

function steps.seed(c)
    return steps.rows(c).matched
end

function steps.inspect(c)
    return { rows = snapshot(c), logs = c.Log:query():count() }
end

function steps.shapes(c)
    local values = {
        simdjson.null, false, 7, "literal", lent.jsonArray(), {},
        lent.parseJson([[{"z":[],"a":[{},[],null,{"quote\"key":"line\n\u00e9"}],"n":1099511627776}]]),
        lent.parseJson("9223372036854775807"),
    }
    local out = {}
    for i, value in values do
        local row = c.Doc:create { name = "shape" .. i, payload = value }
        out[i] = v.json(c.Doc:get(row.id).payload)
    end
    return out
end

function steps.hooks(c, touch)
    local row = c.Doc:by("name", "a")
    local before = v.json(row.payload)
    local changed = c.Doc:update(row.id, { touch = tonumber(touch) })
    return { before = before, row = show(changed), stored = show(c.Doc:get(row.id)),
             log = c.Log:query():order("id", "desc"):first().msg }
end

function steps.equal_fixed(c)
    local row = c.Doc:by("name", "a")
    return show(c.Doc:update(row.id, { fixed = lent.parseJson([[{"object":{},"list":[],"deep":{"n":0}}]]) }))
end

function steps.query_writes(c)
    local value = { nested = { n = 8 }, empty = lent.jsonArray(), object = {} }
    local updated = c.Doc:query():where("payload", "=", value)
        :update({ payload = { nested = { n = 10 }, empty = lent.jsonArray(), object = {} }, extra = simdjson.null }, { "blob" })
    local matches = c.Doc:query():where("payload", "=", { object = {}, empty = lent.jsonArray(), nested = { n = 10 } }):count()
    local deleted = c.Doc:query():where("extra", "=", simdjson.null):delete()
    local new = c.Doc:create { name = "e", mode = "image", blob = RAW .. "b" }
    return { updated = updated, matches = matches, deleted = deleted, name = c.Doc:by("blob", RAW .. "b").name,
             remaining = c.Doc:query():count(), reusedMode = new.mode }
end

function steps.schema_codec(c)
    local graph = app("int", "binary", "v1")
    local _, list = lent.ids(graph.tables.Doc)
    local fields = rc.fields(list)
    local row = c.Doc:by("name", "a")
    row.id = nil
    local encoded = rc.encode(fields, c.Doc.t.format, 1, row)
    local back = rc.decode(fields, encoded)
    local onlyName = rc.fields({ { name = "name", kind = "string", id = 1 } })
    return { status = back.status, blob = v.hex(back.blob), payload = v.json(back.payload),
             skipped = rc.decode(onlyName, encoded).name }
end

local errors = {
    enum = function(c) c.Doc:create { name = "bad", status = "unknown" } end,
    enum_type = function(c) c.Doc:create { name = "bad", status = 1 } end,
    enum_utf8 = function(c) c.Doc:create { name = "bad", status = string.char(255) } end,
    bytes = function(c) c.Doc:create { name = "bad", blob = buffer.fromstring("x") } end,
    bytes_length = function(c) c.Doc:create { name = "bad", blob = string.rep("x", 513) } end,
    bytes_unique = function(c) c.Doc:create { name = "bad", blob = RAW .. "a" } end,
    enum_unique = function(c) c.Doc:create { name = "bad", mode = "image" } end,
    cyclic = function(c)
        local value = {}; value.self = value
        c.Doc:create { name = "bad", payload = value }
    end,
    sparse = function(c) c.Doc:create { name = "bad", payload = { [2] = "gap" } } end,
    mixed = function(c) c.Doc:create { name = "bad", payload = { 1, key = 2 } } end,
    utf8 = function(c) c.Doc:create { name = "bad", payload = { key = string.char(255) } } end,
    nan = function(c) c.Doc:create { name = "bad", payload = { n = 0 / 0 } } end,
    inf = function(c) c.Doc:create { name = "bad", payload = { n = math.huge } } end,
    function_value = function(c) c.Doc:create { name = "bad", payload = { fn = function() end } } end,
    validation = function(c) c.Doc:create { name = "bad", payload = { invalid = true } } end,
    json_order = function(c) c.Doc:query():order("payload"):all() end,
    json_range = function(c) c.Doc:query():where("payload", ">", {}):all() end,
    json_filter = function(c) c.Doc:query():where("payload", "=", string.char(255)):all() end,
    fixed = function(c) steps.hooks(c, "2") end,
    old_snapshot = function(c)
        local row = c.Doc:by("name", "a")
        c.Doc:update(row.id, { fixed = { deep = { n = 0 }, list = {}, object = {} } })
    end,
    hook_invalid = function(c) steps.hooks(c, "4") end,
    clear_required = function(c) c.Doc:update(c.Doc:by("name", "a").id, {}, { "payload" }) end,
    deep = function(c)
        local value = {}; local at = value
        for _ = 1, 128 do at.next = {}; at = at.next end
        c.Doc:create { name = "bad", payload = value }
    end,
}

function steps.bad(c, which) return errors[which](c) end

function steps.migrated(c)
    local out = snapshot(c)
    local row = c.Doc:create { name = "new" }
    return { rows = out, new = show(row) }
end

function steps.archived(c)
    return c.Doc:create({ name = "archived", status = "archived" }).status
end

local schema_errors = {
    enum_missing = function() return { kind = "enum", name = "x" } end,
    enum_empty = function() return { kind = "enum", name = "x", values = {} } end,
    enum_duplicate = function() return { kind = "enum", name = "x", values = { "a", "a" } } end,
    enum_utf8 = function() return { kind = "enum", name = "x", values = { string.char(255) } } end,
    enum_gap = function() return { kind = "enum", name = "x", values = { [2] = "x" } } end,
    nonenum = function() return { kind = "string", name = "x", values = { "a" } } end,
    enum_default = function() return { kind = "enum", name = "x", values = { "a" }, default = "b" } end,
    json_unique = function() return { kind = "json", name = "x", unique = true } end,
    bytes_min = function() return { kind = "bytes", name = "x", min = 1 } end,
    bytes_match = function() return { kind = "bytes", name = "x", match = "x" } end,
    json_length = function() return { kind = "json", name = "x", maxLen = 2 } end,
}

function call(step, mode, ids, format, stage, arg, page)
    local graph = app(ids, format, stage)
    if step == "migrate" then return simdjson.encode(m.migrate(graph, tonumber(page))) end
    if step == "schema" then
        local fields = { schema_errors[arg]() }
        return lent.schema "Bad" { fields = fields }
    end
    if step == "schema_index" then
        return lent.schema "Bad" { fields = { lent.field.json "x" }, indexes = { lent.index("x") } }
    end
    if step == "parse" then return simdjson.encode(lent.encodeJson(lent.parseJson(arg))) end
    if step == "codec" then
        local fields = rc.fields({ { name = "data", kind = arg, id = 1,
            values = arg == "enum" and { "draft", "published" } or nil } })
        local value = arg == "bytes" and RAW or arg == "enum" and "draft" or lent.jsonArray()
        local encoded = rc.encode(fields, format, 1, { data = value })
        local back = rc.decode(fields, encoded).data
        return simdjson.encode({ value = arg == "bytes" and v.hex(back) or arg == "json" and v.json(back) or back,
                                wire = v.hex(encoded) })
    end
    if step == "metadata" then
        local c = m.load()
        local out = { version = c.version, pending = c.migration ~= nil, fields = {}, states = {} }
        for _, f in c.tables.doc.fields do
            out.fields[f.name] = { kind = f.kind, values = f.values,
                default = f.default ~= nil and (f.kind == "json" and v.json(f.default)
                    or f.kind == "bytes" and v.hex(f.default) or f.default) or nil }
        end
        for _, ix in c.tables.doc.indexes do out.states[ix.name] = ix.state or "ready" end
        return simdjson.encode(out)
    end
    if step == "aliases" then
        return simdjson.encode({ bytes = kc.encode("bytes", RAW) == kc.encode("string", RAW),
                                enum = kc.encode("enum", "draft") == kc.encode("string", "draft") })
    end
    if step == "plain" then
        return simdjson.encode(client.tx(function(c)
            local a = c.Doc:create { name = "plainA" }
            local b = c.Doc:create { name = "plainB" }
            a.payload.nested.n = 10
            c.Doc:update(a.id, { payload = a.payload })
            local enumOk, enumErr = pcall(c.Doc.create, c.Doc, { name = "bad", status = "unknown" })
            local fixedOk, fixedErr = pcall(c.Doc.update, c.Doc, a.id, { fixed = { changed = true } })
            return { a = v.json(c.Doc:get(a.id).payload), b = v.json(c.Doc:get(b.id).payload),
                seed = v.hex(b.seed), dynamicMissing = b.dynamic == nil,
                enumOk = enumOk, enumErr = enumErr, fixedOk = fixedOk, fixedErr = fixedErr,
                logs = c.Log:query():count() }
        end, mode == "pessimistic"))
    end
    return simdjson.encode(client.open(graph).tx(function(c) return steps[step](c, arg) end,
                                                 mode == "pessimistic"))
end
'''


def app(client, space, mode="optimistic", ids="int", format="binary", seed=False):
    setup(client)
    client.execute_command("USE", space)
    client.execute_command("SETF", "FIELDSAPP", APP)

    def run(step, arg="", stage="v1", page=1000):
        return json.loads(client.execute_command("CALLF", "FIELDSAPP", step, mode, ids, format,
                                               stage, arg, page))

    assert run("migrate")["done"]
    if seed:
        assert run("seed") == 2
    return run


def finish(run, stage, page=2):
    reports = []
    for _ in range(100):
        report = run("migrate", stage=stage, page=page)
        reports.append(report)
        if report["done"]:
            return reports
    pytest.fail("field migration did not finish")


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("ids", ["int", "uuid"])
@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_new_field_kinds_round_trip_and_support_indexes_queries_and_cursors(client, mode, ids, format):
    run = app(client, f"fields_{mode}_{ids}_{format}", mode, ids, format)
    out = run("rows")
    assert out["input"] == 7
    assert out["matched"] == out["predicates"] == 2
    assert out["sameIds"] and out["created"] == [False, False]
    assert out["bytesOrder"] == "c,d,a,b"
    assert out["enumOrder"] == "d,b,a,c"
    assert [out[k] for k in ("missing", "null", "object", "array", "notObject")] == [1, 1, 1, 1, 3]
    assert out["blobLookup"] == "a"
    a, b, c, d = out["rows"]
    assert a["blob"] == (RAW + b"a").hex()
    assert d["blob"] == "" and c["blob"] == "missing"
    assert json.loads(a["payload"]) == json.loads(c["payload"]) == {"nested": {"n": 8}, "empty": [], "object": {}}
    assert json.loads(b["payload"])["nested"]["n"] == 1
    assert d["payload"] == "null"
    assert all(row["seed"] == "00ff" for row in out["rows"])
    assert all(json.loads(row["fixed"]) == {"deep": {"n": 0}, "list": [], "object": {}} for row in out["rows"])
    if format == "json":
        wire = json.loads(bytes.fromhex(out["raw"]))
        assert wire["blob"] == (RAW + b"a").hex() and wire["seed"] == "00ff"
        assert wire["payload"]["empty"] == [] and wire["payload"]["object"] == {}
    assert run("aliases") == {"enum": True, "bytes": True}
    assert not run("migrate")["changed"]


@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_json_scalars_arrays_null_unicode_and_exact_large_integers(client, format):
    run = app(client, "json_shapes_" + format, format=format)
    values = run("shapes")
    assert [json.loads(value) for value in values[:6]] == [None, False, 7, "literal", [], {}]
    assert json.loads(values[6]) == {"z": [], "a": [{}, [], None, {"quote\"key": "line\né"}], "n": 1099511627776}
    assert values[7] == "9223372036854775807"


@pytest.mark.parametrize("kind", ["enum", "json", "bytes"])
@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_low_level_row_codec_supports_new_kinds(client, kind, format):
    run = app(client, f"field_codec_{kind}_{format}", format=format)
    result = run("codec", arg=kind)
    assert result["value"] == (RAW.hex() if kind == "bytes" else "draft" if kind == "enum" else "[]")
    if format == "binary":
        assert bytes.fromhex(result["wire"])[7] == {"enum": 4, "json": 5, "bytes": 6}[kind]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_json_defaults_and_old_hook_snapshots_are_independent(client, mode, format):
    run = app(client, f"json_hooks_{mode}_{format}", mode, format=format, seed=True)
    initial = run("inspect")["rows"]
    assert json.loads(initial[2]["dynamic"])["nested"]["n"] == 1
    edited = run("hooks", "1")
    assert json.loads(edited["before"])["nested"]["n"] == 8
    assert json.loads(edited["row"]["payload"])["nested"]["n"] == 9
    assert edited["row"] == edited["stored"] and edited["log"] == edited["before"]
    snapshot = run("hooks", "3")
    assert json.loads(snapshot["row"]["fixed"])["deep"]["n"] == 0
    assert json.loads(snapshot["row"]["payload"])["nested"]["n"] == 9
    assert snapshot["row"] == snapshot["stored"]
    assert run("equal_fixed")["fixed"] == initial[0]["fixed"]


@pytest.mark.parametrize("mode", ["optimistic", "pessimistic"])
@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_structural_json_filters_work_with_query_writes(client, mode, format):
    run = app(client, f"json_query_writes_{mode}_{format}", mode, format=format, seed=True)
    assert run("query_writes") == {
        "updated": 2, "matches": 2, "deleted": 3, "remaining": 2, "name": "e", "reusedMode": "image",
    }


@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_schema_field_ids_carry_enum_choices_and_codecs_skip_removed_new_kinds(client, format):
    run = app(client, "field_schema_codec_" + format, format=format, seed=True)
    out = run("schema_codec")
    assert out["status"] == "review" and out["skipped"] == "a"
    assert out["blob"] == (RAW + b"a").hex()
    assert json.loads(out["payload"])["nested"]["n"] == 8


ERRORS = {
    "enum": "wants one of", "enum_type": "wants one of", "enum_utf8": "invalid UTF-8 string", "bytes": "wants bytes",
    "bytes_length": "wants at most 512 bytes", "bytes_unique": "blob=0x000102090a0d1f205cff61",
    "enum_unique": "index by_mode is unique", "cyclic": "cyclic table", "sparse": "without gaps",
    "mixed": "without object keys", "utf8": "must be UTF-8", "nan": "must be finite",
    "inf": "must be finite", "function_value": "JSON needs a value", "validation": "invalid payload",
    "json_order": "is json, which has no order", "json_range": "is json, which has no order",
    "json_filter": "must be UTF-8",
    "fixed": "field fixed is immutable", "old_snapshot": "field fixed is immutable",
    "hook_invalid": "JSON needs a value", "clear_required": "field payload is not optional",
    "deep": "exceeds 128 levels",
}


@pytest.mark.parametrize("which, error", ERRORS.items())
def test_field_errors_roll_back_rows_indexes_and_hook_writes(client, which, error):
    run = app(client, "field_error_" + which, seed=True)
    before = run("inspect")
    with pytest.raises(redis.ResponseError, match=error):
        run("bad", which)
    assert run("inspect") == before


SCHEMA_ERRORS = {
    "enum_missing": "enum needs a list", "enum_empty": "at least one value",
    "enum_duplicate": "is repeated", "enum_utf8": "non-empty UTF-8 strings",
    "enum_gap": "non-empty UTF-8 strings", "nonenum": "takes no values",
    "enum_default": "default wants one of", "json_unique": "is json, which takes no index",
    "bytes_min": "takes no min", "bytes_match": "takes no match", "json_length": "takes no maxLen",
}


@pytest.mark.parametrize("which, error", SCHEMA_ERRORS.items())
def test_schema_checks_new_kind_options(client, which, error):
    run = app(client, "field_schema_" + which)
    with pytest.raises(redis.ResponseError, match=error):
        run("schema", which)


def test_json_fields_refuse_explicit_indexes(client):
    run = app(client, "field_json_index")
    with pytest.raises(redis.ResponseError, match="is json, which takes no index"):
        run("schema_index")


@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_new_kind_defaults_survive_paged_migration_and_old_row_reads(client, format):
    run = app(client, "field_add_" + format, format=format, seed=True)
    reports = finish(run, "add", page=1)
    assert len(reports) == 4 and all(r["version"] == 2 for r in reports)
    out = run("migrated", stage="add")
    for row in out["rows"] + [out["new"]]:
        assert row["tier"] == "free" and row["legacy"] == "ff00"
        assert json.loads(row["settings"]) == {"targets": [], "object": {}}
    assert not run("migrate", stage="add")["changed"]


@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_enum_expansion_and_conversion_to_string_preserve_rows_and_indexes(client, format):
    run = app(client, "enum_expand_" + format, format=format, seed=True)
    assert run("migrate", stage="expand")["done"]
    assert run("archived", stage="expand") == "archived"
    report = run("migrate", stage="enum_string")
    assert report["done"] and not report["steps"]
    assert run("metadata", stage="enum_string")["fields"]["status"]["kind"] == "string"


@pytest.mark.parametrize("stage, error", [
    ("narrow", 'removes enum value "review"'),
    ("byte_change", "changes kind from bytes to string"),
    ("json_change", "changes kind from json to string"),
])
def test_migrations_refuse_changes_that_could_make_typed_rows_unreadable(client, stage, error):
    run = app(client, "field_migration_error_" + stage, seed=True)
    before = run("metadata")
    with pytest.raises(redis.ResponseError, match=error):
        run("migrate", stage=stage)
    assert run("metadata") == before


def test_json_default_shape_changes_are_detected_and_copied(client):
    run = app(client, "field_default_shape", seed=True)
    report = run("migrate", stage="array_default")
    assert report["changed"] and report["version"] == 2
    assert run("metadata", stage="array_default")["fields"]["payload"]["default"] == "[]"
    assert run("migrated", stage="array_default")["new"]["payload"] == "[]"
    assert not run("migrate", stage="array_default")["changed"]


@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_catalog_field_rules_and_copied_defaults_work_without_the_graph(client, format):
    run = app(client, "field_plain_" + format, format=format)
    out = run("plain")
    assert json.loads(out["a"])["nested"]["n"] == 10
    assert json.loads(out["b"])["nested"]["n"] == 0
    assert out["seed"] == "00ff" and out["dynamicMissing"] and out["logs"] == 0
    assert not out["enumOk"] and "wants one of" in out["enumErr"]
    assert not out["fixedOk"] and "field fixed is immutable" in out["fixedErr"]


@pytest.mark.parametrize("stage, encoded", [
    ("false_default", "false"), ("null_default", "null"),
    ("big_default", "9223372036854775807"), ("object_default", "{}"),
])
@pytest.mark.parametrize("format", ["binary", "text", "json"])
def test_json_scalar_defaults_are_preserved_by_the_catalog(client, stage, encoded, format):
    run = app(client, f"json_default_{stage}_{format}", format=format)
    assert run("migrate", stage=stage)["changed"]
    assert run("metadata", stage=stage)["fields"]["payload"]["default"] == encoded
    assert run("migrated", stage=stage)["new"]["payload"] == encoded
    assert not run("migrate", stage=stage)["changed"]


@pytest.mark.parametrize("text", ['{"x":[],"x":{}}', '{"x":[],"x":1}', '{"x":1,"\\u0078":2}'])
def test_json_parser_refuses_duplicate_object_keys(client, text):
    run = app(client, "json_duplicate_" + str(len(text)))
    with pytest.raises(redis.ResponseError, match="unique keys"):
        run("parse", text)


def test_public_json_helpers_preserve_empty_arrays_and_objects(client):
    run = app(client, "json_helpers")
    assert run("parse", '{"a":[],"b":{},"c":[[],{},null]}') == '{"a":[],"b":{},"c":[[],{},null]}'


def test_value_helpers_selftest(client):
    setup(client)
    client.execute_command("USE", "lent")
    assert client.execute_command("CALLF", "VALUES") == "ok"
