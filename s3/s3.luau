-- S3, and anything that speaks its API (MinIO, Cloudflare R2, Backblaze B2,
-- Wasabi, ...), for stored functions. Signing is SIGV4 in this space.
--
--   local s3 = require("s3.S3")               -- inside a handler, not at the top
--   local body, info = s3.get("bucket", "path/to/key")
--   local etag = s3.put("bucket", "k", body, "text/plain")
--   local page = s3.list("bucket", { prefix = "photos/", delimiter = "/" })
--   local url  = s3.presign("bucket", "k", 3600)
--   local up   = s3.upload("bucket", "k")   up:part(body) ... up:finish()  (multipart)
--   local other = s3.client("backup")        -- a second set of settings
--
-- Every call answers nil and a reason on failure rather than raising, the way
-- barch.store.fetch does: `local body, why = s3.get(...)`. A missing object is
-- nil with `why.status == 404`.
--
-- Settings are keys in the `configuration` space. A profile's own key wins over
-- the plain one, so s3.backup.endpoint is used for client("backup") and
-- s3.endpoint for everything else:
--
--   s3.endpoint     https://s3.eu-west-1.amazonaws.com   (default: AWS for the region)
--   s3.region       eu-west-1                            (default us-east-1)
--   s3.access_key   AKIA...
--   s3.secret_key   ...        not "…password": scripts can't read those, and this one signs
--   s3.path_style   1 for http://host/bucket/key, 0 for http://bucket.host/key
--                   (default 0 on amazonaws.com, 1 anywhere else - MinIO wants 1)
--   s3.timeout_ms   20000
--   s3.hash_limit   262144   bodies up to this are hashed into the signature;
--                            bigger ones are sent as UNSIGNED-PAYLOAD
--
-- As a file source, a space's missing files come from a bucket the first time
-- they're asked for, and are stored files after that:
--
--   configuration:  <space>.fs_source       S3SOURCE
--                   <space>.fs_source_list  S3LIST       (optional: listings show the bucket)
--                   s3.source.<space>       bucket[/prefix]
--                   s3.source.<space>.profile  backup     (optional)
--   in <space>:     SETF S3SOURCE "function call(path) return require('s3.S3').source(path) end"
--                   SETF S3LIST   "function call(dir) return require('s3.S3').listing(dir) end"
--
-- Backups of a whole key space are s3.BACKUP (backup.luau); s3.part_size sets
-- the size of its upload parts.
--
-- A network call counts against the calling space's function_deadline_ms, one
-- second by default; raise <space>.function_deadline_ms for spaces that use S3.
--
-- call() is a small command line, for the console and the viewer's Call box.
-- The dotted name is the command from any space; in this one, CALLF S3 ... works:
--   s3.S3 LS bucket [prefix]      s3.S3 GET bucket key      s3.S3 PUT bucket key value [type]
--   s3.S3 DEL bucket key          s3.S3 STAT bucket key     s3.S3 URL bucket key [seconds]
--   s3.S3 BUCKETS                 s3.S3 MKBUCKET bucket     s3.S3 CHECK
--   s3.S3 @backup LS bucket       (@profile first uses s3.backup.* settings)

local function v4()
    return require("s3.SIGV4")
end

local function setting(profile: string?, name: string): string?
    local conf = barch.space.configuration
    if profile and profile ~= "" then
        local own = conf["s3." .. profile .. "." .. name]
        if own ~= nil and own ~= "" then return own end
    end
    local v = conf["s3." .. name]
    if v == "" then return nil end
    return v
end

-- the resolved settings for a profile: endpoint split into scheme, host, base path
local function settings(profile: string?)
    local region = setting(profile, "region") or "us-east-1"
    local endpoint = setting(profile, "endpoint") or ("https://s3." .. region .. ".amazonaws.com")
    local scheme, host, base = string.match(endpoint, "^(https?)://([^/]+)(.*)$")
    if not scheme then error("s3: endpoint must start with http:// or https://, got " .. endpoint) end
    base = string.gsub(base, "/+$", "")
    local style = setting(profile, "path_style")
    local path_style
    if style == nil then
        path_style = string.find(host, "amazonaws%.com$") == nil
    else
        path_style = style == "1" or string.lower(style) == "true"
    end
    local access, secret = setting(profile, "access_key"), setting(profile, "secret_key")
    if not access or not secret then
        error("s3: no credentials - set s3." .. (profile and profile .. "." or "") .. "access_key and secret_key in configuration")
    end
    return {
        profile = profile, region = region, scheme = scheme, host = host, base = base,
        path_style = path_style, access_key = access, secret_key = secret,
        timeout = tonumber(setting(profile, "timeout_ms") or "") or 20000,
        hash_limit = tonumber(setting(profile, "hash_limit") or "") or 262144,
    }
end

-- where a bucket and key go: the host to sign, the path to sign, the url base
local function locate(s, bucket: string?, key: string?)
    key = key or ""
    local host, path
    if not bucket or bucket == "" then
        host, path = s.host, s.base .. "/"
    elseif s.path_style then
        host, path = s.host, s.base .. "/" .. bucket .. (key ~= "" and "/" .. key or "")
    else
        host, path = bucket .. "." .. s.host, s.base .. "/" .. key
    end
    return host, path
end

local function header(r, name: string): string?
    local h = r.headers or {}
    if h[name] ~= nil then return h[name] end
    local want = string.lower(name)
    for k, v in h do
        if string.lower(k) == want then return v end
    end
    return nil
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function unxml(s: string?): string?
    if s == nil then return nil end
    return (string.gsub(s, "&(#?x?%w+);", function(e)
        if ENTITIES[e] then return ENTITIES[e] end
        local n = string.match(e, "^#x(%x+)$")
        if n then return utf8.char(tonumber(n, 16)) end
        n = string.match(e, "^#(%d+)$")
        if n then return utf8.char(tonumber(n)) end
        return "&" .. e .. ";"
    end))
end

local function tag(xml: string, name: string): string?
    return unxml(string.match(xml, "<" .. name .. ">(.-)</" .. name .. ">"))
end

-- one signed request. Answers the response on a 2xx, or nil and a table
-- {status, code, message, error} saying why
local function request(s, method: string, bucket: string?, key: string?, query, headers, body: string?)
    local sig = v4()
    local host, path = locate(s, bucket, key)
    local payload
    if body == nil or body == "" then
        payload = nil                              -- the empty-body hash
    elseif #body <= s.hash_limit then
        payload = sig.hex(sig.sha256(body))
    else
        payload = "UNSIGNED-PAYLOAD"
    end
    local sent = sig.sign({
        method = method, host = host, path = path, query = query, headers = headers,
        payload_hash = payload, region = s.region, access_key = s.access_key,
        secret_key = s.secret_key,
    })
    local qs = sig.query_string(query)
    local url = s.scheme .. "://" .. host .. sig.uri_encode(path, true) .. (qs ~= "" and "?" .. qs or "")
    local req = http.request(url):headers(sent):timeout(s.timeout)
    if body ~= nil and body ~= "" then req = req:body(body) end
    local r
    if method == "GET" then r = req:get()
    elseif method == "PUT" then r = req:put()
    elseif method == "POST" then r = req:post()
    elseif method == "DELETE" then r = req:delete()
    else error("s3: no " .. method .. " in http.request") end
    if not r.ok and (r.status == nil or r.status == 0) then
        return nil, { status = 0, error = "s3: " .. (r.error or "request failed") .. " (" .. url .. ")" }
    end
    if r.status >= 200 and r.status < 300 then
        return r
    end
    local code = r.body and tag(r.body, "Code") or nil
    local message = r.body and tag(r.body, "Message") or nil
    return nil, {
        status = r.status, code = code, message = message,
        error = string.format("s3: %d %s%s", r.status, code or "", message and (": " .. message) or ""),
    }
end

local function info_of(r)
    local size = tonumber(header(r, "content-length") or "")
    local range = header(r, "content-range")         -- bytes 0-0/1234 on a ranged read
    if range then size = tonumber(string.match(range, "/(%d+)$") or "") or size end
    local etag = header(r, "etag")
    return {
        status = r.status, size = size, type = header(r, "content-type"),
        etag = etag and string.gsub(etag, '"', "") or nil,
        modified = header(r, "last-modified"), headers = r.headers,
    }
end

-- ---- the client ----------------------------------------------------------

local Client = {}
Client.__index = Client

function client(profile: string?)
    return setmetatable({ s = settings(profile) }, Client)
end

-- the object's bytes and {status, size, type, etag, modified, headers}.
-- opts.range = "bytes=0-99" reads part of it
function Client:get(bucket: string, key: string, opts)
    local h = nil
    if opts and opts.range then h = { range = opts.range } end
    local r, why = request(self.s, "GET", bucket, key, nil, h)
    if not r then return nil, why end
    return r.body, info_of(r)
end

-- size, type, etag and modified without the body. http.request has no HEAD, so
-- this reads one byte; an empty object answers 416, which is still "there"
function Client:stat(bucket: string, key: string)
    local r, why = request(self.s, "GET", bucket, key, nil, { range = "bytes=0-0" })
    if r then return info_of(r) end
    if why.status == 416 then return { status = 200, size = 0 } end
    return nil, why
end

-- writes the object; answers its etag
function Client:put(bucket: string, key: string, body: string, content_type: string?)
    local h = { ["content-type"] = content_type or "application/octet-stream" }
    local r, why = request(self.s, "PUT", bucket, key, nil, h, body)
    if not r then return nil, why end
    local etag = header(r, "etag")
    return etag and (string.gsub(etag, '"', "")) or true
end

-- a multipart upload, for an object too big for one PUT or not all in hand yet:
--   local up = c:upload(bucket, key)   up:part(body) ...   up:finish() or up:abort()
-- Every part but the last has to be at least 5 MB, and there are at most 10000.
-- An upload that is neither finished nor aborted is kept, and billed, by S3
-- until a lifecycle rule clears it.
local Upload = {}
Upload.__index = Upload

function Client:upload(bucket: string, key: string, content_type: string?)
    local h = { ["content-type"] = content_type or "application/octet-stream" }
    local r, why = request(self.s, "POST", bucket, key, { uploads = "" }, h)
    if not r then return nil, why end
    local id = tag(r.body or "", "UploadId")
    if not id then
        return nil, { status = r.status, error = "s3: no UploadId in the answer to starting an upload" }
    end
    return setmetatable({ s = self.s, bucket = bucket, key = key, id = id, etags = {} }, Upload)
end

-- sends the next part; answers its number
function Upload:part(body: string)
    local n = #self.etags + 1
    local q = { partNumber = tostring(n), uploadId = self.id }
    local r, why = request(self.s, "PUT", self.bucket, self.key, q, nil, body)
    if not r then return nil, why end
    self.etags[n] = header(r, "etag") or ""
    return n
end

-- joins the parts into the object; answers its etag
function Upload:finish()
    local parts = {}
    for n, etag in self.etags do
        table.insert(parts, "<Part><PartNumber>" .. n .. "</PartNumber><ETag>" .. etag .. "</ETag></Part>")
    end
    local body = "<CompleteMultipartUpload>" .. table.concat(parts) .. "</CompleteMultipartUpload>"
    local r, why = request(self.s, "POST", self.bucket, self.key, { uploadId = self.id },
        { ["content-type"] = "application/xml" }, body)
    if not r then return nil, why end
    -- S3 can answer 200 and still fail the join, with an <Error> in the body
    local xml = r.body or ""
    if string.find(xml, "<Error>", 1, true) then
        local code, message = tag(xml, "Code"), tag(xml, "Message")
        return nil, { status = r.status, code = code, message = message,
                      error = "s3: " .. (code or "") .. (message and (": " .. message) or "") }
    end
    local etag = tag(xml, "ETag")
    return etag and (string.gsub(etag, '"', "")) or true
end

-- throws the parts away
function Upload:abort()
    local r, why = request(self.s, "DELETE", self.bucket, self.key, { uploadId = self.id })
    if not r then return nil, why end
    return true
end

function Client:remove(bucket: string, key: string)
    local r, why = request(self.s, "DELETE", bucket, key)
    if not r then return nil, why end
    return true
end

-- one page of ListObjectsV2: {objects = {{key, size, etag, modified}},
-- prefixes = {...}, next = token or nil}. opts: prefix, delimiter, limit
-- (max 1000), after (the `next` of the page before), start_after
function Client:list(bucket: string, opts)
    opts = opts or {}
    local q = { ["list-type"] = "2" }
    if opts.prefix and opts.prefix ~= "" then q.prefix = opts.prefix end
    if opts.delimiter then q.delimiter = opts.delimiter end
    if opts.limit then q["max-keys"] = tostring(opts.limit) end
    if opts.after then q["continuation-token"] = opts.after end
    if opts.start_after then q["start-after"] = opts.start_after end
    local r, why = request(self.s, "GET", bucket, "", q)
    if not r then return nil, why end
    local xml = r.body or ""
    local out = { objects = {}, prefixes = {} }
    for c in string.gmatch(xml, "<Contents>(.-)</Contents>") do
        local etag = tag(c, "ETag")
        table.insert(out.objects, {
            key = tag(c, "Key"), size = tonumber(tag(c, "Size") or ""),
            etag = etag and (string.gsub(etag, '"', "")) or nil, modified = tag(c, "LastModified"),
        })
    end
    for p in string.gmatch(xml, "<CommonPrefixes>(.-)</CommonPrefixes>") do
        table.insert(out.prefixes, tag(p, "Prefix"))
    end
    if tag(xml, "IsTruncated") == "true" then
        out.next = tag(xml, "NextContinuationToken")
    end
    return out
end

-- makes a bucket; outside us-east-1 S3 wants the region named in the body
function Client:create_bucket(bucket: string)
    local body = nil
    if self.s.region ~= "us-east-1" then
        body = '<CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
            .. "<LocationConstraint>" .. self.s.region .. "</LocationConstraint></CreateBucketConfiguration>"
    end
    local r, why = request(self.s, "PUT", bucket, "", nil, nil, body)
    if not r then return nil, why end
    return true
end

-- the buckets these credentials can see: {{name, created}}
function Client:buckets()
    local r, why = request(self.s, "GET", nil, nil)
    if not r then return nil, why end
    local out = {}
    for b in string.gmatch(r.body or "", "<Bucket>(.-)</Bucket>") do
        table.insert(out, { name = tag(b, "Name"), created = tag(b, "CreationDate") })
    end
    return out
end

-- a url anyone can use for `expires` seconds (default an hour, at most 7 days)
function Client:presign(bucket: string, key: string, expires: number?, method: string?)
    local sig = v4()
    local host, path = locate(self.s, bucket, key)
    local qs = sig.presign({
        method = method or "GET", host = host, path = path, region = self.s.region,
        access_key = self.s.access_key, secret_key = self.s.secret_key,
    }, math.clamp(expires or 3600, 1, 604800))
    return self.s.scheme .. "://" .. host .. sig.uri_encode(path, true) .. "?" .. qs
end

-- the same functions on the default profile, so `s3.get(bucket, key)` works
-- without making a client first
local function default() return client(nil) end
function get(bucket, key, opts) return default():get(bucket, key, opts) end
function stat(bucket, key) return default():stat(bucket, key) end
function put(bucket, key, body, content_type) return default():put(bucket, key, body, content_type) end
function remove(bucket, key) return default():remove(bucket, key) end
function upload(bucket, key, content_type) return default():upload(bucket, key, content_type) end
function list(bucket, opts) return default():list(bucket, opts) end
function buckets() return default():buckets() end
function create_bucket(bucket) return default():create_bucket(bucket) end
function presign(bucket, key, expires, method) return default():presign(bucket, key, expires, method) end

-- ---- as a file source ----------------------------------------------------

-- s3.source.<space> = "bucket" or "bucket/prefix" (a prefix gets its trailing
-- slash added), and s3.source.<space>.profile picks the settings
local function mapping(space: string)
    local conf = barch.space.configuration
    local where = conf["s3.source." .. space]
    if where == nil or where == "" then
        error("s3: no bucket for space " .. space .. " - set s3.source." .. space .. " in configuration")
    end
    local bucket, prefix = string.match(where, "^/*([^/]+)/?(.*)$")
    prefix = string.gsub(prefix or "", "^/+", "")
    if prefix ~= "" and string.sub(prefix, -1) ~= "/" then prefix ..= "/" end
    return bucket, prefix, conf["s3.source." .. space .. ".profile"]
end

-- fs_source: the object at the file's path, or nil when the bucket hasn't got
-- it (barch remembers that miss for missing_ttl). Anything else - no network,
-- bad credentials - raises, so the fetch fails and nothing is remembered.
function source(path: string)
    local bucket, prefix, profile = mapping(barch.running())
    local key = prefix .. string.gsub(path, "^/+", "")
    local body, info = client(profile):get(bucket, key)
    if body == nil then
        if info.status == 404 then return nil end
        error(info.error)
    end
    local kind = info.type
    if kind == nil or kind == "" or kind == "binary/octet-stream" then return body end
    return { body, kind }
end

-- fs_source_list: the objects one level down in the bucket, as names. Folders
-- aren't included, because barch shows a source's names as files; a folder
-- turns up once something in it has been fetched. Capped at 10000 names.
function listing(dir: string)
    local bucket, prefix, profile = mapping(barch.running())
    local d = string.gsub(dir or "/", "^/+", "")
    if d ~= "" and string.sub(d, -1) ~= "/" then d ..= "/" end
    local c = client(profile)
    local names, after = {}, nil
    repeat
        local page, why = c:list(bucket, { prefix = prefix .. d, delimiter = "/", after = after })
        if not page then error(why.error) end
        for _, o in page.objects do
            local name = string.sub(o.key, #prefix + #d + 1)
            if name ~= "" then table.insert(names, name) end
        end
        after = page.next
    until after == nil or #names >= 10000
    return names
end

-- ---- CALLF S3 ------------------------------------------------------------

local function fail(why)
    return "(error) " .. (type(why) == "table" and why.error or tostring(why))
end

function call(op: string?, a: string?, b: string?, c: string?, d: string?, e: string?)
    -- `@profile` first picks the settings: s3.S3 @backup LS bucket
    local cl = nil
    if op and string.sub(op, 1, 1) == "@" then
        cl = client(string.sub(op, 2))
        op, a, b, c, d = a, b, c, d, e
    else
        cl = client(nil)
    end
    local function get(bk, k) return cl:get(bk, k) end
    local function stat(bk, k) return cl:stat(bk, k) end
    local function put(bk, k, body, t) return cl:put(bk, k, body, t) end
    local function remove(bk, k) return cl:remove(bk, k) end
    local function list(bk, o) return cl:list(bk, o) end
    local function buckets() return cl:buckets() end
    local function presign(bk, k, s) return cl:presign(bk, k, s) end
    op = string.upper(op or "")
    if op == "CHECK" then
        local ok, why = v4().selftest()
        return ok and "ok: SigV4 matches AWS's published examples" or ("failed: " .. why)
    elseif op == "BUCKETS" then
        local got, why = buckets()
        if not got then return fail(why) end
        local out = {}
        for _, bk in got do table.insert(out, bk.name) end
        return out
    elseif op == "LS" then
        local page, why = list(a, { prefix = b, delimiter = "/" })
        if not page then return fail(why) end
        local out = {}
        for _, p in page.prefixes do table.insert(out, p) end
        for _, o in page.objects do table.insert(out, o.key .. "  " .. tostring(o.size)) end
        if page.next then table.insert(out, "… more") end
        return out
    elseif op == "GET" then
        local body, why = get(a, b)
        if body == nil then return fail(why) end
        return body
    elseif op == "STAT" then
        local info, why = stat(a, b)
        if not info then return fail(why) end
        return { "size " .. tostring(info.size), "type " .. tostring(info.type),
                 "etag " .. tostring(info.etag), "modified " .. tostring(info.modified) }
    elseif op == "PUT" then
        local etag, why = put(a, b, c or "", d)
        if not etag then return fail(why) end
        return "OK " .. tostring(etag)
    elseif op == "DEL" then
        local done, why = remove(a, b)
        if not done then return fail(why) end
        return "OK"
    elseif op == "URL" then
        return presign(a, b, tonumber(c or "") or 3600)
    elseif op == "MKBUCKET" then
        local done, why = cl:create_bucket(a)
        if not done then return fail(why) end
        return "OK"
    end
    return "usage: [@profile] LS bucket [prefix] | GET bucket key | STAT bucket key"
        .. " | PUT bucket key value [type] | DEL bucket key | URL bucket key [seconds]"
        .. " | MKBUCKET bucket | BUCKETS | CHECK"
end
