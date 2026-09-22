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
    -- a number, like every id inside the graph: the packed neighbour lists
    -- give numbers back, and the two have to compare equal
    return tonumber(v)
end

-- How many bytes one stored point takes as f16: dim * 2, set at the top of
-- insert and closest. Not worked out once and kept, because one session's
-- module cache can serve more than one space.
local half_bytes = 0

-- The canonical point, as an nk f16 vector.
--
-- Stored as f16: half the bytes to keep, half to read back, and the
-- distance kernels have their own f16 path. What the wire carries is still
-- f32 - only the graph's own copy is half. A graph written before this
-- holds f32 buffers, which are twice the bytes for the same number of
-- components, so they are converted on the way in and everything in the
-- graph is still compared in one resolution.
function point_vec(id)
    local b = barch.store.get(k_vec(id))
    if b == nil then return nil end
    if half_bytes == 0 then
        half_bytes = dim() * 2
    end
    if #b == half_bytes then
        return nkf16vector(b)
    end
    return nkf16vector(nkf32vector(b))
end

function point_name(id)
    return barch.store.get(k_name(id))
end

function id_of(name)
    local v = barch.store.get(k_id(name))
    if v == nil then return nil end
    return tonumber(v)
end

function level_of(id)
    return getn(k_level(id), 0)
end

-- Neighbour lists are packed ids, not text.
--
-- Every node the search visits reads its list. Splitting a space separated
-- one with string.gmatch measured 1.6 us against 0.07 to write a packed one
-- and 0.46 to read it back, which is most of what an insert spends outside
-- the arithmetic. The first byte says which it is: a packed list starts
-- with \1 and a text one starts with a digit, so a graph written before
-- this still reads, and rewrites itself as its neighbours are relinked.
local NB_PACKED = "\1"

function nbs_of(id, layer)
    local s = barch.store.get(k_nbs(id, layer))
    if s == nil or s == "" then return {} end
    if string.sub(s, 1, 1) ~= NB_PACKED then
        local out = {}
        for tok in string.gmatch(s, "%S+") do
            out[#out + 1] = tonumber(tok)
        end
        return out
    end
    local b = buffer.fromstring(s)
    local n = (buffer.len(b) - 1) // 4
    local out = table.create(n)
    for i = 0, n - 1 do
        out[i + 1] = buffer.readu32(b, 1 + i * 4)
    end
    return out
end

function set_nbs(id, layer, ids)
    local n = #ids
    local b = buffer.create(1 + n * 4)
    buffer.writeu8(b, 0, 1)
    for i = 1, n do
        buffer.writeu32(b, 1 + (i - 1) * 4, ids[i])
    end
    barch.store.set(k_nbs(id, layer), buffer.tostring(b))
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

-- A binary heap of (distance, id), in two plain arrays.
--
-- The search kept its queues in barch.art(), with the distance printed into
-- the key so the tree would order by it - "0.1234 87" - and read back out
-- with string.match. Measured on a queue of thirty: a set 0.68 us, a popmin
-- 1.5, plus 0.14 to build the key and 0.12 to parse it again. Per candidate
-- considered that is two to three microseconds of bookkeeping against 0.23
-- for the distance the queue is there to order. The same push and pop on a
-- heap of numbers is 0.15 us together, and it halved both the query and the
-- build.
--
-- Only a min heap is written. W wants its *worst* element rather than its
-- best, so it stores distances negated and the same heap answers the other
-- question - the one place that reads W.d[1] negates it back. Equal
-- distances come out in no particular order, where the tree used to order
-- them by the id's printed form.
local function heap_new()
    return { d = {}, id = {}, n = 0 }
end

local function heap_push(h, d, id)
    local hd, hi = h.d, h.id
    local c = h.n + 1
    h.n = c
    -- sift the hole up rather than swapping pairs all the way
    while c > 1 do
        local p = c // 2
        if hd[p] <= d then break end
        hd[c], hi[c] = hd[p], hi[p]
        c = p
    end
    hd[c], hi[c] = d, id
end

local function heap_pop(h)
    local n = h.n
    if n == 0 then return nil, nil end
    local hd, hi = h.d, h.id
    local topd, topid = hd[1], hi[1]
    local ld, lid = hd[n], hi[n]
    hd[n], hi[n] = nil, nil
    n -= 1
    h.n = n
    if n > 0 then
        local p = 1
        while true do
            local l = p * 2
            if l > n then break end
            if l < n and hd[l + 1] < hd[l] then l += 1 end
            if hd[l] >= ld then break end
            hd[p], hi[p] = hd[l], hi[l]
            p = l
        end
        hd[p], hi[p] = ld, lid
    end
    return topd, topid
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
    -- C is what to look at next, nearest first. W is the ef best found so
    -- far, and it is asked for its worst, so it holds negated distances.
    local C = heap_new()
    local W = heap_new()

    local function consider(id)
        if visited[id] then return end
        visited[id] = true
        local w = point_vec(id)
        if w == nil then return end
        local d = dist(m, q, w)
        -- W.n < ef is checked first, so W.d[1] is never read while W is empty
        if W.n < ef or d < -W.d[1] then
            heap_push(C, d, id)
            heap_push(W, -d, id)
            if W.n > ef then
                heap_pop(W)
            end
        end
    end

    for i = 1, #eps do
        consider(eps[i])
    end

    while C.n > 0 do
        local cd, cid = heap_pop(C)
        if cid == nil then break end
        if W.n > 0 and cd > -W.d[1] then
            break
        end
        local nbs = nbs_of(cid, layer)
        local nn = #nbs
        if expand ~= nil and nn > expand then nn = expand end
        for i = 1, nn do
            consider(nbs[i])
        end
    end

    -- W comes out worst first, so fill the answer from the back
    local k = W.n
    local out = table.create(k)
    while W.n > 0 do
        local _, id = heap_pop(W)
        out[k] = id
        k -= 1
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
    local Q = heap_new()
    local mmm = mm or metric()
    for i = 1, #nbs do
        local nb = nbs[i]
        local nw = point_vec(nb)
        if nw ~= nil then
            heap_push(Q, dist(mmm, w, nw), nb)
        end
    end
    local keep = {}
    for i = 1, cap do
        if Q.n == 0 then break end
        local _, nb = heap_pop(Q)
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
    local id = count_now
    local lvl = random_level(m)
    half_bytes = n * 2
    local qvec = nkf16vector(f32vec)
    barch.store.set(k_count(), tostring(count_now))
    barch.store.set(k_vec(id), qvec:buffer())
    barch.store.set(k_name(id), name)
    barch.store.set(k_id(name), tostring(id))
    barch.store.set(k_level(id), tostring(lvl))

    local ep = entry()
    if ep == nil then
        barch.store.set(k_entry(), tostring(id))
        return id, true
    end

    local ep_lvl = level_of(ep)
    local curr = ep
    if ep_lvl > lvl then
        for layer = ep_lvl, lvl + 1, -1 do
            curr = greedy(qvec, curr, layer, mm)
        end
    end

    local top = lvl
    if ep_lvl < top then top = ep_lvl end
    for layer = top, 0, -1 do
        -- build expansion cap: only the closest neighbours per pop during
        -- insert beam search (same cap as query time when set). Narrows the
        -- candidate set edges are chosen from, so it shapes the graph.
        local found = search_layer(qvec, {curr}, efc_now, layer, mm, build_expand)
        local pick
        if use_heur then
            pick = select_heuristic(qvec, found, m, mm)
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
        barch.store.set(k_entry(), tostring(id))
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
    -- the graph compares in f16, so the query joins it there
    half_bytes = dim() * 2
    q = nkf16vector(q)
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
    -- the entry point goes out as text, the way it always has: ids are
    -- numbers inside the graph now, and PARAMS is a client-facing answer
    local e = entry()
    return {
        count(),
        M(),
        efc(),
        efs(),
        heur() and 1 or 0,
        metric(),
        dim(),
        e ~= nil and tostring(e) or "",
        expand_cap() or 0,
        build_expand_cap() or 0,
    }
end

function call(...)
    return "vgraph"
end
