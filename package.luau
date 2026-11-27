-- How barchex installs itself from git:
--
--     barchd -g https://github.com/tjizep/barchex
--
-- barch applies this on every sync, in this order: the spaces, then the folders.
-- Each extension folder goes into the key space of the same name, except
-- streams/, which goes into the global space; tests/ stays out. The space
-- viewer that used to be here is github.com/tjizep/barch-spaces: add it with
-- a second -g.
function setup()
    return {
        -- listed so each space exists after a sync, and is open after a
        -- restart before anything else touches it
        spaces = {
            vectors  = {},
            s3       = {},
            watchdog = {},
            lent     = {},
        },
        load = {
            { path = "vectors",  space = "vectors" },
            { path = "s3",       space = "s3" },
            { path = "watchdog", space = "watchdog" },
            { path = "lent",     space = "lent" },
            -- no space: the global one, so XADD and the rest answer by their
            -- bare names on every connection
            { path = "streams" },
        },
    }
end
