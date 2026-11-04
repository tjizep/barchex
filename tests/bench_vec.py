"""Times the vector kernels on blocks of 1,024 elements: lent.VEC's Luau
reference, and barch.vec when barch provides it.

    BARCHD=.../barchd python -m tests.bench_vec

An optional argument sets how many milliseconds each measurement lasts, 200
by default. Each row is millions of elements per second through one kernel, on a column
block (elements packed) and on a block of fixed-width rows (31 bytes, so most
elements are unaligned)."""

import sys

from .conftest import _spawn_barchd, install

BENCH = r"""
local N = 1024
local WORDS = { "east", "west", "north", "south", "up", "down", "left", "right",
                "red", "green", "blue", "cyan", "a", "bb", "ccc", "dddd" }
local WIDTH = { i8 = 1, i16 = 2, i32 = 4, i64 = 8, f64 = 8, str = 8 }
local ROW_AT = { i8 = 0, i32 = 1, i64 = 5, f64 = 13, str = 21, i16 = 29 }
local ROW = 31

-- element i of a kind: 16 distinct values, so groups and = find matches
local function value(kind, i)
    local r = (i * 7919) % 16
    if kind == "f64" then return r * 1.25 end
    if kind == "i64" then return r * 4294967296 + r end
    return r
end

local function block(kind, shape)
    local stride = if shape == "column" then WIDTH[kind] else ROW
    local off = if shape == "column" then 0 else ROW_AT[kind]
    local heap = N * stride
    local b = buffer.create(heap + N * 6)
    for i = 0, N - 1 do
        local at = off + i * stride
        if kind == "i8" then buffer.writei8(b, at, value(kind, i))
        elseif kind == "i16" then buffer.writei16(b, at, value(kind, i))
        elseif kind == "i32" then buffer.writei32(b, at, value(kind, i))
        elseif kind == "i64" then
            local v = value(kind, i)
            buffer.writeu32(b, at, v % 4294967296)
            buffer.writei32(b, at + 4, v // 4294967296)
        elseif kind == "f64" then buffer.writef64(b, at, value(kind, i))
        else
            local w = WORDS[value(kind, i) + 1]
            buffer.writestring(b, heap, w)
            buffer.writeu32(b, at, heap)
            buffer.writeu32(b, at + 4, #w + 1)
            heap += #w
        end
    end
    return b, off, stride
end

-- millions of elements per second through f, doubling the repetitions
-- until a run lasts `ms` milliseconds, since barch.time() counts whole ones
local function timed(ms, f)
    local reps = 8
    while true do
        local t0 = barch.time()
        for _ = 1, reps do f() end
        local took = barch.time() - t0
        if took >= ms then
            return reps * N / took / 1000
        end
        reps *= 2
    end
end

function call(impl, kind, shape, kernel, ms)
    local vec = if impl == "native" then barch.vec else require("lent.VEC")
    if vec == nil or not pcall(vec.grouper, kind) then return "-" end
    ms = tonumber(ms)
    local b, off, stride = block(kind, shape)
    local sel = buffer.create(N * 4)
    local out = buffer.create(N * 4)
    local gids = buffer.create(N * 4)
    local recs = buffer.create(16 * 32)
    local mid = if kind == "str" then "m" else value(kind, 3) + (if kind == "f64" then 0.5 else 0)
    -- half the slots, for the kernels that take a selection
    local half = 0
    for i = 0, N - 1, 2 do buffer.writeu32(sel, half * 4, i); half += 1 end
    local rate
    if kernel == "filter" then
        rate = timed(ms, function() vec.filter(kind, b, off, stride, "<", mid, nil, nil, N, out) end)
    elseif kernel == "filter sel" then
        rate = timed(ms, function() vec.filter(kind, b, off, stride, "<", mid, nil, sel, half, out) end)
        rate = rate * half / N
    elseif kernel == "filterIn" then
        if kind ~= "i8" and kind ~= "i16" and kind ~= "i32" then return "-" end
        local set = buffer.create(16)
        for c = 0, 15, 2 do buffer.writeu8(set, c, 1) end
        rate = timed(ms, function() vec.filterIn(kind, b, off, stride, set, nil, N, out) end)
    elseif kernel == "fold" then
        rate = timed(ms, function() vec.fold(kind, b, off, stride, nil, nil, N, nil, recs) end)
    elseif kernel == "fold groups" then
        local g = vec.grouper(kind)
        g:ids(b, off, stride, nil, nil, N, gids)
        rate = timed(ms, function() vec.fold(kind, b, off, stride, nil, nil, N, gids, recs) end)
    elseif kernel == "grouper ids" then
        local g = vec.grouper(kind)
        rate = timed(ms, function() g:ids(b, off, stride, nil, nil, N, gids) end)
    elseif kernel == "mask" then
        if kind ~= "i8" then return "-" end
        local m = buffer.create(N)
        for i = 0, N - 1, 3 do buffer.writeu8(m, i, 1) end
        rate = timed(ms, function() vec.mask(m, 0, N, out) end)
    elseif kernel == "plain sum" then
        -- a Luau loop written for one kind and layout, for comparison
        if kind ~= "f64" or impl ~= "ref" then return "-" end
        rate = timed(ms, function()
            local s = 0
            for i = 0, N - 1 do s += buffer.readf64(b, off + i * stride) end
            return s
        end)
    end
    return string.format("%.1f", rate)
end
"""

KINDS = ["i8", "i16", "i32", "i64", "f64", "str"]
KERNELS = ["filter", "filter sel", "filterIn", "fold", "fold groups", "grouper ids", "mask",
           "plain sum"]


def main(ms: int = 200) -> None:
    with _spawn_barchd() as server:
        c = server.client
        install(c, "lent", "VEC", "lent/vec.luau")
        c.execute_command("USE", "default")
        c.execute_command("SETF", "BENCH", BENCH)
        native = c.execute_command("CALLF", "BENCH", "native", "f64", "column", "fold", 1) != "-"
        impls = ["ref", "native"] if native else ["ref"]
        cols = [f"{impl} {shape}" for shape in ["column", "row"] for impl in impls]
        print("Millions of elements/s, blocks of 1,024 elements\n")
        print("| kernel | kind | " + " | ".join(cols) + " |")
        print("|---|---|" + "---:|" * len(cols))
        for kernel in KERNELS:
            for kind in KINDS:
                cells = []
                for shape in ["column", "row"]:
                    for impl in impls:
                        cells.append(c.execute_command("CALLF", "BENCH", impl, kind, shape,
                                                       kernel, ms))
                if all(x == "-" for x in cells):
                    continue
                print(f"| {kernel} | {kind} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 200)
