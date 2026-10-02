-- The http key for the space viewer: which routes it serves, and who they run
-- as. package.luau starts it on 127.0.0.1:18091; by hand it is
--
--     USE spaces
--     HTTP START SPACESHTTP 18091 127.0.0.1
function call()
    return "spaces http"
end

function service()
    return {
        kind = "http",
        bind = "127.0.0.1",
        user = "web",
        keys = {"USERS", "SPACESUI", "SPACESAPI"},
    }
end
