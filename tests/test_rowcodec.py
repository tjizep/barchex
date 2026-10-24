import json

import pytest

from .conftest import install

redis = pytest.importorskip("redis")

# Writes one user row in `format` under `key`, or answers the decoded
# fields, the version and the format read back from the store. The later
# schema drops "score", adds "email" and makes "age" a float.
ROWS = """
function call(how, format, key, name, age, score, admin)
    local rc = require("ent.ROWCODEC")
    local users = rc.fields({
        { name = "name", kind = "string", id = 1 },
        { name = "age", kind = "int", id = 2, optional = true },
        { name = "score", kind = "float", id = 3, optional = true },
        { name = "admin", kind = "bool", id = 4, optional = true },
    })
    local later = rc.fields({
        { name = "name", kind = "string", id = 1 },
        { name = "years", kind = "float", id = 2, optional = true },
        { name = "admin", kind = "bool", id = 4, optional = true },
        { name = "email", kind = "string", id = 5, optional = true },
    })
    if how == "write" then
        local row = { name = name, age = tonumber(age), score = tonumber(score) }
        if admin ~= "" then row.admin = admin == "1" end
        barch.store.set(key, rc.encode(users, format, 2, row))
        return "written"
    end
    local schema = how == "later" and later or users
    local row, version, got = rc.decode(schema, barch.store.get(key))
    local out = { tostring(version), got }
    for _, f in schema.list do
        local v = row[f.name]
        out[#out + 1] = f.name .. "=" .. (v == nil and "nil" or tostring(v))
    end
    return out
end
"""


def setup(client):
    install(client, "ent", "ROWCODEC", "ent/rowcodec.luau")
    client.execute_command("USE", "default")
    client.execute_command("SETF", "ROWS", ROWS)


def test_rowcodec_selftest(client):
    install(client, "ent", "ROWCODEC", "ent/rowcodec.luau")
    client.execute_command("USE", "ent")
    assert client.execute_command("CALLF", "ROWCODEC") == "ok"


@pytest.mark.parametrize("fmt", ["json", "text", "binary"])
def test_rows_round_trip_through_the_store(client, fmt):
    setup(client)
    client.execute_command("CALLF", "ROWS", "write", fmt, "row.1",
                           "ann\tlee\n\\ é", "-9007199254740992", "0.1", "1")
    assert client.execute_command("CALLF", "ROWS", "read", fmt, "row.1") == [
        "2", fmt, "name=ann\tlee\n\\ é", "age=-9007199254740992", "score=0.1", "admin=true"]
    client.execute_command("CALLF", "ROWS", "write", fmt, "row.2", "", "", "", "")
    assert client.execute_command("CALLF", "ROWS", "read", fmt, "row.2") == [
        "2", fmt, "name=", "age=nil", "score=nil", "admin=nil"]


@pytest.mark.parametrize("fmt", ["text", "binary"])
def test_text_and_binary_rows_hold_any_bytes(server, fmt):
    raw = redis.Redis(port=server.port, protocol=2)
    install(raw, "ent", "ROWCODEC", "ent/rowcodec.luau")
    raw.execute_command("USE", "default")
    raw.execute_command("SETF", "ROWS", ROWS)
    name = b"\x00\x01\xff\t\\"
    raw.execute_command("CALLF", "ROWS", "write", fmt, "row.b", name, "", "", "")
    back = raw.execute_command("CALLF", "ROWS", "read", fmt, "row.b")
    assert back[2] == b"name=" + name
    raw.close()


def test_json_rows_are_plain_json(client):
    setup(client)
    client.execute_command("CALLF", "ROWS", "write", "json", "row.j", "ann", "41", "", "0")
    assert json.loads(client.execute_command("GET", "row.j")) == {
        "_v": 2, "name": "ann", "age": 41, "admin": False}


@pytest.mark.parametrize("fmt", ["json", "text", "binary"])
def test_older_rows_read_with_the_current_fields(client, fmt):
    setup(client)
    client.execute_command("CALLF", "ROWS", "write", fmt, "row.o", "ann", "41", "1.5", "1")
    years = "years=nil" if fmt == "json" else "years=41"
    # json names fields, so the renamed field reads as missing; text and
    # binary name them by id, so it keeps its value
    assert client.execute_command("CALLF", "ROWS", "later", fmt, "row.o") == [
        "2", fmt, "name=ann", years, "admin=true", "email=nil"]


@pytest.mark.parametrize("fmt, name, age, error", [
    ("binary", "", "1.5", "ROWCODEC field age wants int, got 1.5"),
    ("text", "", "18014398509481984", "ROWCODEC field age wants int"),
    ("json", b"\xff", "", "ROWCODEC field name is not UTF-8"),
])
def test_bad_rows_are_refused(client, fmt, name, age, error):
    setup(client)
    with pytest.raises(redis.ResponseError, match=error):
        client.execute_command("CALLF", "ROWS", "write", fmt, "row.x", name, age, "", "")
    assert client.execute_command("EXISTS", "row.x") == 0
