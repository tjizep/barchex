import re
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

import pytest

from .helpers import connect
from .test_client import setup

redis = pytest.importorskip("redis")

# A Desk has one owner, and an owner has one Desk. Each writer links desk 1,
# or owner 1, to its own row and unlinks it again in one pessimistic
# transaction, so every writer checks the same unique edge at once.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

local app = lent.graph {
    lent.schema "Desk" {
        id = "int", fields = { lent.field.string "name" },
        edges = { lent.edge.to "owner" "Person":unique() },
    },
    lent.schema "Person" {
        id = "int", fields = { lent.field.string "name" },
        edges = { lent.edge.from "desk" "Desk":ref "owner":unique() },
    },
}

function call(step, side, n, times)
    n, times = tonumber(n), tonumber(times)
    if step == "seed" then
        m.migrate(app)
        return client.open(app).tx(function(c)
            for i = 1, n do
                c.Desk:create { name = "d" .. i }
                c.Person:create { name = "p" .. i }
            end
            return "ok"
        end)
    end
    if step == "links" then
        return client.open(app).tx(function(c)
            return #c.Desk:query():links("owner"):all()
        end)
    end
    local db = client.open(app)
    for _ = 1, times do
        db.tx(function(c)
            if side == "from" then
                -- desk 1 has one owner: writer n's person
                c.Desk:link("owner", 1, n)
                c.Desk:unlink("owner", 1, n)
            else
                -- person 1 has one desk: writer n's desk
                c.Desk:link("owner", n, 1)
                c.Desk:unlink("owner", n, 1)
            end
        end, true)
    end
    return "ok"
end
"""

WRITERS = 4


def deadlocks(client):
    info = client.execute_command("INFO", "transactions")
    if isinstance(info, dict):
        return int(info["tx_deadlocks"])
    return int(re.search(r"tx_deadlocks:(\d+)", info).group(1))


@pytest.mark.parametrize("side", ["from", "to"])
def test_links_to_one_row_wait_in_turn(server, client, request, side):
    setup(client)
    space = "uniqlock_" + re.sub(r"\W", "_", request.node.name)
    client.execute_command("USE", space)
    client.execute_command("SETF", "UNIQLOCK", APP)
    assert client.execute_command("CALLF", "UNIQLOCK", "seed", side, WRITERS + 1, 0) == "ok"
    barrier = Barrier(WRITERS)

    def writer(n):
        conn = connect(server.port)
        try:
            conn.execute_command("USE", space)
            barrier.wait(timeout=10)
            return conn.execute_command("CALLF", "UNIQLOCK", "race", side, n, 50)
        finally:
            conn.close()

    before = deadlocks(client)
    with ThreadPoolExecutor(max_workers=WRITERS) as pool:
        done = list(pool.map(writer, range(2, WRITERS + 2)))
    assert done == ["ok"] * WRITERS
    assert deadlocks(client) == before
    assert client.execute_command("CALLF", "UNIQLOCK", "links", side, 0, 0) == 0
