import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Customers place orders, orders hold lines, and each line names a product.
# Path edges reach across the lines: a customer's products, a product's
# buyers, a line's customer, and the products bought in the same orders.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

local function app(version)
    local customer = { lent.edge.to "orders" "Order" }
    local order = { lent.edge.from "customer" "Customer":ref "orders":unique(),
                    lent.edge.to "lines" "Line" }
    local line = { lent.edge.from "order" "Order":ref "lines":unique(),
                   lent.edge.to "product" "Product":unique() }
    local product = { lent.edge.from "lines" "Line":ref "product" }
    if version ~= "plain" then
        table.insert(customer, lent.edge.through "products" "Product":via "orders.lines.product")
        -- through another path edge
        table.insert(customer, lent.edge.through "bought" "Product":via("orders", "products"))
        table.insert(order, lent.edge.through "products" "Product":via "lines.product")
        table.insert(line, { dir = "through", name = "customer", target = "Customer",
                             via = "order.customer" })
        table.insert(product, lent.edge.through "buyers" "Customer":via "lines.order.customer")
        table.insert(product, lent.edge.through "together" "Product"
            :via "lines.order.lines.product")
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
        local r = m.migrate(app(version))
        return { r.version, table.concat(r.steps, " ") }
    end
    -- reads use the catalog alone, so a client without the graph follows paths
    return client.tx(function(c)
        if step == "bad" then
            bad[which](c)
            return "no error"
        end
        return steps[step](c)
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
    assert run("migrate", "plain") == [1, "build Product.by_name"]
    assert run("seed", "plain") == "ok"
    # path edges store nothing, so adding them only changes the catalog
    assert run("migrate", "") == [2, ""]
    assert run("migrate", "") == [2, ""]
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
