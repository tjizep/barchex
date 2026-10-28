import datetime
import json
import random
import sqlite3

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# New York yellow taxi trips in lent, with the four queries of the common
# taxi benchmark. Each test answers one query in SQLite and in lent and
# compares the answers. Group keys that SQL computes, such as the pickup
# year, are computed fields in lent.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local f = lent.field

local app = lent.graph {
    lent.schema "Zone" {
        id = "int",
        fields = {
            f.string "borough", f.string "zone", f.string "service",
        },
        edges = { lent.edge.to "pickups" "Trip", lent.edge.to "dropoffs" "Trip" },
    },
    lent.schema "Trip" {
        fields = {
            f.int "vendor", f.time "pickup", f.time "dropoff",
            f.int "passengers":optional(), f.float "distance", f.int "ratecode",
            f.bool "stored", f.int "payment", f.float "fare", f.float "extra",
            f.float "mta", f.float "tip", f.float "tolls", f.float "improvement",
            f.float "total", f.float "congestion",
            f.int "year":computed(function(r) return lent.year(r.pickup) end),
            f.int "miles":computed(function(r) return math.round(r.distance) end),
        },
        indexes = { lent.index("pickup") },
        edges = {
            lent.edge.from "origin" "Zone":ref "pickups":unique(),
            lent.edge.from "destination" "Zone":ref "dropoffs":unique(),
        },
    },
}
local db = client.open(app)

-- the named values of each row; "null" stands for a missing value, which a
-- reply list cannot hold
local function pick(list, names)
    local out = {}
    for i, r in list do
        local row = {}
        for j, n in names do
            if r[n] == nil then row[j] = "null" else row[j] = r[n] end
        end
        out[i] = row
    end
    return out
end

local q = {}

function q.load(c, data)
    -- each zone keeps its location id, which the trips name
    for _, z in data.zones do
        z.id, z.location = z.location, nil
        c.Zone:create(z)
    end
    c.Trip:createMany(data.trips)
    return "ok"
end

-- SELECT vendor, count(*) GROUP BY vendor
function q.q1(c)
    return pick(c.Trip:query():groupBy("vendor"):aggregate { n = { fn = "count" } },
                { "vendor", "n" })
end

-- SELECT passengers, avg(total) GROUP BY passengers, with avg as sum and count
function q.q2(c)
    local groups = c.Trip:query():groupBy("passengers"):aggregate {
        total = { fn = "sum", field = "total" }, n = { fn = "count" },
    }
    for _, g in groups do g.avg = string.format("%.17g", g.total / g.n) end
    return pick(groups, { "passengers", "avg" })
end

-- SELECT passengers, year, count(*) GROUP BY passengers, year
function q.q3(c)
    return pick(c.Trip:query():groupBy("passengers", "year"):aggregate {
        n = { fn = "count" },
    }, { "passengers", "year", "n" })
end

-- SELECT passengers, year, round(distance), count(*) GROUP BY 1, 2, 3
-- ORDER BY year, count(*) DESC
function q.q4(c)
    local groups = c.Trip:query():groupBy("passengers", "year", "miles"):aggregate {
        n = { fn = "count" },
    }
    table.sort(groups, function(a, b)
        if a.year ~= b.year then return a.year < b.year end
        if a.n ~= b.n then return a.n > b.n end
        if a.passengers ~= b.passengers then
            return (a.passengers or -1) < (b.passengers or -1)
        end
        return a.miles < b.miles
    end)
    return pick(groups, { "passengers", "year", "miles", "n" })
end

-- trips by pickup borough, through the zone edge
function q.boroughs(c, p)
    local groups = c.Trip:query():where("pickup >= a and pickup < b", p)
        :groupBy("origin"):aggregate { n = { fn = "count" } }
    local by = {}
    for _, g in groups do
        local b = c.Zone:get(g.origin).borough
        by[b] = (by[b] or 0) + g.n
    end
    local out = {}
    for b, n in by do out[#out + 1] = { b, n } end
    table.sort(out, function(x, y) return x[1] < y[1] end)
    return out
end

function call(step, arg)
    if step == "migrate" then
        return m.migrate(app).done and "done" or "more"
    end
    return db.tx(function(c) return q[step](c, simdjson.parse(arg)) end)
end
"""

SCHEMA = """
create table zones (location int primary key, borough text, zone text, service text);
create table trips (vendor int, pickup text, dropoff text, passengers int,
                    distance real, ratecode int, stored int, payment int, fare real,
                    extra real, mta real, tip real, tolls real, improvement real,
                    total real, congestion real, pickup_zone int, dropoff_zone int);
"""

EPOCH = datetime.datetime(1970, 1, 1)


def ms(t):
    return int((t - EPOCH).total_seconds()) * 1000


def generate():
    rnd = random.Random(11)
    zones = [{"location": k, "borough": b, "zone": "zone %d" % k, "service": s}
             for k, (b, s) in enumerate([("Manhattan", "Yellow Zone"),
                                         ("Manhattan", "Yellow Zone"),
                                         ("Queens", "Airports"), ("Brooklyn", "Boro Zone"),
                                         ("Bronx", "Boro Zone")], 1)]
    trips = []
    for _ in range(300):
        pickup = datetime.datetime(2021, 6, 1) + datetime.timedelta(
            seconds=rnd.randint(0, 3 * 365 * 86400))
        fare = rnd.randint(250, 9000) / 100
        tip = rnd.randint(0, 2000) / 100
        trips.append({
            "vendor": rnd.choice([1, 2]), "pickup": pickup,
            "dropoff": pickup + datetime.timedelta(seconds=rnd.randint(60, 5400)),
            "passengers": rnd.choice([None, 1, 1, 1, 2, 3, 5]),
            "distance": rnd.randint(0, 3000) / 100, "ratecode": rnd.choice([1, 1, 2, 5]),
            "stored": rnd.random() < 0.05, "payment": rnd.choice([1, 2, 3]),
            "fare": fare, "extra": 0.5, "mta": 0.5, "tip": tip, "tolls": 0.0,
            "improvement": 0.3, "total": round(fare + 1.3 + tip, 2), "congestion": 2.5,
            "origin": rnd.randint(1, 5), "destination": rnd.randint(1, 5)})
    return zones, trips


# One load serves every query in this file, so the fixture uses the server
# directly; the client fixture empties the default space for each test.
@pytest.fixture(scope="module")
def taxi(server):
    client = server.client
    zones, trips = generate()
    setup(client)
    client.execute_command("USE", "nyc_taxi")
    client.execute_command("FLUSHDB")
    client.execute_command("SETF", "TAXI", APP)

    def run(step, arg=None):
        client.execute_command("USE", "nyc_taxi")
        return client.execute_command("CALLF", "TAXI", step, json.dumps(arg or {}))

    assert run("migrate") == "done"
    lent_trips = [{k: ms(v) if isinstance(v, datetime.datetime) else v
                   for k, v in t.items() if v is not None} for t in trips]
    assert run("load", {"zones": zones, "trips": lent_trips}) == "ok"
    db = sqlite3.connect(":memory:")
    db.executescript(SCHEMA)
    db.executemany("insert into zones values (?, ?, ?, ?)",
                   [[z["location"], z["borough"], z["zone"], z["service"]] for z in zones])
    cols = ["vendor", "pickup", "dropoff", "passengers", "distance", "ratecode", "stored",
            "payment", "fare", "extra", "mta", "tip", "tolls", "improvement", "total",
            "congestion", "origin", "destination"]
    db.executemany("insert into trips values (%s)" % ",".join("?" * len(cols)),
                   [[t[c].isoformat(sep=" ") if isinstance(t[c], datetime.datetime)
                     else t[c] for c in cols] for t in trips])
    sql = lambda text, **p: [list(r) for r in db.execute(text, p).fetchall()]
    return run, sql


def nulls(rows):
    return [["null" if v is None else v for v in r] for r in rows]


def test_count_by_vendor(taxi):
    run, sql = taxi
    want = sql("select vendor, count(*) from trips group by vendor order by vendor")
    assert run("q1") == want


def test_average_total_by_passengers(taxi):
    run, sql = taxi
    want = sql("""
        select passengers, avg(total) from trips
        group by passengers order by passengers nulls first""")
    got = run("q2")
    # the two sums add the same floats in different orders
    assert [[p, pytest.approx(float(a))] for p, a in got] == nulls(want)


def test_count_by_passengers_and_year(taxi):
    run, sql = taxi
    want = sql("""
        select passengers, cast(strftime('%Y', pickup) as int) as year, count(*)
        from trips group by passengers, year order by passengers nulls first, year""")
    assert run("q3") == nulls(want)


def test_count_by_passengers_year_and_distance(taxi):
    run, sql = taxi
    want = sql("""
        select passengers, cast(strftime('%Y', pickup) as int) as year,
               cast(round(distance) as int) as miles, count(*) as n
        from trips group by passengers, year, miles
        order by year, n desc, coalesce(passengers, -1), miles""")
    assert run("q4") == nulls(want)


def test_trips_by_pickup_borough(taxi):
    run, sql = taxi
    a, b = datetime.datetime(2022, 1, 1), datetime.datetime(2023, 1, 1)
    want = sql("""
        select borough, count(*) from trips join zones on pickup_zone = location
        where pickup >= :a and pickup < :b group by borough order by borough""",
               a=a.isoformat(sep=" "), b=b.isoformat(sep=" "))
    assert run("boroughs", {"a": ms(a), "b": ms(b)}) == want
