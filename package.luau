-- How barchex installs itself from git:
--
--     barchd -g https://github.com/tjizep/barchex user=default
--
-- barch applies this on every sync, in this order: the spaces, the folders,
-- the HTTP server, then the after hook. Each extension folder goes into the
-- key space of the same name; tests/ stays out.
function setup()
    return {
        -- listed so each space exists after a sync, and is open after a
        -- restart before anything else touches it
        spaces = {
            spaces   = {},
            vectors  = {},
            s3       = {},
            watchdog = {},
        },
        load = {
            { path = "spaces",   space = "spaces" },
            { path = "vectors",  space = "vectors" },
            { path = "s3",       space = "s3" },
            { path = "watchdog", space = "watchdog" },
        },
        -- the space viewer, at http://127.0.0.1:18091/spaces. SPACESAPI is an
        -- admin surface, so keep it on loopback
        http = { space = "spaces", key = "SPACESHTTP", port = 18091, bind = "127.0.0.1" },
        -- web's grants for the viewer. Hooks run as the repository's `user`,
        -- which whoever runs barchd picks; with no user this is skipped
        hooks = {
            after = { space = "spaces", call = "VIEWERGRANTS" },
        },
    }
end
