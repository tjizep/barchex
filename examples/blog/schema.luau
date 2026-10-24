-- The blog's tables. BLOG requires this module and passes app() to MIGRATE,
-- so a change here reaches the space on the next `CALLF BLOG migrate`.
--
--   SCHEMA                  -> the table names, a check that the schema builds

local ent = require("ent.SCHEMA")

function app(): any
    return ent.graph {
        ent.schema "User" {
            fields = {
                ent.field.string "email":unique(),
                ent.field.string "name",
                ent.field.string "bio":optional(),
            },
            edges = {
                ent.edge.to "posts" "Post",
                ent.edge.to "follows" "User",
            },
        },
        ent.schema "Post" {
            format = "json",
            fields = {
                ent.field.string "title",
                ent.field.string "body",
                ent.field.int "stars":default(0),
            },
            indexes = { ent.index("stars") },
            edges = { ent.edge.from "author" "User":ref "posts":unique() },
        },
    }
end

function call()
    return app().order
end
