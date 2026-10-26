-- A small blog on lent: users, posts, follows and stars. Each command runs in
-- one transaction in the space BLOG is installed in.
--
--   CALLF BLOG migrate                       -> the schema version
--   CALLF BLOG user <email> <name>           -> the new user's id
--   CALLF BLOG post <email> <title> <body>   -> the new post's id
--   CALLF BLOG follow <email> <other email>  -> "OK"
--   CALLF BLOG star <post id>                -> the post's stars
--   CALLF BLOG posts <email> [n]             -> the user's newest n posts
--   CALLF BLOG timeline <email> [n]          -> newest posts by people the user follows
--   CALLF BLOG top [n]                       -> the n posts with the most stars
--
-- Ids are barch.uuid() strings. Post lists answer "<id> <stars> <title>"
-- lines. n defaults to 10.

local blog = require("blog.SCHEMA")
local m = require("lent.MIGRATE")
local lent = require("lent.CLIENT")

local function fail(msg: string)
    error("BLOG " .. msg, 0)
end

local function count(n: string?): number
    local v = tonumber(n or "10")
    if v == nil or v < 1 or v ~= math.floor(v) then
        fail("wants a count of 1 or more, got " .. tostring(n))
    end
    return v :: number
end

local function user(c: any, email: string): any
    local u = c.User:by("email", email)
    if u == nil then
        fail("has no user " .. tostring(email))
    end
    return u
end

local function lines(posts: { any }): { string }
    local out = table.create(#posts)
    for i, p in posts do
        out[i] = p.id .. " " .. p.stars .. " " .. p.title
    end
    return out
end

local commands = {}

function commands.user(c, email, name)
    return c.User:create({ email = email, name = name }).id
end

function commands.post(c, email, title, body)
    return c.Post:create({ title = title, body = body, author = user(c, email) }).id
end

function commands.follow(c, email, other)
    c.User:link("follows", user(c, email).id, user(c, other).id)
    return "OK"
end

function commands.star(c, id)
    local p = c.Post:get(id)
    if p == nil then
        fail("has no post " .. tostring(id))
    end
    return c.Post:update(p.id, { stars = p.stars + 1 }).stars
end

-- barch.uuid() ids grow with time, so the newest posts have the highest ids.
function commands.posts(c, email, n)
    local q = c.User:query():where("id", "=", user(c, email).id):queryPosts()
    return lines(q:order("id", "desc"):limit(count(n)):all())
end

function commands.timeline(c, email, n)
    local q = c.User:query():where("id", "=", user(c, email).id)
        :queryFollows():queryPosts()
    return lines(q:order("id", "desc"):limit(count(n)):all())
end

function commands.top(c, n)
    return lines(c.Post:query():order("stars", "desc"):limit(count(n)):all())
end

function call(command: string?, ...: string)
    if command == "migrate" then
        local report = m.migrate(blog.app())
        if not report.done then
            return "migration pending at version " .. report.version .. "; call BLOG migrate again"
        end
        return report.version
    end
    local run = commands[command]
    if run == nil then
        fail("has no command " .. tostring(command))
    end
    local args = { ... }
    return lent.tx(function(c)
        return run(c, table.unpack(args))
    end)
end
