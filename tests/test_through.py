import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Customers place orders, orders hold lines, and each line names a product.
# Path edges reach across the lines: a customer's products, a product's
# buyers, a line's customer, and the products bought in the same orders.
# Version "stored" keeps most of them in stores of their own.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local lay = require("lent.LAYOUT")

local function app(version)
    local function keep(e)
        return version == "stored" and e:stored() or e
    end
    local customer = { lent.edge.to "orders" "Order" }
    local order = { lent.edge.from "customer" "Customer":ref "orders":unique(),
                    lent.edge.to "lines" "Line" }
    local line = { lent.edge.from "order" "Order":ref "lines":unique(),
                   lent.edge.to "product" "Product":unique() }
    local product = { lent.edge.from "lines" "Line":ref "product" }
    if version ~= "plain" then
        table.insert(customer, keep(lent.edge.through "products" "Product"
            :via "orders.lines.product"))
        -- through another path edge
        table.insert(customer, keep(lent.edge.through "bought" "Product":via("orders", "products")))
        table.insert(order, lent.edge.through "products" "Product":via "lines.product")
        table.insert(line, { dir = "through", name = "customer", target = "Customer",
                             via = "order.customer", stored = version == "stored" })
        table.insert(product, keep(lent.edge.through "buyers" "Customer"
            :via "lines.order.customer"))
        table.insert(product, keep(lent.edge.through "together" "Product"
            :via "lines.order.lines.product"))
    end
    if version == "clash" then
        customer[2] = lent.edge.to "products" "Product"
    end
    return lent.graph {
        lent.schema "Customer" { id = "int", fields = { lent.field.string "name" },
                                 edges = customer },
        lent.schema "Order" { id = "int", fields = { lent.field.int "no" }, edges = order },
        lent.schema "Line" { id = "int", fields = { lent.field.int "qty" }, edges = line },
        lent.schema "Product" {
            id = "int",
            fields = { lent.field.string "name":unique(), lent.field.string "color" },
            edges = product,
        },
    }
end

local function names(list)
    local out = {}
    for _, r in list do out[#out + 1] = r.name end
    return table.concat(out, ",")
end

local steps = {}

function steps.seed(c)
    local ann = c.Customer:create { name = "ann" }
    local bob = c.Customer:create { name = "bob" }
    c.Customer:create { name = "cy" }
    local pen = c.Product:create { name = "pen", color = "red" }
    local ink = c.Product:create { name = "ink", color = "blue" }
    local pad = c.Product:create { name = "pad", color = "red" }
    c.Product:create { name = "cap", color = "green" }
    local o1 = c.Order:create { no = 1, customer = ann }
    local o2 = c.Order:create { no = 2, customer = ann }
    local o3 = c.Order:create { no = 3, customer = bob }
    c.Line:create { qty = 2, order = o1, product = pen }
    c.Line:create { qty = 1, order = o1, product = ink }
    c.Line:create { qty = 5, order = o2, product = pen }
    c.Line:create { qty = 3, order = o3, product = pad }
    c.Line:create { qty = 1, order = o3, product = ink }
    return "ok"
end

function steps.follow(c)
    local ann = c.Customer:query():where("name", "=", "ann")
    local q = ann:queryProducts()
    return {
        -- ann bought pen twice; each product comes once
        names(q:all()) .. " | " .. q:explain(),
        names(c.Customer:query():follow("orders.lines.product"):all()),
        names(c.Customer:query():follow("orders", "lines", "product"):all()),
        names(ann:queryBought():all()),
        names(c.Customer:query():where("name", "=", "cy"):queryProducts():all()),
        names(c.Product:query():where("name", "=", "ink"):queryBuyers():all()),
        names(c.Product:query():where("name", "=", "pen"):queryTogether():all()),
        names(c.Order:query():where("no", "=", 3):queryProducts():order("name"):all()),
        -- a path edge and a stored edge in one follow
        names(c.Order:query():where("no", "=", 1):follow("products", "buyers"):all()),
    }
end

function steps.has(c)
    local function bought(name)
        return function(p) p:where("name", "=", name) end
    end
    local red = c.Customer:query():hasProductsWith(function(p) p:where("color", "=", "red") end)
    local pad = c.Customer:query():hasProductsWith(bought("pad"))
    local none = c.Customer:query():hasProductsWith(bought("cap"))
    return {
        names(red:all()) .. " | " .. red:explain(),
        names(pad:all()) .. " | " .. pad:explain(),
        names(none:all()),
        names(c.Customer:query():hasProducts():all()),
        names(c.Product:query():hasBuyersWith(function(b) b:where("name", "=", "bob") end)
            :order("name"):all()),
    }
end

function steps.with(c)
    local out = {}
    for _, r in c.Customer:query():withProducts(function(q) q:order("name", "desc") end):all() do
        out[#out + 1] = r.name .. "=" .. names(r.products)
    end
    for _, r in c.Line:query():where("qty", ">", 2):withCustomer():all() do
        out[#out + 1] = r.qty .. "=" .. r.customer.name
    end
    return out
end

function steps.groups(c)
    local out = {}
    for _, g in c.Line:query():groupBy("customer"):aggregate { qty = { fn = "sum", field = "qty" } } do
        out[#out + 1] = tostring(g.customer) .. "=" .. g.qty
    end
    return out
end

function steps.change(c)
    -- ann's ink came from line 2 alone; her pen also comes from line 3
    c.Line:delete(2)
    c.Line:unlink("product", 1, 1)
    local ann = c.Customer:query():where("name", "=", "ann")
    return names(ann:queryProducts():all())
end

-- Every link of each filled path store against a count of its paths, and
-- the links of `show` as "from>to=paths".
function steps.check(_, show)
    local cat = m.load()
    local wrong, shown = {}, {}
    for store, s in cat.edges do
        if s.path and s.state == nil then
            local t
            for _, x in cat.tables do
                if x.name == s.from then t = x end
            end
            local links = 0
            lay.walk(lay.row(t), function(k)
                local pk = lay.row_pk(t, k)
                local want = lay.path_counts(cat.edges, s.path, { [pk] = 1 }, 1, #s.path)
                lay.walk(lay.edge(s, pk), function(key)
                    local to, n = lay.edge_to(s, key), tonumber(barch.store.get(key))
                    if want[to] ~= n or not barch.store.exists(lay.edge_back(s, to, pk)) then
                        wrong[#wrong + 1] = store .. " " .. pk .. ">" .. to
                    end
                    want[to] = nil
                    links += 1
                    if store == show then shown[#shown + 1] = pk .. ">" .. to .. "=" .. n end
                end)
                for to in want do
                    wrong[#wrong + 1] = store .. " " .. pk .. ">" .. to .. " missing"
                end
            end)
            local _, back = lay.edge_store(s)
            if lay.walk(back, function() end) ~= links then
                wrong[#wrong + 1] = store .. " back keys"
            end
        end
    end
    table.sort(wrong)
    return { #wrong == 0 and "ok" or table.concat(wrong, ", "), table.concat(shown, " ") }
end

-- How many keys the stores of the path edges hold.
function steps.keys()
    local n = 0
    for _, store in { "customer_products", "customer_bought", "line_customer",
                      "product_buyers", "product_together" } do
        for _, prefix in { lay.edge_store({ name = store }) } do
            n += lay.walk(prefix, function() end)
        end
    end
    return n
end

-- Link changes on every hop: new rows and links, unlinks, and deletes.
function steps.edit(c)
    local ann = c.Customer:get(1)
    local cap = c.Product:by("by_name", "cap")
    local o4 = c.Order:create { no = 4, customer = ann }
    c.Line:create { qty = 1, order = o4, product = cap }
    c.Line:create { qty = 1, order = o4, product = 1 }
    -- line 1 moves from order 1 to order 3
    c.Order:unlink("lines", 1, 1)
    c.Order:link("lines", 3, 1)
    c.Line:unlink("product", 4, 3)
    c.Line:link("product", 4, 1)
    c.Order:unlink("customer", 3, 2)
    c.Customer:link("orders", 3, 3)
    c.Line:delete(2)
    return "ok"
end

function steps.remove(c)
    c.Order:delete(1)
    c.Product:delete(1)
    c.Customer:delete(3)
    return "ok"
end

local bad = {
    link = function(c) c.Customer:link("products", 1, 4) end,
    unlink = function(c) c.Customer:unlink("products", 1, 1) end,
    edge = function(c) c.Customer:edge("products", 1, 1) end,
    create = function(c) c.Customer:create { name = "di", products = { 1 } } end,
    update = function(c) c.Customer:update(1, { products = { 4 } }) end,
    group = function(c) c.Customer:query():groupBy("products") end,
    whereEdge = function(c)
        c.Customer:query():hasProductsWith(function(p) p:whereEdge("qty", ">", 1) end):all()
    end,
    follow = function(c) c.Customer:query():follow("orders.nope") end,
    followNone = function(c) c.Customer:query():follow() end,
    followKind = function(c) c.Customer:query():follow(1) end,
}

function call(step, version, which)
    if step == "migrate" then
        local r = m.migrate(app(version), which and tonumber(which))
        return { r.version, table.concat(r.steps, " "), r.done and 1 or 0 }
    end
    -- reads use the catalog alone, so a client without the graph follows paths
    return client.tx(function(c)
        if step == "bad" then
            bad[which](c)
            return "no error"
        end
        return steps[step](c, which)
    end)
end
"""


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", "through_" + request.node.name)
    client.execute_command("SETF", "SHOP", APP)
    return lambda *a: client.execute_command("CALLF", "SHOP", *a)


@pytest.fixture
def shop(run):
    assert run("migrate", "plain") == [1, "build Product.by_name", 1]
    assert run("seed", "plain") == "ok"
    # path edges store nothing, so adding them only changes the catalog
    assert run("migrate", "") == [2, "", 1]
    assert run("migrate", "") == [2, "", 1]
    return run


def test_through_follow(shop):
    assert shop("follow", "") == [
        "pen,ink | edge customer_orders/order_lines/line_product",
        "pen,ink,pad",
        "pen,ink,pad",
        "pen,ink",
        "",
        "ann,bob",
        "pen,ink",
        "ink,pad",
        "ann,bob",
    ]


def test_through_has(shop):
    assert shop("has", "") == [
        # color has no index, so each customer's products are checked
        "ann,bob | id, has products",
        # name has one, so the matching product's buyers are read backwards
        "bob | has products from (by_name = name)",
        "",
        "ann,bob",
        "ink,pad",
    ]


def test_through_with_and_group_by(shop):
    assert shop("with", "") == ["ann=pen,ink", "bob=pad,ink", "cy=", "5=ann", "3=bob"]
    # every hop of Line.customer links one row, so groupBy can use it
    assert shop("groups", "") == ["1=8", "2=4"]


def test_through_follows_changes(shop):
    assert shop("change", "") == "pen"


ERRORS = {
    "link": "LENT table Customer edge products goes through orders.lines.product, so its"
            " links change through those edges",
    "unlink": "edge products goes through orders.lines.product",
    "edge": "edge products goes through orders.lines.product",
    "create": "edge products goes through orders.lines.product",
    "update": "edge products goes through orders.lines.product",
    "group": "LENT table Customer edge products can link a row to many rows, so groupBy"
             " cannot use it",
    "whereEdge": "LENT table Customer edge products has no fields",
    "follow": "LENT table Order has no edge nope",
    "followNone": "LENT table Customer query follow takes at least one edge name",
    "followKind": "LENT table Customer query follow takes edge names, got 1",
}


def test_through_errors(shop):
    for which, message in ERRORS.items():
        with pytest.raises(redis.ResponseError) as err:
            shop("bad", "", which)
        assert message in str(err.value), which


STORED = ["Customer.bought", "Customer.products", "Line.customer", "Product.buyers",
          "Product.together"]


def steps_of(text):
    words = text.split(" ")
    return sorted(zip(words[::2], words[1::2]))


@pytest.fixture
def stored(shop):
    # two rows a page: each store's drop and fill take several calls
    first = shop("migrate", "stored", 2)
    assert first[0] == 3 and first[2] == 0
    assert steps_of(first[1]) == sorted([("drop", e) for e in STORED]
                                        + [("fill", e) for e in STORED])
    while shop("migrate", "stored", 2)[2] == 0:
        pass
    assert shop("migrate", "stored") == [3, "", 1]
    return shop


def test_stored_path_fill(stored):
    assert stored("check", "", "product_together") == [
        # pen's lines 1 and 3 reach pen through their own orders, and line 1
        # reaches ink through order 1
        "ok", "1>1=2 1>2=1 2>1=1 2>2=2 2>3=1 3>2=1 3>3=1"]
    assert stored("check", "", "customer_products")[1] == "1>1=2 1>2=1 2>2=1 2>3=1"
    assert stored("follow", "")[0] == "pen,ink | edge customer_products"
    assert stored("follow", "")[1:] == [
        "pen,ink,pad", "pen,ink,pad", "pen,ink", "", "ann,bob", "pen,ink", "ink,pad", "ann,bob"]
    assert stored("has", "")[0] == "ann,bob | id, has products"
    assert stored("has", "")[1:] == [
        "bob | has products from (by_name = name)", "", "ann,bob", "ink,pad"]
    assert stored("with", "") == ["ann=pen,ink", "bob=pad,ink", "cy=", "5=ann", "3=bob"]
    assert stored("groups", "") == ["1=8", "2=4"]


def test_stored_path_follows_link_changes(stored):
    assert stored("edit", "stored") == "ok"
    assert stored("check", "stored", "customer_products") == [
        "ok", "1>1=2 1>4=1 3>1=2 3>2=1"]
    assert stored("change", "stored") == "pen,cap"
    assert stored("check", "stored")[0] == "ok"
    assert stored("remove", "stored") == "ok"
    assert stored("check", "stored", "customer_products") == ["ok", "1>4=1"]


def test_stored_path_while_filling(shop):
    first = shop("migrate", "stored", 1)
    assert first[2] == 0
    # until its store is filled, a stored path edge walks its hops
    assert shop("follow", "stored")[0] == (
        "pen,ink | edge customer_orders/order_lines/line_product")
    assert shop("edit", "stored") == "ok"
    while shop("migrate", "stored", 1)[2] == 0:
        pass
    assert shop("check", "stored", "customer_products") == [
        "ok", "1>1=2 1>4=1 3>1=2 3>2=1"]
    assert shop("follow", "stored")[0] == "pen,cap | edge customer_products"


def test_stored_path_unstore(stored):
    assert stored("keys", "") > 0
    version, text, done = stored("migrate", "", 1)
    assert (version, done) == (4, 0)
    assert steps_of(text) == sorted(("drop", e) for e in STORED)
    # rows stay writable while the stores are dropped
    assert stored("edit", "") == "ok"
    while stored("migrate", "", 1)[2] == 0:
        pass
    assert stored("keys", "") == 0
    assert stored("follow", "")[0] == "pen,cap | edge customer_orders/order_lines/line_product"


def test_stored_path_refuses_reuse(stored):
    with pytest.raises(redis.ResponseError) as err:
        stored("migrate", "clash")
    assert ("MIGRATE edge customer_products was the store of table Customer edge products,"
            " a stored edge.through; migrate once without the edge before declaring it"
            " again") in str(err.value)
