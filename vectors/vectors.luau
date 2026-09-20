-- The vector commands, all from one key.
--
-- The same shape as examples/hnsw: one function key with a resp transport(),
-- SET and TUNE writing (@write @data) and CLOSEST and PARAMS reading. The
-- points are nk f32 vectors built from the arguments, and distance is cosine
-- (angular) or euclidean over those — switchable with TUNE without a rebuild.
--
-- Storage is vgraph.luau's business (vec.* keys); this key only parses
-- arguments and declares the commands. That module has to be stored first.
--
--   vectors.SET <name> <buffer> (dotted: the stored function, runs where
--     USE selected; the buffer is ONE arg, packed f32, dim*4 bytes)
--   vectors.CLOSEST <buffer> [k] (same buffer; k a separate bare integer)
--   vectors.TUNE [fast|default|accurate] [metric cosine|euclidean]
--                [M efConstruction efSearch [heuristic [metric]]]
--   vectors.PARAMS
--
-- NOTE on the call form: the space name is lowercase, and so is the
-- command. `vectors.SET` (dotted, runs where USE selected) is the stored
-- function; `vectors:SET` (colon) is the builtin SET writing a plain key.
-- The README example for hnsw uses uppercase because that space is HNSW.
--
-- A single comma/space/bracket string ("0,1", "[0, 1]", "1 2") also parses,
-- but only for small vectors (console use): a 384-float comma string is ~8
-- kB of text, and the wire form is the packed buffer — see below.

local g = require("vgraph")

-- Args are always (name, buffer): the vector travels as ONE argument, a
-- packed f32 buffer (dim*4 bytes) built client-side, e.g. Python
-- struct.pack('<384f', *vec). Text floats ("0.1") also parse but are only
-- for the console and tiny vectors — 384 of them is ~8 kB of text and, more
-- importantly, the colon form `vectors:SET` is parsed by the builtin SET
-- first, which treats arg 3+ as EX/NX/GET options: more than (name, value)
-- is a syntax error before the stored function is ever reached. The dotted
-- form `vectors.SET` has no such ceiling but keep one shape everywhere.
--
-- CALL FORMS, and they are not interchangeable:
--   vectors.SET name <buffer>   dotted: the stored function, runs against
--                               the CURRENT space (USE selects the graph)
--   vectors:SET key value       colon: the builtin SET in vectors — writes
--                               a plain key, never touches the graph
--   SET key value               bare after USE vectors: builtin, like colon
-- The hnsw README uses uppercase because that space is HNSW; this space is
-- lowercase vectors and the dotted half is case-sensitive.
--
-- CLOSEST takes (buffer, [k]) the same way. A stored buffer is dim*4 bytes,
-- inside the 512 kB key limit up to 131072 dimensions. nk converts any
-- float kind to canonical f32, so the space holds one resolution while the
-- door takes all four.

-- split one legacy single-string vector argument into components: commas,
-- brackets and any whitespace are all separators, so "0,1", "[0, 1]" and
-- "0 1" all work. Only for small vectors — see the note at the top.
local function components(text)
    local out = {}
    local cleaned = string.gsub(string.gsub(text, "[%[%],]", " "), "%s+", " ")
    for tok in string.gmatch(cleaned, "%S+") do
        out[#out + 1] = tok
    end
    return out
end

-- a packed f32 buffer (dim*4 bytes) into an nk f32 vector. nk decodes any
-- float kind, so f16/bf16/f64 buffers land as f32 too; a short buffer whose
-- length is not a multiple of 4 raises inside nkf32vector and is reported.
local function buffer_vector(buf)
    local ok, vec = pcall(nkf32vector, buf)
    if not ok or vec == nil then
        return nil, "not an f32 buffer (" .. #buf .. " bytes)"
    end
    if #vec == 0 then
        return nil, "vector has no components"
    end
    return vec, nil
end

-- a legacy single-string vector into an nk f32 vector. Parses each
-- component through tonumber, so "1e3", ".5" and "-2" all work; rejects
-- empties and NaN.
local function parse_vector(text, what)
    local parts = components(text)
    if #parts == 0 then
        return nil, (what or "vector") .. " has no components"
    end
    local nums = {}
    for i = 1, #parts do
        local n = tonumber(parts[i])
        if n == nil or n ~= n then
            return nil, "not a number: " .. parts[i]
        end
        nums[i] = n
    end
    return nkf32vector(nums), nil
end

-- Insert. This does not overload the builtin SET: vectors:SET a b is still
-- an ordinary SET in vectors writing key a, and vectors.SET builds the
-- graph in whatever space USE selected.
function cmd_set(name, buf)
    if name == nil or name == "" then
        return {err = "vectors.SET <name> <buffer> needs a name and a packed f32 buffer"}
    end
    if buf == nil or buf == "" then
        return {err = "vectors.SET <name> <buffer> needs a name and a packed f32 buffer"}
    end
    -- the buffer first: an f32 string decodes directly. Anything else falls
    -- back to the legacy text parse (comma/space/bracket floats, tiny only).
    local vec, why = buffer_vector(buf)
    if vec == nil then
        vec, why = parse_vector(buf, "vector")
    end
    if vec == nil then
        return {err = why}
    end
    local id, added_or_err
    -- the whole-space lock: routing by key ("vec.count") can land on a
    -- different shard than the vec.v.<id> writes inside g.insert, and one
    -- shard held + another touched is refused. No key = whole space.
    barch.store.locked(function()
        id, added_or_err = g.insert(name, vec)
    end)
    if id == nil then
        return {err = added_or_err or "could not insert"}
    end
    if added_or_err then
        return {"OK", id}
    end
    return {"exists", id}
end

-- CLOSEST <buffer> [k]. Same packed buffer as SET; k is a separate bare
-- integer arg. One argument answers the nearest point's name; with k, a
-- flat list of name, distance, ...
function cmd_closest(buf, karg)
    if buf == nil or buf == "" then
        return {err = "vectors.CLOSEST <buffer> [k] needs a packed f32 buffer"}
    end
    local k = 1
    if karg ~= nil then
        if not string.find(tostring(karg), "^[0-9]+$") then
            return {err = "k is a bare integer"}
        end
        k = math.floor(tonumber(karg))
        if k < 1 then
            return {err = "k is at least 1"}
        end
    end
    local q, why = buffer_vector(buf)
    if q == nil then
        q, why = parse_vector(buf, "query")
    end
    if q == nil then
        return {err = why}
    end
    local d = g.dim()
    if d ~= 0 and #q ~= d then
        return {err = "dimension mismatch: this space holds " .. d .. ", got " .. #q}
    end
    local hits = g.closest(q, k)
    if #hits == 0 then
        return nil
    end
    if k == 1 then
        return hits[1][1]
    end
    local out = {}
    for i = 1, #hits do
        out[#out + 1] = hits[i][1]
        out[#out + 1] = hits[i][2]
    end
    return out
end

-- TUNE [fast|default|accurate] [metric cosine|euclidean] [expand N]
-- TUNE [M efConstruction efSearch [heuristic [metric [expand [build_expand]]]]]
-- TUNE metric <cosine|euclidean> | TUNE expand <N|0> | TUNE build_expand <N|0>
-- No arguments reports PARAMS. efSearch is the cheap one to raise later;
-- M only shapes edges written after it, so tune before loading. expand
-- caps neighbours considered per pop at query time (0 = no cap, classic);
-- it only affects CLOSEST, never the stored graph. build_expand is the
-- same cap for insert-time beam search: it shapes the graph, so set it
-- before loading.
function cmd_tune(...)
    local a = {...}
    if #a == 0 then
        return g.stats()
    end
    local preset, m, efc, efs, heur, use_metric, use_expand, use_build_expand
    local i = 1
    local p = string.lower(a[1])
    if p == "fast" or p == "default" or p == "accurate" then
        preset = p
        i = 2
    elseif p == "metric" then
        if #a ~= 2 then
            return {err = "vectors.TUNE metric cosine|euclidean"}
        end
        local only = string.lower(a[2])
        if only ~= "cosine" and only ~= "euclidean" then
            return {err = "metric is cosine or euclidean"}
        end
        local err = g.apply_tune(nil, nil, nil, nil, nil, only)
        if err ~= nil then return {err = err} end
        return g.stats()
    elseif p == "expand" then
        if #a ~= 2 then
            return {err = "vectors.TUNE expand <N|0>"}
        end
        local n = tonumber(a[2])
        if n == nil or n < 0 then
            return {err = "expand is 0 (no cap) or a positive integer"}
        end
        local err = g.apply_tune(nil, nil, nil, nil, nil, nil, math.floor(n))
        if err ~= nil then return {err = err} end
        return g.stats()
    elseif p == "build_expand" then
        if #a ~= 2 then
            return {err = "vectors.TUNE build_expand <N|0>"}
        end
        local n = tonumber(a[2])
        if n == nil or n < 0 then
            return {err = "build_expand is 0 (no cap) or a positive integer"}
        end
        local err = g.apply_tune(nil, nil, nil, nil, nil, nil, nil, math.floor(n))
        if err ~= nil then return {err = err} end
        return g.stats()
    else
        m = tonumber(a[1])
        efc = tonumber(a[2])
        efs = tonumber(a[3])
        if m == nil then
            return {err = "vectors.TUNE fast|default|accurate, metric cosine|euclidean, expand N, build_expand N, or M efConstruction efSearch [heuristic [metric [expand [build_expand]]]]"}
        end
        i = 4
    end
    -- the tail after either head: [heuristic [metric [expand [build_expand]]]]
    -- (or any suffix starting at metric/expand)
    if a[i] ~= nil then
        local t = string.lower(a[i])
        if t == "cosine" or t == "euclidean" then
            use_metric = t
            i = i + 1
        else
            local h = tonumber(a[i])
            if h == nil or (h ~= 0 and h ~= 1) then
                return {err = "heuristic is 0 or 1"}
            end
            heur = h
            i = i + 1
            if a[i] ~= nil then
                t = string.lower(a[i])
                if t ~= "cosine" and t ~= "euclidean" then
                    return {err = "metric is cosine or euclidean"}
                end
                use_metric = t
                i = i + 1
            end
        end
        if a[i] ~= nil then
            local n = tonumber(a[i])
            if n == nil or n < 0 then
                return {err = "expand is 0 (no cap) or a positive integer"}
            end
            use_expand = math.floor(n)
            i = i + 1
        end
        if a[i] ~= nil then
            local n = tonumber(a[i])
            if n == nil or n < 0 then
                return {err = "build_expand is 0 (no cap) or a positive integer"}
            end
            use_build_expand = math.floor(n)
            i = i + 1
        end
    end
    if a[i] ~= nil then
        return {err = "vectors.TUNE takes at most M efConstruction efSearch [heuristic [metric [expand [build_expand]]]]"}
    end
    local err = g.apply_tune(preset, m, efc, efs, heur, use_metric, use_expand, use_build_expand)
    if err ~= nil then return {err = err} end
    return g.stats()
end

-- count, M, efConstruction, efSearch, heuristic, metric, dim, entry,
-- expand, build_expand
function cmd_params()
    return g.stats()
end

-- the key's own name, vectors.VECTORS, says what the key answers to.
-- FUNCTIONS COMMANDS gives the same names with the categories attached.
function call()
    return {
        "SET <name> <vector>",
        "CLOSEST <vector> [k]",
        "TUNE [fast|default|accurate | M efConstruction efSearch [heuristic [metric [expand [build_expand]]]] | metric cosine|euclidean | expand N | build_expand N]",
        "PARAMS",
    }
end

function transport()
    return {
        kind = "resp",
        methods = {
            SET = cmd_set,
            CLOSEST = cmd_closest,
            TUNE = cmd_tune,
            PARAMS = cmd_params,
        },
        categories = {
            SET = {"write", "data"},
            CLOSEST = {"read"},
            TUNE = {"write", "data"},
            PARAMS = {"read"},
        },
        -- SET name buffer, CLOSEST buffer [k]: SET is exactly 2 args;
        -- CLOSEST is 1-2, expressed as "at least 1" (TUNE/PARAMS keep 0)
        arity = {SET = 2, CLOSEST = -1, TUNE = 0, PARAMS = 0},
    }
end
