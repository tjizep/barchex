--@barch {"deadline_ms": 30000}
-- Backups of a whole key space to S3, and restores from them, through barch's
-- streaming save and load (barch.space.NAME:save / :load).
--
--   s3.BACKUP SAVE space bucket[/prefix]           the backup's name
--   s3.BACKUP LIST space bucket[/prefix]           the backups there, oldest first
--   s3.BACKUP LOAD space bucket[/prefix] [name]    puts the space back; the latest
--                                                  complete one when no name
--   s3.BACKUP DROP space bucket[/prefix] name      deletes one
--   s3.BACKUP @backup SAVE ...                     @profile first uses s3.backup.* settings
--
-- From a stored function, inside the handler:
--
--   local b = require("s3.BACKUP")
--   local name, why = b.save("orders", "my-bucket", "nightly/", { profile = "backup" })
--   local done, why = b.load("orders", "my-bucket", "nightly/", name)
--
-- A save is one moment. With no transaction open, BACKUP does BEGIN, streams the
-- space to the bucket, takes the shard count, and COMMITs - on a failure too, since
-- a ROLLBACK would undo other clients' writes - then writes the manifest. Writes
-- carry on throughout; barch keeps the BEGIN-time pages copy-on-write until the
-- COMMIT, so a slow upload of a busy space costs that much more memory. Inside your
-- own BEGIN it saves that moment and leaves the COMMIT to you.
--
-- A load is refused inside a transaction, and replaces the space a shard at a time.
-- Before it starts, the shard count is compared with the space's and every shard's
-- object is checked to be there at the size the manifest says, so a mismatch stops
-- it with the space untouched. When the backup carries a dictionary, LOAD checks it
-- the same way and sets it on the space before the shards.
--
-- In the bucket a backup is
--
--   <prefix><space>/<name>/shard-0000        one object per shard, as barch streamed it
--   <prefix><space>/<name>/dictionary.bin    the space's zstd dictionary, when it has one
--   <prefix><space>/<name>/manifest.json     written last: no manifest, no backup
--
-- A compressed key space carries its dictionary too. barch stores a compressed
-- value as zstd bytes that name the dictionary they were made with, so a restore
-- into a space that does not already hold that dictionary cannot read them. The
-- manifest names dictionary.bin and LOAD sets it on the space before the shards,
-- which is why a backup taken with compression on restores its values even on a
-- server that has never seen the dictionary. A space with compression off, or on
-- but not yet trained, has no dictionary and no dictionary.bin.
--
-- <name> is the UTC time the save started, 20260924T081500Z. A shard bigger than
-- s3.part_size (in configuration, default 8 MB, at least 5 MB) goes up as a
-- multipart upload, a part at a time, so a save holds about one part in memory.
-- A load holds a shard, because barch collects a shard whole before replacing it.
--
-- The --@barch header at the top gives a save or load 30 s of running time,
-- barch's default function_deadline_max_ms; waiting on S3 doesn't count. The whole
-- run, waits included, stops at function_wall_factor times that, 300 s by default.
-- The caps of the space the connection is in (USE) apply, so for a bigger space
-- raise <space>.function_deadline_max_ms and the header, or the wall factor.
--
-- A run stopped at the ceiling ends with FUNCTION timeout. Stopped during an
-- upload, as it nearly always is, the save still COMMITs, but it can't remove what
-- it wrote, since every request after the ceiling fails at once. Stopped while
-- Luau is running, the timeout can't be caught and the space is left in its
-- transaction, with pages copy-on-write until someone ends it. So after a timeout:
-- COMMIT in that space if it's still in a transaction (not ROLLBACK, which would
-- take back every write since the BEGIN), and DROP the unfinished backup LIST
-- shows. An abandoned multipart upload stays in the bucket; a lifecycle rule with
-- AbortIncompleteMultipartUpload clears those. Saving needs read rights in the
-- space, loading write rights.

local FORMAT = 2
local MB = 1024 * 1024
local DICT = "dictionary.bin"

local function s3() return require("s3.S3") end

local function part_size(): number
    local v = tonumber(barch.space.configuration["s3.part_size"] or "")
    if not v then return 8 * MB end
    return math.max(v, 5 * MB)
end

-- "bucket" or "bucket/some/prefix" to bucket and "some/prefix/"
local function where(location: string)
    local bucket, prefix = string.match(location or "", "^/*([^/]+)/?(.*)$")
    if not bucket then error("s3: want bucket[/prefix], got '" .. tostring(location) .. "'") end
    prefix = string.gsub(prefix or "", "^/+", "")
    if prefix ~= "" and string.sub(prefix, -1) ~= "/" then prefix ..= "/" end
    return bucket, prefix
end

local function base_of(prefix: string, space: string, name: string): string
    return prefix .. space .. "/" .. name .. "/"
end

local function shard_key(base: string, shard: number): string
    return base .. string.format("shard-%04d", shard)
end

local function why_of(e): string
    if type(e) == "table" then return e.error or "s3: failed" end
    return tostring(e)
end

-- every object under a prefix, following the pages
local function all_objects(c, bucket: string, prefix: string)
    local out, after = {}, nil
    repeat
        local page, why = c:list(bucket, { prefix = prefix, after = after })
        if not page then return nil, why end
        for _, o in page.objects do table.insert(out, o) end
        after = page.next
    until after == nil
    return out
end

-- the backups of a space: {{name, complete, bytes, objects}}, oldest first
function list(space: string, bucket: string, prefix: string?, opts)
    opts = opts or {}
    local c = s3().client(opts.profile)
    local root = (prefix or "") .. space .. "/"
    local objects, why = all_objects(c, bucket, root)
    if not objects then return nil, why end
    local by, names = {}, {}
    for _, o in objects do
        local name, rest = string.match(string.sub(o.key, #root + 1), "^([^/]+)/(.+)$")
        if name then
            local b = by[name]
            if not b then
                b = { name = name, complete = false, bytes = 0, objects = 0 }
                by[name] = b
                table.insert(names, name)
            end
            b.objects += 1
            if rest == "manifest.json" then b.complete = true else b.bytes += o.size or 0 end
        end
    end
    table.sort(names)
    local out = {}
    for _, n in names do table.insert(out, by[n]) end
    return out
end

local function read_manifest(c, bucket: string, base: string)
    local body, why = c:get(bucket, base .. "manifest.json")
    if body == nil then return nil, why end
    local ok, m = pcall(simdjson.parse, body)
    if not ok or type(m) ~= "table" or m.format == nil or type(m.shards) ~= "table" then
        return nil, { error = "s3: " .. base .. "manifest.json isn't a backup manifest" }
    end
    if m.format > FORMAT then
        return nil, { error = "s3: " .. base .. " is backup format " .. tostring(m.format)
            .. ", newer than this BACKUP (" .. FORMAT .. ")" }
    end
    return m
end

-- whether the space is in a transaction already. BEGIN answers OK either way, so
-- this starts a save and stops it at its first block: refused means no transaction
local STOP = "s3.BACKUP: in a transaction"
local function in_transaction(sp): boolean
    local ok, err = pcall(function() sp:save(function() error(STOP) end) end)
    if ok then return true end                 -- no shards, so no blocks: nothing to lose
    local e = tostring(err)
    if string.find(e, STOP, 1, true) then return true end
    if string.find(e, "BEGIN first", 1, true) then return false end
    error(e)
end

-- how many shards the space has; inside a transaction, as they were at BEGIN
local function shard_count(sp): number
    local n = 0
    sp:stats(function() n += 1 end)
    return n
end

local function remove_all(c, bucket: string, keys)
    for _, k in keys do pcall(function() c:remove(bucket, k) end) end
end

-- Saves the space; answers the backup's name, or nil and why. On a failure the
-- objects already written are removed and an unfinished upload is aborted.
--
-- With no transaction open it opens one, saves, and commits it, whether the save
-- worked or not: a ROLLBACK would take back everyone's writes since the BEGIN, not
-- just ours, and a save writes nothing. Inside the caller's BEGIN it saves that
-- moment and leaves the COMMIT to the caller.
function save(space: string, bucket: string, prefix: string?, opts)
    opts = opts or {}
    prefix = prefix or ""
    local c = s3().client(opts.profile)
    local sp = barch.space[space]
    local size = part_size()
    local v4 = require("s3.SIGV4")
    local started = v4.now()
    local name = v4.amz_date(started // 1000)
    -- two saves in the same second get -1, -2, ...
    local taken = list(space, bucket, prefix, opts) or {}
    local used = {}
    for _, b in taken do used[b.name] = true end
    local n = 0
    local stem = name
    while used[name] do n += 1; name = stem .. "-" .. n end
    local base = base_of(prefix, space, name)

    local shards = {}      -- manifest entries, in shard order
    local dictionary = nil -- the manifest's dictionary entry, when the space has one
    local written = {}     -- keys to remove if this fails
    local cur = nil        -- the shard being sent: {shard, key, pieces, held, bytes, blocks, up}

    local function send_part()
        local body = table.concat(cur.pieces)
        cur.pieces, cur.held = {}, 0
        if not cur.up then
            local up, why = c:upload(bucket, cur.key)
            if not up then error(why_of(why)) end
            cur.up = up
        end
        local ok, why = cur.up:part(body)
        if not ok then error(why_of(why)) end
    end

    local function close_shard()
        if not cur then return end
        if cur.up then
            if cur.held > 0 then send_part() end
            local ok, why = cur.up:finish()
            if not ok then error(why_of(why)) end
            cur.up = nil
        else
            local ok, why = c:put(bucket, cur.key, table.concat(cur.pieces))
            if not ok then error(why_of(why)) end
        end
        table.insert(shards, { shard = cur.shard, key = string.sub(cur.key, #base + 1),
                               bytes = cur.bytes, blocks = cur.blocks })
        cur = nil
    end

    local blocks, total, count = 0, 0, 0
    local owned = not in_transaction(sp)
    if owned then sp:call("BEGIN") end
    local ok, err = pcall(function()
        -- the dictionary goes up before the shards it decodes, and before the
        -- manifest that names it
        local d = sp:getDictionary()
        if d then
            local bytes = buffer.tostring(d)
            local key = base .. DICT
            local put, why = c:put(bucket, key, bytes, "application/octet-stream")
            if not put then error(why_of(why)) end
            table.insert(written, key)
            dictionary = { key = DICT, bytes = #bytes }
        end
        blocks = sp:save(function(buf, block, shard)
            if cur == nil or cur.shard ~= shard then
                close_shard()
                cur = { shard = shard, key = shard_key(base, shard), pieces = {}, held = 0,
                        bytes = 0, blocks = 0 }
                table.insert(written, cur.key)     -- an unfinished one is removed too
            end
            local s = buffer.tostring(buf)
            table.insert(cur.pieces, s)
            cur.held += #s
            cur.bytes += #s
            cur.blocks += 1
            if cur.held >= size then send_part() end
        end)
        close_shard()
        count = shard_count(sp)                   -- from the same moment as the save
    end)
    -- the manifest doesn't need the moment, so it goes up after the COMMIT
    if owned then
        local done, bad = pcall(function() sp:call("COMMIT") end)
        if not done and ok then ok, err = false, bad end
    end
    if ok then ok, err = pcall(function()
        for _, e in shards do total += e.bytes end
        local manifest = simdjson.encode({
            format = FORMAT, space = space, name = name, started = started,
            shard_count = count, shards = shards, bytes = total, blocks = blocks,
            dictionary = dictionary,
        })
        local put, why = c:put(bucket, base .. "manifest.json", manifest, "application/json")
        if not put then error(why_of(why)) end
    end) end
    if not ok then
        if cur and cur.up then pcall(function() cur.up:abort() end) end
        remove_all(c, bucket, written)
        return nil, { error = "backup of " .. space .. " failed: " .. why_of(err) }
    end
    return name, { bytes = total, shards = #shards, blocks = blocks, key = base }
end

-- the latest complete backup's name
local function latest(c, space: string, bucket: string, prefix: string, opts)
    local all, why = list(space, bucket, prefix, opts)
    if not all then return nil, why end
    for i = #all, 1, -1 do
        if all[i].complete then return all[i].name end
    end
    return nil, { error = "s3: no complete backup of " .. space .. " under " .. bucket .. "/" .. prefix }
end

-- Puts the space back from a backup (the latest complete one when name is nil).
-- Answers the backup's manifest, or nil and why.
function load(space: string, bucket: string, prefix: string?, name: string?, opts)
    opts = opts or {}
    prefix = prefix or ""
    local c = s3().client(opts.profile)
    if name == nil or name == "" or string.upper(name) == "LATEST" then
        local found, why = latest(c, space, bucket, prefix, opts)
        if not found then return nil, why end
        name = found
    end
    local base = base_of(prefix, space, name)
    local m, why = read_manifest(c, bucket, base)
    if not m then
        if why and why.status == 404 then
            return nil, { error = "s3: no backup " .. name .. " of " .. space .. " (no " .. base .. "manifest.json)" }
        end
        return nil, why
    end
    -- everything is checked before the load touches the space
    local by = {}
    for _, e in m.shards do
        local info, bad = c:stat(bucket, base .. e.key)
        if not info then return nil, { error = "s3: " .. base .. e.key .. ": " .. why_of(bad) } end
        if info.size ~= e.bytes then
            return nil, { error = string.format("s3: %s%s is %s bytes, the manifest says %d",
                base, e.key, tostring(info.size), e.bytes) }
        end
        by[e.shard] = e
    end
    if m.dictionary then
        local info, bad = c:stat(bucket, base .. m.dictionary.key)
        if not info then return nil, { error = "s3: " .. base .. m.dictionary.key .. ": " .. why_of(bad) } end
        if info.size ~= m.dictionary.bytes then
            return nil, { error = string.format("s3: %s%s is %s bytes, the manifest says %d",
                base, m.dictionary.key, tostring(info.size), m.dictionary.bytes) }
        end
    end
    local sp = barch.space[space]
    if m.shard_count and m.shard_count > 0 then
        local have = shard_count(sp)
        if have ~= m.shard_count then
            return nil, { error = string.format("s3: backup %s has %d shards and %s has %d;"
                .. " a restore needs the same number", name, m.shard_count, space, have) }
        end
    end
    -- the dictionary has to be on the space before the shards land, since their
    -- compressed values name it; setting it is the only step that changes the
    -- space before the load, and it is refused when the space has another
    if m.dictionary then
        local body, bad = c:get(bucket, base .. m.dictionary.key)
        if body == nil then return nil, { error = "s3: " .. base .. m.dictionary.key .. ": " .. why_of(bad) } end
        local took, result = pcall(function() return sp:setDictionary(body) end)
        if not took then
            return nil, { error = "s3: " .. name .. " carries a dictionary the space "
                .. space .. " won't take: " .. why_of(result) }
        end
        if not result then
            return nil, { error = "s3: " .. name .. " carries a dictionary, but compression is off here" }
        end
    end
    local chunk = part_size()
    local ok, err = pcall(function()
        sp:load(function(block, shard)
            local e = by[shard]
            if not e then return nil end          -- barch says which shard it wanted
            local from = block * chunk
            if from >= e.bytes then
                if block == 0 then return "" end   -- an empty shard is still one block
                return nil
            end
            local to = math.min(from + chunk, e.bytes) - 1
            local body, bad = c:get(bucket, base .. e.key, { range = "bytes=" .. from .. "-" .. to })
            if body == nil then error(why_of(bad)) end
            if #body ~= to - from + 1 then
                error(string.format("s3: %s%s answered %d bytes for %d-%d", base, e.key, #body, from, to))
            end
            return body
        end)
    end)
    if not ok then
        return nil, { error = "restore of " .. space .. " from " .. name .. " failed: " .. why_of(err) }
    end
    return m
end

-- Deletes a backup: the manifest first, so a half-deleted one reads as unfinished.
function drop(space: string, bucket: string, prefix: string?, name: string, opts)
    opts = opts or {}
    local c = s3().client(opts.profile)
    local base = base_of(prefix or "", space, name)
    local objects, why = all_objects(c, bucket, base)
    if not objects then return nil, why end
    if #objects == 0 then return nil, { error = "s3: no backup " .. name .. " of " .. space } end
    local ok, bad = c:remove(bucket, base .. "manifest.json")
    if not ok and bad.status ~= 404 then return nil, bad end
    for _, o in objects do
        if o.key ~= base .. "manifest.json" then
            local done, err = c:remove(bucket, o.key)
            if not done then return nil, err end
        end
    end
    return #objects
end

-- ---- s3.BACKUP -----------------------------------------------------------

local function fail(why)
    return "(error) " .. why_of(why)
end

function call(op: string?, space: string?, location: string?, name: string?, extra: string?)
    local opts = {}
    if op and string.sub(op, 1, 1) == "@" then
        opts.profile = string.sub(op, 2)
        op, space, location, name = space, location, name, extra
    end
    op = string.upper(op or "")
    local usage = "usage: [@profile] SAVE space bucket[/prefix] | LIST space bucket[/prefix]"
        .. " | LOAD space bucket[/prefix] [name] | DROP space bucket[/prefix] name"
    if op == "" or not space or not location then return usage end
    local bucket, prefix = where(location)
    if op == "SAVE" then
        local got, why = save(space, bucket, prefix, opts)
        if not got then return fail(why) end
        return got
    elseif op == "LIST" then
        local all, why = list(space, bucket, prefix, opts)
        if not all then return fail(why) end
        local out = {}
        for _, b in all do
            table.insert(out, string.format("%s  %d bytes%s", b.name, b.bytes,
                b.complete and "" or "  (unfinished)"))
        end
        return out
    elseif op == "LOAD" then
        local m, why = load(space, bucket, prefix, name, opts)
        if not m then return fail(why) end
        return string.format("OK %s: %d shards, %d bytes", m.name, #m.shards, m.bytes)
    elseif op == "DROP" then
        if not name then return usage end
        local n, why = drop(space, bucket, prefix, name, opts)
        if not n then return fail(why) end
        return "OK " .. n .. " objects"
    end
    return usage
end
