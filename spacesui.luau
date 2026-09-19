-- The spaces page, out of the `spaces.html` key this repository also ships.
--
-- Git sync with `as = keys` stores `.luau` as functions and everything else as
-- ordinary keys, so the HTML is not in the file store. This route serves that
-- key. CSS and icons still come from the shop at `/shop/shop.css` and
-- `/shop/common.js` when both are on the same host.
function call()
    return "spacesui"
end

function get(req, res)
    local html = barch.store["spaces.html"]
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
