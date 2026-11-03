"""Checks lent.VEC, the reference vector kernels, and barch.vec when barch
provides it, against the same answers computed here. Each kernel runs on a
column block, where elements are packed, and on a block of fixed-width rows,
where an odd row width leaves most elements unaligned."""

import math
import random
import struct

import pytest

from .conftest import install

redis = pytest.importorskip("redis")

KERNELS = r"""
local function vec_of(impl)
    if impl == "native" then
        return barch.vec
    end
    return require("lent.VEC")
end

local function u32s(text)
    if text == "-" then
        return nil
    end
    local list = {}
    for v in string.gmatch(text, "[^,]+") do
        list[#list + 1] = tonumber(v)
    end
    local b = buffer.create(math.max(#list, 1) * 4)
    for i, v in list do
        buffer.writeu32(b, (i - 1) * 4, v)
    end
    return b
end

local function opt(text)
    if text == "-" then
        return nil
    end
    return tonumber(text)
end

local function indexes(b, n)
    local out = {}
    for k = 0, n - 1 do
        out[k + 1] = buffer.readu32(b, k * 4)
    end
    return out
end

local function g17(x)
    return string.format("%.17g", x)
end

function call(step, impl, ...)
    local vec = vec_of(impl)
    if step == "native" then
        return if barch.vec then 1 else 0
    end
    local a = { ... }
    if step == "errors" then
        local b = buffer.create(16)
        local out = buffer.create(64)
        local cases = {
            function() vec.filter("u8", b, 0, 8, "=", 1, nil, nil, 2, out) end,
            function() vec.filter("f64", b, 0, 8, "!=", 1, nil, nil, 2, out) end,
            function() vec.filter("f64", b, 0, 8, "=", 1, nil, nil, 3, out) end,
            function() vec.filter("f64", b, 1, 8, "=", 1, nil, nil, 2, out) end,
            function() vec.filter("str", b, 0, 8, "=", 1, nil, nil, 2, out) end,
            function() vec.filter("i32", b, 0, 4, "=", "x", nil, nil, 2, out) end,
            function() vec.filter("f64", b, 0, 0, "=", 1, nil, nil, 2, out) end,
            function() vec.filterIn("f64", b, 0, 8, b, nil, 2, out) end,
            function() vec.fold("f64", b, 0, 8, nil, nil, 2, buffer.create(4), out) end,
            function() vec.mask(b, 10, 7, out) end,
            function() vec.offsets(b, 0, 5, 0, out) end,
            function() vec.grouper("u8") end,
            function() vec.grouper("i8"):key(0) end,
            function() vec.filter("f64", b, 0, 8, "=", 1, nil, u32s("0,9"), 2, out) end,
        }
        local msgs = {}
        for i, f in cases do
            local ok, err = pcall(f)
            msgs[i] = if ok then "no error" else tostring(err)
        end
        return msgs
    end
    if step == "mask" then
        local m = buffer.fromstring(a[1])
        local out = buffer.create(#a[1] * 4)
        return indexes(out, vec.mask(m, tonumber(a[2]), tonumber(a[3]), out))
    end
    if step == "offsets" then
        local b = buffer.fromstring(a[1])
        local n = tonumber(a[3])
        local out = buffer.create(math.max(n, 1) * 8)
        local last = vec.offsets(b, tonumber(a[2]), n, tonumber(a[4]), out)
        local list = { last }
        for i = 0, n * 2 - 1 do
            list[#list + 1] = buffer.readu32(out, i * 4)
        end
        return list
    end
    -- the column kernels: kind, data, off, stride, then the kernel's own
    local kind, b, off, stride = a[1], buffer.fromstring(a[2]), tonumber(a[3]), tonumber(a[4])
    if step == "filter" then
        local value = if kind == "str" then a[6] else tonumber(a[6])
        local sel, n = u32s(a[8]), tonumber(a[9])
        local out = if a[10] == "same" and sel then sel else buffer.create(math.max(n, 1) * 4)
        local kept = vec.filter(kind, b, off, stride, a[5], value, opt(a[7]), sel, n, out)
        return indexes(out, kept)
    end
    if step == "filterIn" then
        local sel, n = u32s(a[6]), tonumber(a[7])
        local out = buffer.create(math.max(n, 1) * 4)
        local kept = vec.filterIn(kind, b, off, stride, buffer.fromstring(a[5]), sel, n, out)
        return indexes(out, kept)
    end
    if step == "fold" then
        local sel, n, gids, groups = u32s(a[6]), tonumber(a[7]), u32s(a[8]), tonumber(a[9])
        local out = buffer.create(groups * 32)
        for g = 0, groups - 1 do
            buffer.writef64(out, g * 32 + 16, math.huge)
            buffer.writef64(out, g * 32 + 24, -math.huge)
        end
        -- two calls, so the records carry from one block to the next
        local half = n // 2
        local function part(from, count)
            local s = sel and buffer.create(math.max(count, 1) * 4)
            local gs = gids and buffer.create(math.max(count, 1) * 4)
            for k = 0, count - 1 do
                if s then buffer.writeu32(s, k * 4, buffer.readu32(sel, (from + k) * 4)) end
                if gs then buffer.writeu32(gs, k * 4, buffer.readu32(gids, (from + k) * 4)) end
            end
            if sel == nil then
                -- dense candidates start at 0, so the second half moves off
                vec.fold(kind, b, off + from * stride, stride, opt(a[5]), nil, count, gs, out)
            else
                vec.fold(kind, b, off, stride, opt(a[5]), s, count, gs, out)
            end
        end
        part(0, half)
        part(half, n - half)
        local list = {}
        for i = 0, groups * 4 - 1 do
            list[#list + 1] = g17(buffer.readf64(out, i * 8))
        end
        return list
    end
    if step == "ids" then
        local sel, n = u32s(a[6]), tonumber(a[7])
        local g = vec.grouper(kind)
        local gids = buffer.create(math.max(n, 1) * 4)
        local list = {}
        -- two calls on one grouper, so its groups carry over
        local half = n // 2
        local first = sel and u32s(table.concat(indexes(sel, half), ",") .. ",0")
        local second = sel and u32s(table.concat(indexes(sel, n), ",", half + 1) .. ",0")
        if sel then
            g:ids(b, off, stride, opt(a[5]), first, half, gids)
        else
            g:ids(b, off, stride, opt(a[5]), nil, half, gids)
        end
        for _, id in indexes(gids, half) do list[#list + 1] = tostring(id) end
        local size
        if sel then
            size = g:ids(b, off, stride, opt(a[5]), second, n - half, gids)
        else
            size = g:ids(b, off + half * stride, stride, opt(a[5]), nil, n - half, gids)
        end
        for _, id in indexes(gids, n - half) do list[#list + 1] = tostring(id) end
        list[#list + 1] = "size " .. size
        for id = 0, g:size() - 1 do
            local key = g:key(id)
            list[#list + 1] = if key == nil then "nil"
                elseif type(key) == "number" then g17(key)
                else "s:" .. (string.gsub(key, ".", function(c) return string.format("%02x", string.byte(c)) end))
        end
        return list
    end
    error("unknown step " .. tostring(step))
end
"""

KINDS = ["i8", "i32", "i64", "f64", "str"]
OPS = ["=", "~=", "<", "<=", ">", ">="]
FORMAT = {"i8": "<b", "i32": "<i", "i64": "<q", "f64": "<d"}
WIDTH = {"i8": 1, "i32": 4, "i64": 8, "f64": 8, "str": 8}
NONE = {"i8": -128, "i32": -(2**31), "i64": -(2**53)}
# where each kind sits in a row, and the row's width; odd, so rows misalign
ROW_AT = {"i8": 0, "i32": 1, "i64": 5, "f64": 13, "str": 21}
ROW = 29
N = 300
WORDS = ["", "a", "ab", "abc", "b", "ba", "z", "\x00x", "\xffend", "east", "west"]


def values(kind, rng):
    """N values of a kind, with None for nil, drawn from a few repeats so
    = and groups find matches."""
    out = []
    for _ in range(N):
        if rng.random() < 0.1:
            out.append(None)
        elif kind == "str":
            out.append(rng.choice(WORDS))
        elif kind == "i8":
            out.append(rng.randint(-127, 127) if rng.random() < 0.3 else rng.randint(-4, 4))
        elif kind == "i32":
            out.append(rng.choice([rng.randint(-(2**31) + 1, 2**31 - 1), rng.randint(-9, 9)]))
        elif kind == "i64":
            out.append(rng.choice([rng.randint(-(2**53) + 1, 2**53), rng.randint(-9, 9) * 2**40]))
        else:
            out.append(rng.choice([rng.uniform(-1e6, 1e6), float(rng.randint(-5, 5)), -0.0]))
    return out


def encode(kind, v):
    if v is None:
        return struct.pack("<d", math.nan) if kind == "f64" else struct.pack(FORMAT[kind], NONE[kind])
    return struct.pack(FORMAT[kind], v)


def layout(kind, vals, shape):
    """The block that holds vals as `shape`, "column" or "row", and the
    off and stride its elements take."""
    if shape == "column":
        head, off, stride = b"hdr", 3, WIDTH[kind]
        cells = [None] * N
    else:
        head, off, stride = b"", ROW_AT[kind], ROW
        cells = [bytearray(ROW) for _ in range(N)]
    body = bytearray()
    data_at = len(head) + (N * WIDTH[kind] if shape == "column" else N * ROW)
    heap = bytearray()
    for i, v in enumerate(vals):
        if kind == "str":
            raw = None if v is None else v.encode("latin-1")
            cell = struct.pack("<II", data_at + len(heap), 0 if raw is None else len(raw) + 1)
            if raw:
                heap += raw
        else:
            cell = encode(kind, v)
        if shape == "column":
            body += cell
        else:
            at = ROW_AT[kind]
            cells[i][at:at + len(cell)] = cell
    if shape == "row":
        for c in cells:
            body += c
    return bytes(head + body + heap), off, stride


def holds(op, x, w):
    return {"=": x == w, "~=": x != w, "<": x < w, "<=": x <= w, ">": x > w, ">=": x >= w}[op]


def passes(op, v, w):
    if v is None:
        return op == "~="
    if isinstance(v, str):
        v, w = v.encode("latin-1"), w.encode("latin-1")
    return holds(op, v, w)


def csv(idx):
    return ",".join(map(str, idx)) if idx else "0"


def g17(x):
    return "%.17g" % x


@pytest.fixture(scope="module", params=["ref", "native"])
def run(server, request):
    c = server.client
    c.execute_command("USE", "lent")
    install(c, "lent", "VEC", "lent/vec.luau")
    c.execute_command("USE", "default")
    c.execute_command("SETF", "VECT", KERNELS)
    if request.param == "native" and c.execute_command("CALLF", "VECT", "native", "ref") != 1:
        pytest.skip("barch has no barch.vec")
    impl = request.param
    return lambda step, *a: c.execute_command("CALLF", "VECT", step, impl, *a)


def test_selftest(server):
    c = server.client
    install(c, "lent", "VEC", "lent/vec.luau")
    c.execute_command("USE", "lent")
    assert c.execute_command("CALLF", "VEC") == "ok"
    c.execute_command("USE", "default")


@pytest.mark.parametrize("shape", ["column", "row"])
@pytest.mark.parametrize("kind", KINDS)
def test_filter(run, kind, shape):
    rng = random.Random(f"{kind}{shape}")
    vals = values(kind, rng)
    data, off, stride = layout(kind, vals, shape)
    none = "-" if kind in ("f64", "str") else str(NONE[kind])
    present = [v for v in vals if v is not None]
    sel = sorted(rng.sample(range(N), N // 3))
    for op in OPS:
        for w in [rng.choice(present), rng.choice(present)]:
            arg = w if kind == "str" else g17(w) if kind == "f64" else str(w)
            want = [i for i in range(N) if passes(op, vals[i], w)]
            assert run("filter", kind, data, off, stride, op, arg, none, "-", N, "") == want, (op, w)
            want = [i for i in sel if passes(op, vals[i], w)]
            assert run("filter", kind, data, off, stride, op, arg, none, csv(sel), len(sel),
                       "same") == want, (op, w)


@pytest.mark.parametrize("shape", ["column", "row"])
def test_filter_without_none_reads_every_integer(run, shape):
    vals = [-128, 0, 5, -128, 7]
    data, off, stride = layout("i8", vals + [0] * (N - 5), shape)
    assert run("filter", "i8", data, off, stride, "<", "0", "-", "-", 5, "") == [0, 3]
    assert run("filter", "i8", data, off, stride, "<", "0", "-128", "-", 5, "") == []
    assert run("filter", "i8", data, off, stride, "~=", "0", "-128", "-", 5, "") == [0, 2, 3, 4]


@pytest.mark.parametrize("shape", ["column", "row"])
@pytest.mark.parametrize("kind", ["i8", "i32"])
def test_filter_in(run, kind, shape):
    rng = random.Random(f"in{kind}{shape}")
    vals = [rng.randint(-3, 40) for _ in range(N)]
    data, off, stride = layout(kind, vals, shape)
    allowed = bytes(rng.random() < 0.4 for _ in range(30))
    want = [i for i, c in enumerate(vals) if 0 <= c < len(allowed) and allowed[c]]
    assert run("filterIn", kind, data, off, stride, allowed, "-", N) == want
    sel = sorted(rng.sample(range(N), 50))
    want = [i for i in sel if 0 <= vals[i] < len(allowed) and allowed[vals[i]]]
    assert run("filterIn", kind, data, off, stride, allowed, csv(sel), len(sel)) == want


def records(kind, vals, gids, groups):
    out = []
    for g in range(groups):
        mine = [v for v, h in zip(vals, gids) if h == g and v is not None]
        if kind == "str":
            out.append([len(mine), 0, math.inf, -math.inf])
        else:
            out.append([len(mine), sum(mine), min(mine, default=math.inf), max(mine, default=-math.inf)])
    return out


def same_records(got, want, kind):
    got = [float(x) for x in got]
    for g, rec in enumerate(want):
        count, total, least, most = got[g * 4:g * 4 + 4]
        assert count == rec[0]
        if kind == "f64":
            # a native sum may add in another order
            scale = sum(abs(x) for x in [rec[1]] + [least, most] if math.isfinite(x)) or 1
            assert abs(total - rec[1]) <= 1e-9 * scale * max(rec[0], 1)
        else:
            assert total == rec[1]
        assert least == rec[2] and most == rec[3]


@pytest.mark.parametrize("shape", ["column", "row"])
@pytest.mark.parametrize("kind", KINDS)
def test_fold(run, kind, shape):
    rng = random.Random(f"fold{kind}{shape}")
    vals = values(kind, rng)
    if kind == "i64":
        # sums stay exact within +-2^53
        vals = [None if v is None else v // 2**12 for v in vals]
    data, off, stride = layout(kind, vals, shape)
    none = "-" if kind in ("f64", "str") else str(NONE[kind])
    got = run("fold", kind, data, off, stride, none, "-", N, "-", 1)
    same_records(got, records(kind, vals, [0] * N, 1), kind)
    sel = sorted(rng.sample(range(N), N // 2))
    gids = [rng.randrange(5) for _ in sel]
    got = run("fold", kind, data, off, stride, none, csv(sel), len(sel), csv(gids), 5)
    same_records(got, records(kind, [vals[i] for i in sel], gids, 5), kind)


@pytest.mark.parametrize("shape", ["column", "row"])
@pytest.mark.parametrize("kind", KINDS)
def test_grouper_numbers_values_in_first_seen_order(run, kind, shape):
    rng = random.Random(f"ids{kind}{shape}")
    vals = values(kind, rng)
    data, off, stride = layout(kind, vals, shape)
    none = "-" if kind in ("f64", "str") else str(NONE[kind])

    def expect(order):
        seen, ids = {}, []
        for i in order:
            v = vals[i]
            key = ("nil",) if v is None else (0.0 if v == 0 else v)
            ids.append(str(seen.setdefault(key, len(seen))))
        keys = ["nil" if k == ("nil",) else "s:" + k.encode("latin-1").hex() if kind == "str"
                else g17(k) for k in seen]
        return ids + ["size %d" % len(seen)] + keys

    got = run("ids", kind, data, off, stride, none, "-", N)
    assert got == expect(range(N))
    sel = sorted(rng.sample(range(N), 100))
    assert run("ids", kind, data, off, stride, none, csv(sel), len(sel)) == expect(sel)


def test_mask_and_offsets(run):
    presence = bytes([1, 0, 0, 1, 1, 0, 2, 0, 1])
    assert run("mask", presence, 0, 9) == [0, 3, 4, 6, 8]
    assert run("mask", presence, 3, 4) == [0, 1, 3]
    lengths = struct.pack("<5I", 3, 0, 1, 6, 0)
    assert run("offsets", b"xx" + lengths, 2, 5, 22) == [
        29, 22, 3, 24, 0, 24, 1, 24, 6, 29, 0]


def test_errors(run):
    got = run("errors")
    assert got[:13] == [
        "vec.filter: unknown kind u8",
        "vec.filter: unknown op !=",
        "vec.filter: reads past the end of a buffer",
        "vec.filter: reads past the end of a buffer",
        "vec.filter: kind str compares with a string",
        "vec.filter: kind i32 compares with a number",
        "vec.filter: stride must be a whole number from 1",
        "vec.filterIn: takes kind i8 or i32",
        "vec.fold: takes a buffer of n u32 group ids or nil for gids",
        "vec.mask: reads past the end of a buffer",
        "vec.offsets: reads past the end of a buffer",
        "vec.grouper: unknown kind u8",
        "vec.key: has no group 0",
    ]
    # an index in sel past the block raises; the reference's message comes
    # from Luau's buffer checks
    assert got[13] != "no error"
