-- STREAMS: append-only streams with the Redis XADD family, so a producer
-- such as Debezium Server's Redis sink can publish into barch, and a queue
-- service can take each new entry as it arrives.
--
--   XADD key [NOMKSTREAM] [MAXLEN|MINID [=|~] threshold [LIMIT count]]
--        *|ms|ms-*|ms-seq field value [field value ...]
--   XLEN key
--   XRANGE key start end [COUNT n]       XREVRANGE key end start [COUNT n]
--   XREAD [COUNT n] STREAMS key [key ...] id [id ...]
--   XDEL key id [id ...]
--   XTRIM key MAXLEN|MINID [=|~] threshold [LIMIT count]
--   XQUEUE ADD pattern queue [NOSTORE]  XQUEUE REMOVE pattern queue
--   XQUEUE LIST
--
-- The commands come from one resp transport(). Stored in the global space
-- (the one a connection starts in, selected again with `USE 0`; the named
-- space `default` is a different one), they answer by their bare names on
-- every connection, which is how a Redis client reaches them. A stream lives
-- in the space the connection has selected with USE, the way a Redis key
-- lives in its database.
--
-- XQUEUE ADD forwards every entry later added to a matching stream to a
-- barch queue, as JSON: {"stream": key, "id": id, "fields": [f, v, ...]}.
-- A pattern is a stream name, or a prefix ending in "*". The queue has to be
-- declared under configuration:queues/ first; XADD fails while it is not.
-- With NOSTORE the stream keeps only its last id, so a matching entry goes
-- to the queue alone, unless another matching forward stores it.
--
-- Keys, all under "xs\1":
--
--   xs\1<key>\1m              the stream's state: last id, length, added
--   xs\1<key>\1e<ms><seq>     one entry; ms and seq as 14 hex digits each,
--                             so key order is id order
--   xs\1\1q                   the XQUEUE forwards
--
-- An entry's value is its fields and values, each as string.pack(">s4").

local ROOT = "xs\1"
local FORWARDS = ROOT .. "\1q"
-- ids are Luau numbers, so each half is a whole number below 2^53
local MAX_PART = 9007199254740991
local PAGE = 10000

local function fail(why)
    error(why, 0)
end

local function meta_key(key)
    return ROOT .. key .. "\1m"
end

local function entries_of(key)
    local lo = ROOT .. key .. "\1e"
    return lo, ROOT .. key .. "\1f"
end

local function entry_key(key, ms, seq)
    return ROOT .. key .. "\1e" .. string.format("%014x%014x", ms, seq)
end

local function id_of(entry)
    local hex = string.sub(entry, -28)
    return tonumber(string.sub(hex, 1, 14), 16), tonumber(string.sub(hex, 15), 16)
end

local function id_text(ms, seq)
    return string.format("%d-%d", ms, seq)
end

local function check_key(key)
    if string.find(key, "\1", 1, true) then
        fail("ERR a stream name can't hold the byte \\x01")
    end
end

local function read_meta(key)
    local raw = barch.store.get(meta_key(key))
    if raw == nil then return nil end
    local ms, seq, length, added = string.unpack("<dddd", raw)
    return { ms = ms, seq = seq, length = length, added = added }
end

local function write_meta(key, m)
    barch.store.set(meta_key(key), string.pack("<dddd", m.ms, m.seq, m.length, m.added))
end

local function encode_fields(fields)
    local parts = table.create(#fields)
    for i, f in fields do
        parts[i] = string.pack(">s4", f)
    end
    return table.concat(parts)
end

local function decode_fields(raw)
    local out = {}
    local at = 1
    while at <= #raw do
        local f
        f, at = string.unpack(">s4", raw, at)
        out[#out + 1] = f
    end
    return out
end

local function whole(text, what)
    local n = tonumber(text)
    if n == nil or n < 0 or n ~= math.floor(n) or n > MAX_PART or not string.match(text, "^%d+$") then
        fail("ERR " .. what)
    end
    return n
end

-- "ms-seq" or "ms", with seq taken as `missing` when it is left out
local function parse_id(text, missing)
    local ms, seq = string.match(text, "^(%d+)%-(%d+)$")
    if ms == nil then
        ms = string.match(text, "^(%d+)$")
        if ms == nil then
            fail("ERR Invalid stream ID specified as stream command argument")
        end
        return whole(ms, "Invalid stream ID specified as stream command argument"), missing
    end
    local bad = "Invalid stream ID specified as stream command argument"
    return whole(ms, bad), whole(seq, bad)
end

local function next_id(ms, seq)
    if seq < MAX_PART then return ms, seq + 1 end
    if ms < MAX_PART then return ms + 1, 0 end
    return nil
end

-- the clock, from barch.time() where this barchd has it, and from a key's
-- expiry where it doesn't
local function now_ms()
    if barch.time then
        return math.floor(barch.time())
    end
    barch.call("SET", ROOT .. "\1clock", "1", "PX", "60000")
    return integer.tonumber(barch.call("PEXPIRETIME", ROOT .. "\1clock")) - 60000
end

local function upper(s)
    return string.upper(s or "")
end

-- MAXLEN|MINID [=|~] threshold [LIMIT count], from a[i]; nil when a[i]
-- starts something else
local function parse_trim(a, i)
    local kind = upper(a[i])
    if kind ~= "MAXLEN" and kind ~= "MINID" then return nil, i end
    i += 1
    local approx = false
    if a[i] == "=" or a[i] == "~" then
        approx = a[i] == "~"
        i += 1
    end
    if a[i] == nil then fail("ERR syntax error") end
    local trim = { kind = kind }
    if kind == "MAXLEN" then
        trim.maxlen = whole(a[i], "The MAXLEN argument must be >= 0.")
    else
        trim.ms, trim.seq = parse_id(a[i], 0)
    end
    i += 1
    if upper(a[i]) == "LIMIT" then
        if not approx then
            fail("ERR syntax error, LIMIT cannot be used without the special ~ option")
        end
        if a[i + 1] == nil then fail("ERR syntax error") end
        trim.limit = whole(a[i + 1], "The LIMIT argument must be >= 0.")
        i += 2
    end
    return trim, i
end

-- removes entries from the front as trim says; inside the locked region
local function apply_trim(key, m, trim)
    local lo, hi = entries_of(key)
    local budget = trim.limit
    if budget == 0 then budget = nil end
    local removed = 0
    while true do
        local want
        if trim.kind == "MAXLEN" then
            want = m.length - trim.maxlen
        else
            want = m.length
        end
        if budget then want = math.min(want, budget - removed) end
        if want <= 0 then break end
        local keys = barch.store.range(lo, hi, math.min(want, PAGE))
        if #keys == 0 then break end
        local stop = false
        for _, k in keys do
            if trim.kind == "MINID" then
                local ms, seq = id_of(k)
                if ms > trim.ms or (ms == trim.ms and seq >= trim.seq) then
                    stop = true
                    break
                end
            end
            barch.store.remove(k)
            removed += 1
            m.length -= 1
        end
        if stop then break end
    end
    return removed
end

local function load_forwards()
    local raw = barch.store.get(FORWARDS)
    if raw == nil then return {} end
    local list = decode_fields(raw)
    local out = {}
    for i = 1, #list, 3 do
        out[#out + 1] = { pattern = list[i], queue = list[i + 1], nostore = list[i + 2] == "NOSTORE" }
    end
    return out
end

local function save_forwards(list)
    if #list == 0 then
        barch.store.remove(FORWARDS)
        return
    end
    local flat = {}
    for _, f in list do
        flat[#flat + 1] = f.pattern
        flat[#flat + 1] = f.queue
        flat[#flat + 1] = if f.nostore then "NOSTORE" else ""
    end
    barch.store.set(FORWARDS, encode_fields(flat))
end

local function matches(pattern, key)
    if string.sub(pattern, -1) == "*" then
        local prefix = string.sub(pattern, 1, -2)
        return string.sub(key, 1, #prefix) == prefix
    end
    return pattern == key
end

-- the queues an entry of key goes to, each named once, and whether the
-- stream keeps the entry: it does unless every matching forward is NOSTORE
local function queues_for(key)
    local out, seen = {}, {}
    local keep = nil
    for _, f in load_forwards() do
        if matches(f.pattern, key) then
            keep = keep or not f.nostore
            if not seen[f.queue] then
                seen[f.queue] = true
                out[#out + 1] = f.queue
            end
        end
    end
    return out, keep ~= false
end

-- runs fn with the whole space locked, and raises what it returns as err
local function locked(fn)
    local result, why
    barch.store.locked(function()
        result, why = fn()
    end)
    if why then fail(why) end
    return result
end

local function xadd(...)
    local a = { ... }
    local key = a[1]
    if key == nil then fail("ERR wrong number of arguments for 'xadd' command") end
    check_key(key)
    local i = 2
    local nomk, trim = false, nil
    while true do
        local w = upper(a[i])
        if w == "NOMKSTREAM" then
            nomk = true
            i += 1
        elseif w == "MAXLEN" or w == "MINID" then
            trim, i = parse_trim(a, i)
        else
            break
        end
    end
    local id = a[i]
    if id == nil then fail("ERR wrong number of arguments for 'xadd' command") end
    local fields = table.move(a, i + 1, #a, 1, {})
    if #fields == 0 or #fields % 2 ~= 0 then
        fail("ERR wrong number of arguments for 'xadd' command")
    end

    -- what the id asks for: auto, a given ms with its seq to pick, or both
    local want_ms, want_seq
    if id ~= "*" then
        local ms_text = string.match(id, "^(%d+)%-%*$")
        if ms_text then
            want_ms = whole(ms_text, "Invalid stream ID specified as stream command argument")
        else
            want_ms, want_seq = parse_id(id, 0)
            if want_ms == 0 and want_seq == 0 then
                fail("ERR The ID specified in XADD must be greater than 0-0")
            end
        end
    end

    -- found before the lock: barch.time may need barch.call, and both the
    -- forwards and their JSON are checked before anything is written
    local now = now_ms()
    local queues, keep = queues_for(key)
    local head, tail
    if #queues > 0 then
        head = '{"stream":' .. simdjson.encode(key) .. ',"id":"'
        tail = '","fields":' .. simdjson.encode(fields) .. "}"
    end
    local value = encode_fields(fields)

    local added = locked(function()
        local m = read_meta(key)
        if m == nil then
            if nomk then return nil end
            m = { ms = 0, seq = 0, length = 0, added = 0 }
        end
        local ms, seq
        if want_ms == nil then
            if now > m.ms then
                ms, seq = now, 0
            else
                ms, seq = next_id(m.ms, m.seq)
            end
        elseif want_seq == nil then
            if want_ms > m.ms then
                ms, seq = want_ms, 0
            elseif want_ms == m.ms and m.seq < MAX_PART then
                ms, seq = want_ms, m.seq + 1
            end
        elseif want_ms > m.ms or (want_ms == m.ms and want_seq > m.seq) then
            ms, seq = want_ms, want_seq
        end
        if ms == nil or (m.added > 0 and ms == m.ms and seq == m.seq) then
            return nil, "ERR The ID specified in XADD is equal or smaller than the target stream top item"
        end
        if keep then
            barch.store.set(entry_key(key, ms, seq), value)
            m.length += 1
        end
        m.ms, m.seq = ms, seq
        m.added += 1
        if trim then apply_trim(key, m, trim) end
        write_meta(key, m)
        return id_text(ms, seq)
    end)
    if added == nil then return nil end

    -- the id is taken; a queue that refuses the entry fails the call, so the
    -- producer sends it again
    for _, q in queues do
        local ok, why = pcall(barch.queue, q, head .. added .. tail)
        if not ok then
            local did = if keep then "stored " .. added .. " in " .. key
                else "gave " .. added .. " to " .. key .. " without storing it"
            fail("ERR XADD " .. did .. " but queue " .. q .. " refused it: " .. tostring(why))
        end
    end
    return added
end

local function xlen(key)
    local m = read_meta(key)
    return if m then m.length else 0
end

-- a range bound: "-", "+", "(" exclusive, and a missing seq as lo or hi
local function bound(text, is_start)
    if text == "-" then return 0, 0 end
    if text == "+" then return MAX_PART, MAX_PART end
    local exclusive = string.sub(text, 1, 1) == "("
    if exclusive then text = string.sub(text, 2) end
    local ms, seq = parse_id(text, if is_start then 0 else MAX_PART)
    if exclusive then
        if is_start then
            ms, seq = next_id(ms, seq)
        elseif seq > 0 then
            seq -= 1
        elseif ms > 0 then
            ms, seq = ms - 1, MAX_PART
        else
            ms = nil
        end
        if ms == nil then return nil end
    end
    return ms, seq
end

local function entry_reply(k, raw)
    local ms, seq = id_of(k)
    return { id_text(ms, seq), decode_fields(raw) }
end

local function parse_count(a, i, name)
    if a[i] == nil then return nil end
    if upper(a[i]) ~= "COUNT" or a[i + 1] == nil or a[i + 2] ~= nil then
        fail("ERR syntax error")
    end
    local n = tonumber(a[i + 1])
    if n == nil or n ~= math.floor(n) then
        fail("ERR value is not an integer or out of range")
    end
    return n
end

-- entries with ids in [lo, hi], oldest first, at most count of them
local function forward(key, lo_ms, lo_seq, hi_ms, hi_seq, count)
    local out = {}
    local lo = entry_key(key, lo_ms, lo_seq)
    local hi = entry_key(key, hi_ms, hi_seq) .. "\1"
    while count == nil or #out < count do
        local want = if count then math.min(count - #out, PAGE) else PAGE
        local keys, values = barch.store.rangeValues(lo, hi, want)
        for j, k in keys do
            out[#out + 1] = entry_reply(k, values[j])
        end
        if #keys < want then break end
        lo = keys[#keys] .. "\1"
    end
    return out
end

local function xrange(key, start, stop, ...)
    local count = parse_count({ ... }, 1)
    local lo_ms, lo_seq = bound(start, true)
    local hi_ms, hi_seq = bound(stop, false)
    if lo_ms == nil or hi_ms == nil or (count and count <= 0) then return {} end
    if lo_ms > hi_ms or (lo_ms == hi_ms and lo_seq > hi_seq) then return {} end
    return forward(key, lo_ms, lo_seq, hi_ms, hi_seq, count)
end

local function xrevrange(key, stop, start, ...)
    local count = parse_count({ ... }, 1)
    local lo_ms, lo_seq = bound(start, true)
    local hi_ms, hi_seq = bound(stop, false)
    if lo_ms == nil or hi_ms == nil or (count and count <= 0) then return {} end
    if lo_ms > hi_ms or (lo_ms == hi_ms and lo_seq > hi_seq) then return {} end
    local lo = entry_key(key, lo_ms, lo_seq)
    local hi = entry_key(key, hi_ms, hi_seq) .. "\1"
    local out = {}
    -- walks back from the end by offset, a page at a time
    local left = barch.store.count(lo, hi)
    while left > 0 and (count == nil or #out < count) do
        local want = math.min(left, PAGE)
        if count then want = math.min(want, count - #out) end
        local keys, values = barch.store.rangeValues(lo, hi, want, left - want)
        for j = #keys, 1, -1 do
            out[#out + 1] = entry_reply(keys[j], values[j])
        end
        left -= want
    end
    return out
end

local function xread(...)
    local a = { ... }
    local i, count = 1, nil
    while a[i] ~= nil and upper(a[i]) ~= "STREAMS" do
        local w = upper(a[i])
        if w == "COUNT" and a[i + 1] ~= nil then
            count = tonumber(a[i + 1])
            if count == nil or count ~= math.floor(count) then
                fail("ERR value is not an integer or out of range")
            end
            i += 2
        elseif w == "BLOCK" then
            fail("ERR XREAD BLOCK is not supported: read without BLOCK, or use XQUEUE to have each entry pushed to a queue")
        else
            fail("ERR syntax error")
        end
    end
    local rest = #a - i
    if a[i] == nil or rest == 0 or rest % 2 ~= 0 then
        fail("ERR Unbalanced 'xread' list of streams: for each stream key an ID or '$' must be specified.")
    end
    local n = rest // 2
    local out = {}
    for s = 1, n do
        local key = a[i + s]
        local after = a[i + n + s]
        local ms, seq
        if after == "$" then
            local m = read_meta(key)
            ms, seq = if m then m.ms else 0, if m then m.seq else 0
        else
            ms, seq = parse_id(after, 0)
        end
        ms, seq = next_id(ms, seq)
        if ms ~= nil and (count == nil or count > 0) then
            local got = forward(key, ms, seq, MAX_PART, MAX_PART, count)
            if #got > 0 then
                out[#out + 1] = { key, got }
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

local function xdel(key, ...)
    local ids = { ... }
    local keys = table.create(#ids)
    for j, id in ids do
        local ms, seq = parse_id(id, 0)
        keys[j] = entry_key(key, ms, seq)
    end
    return locked(function()
        local m = read_meta(key)
        if m == nil then return 0 end
        local removed = 0
        for _, k in keys do
            if barch.store.exists(k) then
                barch.store.remove(k)
                removed += 1
            end
        end
        m.length -= removed
        write_meta(key, m)
        return removed
    end)
end

local function xtrim(key, ...)
    local a = { key, ... }
    local trim, i = parse_trim(a, 2)
    if trim == nil or a[i] ~= nil then fail("ERR syntax error") end
    return locked(function()
        local m = read_meta(key)
        if m == nil then return 0 end
        local removed = apply_trim(key, m, trim)
        write_meta(key, m)
        return removed
    end)
end

local function xqueue(sub, pattern, queue, ...)
    local w = upper(sub)
    if w == "LIST" then
        if pattern ~= nil then fail("ERR XQUEUE LIST takes no arguments") end
        local out = {}
        for _, f in load_forwards() do
            out[#out + 1] = if f.nostore then { f.pattern, f.queue, "NOSTORE" } else { f.pattern, f.queue }
        end
        return out
    end
    local option = ...
    local nostore = w == "ADD" and option ~= nil and upper(option) == "NOSTORE"
    if (w ~= "ADD" and w ~= "REMOVE") or queue == nil
        or select("#", ...) > (if nostore then 1 else 0) then
        fail("ERR XQUEUE takes ADD pattern queue [NOSTORE], REMOVE pattern queue, or LIST")
    end
    check_key(pattern)
    return locked(function()
        local list = load_forwards()
        for j, f in list do
            if f.pattern == pattern and f.queue == queue then
                if w == "REMOVE" then
                    table.remove(list, j)
                    save_forwards(list)
                    return 1
                end
                if f.nostore == nostore then return 0 end
                f.nostore = nostore
                save_forwards(list)
                return 1
            end
        end
        if w == "REMOVE" then return 0 end
        list[#list + 1] = { pattern = pattern, queue = queue, nostore = nostore }
        save_forwards(list)
        return 1
    end)
end

-- each method answers an error reply rather than raising, so the client
-- sees the message without a FUNCTION prefix
local function replying(fn)
    return function(...)
        local ok, result = pcall(fn, ...)
        if ok then return result end
        return { err = tostring(result) }
    end
end

function call()
    return {
        "XADD key [NOMKSTREAM] [MAXLEN|MINID [=|~] threshold [LIMIT count]] *|id field value [field value ...]",
        "XLEN key",
        "XRANGE key start end [COUNT count]",
        "XREVRANGE key end start [COUNT count]",
        "XREAD [COUNT count] STREAMS key [key ...] id [id ...]",
        "XDEL key id [id ...]",
        "XTRIM key MAXLEN|MINID [=|~] threshold [LIMIT count]",
        "XQUEUE ADD pattern queue [NOSTORE] | XQUEUE REMOVE pattern queue | XQUEUE LIST",
    }
end

function transport()
    return {
        kind = "resp",
        methods = {
            XADD = replying(xadd),
            XLEN = replying(xlen),
            XRANGE = replying(xrange),
            XREVRANGE = replying(xrevrange),
            XREAD = replying(xread),
            XDEL = replying(xdel),
            XTRIM = replying(xtrim),
            XQUEUE = replying(xqueue),
        },
        categories = {
            XADD = { "write", "data" },
            XLEN = { "read" },
            XRANGE = { "read" },
            XREVRANGE = { "read" },
            XREAD = { "read" },
            XDEL = { "write", "data" },
            XTRIM = { "write", "data" },
            XQUEUE = { "write", "data" },
        },
        arity = {
            XADD = -4, XLEN = 1, XRANGE = -3, XREVRANGE = -3, XREAD = -3,
            XDEL = -2, XTRIM = -3, XQUEUE = -1,
        },
    }
end
