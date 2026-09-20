-- Vector HNSW graph helpers. Required by SET and CLOSEST in this space.
--
-- The same index as examples/hnsw, but the points are nk f32 vectors instead
-- of words: distance is cosine (angular) or euclidean over decoded buffers,
-- not Levenshtein over strings. Everything else — ART candidate queues,
-- greedy descent, ef-search, neighbour caps, random levels — is the
-- example's walk unchanged.
--
-- Storage, all under vec.* keys in this space:
--   vec.count        number of points
--   vec.entry        entry point id
--   vec.M vec.efc vec.efs vec.heur   build/search params (see TUNE)
--   vec.metric       "cosine" or "euclidean". Switchable without a rebuild:
--                    distances are computed from the stored buffers on the
--                    fly, so TUNE only rewrites this key.
--   vec.dim          dimensionality, fixed by the first insert
--   vec.v.<id>       f32 buffer (dim*4 bytes), the canonical point
--   vec.name.<id>    point name; vec.id.<name> is the reverse lookup
--
-- Buffers are decoded fresh on every comparison. A production version would
-- keep a per-call decode cache; this one favours code that reads like the
-- example it came from.

local PFX = "vec."

local function k_count()  return PFX .. "count" end
local function k_entry()  return PFX .. "entry" end
local function k_M()      return PFX .. "M" end
local function k_efc()    return PFX .. "efc" end
local function k_efs()    return PFX .. "efs" end
local function k_heur()   return PFX .. "heur" end
local function k_metric() return PFX .. "metric" end
local function k_dim()    return PFX .. "dim" end
local function k_vec(id)  return PFX .. "v." .. id end
local function k_name(id) return PFX .. "name." .. id end
local function k_id(name) return PFX .. "id." .. name end
local function k_level(id) return PFX .. "lv." .. id end
local function k_nbs(id, layer) return PFX .. "n." .. id .. "." .. layer end

function getn(key, default)
    local v = barch.store.get(key)
    if v == nil then return default end
    return tonumber(v) or default
end

function M()    return getn(k_M(), 16) end
function efc()  return getn(k_efc(), 64) end
function efs()  return getn(k_efs(), 32) end
function heur() return getn(k_heur(), 0) ~= 0 end
function count() return getn(k_count(), 0) end
function dim()  return getn(k_dim(), 0) end

function metric()
    local v = barch.store.get(k_metric())
    if v == "euclidean" then return "euclidean" end
    return "cosine"
end

function entry()
    local v = barch.store.get(k_entry())
    if v == nil then return nil end
    return v
end

-- the canonical point: an nk f32 vector decoded from the stored buffer
function point_vec(id)
    local b = barch.store.get(k_vec(id))
    if b == nil then return nil end
    return nkf32vector(b)
end

function point_name(id)
    return barch.store.get(k_name(id))
end

function id_of(name)
    return barch.store.get(k_id(name))
end

function level_of(id)
    return getn(k_level(id), 0)
end

function nbs_of(id, layer)
    local s = barch.store.get(k_nbs(id, layer))
    if s == nil or s == "" then return {} end
    local out = {}
    for tok in string.gmatch(s, "%S+") do
        out[#out + 1] = tok
    end
    return out
end

function set_nbs(id, layer, ids)
    barch.store.set(k_nbs(id, layer), table.concat(ids, " "))
end

-- nk's metrics need both sides in the same resolution. Distances are
-- computed in f32 (the stored canonical kind), so a query arriving in any
-- other kind is converted first — see doc_of.
--
-- metric() reads vec.metric per call: hoisted by the caller. dist() takes
-- the metric once so the hot path (greedy/search, thousands of calls per
-- query) does no key reads at all — each barch.store.get costs an
-- instruction-slice tick and thousands of them blow the function budget
-- on a 7k-point space. Same for pq below: no store reads in the loop.
local function dist(m, a, b)
    if m == "euclidean" then
        return a:euclidean(b)
    end
    return a:cosine(b)
end

function distance(a, b)
    return dist(metric(), a, b)
end

-- ART priority queue keyed by "dist id" so equal distances still order
local function pq_key(dist, id)
    return tostring(dist) .. " " .. tostring(id)
end

local function pq_dist(key)
    return tonumber((string.match(key, "^(%S+)"))) or 0
end

function random_level(m)
    local mL = 1 / math.log(math.max(m, 2))
    local r = math.random()
    if r < 1e-12 then r = 1e-12 end
    return math.floor(-math.log(r) * mL)
end

function Mmax(layer, m)
    if layer == 0 then return m * 2 end
    return m
end

-- greedy walk on one layer: always step to a closer neighbour.
-- m is the metric, read once by the caller (see dist).
function greedy(q, start, layer, m)
    local curr = start
    local cw = point_vec(curr)
    if cw == nil then return curr end
    local cd = dist(m, q, cw)
    local moved = true
    while moved do
        moved = false
        local nbs = nbs_of(curr, layer)
        for i = 1, #nbs do
            local nb = nbs[i]
            local nw = point_vec(nb)
            if nw ~= nil then
                local d = dist(m, q, nw)
                if d < cd then
                    curr, cd, moved = nb, d, true
                end
            end
        end
    end
    return curr
end

-- ef-search on one layer. C is a min queue of candidates, W the found set.
-- returns a list of ids, closest first, at most ef of them.
-- m is the metric and ef the beam, both read once by the caller.
--
-- Expansion cap (from libspaces smallworld.lua): when a candidate is popped,
-- only its `expand` closest neighbours are considered, not the whole list.
-- Neighbour lists are insertion ordered (closest first at link time under
-- the heuristic, arbitrary otherwise), so this is exact for small expand
-- and an approximation for large lists. expand=nil means no cap (classic).
function search_layer(q, eps, ef, layer, m, expand)
    if ef < 1 then ef = 1 end
    local visited = {}
    local C = barch.art()
    local W = barch.art()

    local function consider(id)
        if visited[id] then return end
        visited[id] = true
        local w = point_vec(id)
        if w == nil then return end
        local d = dist(m, q, w)
        local far = W:max()
        if W:size() < ef or far == nil or d < pq_dist(far) then
            local pk = pq_key(d, id)
            C:set(pk, id)
            W:set(pk, id)
            if W:size() > ef then
                W:popmax()
            end
        end
    end

    for i = 1, #eps do
        consider(eps[i])
    end

    while C:size() > 0 do
        local ck, cid = C:popmin()
        if cid == nil then break end
        local far = W:max()
        if far ~= nil and pq_dist(ck) > pq_dist(far) then
            break
        end
        local nbs = nbs_of(cid, layer)
        local nn = #nbs
        if expand ~= nil and nn > expand then nn = expand end
        for i = 1, nn do
            consider(nbs[i])
        end
    end

    local out = {}
    while W:size() > 0 do
        local _, id = W:popmin()
        out[#out + 1] = id
    end
    return out
end

function select_simple(ids, m)
    local out = {}
    local n = m
    if n > #ids then n = #ids end
    for i = 1, n do
        out[i] = ids[i]
    end
    return out
end

-- keep neighbours that are not already closer to each other than to the query.
-- m is the neighbour cap, mm the metric: both read once by the caller.
function select_heuristic(q, ids, m, mm)
    local selected = {}
    for i = 1, #ids do
        if #selected >= m then break end
        local c = ids[i]
        local cv = point_vec(c)
        if cv == nil then break end
        local dq = dist(mm, q, cv)
        local keep = true
        for j = 1, #selected do
            local sw = point_vec(selected[j])
            if sw ~= nil and dist(mm, cv, sw) < dq then
                keep = false
                break
            end
        end
        if keep then
            selected[#selected + 1] = c
        end
    end
    if #selected < m then
        local have = {}
        for i = 1, #selected do have[selected[i]] = true end
        for i = 1, #ids do
            if #selected >= m then break end
            if not have[ids[i]] then
                selected[#selected + 1] = ids[i]
            end
        end
    end
    return selected
end

function prune(id, layer, cap, mm)
    local nbs = nbs_of(id, layer)
    if #nbs <= cap then return end
    local w = point_vec(id)
    if w == nil then return end
    local Q = barch.art()
    for i = 1, #nbs do
        local nb = nbs[i]
        local nw = point_vec(nb)
        if nw ~= nil then
            local d = dist(mm or metric(), w, nw)
            Q:set(pq_key(d, nb), nb)
        end
    end
    local keep = {}
    for i = 1, cap do
        if Q:size() == 0 then break end
        local _, nb = Q:popmin()
        keep[#keep + 1] = nb
    end
    set_nbs(id, layer, keep)
end

local function has(list, id)
    for i = 1, #list do
        if list[i] == id then return true end
    end
    return false
end

function link(a, b, layer, cap, mm)
    local na = nbs_of(a, layer)
    if not has(na, b) then
        na[#na + 1] = b
        set_nbs(a, layer, na)
        prune(a, layer, cap, mm)
    end
    local nb = nbs_of(b, layer)
    if not has(nb, a) then
        nb[#nb + 1] = a
        set_nbs(b, layer, nb)
        prune(b, layer, cap, mm)
    end
end

-- insert a canonical f32 vector under name. Returns id, true on a new point,
-- id, false when the name is already there, nil, err on a dimension mismatch.
function insert(name, f32vec)
    local exists = id_of(name)
    if exists ~= nil then
        return exists, false
    end
    local n = #f32vec
    local d = dim()
    if d == 0 then
        barch.store.set(k_dim(), tostring(n))
    elseif n ~= d then
        return nil, "dimension mismatch: this space holds " .. d .. ", got " .. n
    end
    local m = M()
    local mm = metric()
    local efc_now = efc()
    local use_heur = heur()
    local build_expand = build_expand_cap()
    local count_now = count() + 1
    local id = tostring(count_now)
    local lvl = random_level(m)
    barch.store.set(k_count(), tostring(count_now))
    barch.store.set(k_vec(id), f32vec:buffer())
    barch.store.set(k_name(id), name)
    barch.store.set(k_id(name), id)
    barch.store.set(k_level(id), tostring(lvl))

    local ep = entry()
    if ep == nil then
        barch.store.set(k_entry(), id)
        return id, true
    end

    local ep_lvl = level_of(ep)
    local curr = ep
    if ep_lvl > lvl then
        for layer = ep_lvl, lvl + 1, -1 do
            curr = greedy(f32vec, curr, layer, mm)
        end
    end

    local top = lvl
    if ep_lvl < top then top = ep_lvl end
    for layer = top, 0, -1 do
        -- build expansion cap: only the closest neighbours per pop during
        -- insert beam search (same cap as query time when set). Narrows the
        -- candidate set edges are chosen from, so it shapes the graph.
        local found = search_layer(f32vec, {curr}, efc_now, layer, mm, build_expand)
        local pick
        if use_heur then
            pick = select_heuristic(f32vec, found, m, mm)
        else
            pick = select_simple(found, m)
        end
        local cap = Mmax(layer, m)
        for i = 1, #pick do
            link(id, pick[i], layer, cap, mm)
        end
        if #found > 0 then
            curr = found[1]
        end
    end

    if lvl > ep_lvl then
        barch.store.set(k_entry(), id)
    end
    return id, true
end

local function k_expand() return PFX .. "expand" end
local function k_build_expand() return PFX .. "build_expand" end

-- expansion cap for query-time search_layer: neighbours considered per pop.
-- 0/absent = no cap (classic HNSW). Tunable without rebuild; only reads
-- once per closest() call.
function expand_cap()
    local v = barch.store.get(k_expand())
    if v == nil then return nil end
    local n = tonumber(v) or 0
    if n < 1 then return nil end
    return math.floor(n)
end

-- build expansion cap for insert-time beam search. Separate key because it
-- shapes the stored graph (only affects inserts after it is set); read once
-- per insert. 0/absent = no cap.
function build_expand_cap()
    local v = barch.store.get(k_build_expand())
    if v == nil then return nil end
    local n = tonumber(v) or 0
    if n < 1 then return nil end
    return math.floor(n)
end

-- k nearest to the query vector, as {name, distance} pairs, closest first.
-- Reads metric and efSearch once: everything below is pure compute.
function closest(q, k)
    if k == nil or k < 1 then k = 1 end
    local m = metric()
    local beam = math.max(efs(), k)
    local ep = entry()
    if ep == nil then return {} end
    local curr = ep
    local top = level_of(ep)
    if top > 0 then
        for layer = top, 1, -1 do
            curr = greedy(q, curr, layer, m)
        end
    end
    local found = search_layer(q, {curr}, beam, 0, m, expand_cap())
    local out = {}
    local n = k
    if n > #found then n = #found end
    for i = 1, n do
        local id = found[i]
        local w = point_vec(id)
        if w ~= nil then
            out[i] = {point_name(id), dist(m, q, w)}
        end
    end
    return out
end

function apply_tune(preset, m, construction, search, use_heur, use_metric, use_expand, use_build_expand)
    if preset == "fast" then
        m, construction, search, use_heur = 8, 16, 8, 0
    elseif preset == "default" then
        m, construction, search, use_heur = 16, 64, 32, 0
    elseif preset == "accurate" then
        m, construction, search, use_heur = 32, 200, 100, 1
    end
    if use_metric ~= nil then
        if use_metric ~= "cosine" and use_metric ~= "euclidean" then
            return "metric is cosine or euclidean"
        end
    end
    if m ~= nil then barch.store.set(k_M(), tostring(m)) end
    if construction ~= nil then barch.store.set(k_efc(), tostring(construction)) end
    if search ~= nil then barch.store.set(k_efs(), tostring(search)) end
    if use_heur ~= nil then barch.store.set(k_heur(), tostring(use_heur)) end
    if use_metric ~= nil then barch.store.set(k_metric(), use_metric) end
    if use_expand ~= nil then barch.store.set(k_expand(), tostring(use_expand)) end
    if use_build_expand ~= nil then barch.store.set(k_build_expand(), tostring(use_build_expand)) end
    return nil
end

-- count, M, efConstruction, efSearch, heuristic, metric, dim, entry,
-- expand, build_expand
function stats()
    return {
        count(),
        M(),
        efc(),
        efs(),
        heur() and 1 or 0,
        metric(),
        dim(),
        entry() or "",
        expand_cap() or 0,
        build_expand_cap() or 0,
    }
end

function call(...)
    return "vgraph"
end
