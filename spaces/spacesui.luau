-- The spaces page, out of the `spaces.html` key this repository also ships.
--
-- Git sync with `as = keys` stores `.luau` as functions and everything else as
-- ordinary keys, so the HTML is not in the file store. This route serves that
-- key. The page is self-contained: the CSS, the icons, the theme toggle and
-- the sign-in form are inlined, so it needs nothing from the shop.
function call()
    return "spacesui"
end

function get(req, res)
    local html = barch.store.get("spaces.html")
    if type(html) ~= "string" then
        res.code = 404
        res.body = "spaces.html is not in this space"
        return
    end
    res:header("Content-Type", "text/html; charset=utf-8")
    res.body = html
end

function transport()
    return {
        kind = "resource",
        route = "/spaces",
        methods = { GET = get },
        send = "text/html; charset=utf-8",
    }
end
