-- The blog's tables. BLOG requires this module and passes app() to MIGRATE,
-- so a change here reaches the space on the next `CALLF BLOG migrate`.
--
--   SCHEMA                  -> the table names, a check that the schema builds

local lent = require("lent.SCHEMA")

function app(): any
    return lent.graph {
        lent.schema "User" {
            fields = {
                lent.field.string "email":unique(),
                lent.field.string "name",
                lent.field.string "bio":optional(),
            },
            edges = {
                lent.edge.to "posts" "Post",
                lent.edge.to "follows" "User",
            },
        },
        lent.schema "Post" {
            format = "json",
            fields = {
                lent.field.string "title",
                lent.field.string "body",
                lent.field.int "stars":default(0),
            },
            indexes = { lent.index("stars") },
            edges = { lent.edge.from "author" "User":ref "posts":unique() },
        },
    }
end

function call()
    return app().order
end
