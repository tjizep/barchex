"""Times queries over a column table of two int fields, and takes apart where
the time goes: the fold's stages, its vector kernels and its cursor reads.

    BARCHD=.../barchd python -m tests.bench_columns ROWS BLOCK

ROWS rows are loaded into table P, whose column blocks are BLOCK bytes. Each
row holds age = id % 100 and weight = id * 7919 % 1000. Environment settings:

    STEPS    steps to run, comma separated, each `name` or `name:arg:...`;
             `run,run` by default. A step without arguments gets REPS.
    REPS     repetitions of each measurement, 2000 by default.
    FIRST    the first id, 1 by default. 262144 starts at a block boundary
             for every block size up to 256 KB, so every block is full.
    RANGED   0 for a hashed sharded space; range sharded by default.
    AOT      1 installs the bench function with SETF ... AOT.

Steps:

    run, runat:ROWS:REPS, plain   each query's time, and its stages
    vecprof:QUERY:REPS            each vector kernel's calls and time
    reduced:REPS:FIRST:N          `age > 10 sum` as its kernels alone, then
                                  with each part of lent's fold added
    curcost:REPS:FIRST:N          what a cursor read of a block costs
    prims, sizes, vecsizes        store reads and kernels on their own
    loop:QUERY:SECONDS            one query in a loop, for a profiler
    prof, fold5                   time inside lent's fold; they need a copy
                                  of lent/columns.luau with timers that fill
                                  its PROF and PN tables

To compare two versions of lent, run each checkout's own copy of this file.
"""
import os
import sys
import time

from .conftest import _spawn_barchd
from .test_client import setup

APP = r"""
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local col = require("lent.COLUMNS")
local LAY = require("lent.LAYOUT")
local KC = require("lent.KEYCODEC")
local SHEAD = 8
local f = lent.field
local app = lent.graph { lent.schema "P" { id = "int", format = "column", block = __BLOCK__,
    fields = { f.int "age", f.int "weight" } } }
local db = client.open(app)
local steps = {}
function steps.migrate() return m.migrate(app).version end
function steps.load(from, n)
    from, n = tonumber(from), tonumber(n)
    return db.tx(function(c)
        local list = table.create(n)
        for i = from, from + n - 1 do
            list[#list + 1] = { id = i, age = i % 100, weight = (i * 7919) % 1000 }
        end
        c.P:createMany(list)
        return "ok"
    end)
end
local function timed(reps, fn)
    fn()
    local t0 = barch.time()
    local r
    for _ = 1, reps do r = fn() end
    return (barch.time() - t0) / reps, r
end
local QUERIES = {
    { "build only", function(c) return c.P:query():where("age > 10") end },
    { "empty span sum", function(c) return c.P:query():where("id < 0 and age > 10"):sum("weight") end },
    { "count all", function(c) return c.P:query():count() end },
    { "sum all", function(c) return c.P:query():sum("weight") end },
    { "age > 10 count", function(c) return c.P:query():where("age > 10"):count() end },
    { "age > 10 sum", function(c) return c.P:query():where("age > 10"):sum("weight") end },
    { "10<age<20 sum", function(c) return c.P:query():where("age > 10 and age < 20"):sum("weight") end },
    { "and or sum", function(c)
        return c.P:query():where("age > 10 and age < 20 or weight < 100"):sum("weight") end },
    { "grouped sum", function(c)
        return #c.P:query():where("age > 10 and age < 20"):groupBy("age")
            :aggregate({ s = { fn = "sum", field = "weight" } }) end },
}
function steps.run(reps)
    reps = tonumber(reps)
    local out = {}
    local function per(fn)
        fn()
        local t0 = barch.time()
        for _ = 1, reps do fn() end
        return (barch.time() - t0) / reps
    end
    local function both(fn)
        for _, q in QUERIES do db.tx(function(c) fn(c, "tx", q) end) end
        for _, q in QUERIES do fn(db.client(), "notx", q) end
    end
    both(function(c, mode, q)
        do
            -- capture one run's stage arguments and store calls
            local sf, fo, fi = col.start_fold, col.fold, col.finish
            local sargs, fargs = nil, {}
            local calls, ncalls = {}, {}
            col.start_fold = function(...) sargs = table.pack(...); return sf(...) end
            col.fold = function(t, job, lo, hi) fargs[#fargs + 1] = { t, lo, hi }; return fo(t, job, lo, hi) end
            local saved = {}
            for k, v in barch.store do
                if type(v) == "function" then
                    saved[k] = v
                    barch.store[k] = function(...)
                        ncalls[k] = (ncalls[k] or 0) + 1
                        calls[#calls + 1] = { v, table.pack(...) }
                        return v(...)
                    end
                end
            end
            local r = q[2](c)
            for k, v in saved do barch.store[k] = v end
            col.start_fold, col.fold = sf, fo
            local total = per(function() return q[2](c) end)
            local tstart, tall, tstore = 0, 0, 0
            if sargs then
                tstart = per(function() return sf(table.unpack(sargs, 1, sargs.n)) end)
                tall = per(function()
                    local job = sf(table.unpack(sargs, 1, sargs.n))
                    for _, f in fargs do if fo(f[1], job, f[2], f[3]) then break end end
                    fi(job)
                end)
            end
            if mode == "notx" then tstore = per(function()
                for _, cl in calls do cl[1](table.unpack(cl[2], 1, cl[2].n)) end
            end) end
            local names = {}
            for k, n in ncalls do names[#names + 1] = k .. "=" .. n end
            table.sort(names)
            out[#out + 1] = string.format("%-4s %-15s total=%.4f start=%.4f fold+finish=%.4f client=%.4f store=%.4f spans=%d r=%s %s",
                mode, q[1], total, tstart, tall - tstart, total - tall, tstore, #fargs, tostring(r), table.concat(names, " "))
        end
    end)
    return out
end
function steps.runat(rows, reps)
    local was = col.in_place and col.in_place(tonumber(rows))
    local out = steps.run(reps)
    if col.in_place then col.in_place(was) end
    table.insert(out, 1, "in_place=" .. rows .. (if col.in_place then "" else " (no setting)"))
    return out
end
function steps.alloc(reps)
    reps = tonumber(reps)
    local out = {}
    local function per(fn)
        fn()
        local t0 = barch.time()
        for _ = 1, reps do fn() end
        return (barch.time() - t0) / reps
    end
    local keep
    for _, size in { 4096, 32768, 65536, 131072, 262144 } do
        out[#out + 1] = string.format("buffer.create(%d) ms=%.5f", size, per(function() keep = buffer.create(size) end))
    end
    out[#out + 1] = string.format("start_fold set (2x131072+40960+2x4096) ms=%.5f", per(function()
        keep = { buffer.create(131072), buffer.create(131072), buffer.create(40960), buffer.create(4096), buffer.create(4096) } end))
    out[#out + 1] = string.format("table.create(32768,0) ms=%.5f", per(function() keep = table.create(32768, 0) end))
    out[#out + 1] = string.format("gc count KB=%.0f", gcinfo and gcinfo() or -1)
    return out
end
function steps.loop(name, secs)
    secs = tonumber(secs)
    local q
    for _, x in QUERIES do if x[1] == name then q = x[2] end end
    local c = db.client()
    local t0, n = barch.time(), 0
    while barch.time() - t0 < secs * 1000 do
        for _ = 1, 100 do q(c) end
        n += 100
    end
    return { string.format("%s ran %d in %.0f ms: %.4f ms each", name, n, barch.time() - t0, (barch.time() - t0) / n) }
end
function steps.prof(reps)
    reps = tonumber(reps)
    local out = {}
    local c = db.client()
    for _, q in QUERIES do
        q[2](c)
        table.clear(col.PROF)
        local t0 = barch.time()
        for _ = 1, reps do q[2](c) end
        local total = (barch.time() - t0) / reps * 1000
        local names = {}
        for k in col.PROF do names[#names + 1] = k end
        table.sort(names)
        local parts = {}
        for _, k in names do parts[#parts + 1] = string.format("%s=%.1f", k, col.PROF[k] / reps * 1000) end
        out[#out + 1] = string.format("%-15s us=%.1f %s", q[1], total, table.concat(parts, " "))
    end
    return out
end
function steps.vecprof(name, reps)
    reps = tonumber(reps)
    local q
    for _, x in QUERIES do if x[1] == name then q = x[2] end end
    local c = db.client()
    q(c)
    local v, proxy, T, N = barch.vec, {}, {}, {}
    for k, f in v do
        if type(f) == "function" then
            proxy[k] = function(...)
                local t0 = barch.time()
                local a, b, cc, d = f(...)
                T[k] = (T[k] or 0) + barch.time() - t0
                N[k] = (N[k] or 0) + 1
                return a, b, cc, d
            end
        else
            proxy[k] = f
        end
    end
    local was = col.kernels(proxy)
    local t0 = barch.time()
    for _ = 1, reps do q(c) end
    local total = (barch.time() - t0) / reps * 1000
    col.kernels(was)
    local out = { string.format("%s us=%.1f", name, total) }
    for k, t in T do
        out[#out + 1] = string.format("  vec.%s calls=%.1f us=%.1f", k, N[k] / reps, t / reps * 1000)
    end
    return out
end
-- what a cursor read of a column block costs, and which part
function steps.curcost(reps, first, n)
    reps, first, n = tonumber(reps), tonumber(first), tonumber(n)
    local c = db.client()
    local sf, job = col.start_fold, nil
    col.start_fold = function(...) job = sf(...); return job end
    c.P:query():where("age > 10"):sum("weight")
    col.start_fold = sf
    local W
    for _, x in job.sources do if x.name == "weight" then W = x end end
    local fb0, fb1 = first // W.rows, (first + n - 1) // W.rows
    local keys = {}
    for fb = fb0, fb1 do keys[#keys + 1] = W.prefix .. KC.encode("int", fb) end
    local lo, hi = keys[1], W.prefix .. KC.encode("int", fb1 + 1)
    local head = buffer.create(8)
    local out = {}
    local function per(name, fn)
        fn()
        local t0 = barch.time()
        for _ = 1, reps do fn() end
        local us = (barch.time() - t0) / reps * 1000
        out[#out + 1] = string.format("%-36s us/read=%.3f", name, us / #keys)
    end
    local cur = barch.store.cursor(lo, hi)
    per("read 8 header bytes, in order", function() for _, k in keys do cur:read(k, head, 0, 0, 8) end end)
    per("read size only, in order", function() for _, k in keys do cur:read(k) end end)
    per("same key again", function() for _ = 1, #keys do cur:read(keys[1], head, 0, 0, 8) end end)
    per("in reverse order", function() for i = #keys, 1, -1 do cur:read(keys[i], head, 0, 0, 8) end end)
    per("cursor open + reads", function()
        local cc = barch.store.cursor(lo, hi)
        for _, k in keys do cc:read(k, head, 0, 0, 8) end
    end)
    per("getBufferAt (copies the block)", function() for _, k in keys do barch.store.getBufferAt(k, 0) end end)
    local f = function() end
    per("empty Luau call", function() for _ in keys do f() end end)
    return out
end
function steps.fold5(reps)
    reps = tonumber(reps)
    local c = db.client()
    local Q = function() return c.P:query():where("age > 10"):sum("weight") end
    local sf, fo, fi = col.start_fold, col.fold, col.finish
    local sargs, fargs = nil, {}
    col.start_fold = function(...) sargs = table.pack(...); return sf(...) end
    col.fold = function(t, j, lo, hi) fargs[#fargs + 1] = { t, lo, hi }; return fo(t, j, lo, hi) end
    Q()
    col.start_fold, col.fold = sf, fo
    local T, N = {}, {}
    local function add(k, t) T[k] = (T[k] or 0) + t; N[k] = (N[k] or 0) + 1 end
    local proxy = {}
    for k, f in barch.vec do
        proxy[k] = if type(f) == "function" then function(...)
            local t0 = barch.time()
            local a, b, cc, d = f(...)
            add("vec." .. k, barch.time() - t0)
            return a, b, cc, d
        end else f
    end
    local function run()
        local t0 = barch.time()
        local j = sf(table.unpack(sargs, 1, sargs.n))
        local t1 = barch.time()
        for _, f in fargs do if fo(f[1], j, f[2], f[3]) then break end end
        local t2 = barch.time()
        fi(j)
        local t3 = barch.time()
        add("start_fold", t1 - t0); add("fold", t2 - t1); add("finish", t3 - t2); add("all", t3 - t0)
    end
    local out = {}
    local function report(tag)
        local names = {}
        for k in T do names[#names + 1] = k end
        for k in col.PROF do names[#names + 1] = k end
        table.sort(names)
        out[#out + 1] = tag
        for _, k in names do
            local t, n = T[k] or col.PROF[k], N[k] or col.PN[k]
            out[#out + 1] = string.format("  %-16s us=%7.1f calls=%6.1f", k, t / reps * 1000, n / reps)
        end
    end
    -- plain: only the stage timers
    run(); table.clear(T); table.clear(N); table.clear(col.PROF); table.clear(col.PN)
    for _ = 1, reps do run() end
    report("stages, function timers on")
    local was = col.kernels(proxy)
    run(); table.clear(T); table.clear(N); table.clear(col.PROF); table.clear(col.PN)
    for _ = 1, reps do run() end
    col.kernels(was)
    report("stages, function and kernel timers on")
    -- what one timed wrapper costs
    local wrapped = function(...)
        local t0 = barch.time()
        local a = select(1, ...)
        add("x", barch.time() - t0)
        return a
    end
    local t0 = barch.time()
    for i = 1, 100000 do wrapped(i) end
    out[#out + 1] = string.format("  one timed wrapper ns=%.1f", (barch.time() - t0) / 100000 * 1e6)
    return out
end

-- age > 10 sum stripped to its kernels, then rebuilt a piece at a time
function steps.reduced(reps, first, n)
    reps, first, n = tonumber(reps), tonumber(first), tonumber(n)
    local c = db.client()
    local Q = function() return c.P:query():where("age > 10"):sum("weight") end
    local sf, job, sargs = col.start_fold, nil, nil
    local fo, fargs = col.fold, {}
    col.start_fold = function(...) sargs = table.pack(...); job = sf(...); return job end
    col.fold = function(t, j, lo, hi) fargs[#fargs + 1] = { t, lo, hi }; return fo(t, j, lo, hi) end
    local want = Q()
    col.start_fold, col.fold = sf, fo
    local A, W
    for _, s in job.sources do
        if s.name == "age" then A = s elseif s.name == "weight" then W = s end
    end
    local g, unit, v = job.g, job.unit, barch.vec
    local crows, grows, pbase, plive = A.rows, g.rows, g.pbase, g.plive
    local kind, w = A.int.kind, A.int.width
    local wkind, ww = W.int.kind, W.int.width
    local pprefix = LAY.present(g.t)
    local fb0, fb1 = first // crows, (first + n - 1) // crows
    local akeys, wkeys, pkeys, ab, wb, pbufs = {}, {}, {}, {}, {}, {}
    for fb = fb0, fb1 do
        akeys[fb] = A.prefix .. KC.encode("int", fb)
        wkeys[fb] = W.prefix .. KC.encode("int", fb)
        ab[fb] = barch.store.getBufferAt(akeys[fb], 0)
        wb[fb] = barch.store.getBufferAt(wkeys[fb], 0)
        local pk = fb * crows // grows
        pkeys[pk] = pprefix .. KC.encode("int", pk)
        pbufs[pk] = barch.store.getBufferAt(pkeys[pk], 0)
    end
    local out = { string.format("want=%s unit=%d crows=%d grows=%d kinds=%s/%d %s/%d none=%s/%s blocks=%d..%d",
        tostring(want), unit, crows, grows, kind, w, wkind, ww, tostring(A.int.none), tostring(W.int.none), fb0, fb1) }
    local bits, pbits = buffer.create(unit // 8), buffer.create(unit // 8)
    local recs, head, phead = buffer.create(32), buffer.create(8), buffer.create(16)
    local function per(name, fn)
        fn()
        local t0 = barch.time()
        local r
        for _ = 1, reps do r = fn() end
        local us = (barch.time() - t0) / reps * 1000
        out[#out + 1] = string.format("%-34s us=%7.1f G rows/s=%5.2f sum=%s", name, us, n / us / 1000, tostring(r))
    end
    local function sum() return buffer.readf64(recs, 8) end
    per("0 compare + foldBits, copied", function()
        buffer.fill(recs, 0, 0)
        for fb = fb0, fb1 do
            v.compare(kind, ab[fb], SHEAD, w, ">", 10, nil, unit, bits, 0)
            v.foldBits(wkind, wb[fb], SHEAD, ww, nil, bits, 0, unit, nil, recs)
        end
        return sum()
    end)
    per("1 + none", function()
        buffer.fill(recs, 0, 0)
        for fb = fb0, fb1 do
            v.compare(kind, ab[fb], SHEAD, w, ">", 10, A.int.none, unit, bits, 0)
            v.foldBits(wkind, wb[fb], SHEAD, ww, W.int.none, bits, 0, unit, nil, recs)
        end
        return sum()
    end)
    per("2 + packed check (header)", function()
        buffer.fill(recs, 0, 0)
        for fb = fb0, fb1 do
            local pk = fb * crows // grows
            local pb = pbufs[pk]
            if buffer.readi32(pb, plive) ~= grows then
                local at = pbase + fb * crows - pk * grows
                v.compare("i8", pb, at, 1, "~=", 0, nil, unit, pbits, 0)
            end
            v.compare(kind, ab[fb], SHEAD, w, ">", 10, A.int.none, unit, bits, 0)
            v.foldBits(wkind, wb[fb], SHEAD, ww, W.int.none, bits, 0, unit, nil, recs)
        end
        return sum()
    end)
    per("2b presence compare + and (always)", function()
        buffer.fill(recs, 0, 0)
        for fb = fb0, fb1 do
            local pk = fb * crows // grows
            local at = pbase + fb * crows - pk * grows
            v.compare("i8", pbufs[pk], at, 1, "~=", 0, nil, unit, pbits, 0)
            v.compare(kind, ab[fb], SHEAD, w, ">", 10, A.int.none, unit, bits, 0)
            v.bits("and", bits, 0, pbits, 0, unit, bits, 0)
            v.foldBits(wkind, wb[fb], SHEAD, ww, W.int.none, bits, 0, unit, nil, recs)
        end
        return sum()
    end)
    local function inplace(fresh)
        return function()
            buffer.fill(recs, 0, 0)
            local pk0, pk1 = fb0 * crows // grows, fb1 * crows // grows
            local pcur = barch.store.cursor(pprefix .. KC.encode("int", pk0), pprefix .. KC.encode("int", pk1 + 1))
            local acur = barch.store.cursor(A.prefix .. KC.encode("int", fb0), A.prefix .. KC.encode("int", fb1 + 1))
            local wcur = barch.store.cursor(W.prefix .. KC.encode("int", fb0), W.prefix .. KC.encode("int", fb1 + 1))
            local lastpk = nil
            for fb = fb0, fb1 do
                local pk = fb * crows // grows
                local ak, wk, pkey
                if fresh then
                    ak, wk = A.prefix .. KC.encode("int", fb), W.prefix .. KC.encode("int", fb)
                    pkey = pprefix .. KC.encode("int", pk)
                else
                    ak, wk, pkey = akeys[fb], wkeys[fb], pkeys[pk]
                end
                if pk ~= lastpk then
                    pcur:read(pkey, phead, 0, 0, 16)
                    lastpk = pk
                end
                if buffer.readi32(phead, plive) ~= grows then
                    local at = pbase + fb * crows - pk * grows
                    v.compare("i8", pcur, at, 1, "~=", 0, nil, unit, pbits, 0)
                end
                acur:read(ak, head, 0, 0, SHEAD)
                v.compare(kind, acur, SHEAD, w, ">", 10, A.int.none, unit, bits, 0)
                wcur:read(wk, head, 0, 0, SHEAD)
                v.foldBits(wkind, wcur, SHEAD, ww, W.int.none, bits, 0, unit, nil, recs)
            end
            return sum()
        end
    end
    local bb = {}
    for fb = fb0, fb1 do bb[fb] = buffer.create(unit // 8) end
    per("2c column at a time, copied", function()
        buffer.fill(recs, 0, 0)
        for fb = fb0, fb1 do
            v.compare(kind, ab[fb], SHEAD, w, ">", 10, A.int.none, unit, bb[fb], 0)
        end
        for fb = fb0, fb1 do
            v.foldBits(wkind, wb[fb], SHEAD, ww, W.int.none, bb[fb], 0, unit, nil, recs)
        end
        return sum()
    end)
    per("3c column at a time, in place", function()
        buffer.fill(recs, 0, 0)
        local pk0, pk1 = fb0 * crows // grows, fb1 * crows // grows
        local pcur = barch.store.cursor(pprefix .. KC.encode("int", pk0), pprefix .. KC.encode("int", pk1 + 1))
        local acur = barch.store.cursor(A.prefix .. KC.encode("int", fb0), A.prefix .. KC.encode("int", fb1 + 1))
        local wcur = barch.store.cursor(W.prefix .. KC.encode("int", fb0), W.prefix .. KC.encode("int", fb1 + 1))
        for pk = pk0, pk1 do
            pcur:read(pkeys[pk], phead, 0, 0, 16)
            if buffer.readi32(phead, plive) ~= grows then error("gap") end
        end
        for fb = fb0, fb1 do
            acur:read(akeys[fb], head, 0, 0, SHEAD)
            v.compare(kind, acur, SHEAD, w, ">", 10, A.int.none, unit, bb[fb], 0)
        end
        for fb = fb0, fb1 do
            wcur:read(wkeys[fb], head, 0, 0, SHEAD)
            v.foldBits(wkind, wcur, SHEAD, ww, W.int.none, bb[fb], 0, unit, nil, recs)
        end
        return sum()
    end)
    per("3 + in-place cursors", inplace(false))
    per("4 + keys encoded per query", inplace(true))
    per("5 start_fold/fold/finish", function()
        local j = sf(table.unpack(sargs, 1, sargs.n))
        for _, f in fargs do if fo(f[1], j, f[2], f[3]) then break end end
        col.finish(j)
        return #fargs
    end)
    per("6 full query", Q)
    return out
end
function steps.prims(reps)
    reps = tonumber(reps)
    local out = {}
    local t = app.tables and app.tables.P or nil
    local all
    -- find the presence prefix from the store
    local any = barch.store.range("lent.p", "lent.q", 1)[1]
    all = string.sub(any, 1, #any - #KC.encode("int", LAY.present_block(any)))
    local hi = KC.after(all)
    local function per(name, fn)
        fn()
        local t0 = barch.time()
        for _ = 1, reps do fn() end
        out[#out + 1] = string.format("%-28s us=%.2f", name, (barch.time() - t0) / reps * 1000)
    end
    per("range(all, 16)", function() return barch.store.range(all, hi, 16) end)
    per("range(all, 1)", function() return barch.store.range(all, hi, 1) end)
    per("rangeValues(all, 16)", function() return barch.store.rangeValues(all, hi, 16) end)
    per("cursor open", function() return barch.store.cursor(all, hi) end)
    local cur = barch.store.cursor(all, hi)
    local b = buffer.create(cur:read(any))
    per("cur:read presence", function() return cur:read(any, b) end)
    per("cur:read missing", function() return cur:read(all .. KC.encode("int", 99999)) end)
    per("get presence", function() return barch.store.get(any) end)
    per("getBufferAt presence", function() return barch.store.getBufferAt(any, 0) end)
    local v = barch.vec
    local N = buffer.len(b) - 16; out[#out + 1] = "presence rows " .. N; local bits = buffer.create((N + 7) // 8)
    per("vec.compare i8 32768", function() return v.compare("i8", b, 16, 1, "~=", 0, nil, N, bits, 0) end)
    per("vec.bits and 32768", function() return v.bits("and", bits, 0, bits, 0, N, bits, 0) end)
    per("barch.time", function() return barch.time() end)
    return out
end
function steps.plain(reps)
    reps = tonumber(reps)
    local out = {}
    local function both(fn)
        db.tx(function(c) fn(c, "tx") end)
        fn(db.client(), "notx")
    end
    both(function(c, mode)
        for _, q in QUERIES do
            q[2](c)
            local t0 = barch.time()
            local r
            for _ = 1, reps do r = q[2](c) end
            out[#out + 1] = string.format("%-4s %-15s ms=%.4f r=%s", mode, q[1], (barch.time() - t0) / reps, tostring(r))
        end
    end)
    return out
end
-- time reading store values of each size through a cursor, get and getBufferAt
function steps.sizes(reps)
    reps = tonumber(reps)
    local out = {}
    local sizes = { 4096, 16384, 32768, 49152, 65000, 65536, 65552, 81920, 98304, 131072, 196608, 262144, 524288, 1048576 }
    for _, n in sizes do
        local b = buffer.create(n)
        for i = 0, n - 1 do buffer.writeu8(b, i, (i * 31 + i // 251) % 251) end
        local k = "zz.size." .. string.format("%08d", n)
        local ok, e = pcall(barch.store.set, k, buffer.tostring(b))
        if not ok then out[#out + 1] = n .. " set failed: " .. tostring(e) continue end
    end
    for _, n in sizes do
        local k = "zz.size." .. string.format("%08d", n)
        local r = math.max(200, reps * 4096 // n)
        local cur = barch.store.cursor("zz.size.", "zz.size/")
        local got = cur:read(k)
        if type(got) ~= "number" then out[#out + 1] = n .. " missing" continue end
        local b = buffer.create(got)
        local function per(fn)
            fn()
            local t0 = barch.time()
            for _ = 1, r do fn() end
            return (barch.time() - t0) / r * 1000
        end
        local tc = per(function() return cur:read(k, b) end)
        local tb = per(function() return barch.store.getBufferAt(k, 0) end)
        local tg = per(function() return barch.store.get(k) end)
        local tm = per(function() buffer.copy(b, 0, b, 0, n) end)
        out[#out + 1] = string.format("%8d B  cur:read %8.2f us %6.1f ns/KB | getBufferAt %8.2f us %6.1f ns/KB | get %8.2f us | luau copy %7.2f us",
            n, tc, tc * 1e3 * 1024 / n, tb, tb * 1e3 * 1024 / n, tg, tm)
    end
    return out
end
function steps.bigset()
    local out = {}
    for _, n in { 262144, 300000, 393216, 524287, 524288, 1048575 } do
        local k = "zz.big." .. n
        local ok, e = pcall(barch.store.set, k, string.rep("a", n))
        local got = barch.store.get(k)
        local okb, eb = pcall(barch.store.setBufferAt, k .. "b", buffer.create(n), 0)
        local gotb = barch.store.get(k .. "b")
        out[#out + 1] = string.format("%8d set ok=%s ret=%s stored=%s | setBufferAt ok=%s ret=%s stored=%s",
            n, tostring(ok), tostring(e), tostring(got and #got), tostring(okb), tostring(eb), tostring(gotb and #gotb))
    end
    return out
end
-- time vec kernels per slot as the chunk grows, to look for cache steps
function steps.vecsizes(reps)
    reps = tonumber(reps)
    local v = barch.vec
    local out = { string.format("%8s %8s | %7s %7s %7s %7s %7s %7s | %7s", "slots", "bytes",
        "cmp i8", "cmp i16", "cmp f64", "and", "fb i16", "fb f64", "chain") }
    local MAX = 1048576
    local p8, p16, p64 = buffer.create(MAX), buffer.create(MAX * 2), buffer.create(MAX * 8)
    local seed = 12345
    for i = 0, MAX - 1 do
        seed = (seed * 1103515245 + 12345) % 2147483648
        local x = seed % 1000
        buffer.writeu8(p8, i, if x < 900 then 1 else 0)
        buffer.writei16(p16, i * 2, x)
        buffer.writef64(p64, i * 8, x)
    end
    local b1, b2 = buffer.create(MAX // 8), buffer.create(MAX // 8)
    local recs = buffer.create(32)
    for _, n in { 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576 } do
        local r = math.max(20, reps * 4096 // n)
        local function per(fn)
            fn()
            local t0 = barch.time()
            for _ = 1, r do fn() end
            return (barch.time() - t0) / r * 1e6 / n
        end
        local c8 = per(function() v.compare("i8", p8, 0, 1, "~=", 0, nil, n, b1, 0) end)
        local c16 = per(function() v.compare("i16", p16, 0, 2, ">", 10, nil, n, b2, 0) end)
        local c64 = per(function() v.compare("f64", p64, 0, 8, ">", 10, nil, n, b2, 0) end)
        local an = per(function() v.bits("and", b1, 0, b2, 0, n, b2, 0) end)
        local f16 = per(function() v.foldBits("i16", p16, 0, 2, nil, b2, 0, n, nil, recs) end)
        local f64 = per(function() v.foldBits("f64", p64, 0, 8, nil, b2, 0, n, nil, recs) end)
        -- presence, one i16 condition, and, then a sum over an f64 column
        local ch = per(function()
            v.compare("i8", p8, 0, 1, "~=", 0, nil, n, b1, 0)
            v.compare("i16", p16, 0, 2, ">", 10, nil, n, b2, 0)
            v.bits("and", b2, 0, b1, 0, n, b2, 0)
            v.foldBits("f64", p64, 0, 8, nil, b2, 0, n, nil, recs)
        end)
        out[#out + 1] = string.format("%8d %8d | %7.3f %7.3f %7.3f %7.3f %7.3f %7.3f | %7.3f",
            n, n * 11, c8, c16, c64, an, f16, f64, ch)
    end
    out[#out + 1] = "ns per slot; bytes = presence + i16 + f64 column per chunk"
    return out
end
function call(step, ...) return steps[step](...) end
"""

def main(rows, block):
    with _spawn_barchd() as server:
        c = server.client
        c.execute_command("CONFIG SET function_deadline_ms 600000")
        setup(c)
        if os.environ.get("RANGED", "1") != "0":
            c.execute_command("USE", "configuration"); c.execute_command("SET", "ints.range_sharded", "1")
        c.execute_command("USE", "ints")
        c.execute_command("SETF", "WHERE", APP.replace("__BLOCK__", block), *(["AOT"] if os.environ.get("AOT") == "1" else []))
        assert c.execute_command("CALLF", "WHERE", "migrate") == 1
        t0 = time.time()
        first = int(os.environ.get("FIRST", "1"))
        for i in range(first, first + rows, 8192):
            c.execute_command("CALLF", "WHERE", "load", str(i), str(min(8192, first + rows - i)))
        print(f"rows={rows} block={block} loaded in {time.time() - t0:.0f}s", flush=True)
        for step in os.environ.get("STEPS", "run,run").split(","):
            print("--", step)
            args = step.split(":")
            if len(args) == 1: args.append(os.environ.get("REPS", "2000"))
            if args[0] == "loop": print("ready", flush=True)
            for line in c.execute_command("CALLF", "WHERE", *args):
                print(line.decode() if isinstance(line, bytes) else line, flush=True)

if __name__ == "__main__":
    main(int(sys.argv[1]), sys.argv[2])
