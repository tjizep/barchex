-- package.luau's after hook: the rights the viewer's HTTP user needs.
--
-- The routes run as `web`, and the viewer's buttons read and write keys, call
-- functions, change settings, and import and export (`dangerous`). This adds
-- the categories web's rule does not mention yet. A category the operator
-- set either way, such as `+outbound` or `-dangerous`, stays as it is.
local needs = { "read", "write", "data", "keys", "function", "config", "dangerous" }

function call(repo, from, to)
    -- GETUSER answers category, "true" or "false", category, ...
    local now = barch.call("ACL", "GETUSER", "web")
    local set = {}
    if type(now) == "table" then
        for i = 1, #now, 2 do
            set[now[i]] = true
        end
    end
    local missing = {}
    for _, cat in ipairs(needs) do
        if not set[cat] then
            table.insert(missing, "+" .. cat)
        end
    end
    if #missing > 0 then
        barch.call("ACL", "SETUSER", "web", "on", table.unpack(missing))
    end
    return "ok"
end
