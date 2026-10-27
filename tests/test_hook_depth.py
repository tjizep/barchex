import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Hooks that write rows whose hooks write again. A Step's create hook
# creates the next Step until it reaches the row's `stop`; Ping and Pong
# create each other.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")

local app = lent.graph {
    lent.schema "Step" {
        id = "int",
        fields = { lent.field.int "n", lent.field.int "stop" },
        hooks = { create = { function(c, r)
            if r.n < r.stop then
                c.Step:create { n = r.n + 1, stop = r.stop }
            end
        end } },
    },
    lent.schema "Ping" {
        id = "int",
        fields = { lent.field.int "n" },
        hooks = { create = { function(c, r) c.Pong:create { n = r.n + 1 } end } },
    },
    lent.schema "Pong" {
        id = "int",
        fields = { lent.field.int "n" },
        hooks = { create = { function(c, r) c.Ping:create { n = r.n + 1 } end } },
    },
}
local db = client.open(app)

local function err(fn)
    local ok, e = pcall(fn)
    return ok and "no error" or tostring(e)
end

local steps = {}

-- 16 nested hook runs fit; a 17th raises, and the caught error takes back
-- every row the chain wrote, so later writes start at depth 0 again
function steps.chain(c)
    c.Step:create { n = 1, stop = 16 }
    local deep = err(function() c.Step:create { n = 1, stop = 17 } end)
    local after = c.Step:query():count()
    c.Step:create { n = 1, stop = 16 }
    return { deep, after, c.Step:query():count() }
end

function steps.loop(c)
    return { err(function() c.Ping:create { n = 0 } end), c.Ping:query():count(),
             c.Pong:query():count() }
end

function call(step, mode)
    if step == "migrate" then
        return m.migrate(app).done and "done" or "more"
    end
    return db.tx(function(c) return steps[step](c) end, mode == "pessimistic")
end
"""


@pytest.fixture(params=["optimistic", "pessimistic"])
def run(client, request):
    setup(client)
    client.execute_command("USE", re.sub(r"\W", "_", "hook_depth_" + request.node.name))
    client.execute_command("SETF", "HOOKDEPTH", APP)
    mode = request.param
    run = lambda step: client.execute_command("CALLF", "HOOKDEPTH", step, mode)
    assert run("migrate") == "done"
    return run


def test_hooks_nest_sixteen_deep(run):
    assert run("chain") == [
        "LENT table Step create hooks nest more than 16 deep; each write from a hook runs"
        " hooks again, here through table Step create",
        16,
        32,
    ]


def test_hooks_that_write_each_other_stop(run):
    assert run("loop") == [
        "LENT table Ping create hooks nest more than 16 deep; each write from a hook runs"
        " hooks again, here through table Ping create, table Pong create",
        0,
        0,
    ]
