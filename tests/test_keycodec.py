from .conftest import install


# Replaces the keys under `ord.` with one key per argument and answers the
# argument positions in the order barch.store.range walks the keys back.
ORDER = """
function call(kind, ...)
    local kc = require("ent.KEYCODEC")
    for _, k in barch.store.range("ord.", kc.after("ord."), 10000) do
        barch.store.remove(k)
    end
    for i, raw in {...} do
        local v = raw
        if kind == "int" or kind == "float" then v = tonumber(raw) end
        if kind == "bool" then v = raw == "1" end
        if raw == "" and kind ~= "string" then v = nil end
        barch.store.set("ord." .. kc.encode(kind, v), tostring(i))
    end
    local out = {}
    for _, k in barch.store.range("ord.", kc.after("ord."), 10000) do
        out[#out + 1] = tonumber(barch.store.get(k))
    end
    return out
end
"""

# Packs (string, int) pairs; with no pairs, answers the positions of the
# keys whose string is exactly `prefix`, found by a range over its packing.
TUPLES = """
function call(prefix, ...)
    local kc = require("ent.KEYCODEC")
    local args = {...}
    local kinds = { "string", "int" }
    for i = 1, #args, 2 do
        local key = "tup." .. kc.pack(kinds, { args[i], tonumber(args[i + 1]) })
        barch.store.set(key, tostring((i + 1) // 2))
    end
    local lo, hi = "tup.", kc.after("tup.")
    if #args == 0 then
        lo = "tup." .. kc.encode("string", prefix)
        hi = kc.after(lo)
    end
    local out = {}
    for _, k in barch.store.range(lo, hi, 10000) do
        local back = kc.unpack(k, 2, 5)
        if back[1] == nil then error("lost the string of " .. k) end
        out[#out + 1] = tonumber(barch.store.get(k))
    end
    return out
end
"""


def setup(client):
    install(client, "ent", "KEYCODEC", "ent/keycodec.luau")
    client.execute_command("USE", "default")
    client.execute_command("SETF", "ORDER", ORDER)
    client.execute_command("SETF", "TUPLES", TUPLES)


def walked(client, kind, values, arg):
    order = client.execute_command("CALLF", "ORDER", kind, *[arg(v) for v in values])
    return [values[int(i) - 1] for i in order]


def test_keycodec_selftest(client):
    install(client, "ent", "KEYCODEC", "ent/keycodec.luau")
    client.execute_command("USE", "ent")
    assert client.execute_command("CALLF", "KEYCODEC") == "ok"


def test_ints_walk_in_numeric_order(client):
    setup(client)
    # barch would order these keys wrongly as raw text, and as numbers it
    # would put every double after every integer
    values = [0, 1, -1, 9, 10, 100, -100, 2**32, -(2**32), 2**32 - 1,
              -(2**32) - 1, 2**53, -(2**53), 123456789012345]
    assert walked(client, "int", values, str) == sorted(values)


def test_floats_walk_in_numeric_order(client):
    setup(client)
    values = [0.0, 1.5, -1.5, 2.5, 10.0, -10.0, 1e-300, -1e-300, 5e-324,
              -5e-324, 1e308, -1e308, float("inf"), float("-inf"), 0.1, 3.0]

    def arg(v):
        return {float("inf"): "1e999", float("-inf"): "-1e999"}.get(v, repr(v))

    assert walked(client, "float", values, arg) == sorted(values)


def test_strings_walk_in_byte_order(client):
    setup(client)
    values = [b"", b"a", b"a ", b"a b", b"ab", b"a\x00", b"a\x00b", b"a\x01",
              b"a\x01\x01", b"a\x02", b"a\x02\x02", b"a\x03", b"a\x1e", b"a\x1f", b"a\x1f\x01", b"a!",
              b"a\x7f", b"a\x80", b"a\xff", b"\xff", b"\xc3\xa9t\xc3\xa9", b" ",
              b"\x00", b"\x01", b"\x02", b"1", b"-1", b"inf"]
    assert walked(client, "string", values, lambda v: v) == sorted(values)


def test_nulls_walk_first(client):
    setup(client)
    values = [5, None, -5]
    assert walked(client, "int", values, lambda v: "" if v is None else str(v)) == [None, -5, 5]
    assert walked(client, "bool", [True, False], lambda v: "1" if v else "0") == [False, True]


def test_packed_tuples_walk_in_tuple_order(client):
    setup(client)
    # each string is a prefix of the next, which is where a separator-based
    # encoding goes wrong: ("a", 5) has to sort before ("a\0", -5)
    pairs = [(b"a", 5), (b"a", -5), (b"a\x00", -5), (b"a\x00", 0), (b"ab", 1),
             (b"", 7), (b"a b", 2), (b"a\x01", 3), (b"b", -1)]
    flat = [x for s, n in pairs for x in (s, str(n))]
    order = client.execute_command("CALLF", "TUPLES", "", *flat)
    assert [pairs[int(i) - 1] for i in order] == sorted(pairs)

    # a range over one packed string holds exactly that string's keys
    exact = client.execute_command("CALLF", "TUPLES", b"a")
    assert sorted(pairs[int(i) - 1] for i in exact) == [(b"a", -5), (b"a", 5)]
    exact = client.execute_command("CALLF", "TUPLES", b"a\x00")
    assert sorted(pairs[int(i) - 1] for i in exact) == [(b"a\x00", -5), (b"a\x00", 0)]


def test_readme_example(client):
    install(client, "ent", "KEYCODEC", "ent/keycodec.luau")
    client.execute_command("USE", "default")
    client.execute_command("SETF", "EXAMPLE", """
function call()
    local kc = require("ent.KEYCODEC")
    for _, row in { { 41, "zed" }, { 42, "ann" }, { 42, "bob" }, { 43, "al" } } do
        barch.store.set("ent.i.user.by_age" .. kc.pack({ "int", "string" }, row), "")
    end
    local key = "ent.i.user.by_age" .. kc.pack({ "int", "string" }, { 42, "ann" })
    local values, next = kc.unpack(key, 2, #"ent.i.user.by_age" + 1)  -- { 42, "ann" }
    local lo = "ent.i.user.by_age" .. kc.encode("int", 42)
    local keys = barch.store.range(lo, kc.after(lo), 100)            -- every age 42
    local names = {}
    for _, k in keys do
        names[#names + 1] = kc.unpack(k, 2, #"ent.i.user.by_age" + 1)[2]
    end
    return { values[1], values[2], next == #key + 1 and 1 or 0, unpack(names) }
end
""")
    assert client.execute_command("CALLF", "EXAMPLE") == [42, "ann", 1, "ann", "bob"]
