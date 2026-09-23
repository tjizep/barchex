--!native
-- AWS Signature Version 4, in plain Luau, for the S3 module (function S3 in
-- this space). The function sandbox has no hashing and no clock, so both are
-- made here: SHA-256 and HMAC-SHA256 out of bit32 and buffer, and the time
-- out of a key's expiry (see now()).
--
-- Required, not called: `local v4 = require("s3.SIGV4")`. A function key has to
-- define call(), so this one answers a self-check against the example requests
-- in AWS's S3 SigV4 documentation, whose signatures are published there:
--
--   s3.SIGV4                -> "ok" or which example failed (from any space)
--
-- `--!native` on the first line compiles this to native code (barch TODO 413);
-- the hashing is the only part of an S3 request that is real work in Luau.

local band, bxor, bnot = bit32.band, bit32.bxor, bit32.bnot
local rrotate, rshift, byteswap = bit32.rrotate, bit32.rshift, bit32.byteswap

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- SHA-256 of a string, as 32 raw bytes
function sha256(msg: string): string
    local len = #msg
    local total = (len + 9 + 63) // 64 * 64
    local b = buffer.create(total)
    buffer.writestring(b, 0, msg)
    buffer.writeu8(b, len, 0x80)
    local bits = len * 8                       -- big-endian bit length in the last 8 bytes
    buffer.writeu32(b, total - 8, byteswap(bits // 0x100000000))
    buffer.writeu32(b, total - 4, byteswap(bits % 0x100000000))

    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    local w = table.create(64, 0)
    for at = 0, total - 1, 64 do
        for i = 1, 16 do
            w[i] = byteswap(buffer.readu32(b, at + (i - 1) * 4))
        end
        for i = 17, 64 do
            local a, c = w[i - 15], w[i - 2]
            local s0 = bxor(rrotate(a, 7), rrotate(a, 18), rshift(a, 3))
            local s1 = bxor(rrotate(c, 17), rrotate(c, 19), rshift(c, 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 0x100000000
        end
        local a, bb, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 1, 64 do
            local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = (h + S1 + ch + K[i] + w[i]) % 0x100000000
            local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
            local maj = bxor(band(a, bb), band(a, c), band(bb, c))
            local t2 = (S0 + maj) % 0x100000000
            h, g, f, e = g, f, e, (d + t1) % 0x100000000
            d, c, bb, a = c, bb, a, (t1 + t2) % 0x100000000
        end
        h0 = (h0 + a) % 0x100000000; h1 = (h1 + bb) % 0x100000000
        h2 = (h2 + c) % 0x100000000; h3 = (h3 + d) % 0x100000000
        h4 = (h4 + e) % 0x100000000; h5 = (h5 + f) % 0x100000000
        h6 = (h6 + g) % 0x100000000; h7 = (h7 + h) % 0x100000000
    end
    local out = buffer.create(32)
    for i, v in { h0, h1, h2, h3, h4, h5, h6, h7 } do
        buffer.writeu32(out, (i - 1) * 4, byteswap(v))
    end
    return buffer.tostring(out)
end

function hex(raw: string): string
    return (string.gsub(raw, ".", function(ch) return string.format("%02x", string.byte(ch)) end))
end

local function xor_pad(key: string, byte: number): string
    local b = buffer.create(64)
    buffer.fill(b, 0, byte)
    for i = 1, #key do
        buffer.writeu8(b, i - 1, bxor(string.byte(key, i), byte))
    end
    return buffer.tostring(b)
end

-- HMAC-SHA256, raw bytes
function hmac(key: string, msg: string): string
    if #key > 64 then key = sha256(key) end
    return sha256(xor_pad(key, 0x5c) .. sha256(xor_pad(key, 0x36) .. msg))
end

-- The time, as barch has it. The sandbox has no clock, but a key's expiry is
-- kept against the system clock and PEXPIRETIME reports it as unix ms, so a
-- key set to expire in a minute says what the time is to the millisecond.
-- The key lives in this space, `s3`, not in whichever space is calling.
function now(): number
    local sp = barch.space.s3
    sp:call("SET", "sigv4:clock", "1", "PX", "60000")
    local at = sp:call("PEXPIRETIME", "sigv4:clock")
    return integer.tonumber(at) - 60000
end

-- unix seconds to "20130524T000000Z" and "20130524"
function amz_date(unix: number): (string, string)
    local s = unix // 1
    local days, rest = s // 86400, s % 86400
    -- civil from days (Howard Hinnant's algorithm), valid for any date after 1970
    local z = days + 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y += 1 end
    local date = string.format("%04d%02d%02d", y, m, d)
    return string.format("%sT%02d%02d%02dZ", date, rest // 3600, rest % 3600 // 60, rest % 60), date
end

-- RFC 3986 encoding the way SigV4 wants it: everything but A-Z a-z 0-9 - . _ ~,
-- and '/' kept only when `keep_slash` (an object key in a path)
function uri_encode(s: string, keep_slash: boolean?): string
    local keep = keep_slash and "[^%w%-%._~/]" or "[^%w%-%._~]"
    return (string.gsub(s, keep, function(ch)
        return string.format("%%%02X", string.byte(ch))
    end))
end

local EMPTY_SHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

-- the query string, sorted and encoded: what is signed, and what goes in the url
function query_string(query: { [string]: string }?): string
    if not query then return "" end
    local keys = {}
    for k in query do table.insert(keys, k) end
    table.sort(keys)
    local parts = {}
    for _, k in keys do
        table.insert(parts, uri_encode(k) .. "=" .. uri_encode(query[k] or ""))
    end
    return table.concat(parts, "&")
end

local function signing_key(secret: string, date: string, region: string, service: string): string
    local k = hmac("AWS4" .. secret, date)
    k = hmac(k, region)
    k = hmac(k, service)
    return hmac(k, "aws4_request")
end

--[[
Sign one request. `r` is:
  method, host ("bucket.s3.amazonaws.com" or "127.0.0.1:9000"), path (already
  the object's path, not yet encoded), query (table), headers (table of the
  extra headers to sign and send), payload_hash (hex, or "UNSIGNED-PAYLOAD";
  empty-body hash when left out), region, service ("s3"), access_key,
  secret_key, time (unix seconds; now() when left out)
Answers the headers to send, Authorization included, and the canonical request
and string to sign for anyone debugging a SignatureDoesNotMatch.
]]
function sign(r): ({ [string]: string }, string, string)
    local stamp, date = amz_date(r.time or now() // 1000)
    local payload = r.payload_hash or EMPTY_SHA
    local headers = { host = r.host, ["x-amz-date"] = stamp, ["x-amz-content-sha256"] = payload }
    for k, v in r.headers or {} do headers[string.lower(k)] = v end
    local names = {}
    for k in headers do table.insert(names, k) end
    table.sort(names)
    local lines = {}
    for _, k in names do
        local v = string.gsub(string.gsub(tostring(headers[k]), "^%s+", ""), "%s+$", "")
        table.insert(lines, k .. ":" .. string.gsub(v, "%s+", " "))
    end
    local signed = table.concat(names, ";")
    local creq = table.concat({
        r.method, uri_encode(r.path, true), query_string(r.query),
        table.concat(lines, "\n") .. "\n", signed, payload,
    }, "\n")
    local scope = table.concat({ date, r.region, r.service or "s3", "aws4_request" }, "/")
    local sts = table.concat({ "AWS4-HMAC-SHA256", stamp, scope, hex(sha256(creq)) }, "\n")
    local sig = hex(hmac(signing_key(r.secret_key, date, r.region, r.service or "s3"), sts))
    headers.authorization = string.format("AWS4-HMAC-SHA256 Credential=%s/%s,SignedHeaders=%s,Signature=%s",
        r.access_key, scope, signed, sig)
    headers.host = nil                         -- curl sends Host from the url, which is what was signed
    return headers, creq, sts
end

--[[
A presigned url's query string: the same request as sign() describes, signed
into X-Amz-* query parameters instead of headers, good for `expires` seconds.
Only `host` is signed, and the payload is UNSIGNED-PAYLOAD, as S3 expects.
Answers the query string (already encoded, without the '?').
]]
function presign(r, expires: number): string
    local stamp, date = amz_date(r.time or now() // 1000)
    local scope = table.concat({ date, r.region, r.service or "s3", "aws4_request" }, "/")
    local q = {}
    for k, v in r.query or {} do q[k] = v end
    q["X-Amz-Algorithm"] = "AWS4-HMAC-SHA256"
    q["X-Amz-Credential"] = r.access_key .. "/" .. scope
    q["X-Amz-Date"] = stamp
    q["X-Amz-Expires"] = tostring(expires)
    q["X-Amz-SignedHeaders"] = "host"
    local query = query_string(q)
    local creq = table.concat({
        r.method, uri_encode(r.path, true), query, "host:" .. r.host .. "\n", "host", "UNSIGNED-PAYLOAD",
    }, "\n")
    local sts = table.concat({ "AWS4-HMAC-SHA256", stamp, scope, hex(sha256(creq)) }, "\n")
    local sig = hex(hmac(signing_key(r.secret_key, date, r.region, r.service or "s3"), sts))
    return query .. "&X-Amz-Signature=" .. sig
end

-- The worked examples from AWS's "Signature Calculations for the Authorization
-- Header: Transferring Payload in a Single Chunk" and "Query String
-- Authentication" pages for S3, with the signatures AWS publishes for them.
local EXAMPLE = {
    access_key = "AKIAIOSFODNN7EXAMPLE",
    secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    region = "us-east-1", host = "examplebucket.s3.amazonaws.com",
    time = 1369353600,                          -- 20130524T000000Z
}

local function example(extra)
    local r = table.clone(EXAMPLE)
    for k, v in extra do r[k] = v end
    return r
end

local function signature_of(headers): string
    return string.match(headers.authorization, "Signature=(%x+)")
end

function selftest(): (boolean, string?)
    if hex(sha256("")) ~= EMPTY_SHA then return false, "sha256 of the empty string" end
    if hex(sha256("abc")) ~= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" then
        return false, "sha256 of abc"
    end
    local checks = {
        { "GET object", example({ method = "GET", path = "/test.txt", headers = { range = "bytes=0-9" } }),
          "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41" },
        { "PUT object", example({ method = "PUT", path = "/test$file.text",
            headers = { date = "Fri, 24 May 2013 00:00:00 GMT", ["x-amz-storage-class"] = "REDUCED_REDUNDANCY" },
            payload_hash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072" }),
          "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd" },
        { "GET lifecycle", example({ method = "GET", path = "/", query = { lifecycle = "" } }),
          "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543" },
        { "GET bucket", example({ method = "GET", path = "/", query = { ["max-keys"] = "2", prefix = "J" } }),
          "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7" },
    }
    for _, c in checks do
        local got = signature_of((sign(c[2])))
        if got ~= c[3] then return false, c[1] .. " signed as " .. tostring(got) end
    end
    local q = presign(example({ method = "GET", path = "/test.txt" }), 86400)
    local got = string.match(q, "X%-Amz%-Signature=(%x+)")
    if got ~= "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404" then
        return false, "presigned url signed as " .. tostring(got)
    end
    return true
end

function call()
    local ok, why = selftest()
    return ok and "ok" or ("failed: " .. why)
end
