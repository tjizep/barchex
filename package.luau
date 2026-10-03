-- How barchex installs itself from git:
--
--     barchd -g https://github.com/tjizep/barchex
--
-- barch applies this on every sync, in this order: the spaces, then the folders.
-- Each extension folder goes into the key space of the same name; tests/ stays
-- out. The space viewer that used to be here is github.com/tjizep/barch-spaces:
-- add it with a second -g.
function setup()
    return {
        -- listed so each space exists after a sync, and is open after a
        -- restart before anything else touches it
        spaces = {
            vectors  = {},
            s3       = {},
            watchdog = {},
        },
        load = {
            { path = "vectors",  space = "vectors" },
            { path = "s3",       space = "s3" },
            { path = "watchdog", space = "watchdog" },
        },
    }
end
