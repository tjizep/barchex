import calendar
import datetime
import json
import random
import re

import pytest

from .test_client import setup

redis = pytest.importorskip("redis")

# Date helpers: lent.date and its calendar parts, checked against Python's
# datetime, and the date calls in filter expressions.
APP = """
local lent = require("lent.SCHEMA")
local m = require("lent.MIGRATE")
local client = require("lent.CLIENT")
local f = lent.field

local app = lent.graph {
    lent.schema "Event" {
        id = "int",
        fields = {
            f.string "name", f.time "at", f.time "ends":optional(),
            f.int "year":computed(function(r) return lent.year(r.at) end):stored(),
            f.int "endMonth":computed(function(r) return lent.month(r.ends) end),
        },
        indexes = { lent.index("at"), lent.index("year") },
    },
}
local db = client.open(app)

local function err(fn)
    local ok, e = pcall(fn)
    return ok and "no error" or tostring(e)
end

local steps = {}

-- each text as { ms, formatTime, parts, addMonths(n) as text }
function steps.convert(_, arg)
    local out = {}
    for i, case in lent.parseJson(arg) do
        local t = lent.date(case[1])
        local p = lent.dateParts(t)
        out[i] = lent.encodeJson({
            t, lent.formatTime(t), lent.formatDate(t),
            { p.year, p.month, p.day, p.hour, p.minute, p.second, p.millisecond, p.weekday },
            lent.formatTime(lent.addMonths(t, case[2])),
            lent.year(t), lent.month(t), lent.day(t),
        })
    end
    return out
end

function steps.forms()
    return {
        lent.date(1995, 3, 15), lent.date(1995, 3, 15, 10, 20, 30, 250),
        lent.date("1995-03-15T10:20:30.250Z"), lent.date("1995-03-15 12:20:30.25+02:00"),
        tostring(lent.year(nil)), tostring(lent.formatDate(nil)), tostring(lent.addMonths(nil, 1)),
    }
end

function steps.errors()
    return {
        err(function() lent.date("1995-02-29") end),
        err(function() lent.date("15/03/1995") end),
        err(function() lent.date(1995, 13, 1) end),
        err(function() lent.year("1995") end),
        err(function() lent.dateParts(1.5) end),
        err(function() lent.addMonths(0, 1.5) end),
        err(function() lent.addMonths(lent.date("9999-12-01"), 1) end),
    }
end

function steps.query(c)
    for i, at in { "1994-12-31T23:59:59.999Z", "1995-01-01", "1995-06-30T12:00Z", "1996-01-01" } do
        c.Event:create { name = "e" .. i, at = lent.date(at),
                         ends = i % 2 == 0 and lent.addMonths(lent.date(at), 2) or nil }
    end
    local function names(q)
        local out = {}
        for _, r in q:all() do out[#out + 1] = r.name .. (r.endMonth and "/" .. r.endMonth or "") end
        return table.concat(out, " ")
    end
    local span = c.Event:query():where("at >= date('1995-01-01') and at < date('1996-01-01')")
    local years = {}
    for _, g in c.Event:query():groupBy("year"):aggregate { n = { fn = "count" } } do
        years[#years + 1] = g.year .. "=" .. g.n
    end
    return {
        names(span), span:explain(),
        names(c.Event:query():where("year(at) == 1995 and month(at) > 1")),
        names(c.Event:query():where("day(ends) == 1")),
        names(c.Event:query():where("at < date(d)", { d = "1995-01-01" })),
        table.concat(years, " "),
        err(function() c.Event:query():where("at > date('soon')") end),
        err(function() c.Event:query():where("year(name) == 1") end),
        err(function() c.Event:query():where("week(at) == 1") end),
    }
end

function call(step, arg)
    if step == "migrate" then
        return m.migrate(app).done and "done" or "more"
    end
    return db.tx(function(c) return steps[step](c, arg) end)
end
"""


@pytest.fixture
def run(client, request):
    setup(client)
    client.execute_command("USE", re.sub(r"\W", "_", "dates_" + request.node.name))
    client.execute_command("SETF", "DATESAPP", APP)
    run = lambda step, arg="": client.execute_command("CALLF", "DATESAPP", step, arg)
    assert run("migrate") == "done"
    return run


EPOCH = datetime.datetime(1970, 1, 1)


def add_months(d, n):
    months = d.year * 12 + d.month - 1 + n
    y, m = divmod(months, 12)
    return d.replace(year=y, month=m + 1, day=min(d.day, calendar.monthrange(y, m + 1)[1]))


def iso(d):
    return "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ" % (
        d.year, d.month, d.day, d.hour, d.minute, d.second, d.microsecond // 1000)


def test_calendar_matches_python(run):
    rnd = random.Random(7)
    cases = []
    for _ in range(400):
        d = datetime.datetime(rnd.randint(1, 9998), rnd.randint(1, 12), rnd.randint(1, 28))
        d = d.replace(day=rnd.randint(1, calendar.monthrange(d.year, d.month)[1]))
        d += datetime.timedelta(milliseconds=rnd.randint(0, 86399999))
        cases.append((d, rnd.randint(-30, 30)))
    texts = [[iso(d), n] for d, n in cases]
    for (d, n), got in zip(cases, run("convert", json.dumps(texts))):
        ms = (d - EPOCH) // datetime.timedelta(milliseconds=1)
        assert json.loads(got) == [
            ms, iso(d), iso(d)[:10],
            [d.year, d.month, d.day, d.hour, d.minute, d.second, d.microsecond // 1000,
             d.isoweekday()],
            iso(add_months(d, n)), d.year, d.month, d.day,
        ], iso(d)


def test_date_forms(run):
    assert run("forms") == [
        795225600000, 795262830250, 795262830250, 795262830250, "nil", "nil", "nil",
    ]


def test_date_errors(run):
    wants = "wants a date such as 1995-03-15 or 1995-03-15T10:20:30Z, got "
    assert run("errors") == [
        "date " + wants + '"1995-02-29"',
        "date " + wants + '"15/03/1995"',
        "date has no date and time year 1995, month 13, day 1, 0:0:0.0",
        "year takes a time in Unix milliseconds, got 1995",
        "dateParts takes a time in Unix milliseconds, got 1.5",
        "addMonths takes a whole number of months, got 1.5",
        "addMonths has no date and time year 10000, month 1, day 1, 0:0:0.0",
    ]


def test_dates_in_queries(run):
    assert run("query") == [
        "e2/3 e3", "by_at range at",
        "e3",
        "e2/3 e4/3",
        "e1",
        "1994=1 1995=2 1996=1",
        """LENT table Event query where "at > date('soon')" at column 6: date wants a date such as 1995-03-15 or"""
        """ 1995-03-15T10:20:30Z, got "soon\"""",
        """LENT table Event query where "year(name) == 1" at column 1: year takes a number, got field name"""
        """ (string)""",
        """LENT table Event query where "week(at) == 1" at column 1: has no function week; expressions call date,"""
        """ year, month and day""",
    ]
