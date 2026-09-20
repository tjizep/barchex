-- Accounts for the spaces viewer, stored in this space — not the shop's `users`
-- space. Keys: `user:<email>` {email,name,salt,hash}, `sess:<sid>` email,
-- `admin:<email>` = "1".
--
-- With no accounts yet, every request is a local admin so a clean server is
-- usable. The first account to register — or the first existing account to
-- sign on when no admin exists yet — becomes admin and that guest path stops.
function call()
    return "users"
end

local function token(n)
    local t = {}
    for i = 1, n do t[i] = string.format("%02x", math.random(0, 255)) end
    return table.concat(t)
end

-- FNV-1a, 32 bit. Enough to not store a password in the clear; not a KDF.
local function digest(s)
    local h = 2166136261
    for i = 1, #s do
        h = bit32.bxor(h, string.byte(s, i))
        h = bit32.band(h * 16777619, 0xffffffff)
    end
    return string.format("%08x", h)
end

function normalize_email(email)
    return string.lower(string.match(email or "", "^%s*(.-)%s*$"))
end

local function has_admin()
    local page = barch.store.range("admin:", "admin;", 1)
    return type(page) == "table" and #page > 0
end

local function guest()
    return { email = "local", name = "local" }
end

function current(req)
    local sid = req:cookie("sid")
    if sid ~= nil and sid ~= "" then
        local email = barch.store.get("sess:" .. sid)
        if email ~= nil then
            local raw = barch.store.get("user:" .. email)
            if raw ~= nil then return simdjson.parse(raw) end
        end
    end
    if not has_admin() then return guest() end
    return nil
end

function is_admin(req)
    local user = current(req)
    if user == nil or user.email == nil then return false end
    if not has_admin() then return true end
    return barch.store.get("admin:" .. string.lower(user.email)) ~= nil
end

local function start_session(res, email)
    local sid = token(16)
    barch.store.set("sess:" .. sid, email)
    res:cookie("sid", sid, { path = "/", httponly = true })
end

local function no(why, code)
    return { error = why, code = code or 400 }
end

local function yes(u)
    return { ok = true, user = { email = u.email, name = u.name } }
end

function register(req, res)
    if req.body == nil or req.body == "" then return no("name, email and password are required") end
    local j = simdjson.parse(req.body)
    local email = normalize_email(j.email)
    local password = j.password
    if email == "" or type(password) ~= "string" or #password < 6 then
        return no("an email and a password of at least 6 characters are required")
    end
    local key = "user:" .. email
    if barch.store.get(key) ~= nil then return no("an account with that email already exists", 409) end
    local first = not has_admin()
    local salt = token(8)
    local doc = { email = email, name = j.name or "", salt = salt, hash = digest(salt .. password) }
    barch.store.set(key, simdjson.encode(doc))
    if first then barch.store.set("admin:" .. email, "1") end
    start_session(res, email)
    return yes(doc)
end

function signon(req, res)
    if req.body == nil or req.body == "" then return no("email and password are required") end
    local j = simdjson.parse(req.body)
    local email = normalize_email(j.email)
    local raw = barch.store.get("user:" .. email)
    if raw == nil then return no("no such account, or the password is wrong", 401) end
    local u = simdjson.parse(raw)
    if digest(u.salt .. tostring(j.password)) ~= u.hash then
        return no("no such account, or the password is wrong", 401)
    end
    -- no admin yet (accounts imported or restored without one): whoever signs
    -- on first claims it, same as the first register() above
    if not has_admin() then
        barch.store.set("admin:" .. string.lower(u.email), "1")
    end
    start_session(res, u.email)
    return yes(u)
end

function signout(req, res)
    local sid = req:cookie("sid")
    if sid ~= nil and sid ~= "" then barch.store.remove("sess:" .. sid) end
    -- belt and braces: some browsers need Expires as well as Max-Age=0,
    -- and clearing by raw header also drops any sid the server never
    -- issued (a stale cookie from another app on this host/port keeps
    -- coming back otherwise and every request reads as signed out).
    res:cookie("sid", "", { path = "/", max_age = 0, httponly = true })
    res:header("Set-Cookie", "sid=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; HttpOnly")
    return { ok = true }
end

local function send(res, body, code)
    res.code = code or 200
    res:header("Content-Type", "application/json")
    res.body = simdjson.encode(body)
end

function get(req, res)
    local u = current(req)
    if u == nil then send(res, { error = "not signed in" }, 401); return end
    send(res, { ok = true, user = { email = u.email, name = u.name }, admin = is_admin(req) })
end

function post(req, res)
    local path = req.url or ""
    local out
    if string.find(path, "register", 1, true) then out = register(req, res)
    elseif string.find(path, "signout", 1, true) then out = signout(req, res)
    else out = signon(req, res) end
    send(res, out, out.code)
end

function transport()
    return {
        kind = "resource",
        route = "/api/spaces-user/*",
        methods = { GET = get, POST = post },
        send = "application/json",
    }
end
