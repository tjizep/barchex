-- WATCHDOG: keeps an eye on barch's error counters and sends mail when one of
-- them starts climbing, when things are quiet again, and when barchd restarts.
--
--   watchdog.WATCHDOG INSTALL [user]   add the cron entry that ticks it (as user,
--                                      default "default"); UNINSTALL takes it away
--   watchdog.WATCHDOG STATUS           each counter: last window, rate, baseline
--   watchdog.WATCHDOG TEST             sends a test message to watchdog.to
--   watchdog.WATCHDOG TICK             one check; what the cron entry calls
--   watchdog.WATCHDOG RESET            forgets the samples and alert state
--
-- Every tick reads INFO ERRORS and INFO FOREIGN and keeps a sample of the
-- counters. A counter is alerting when the last `window` holds at least
-- `min_count` of its errors, at more than `factor` times its rate over the
-- `baseline` before that. With no baseline yet, min_count alone decides. The
-- counters are totals since barchd started, and CONFIG RESETSTAT or a restart
-- sets them back to 0, so a counter that goes down counts from 0 again.
--
-- Settings are keys in configuration, read on every tick:
--
--   watchdog.to         who gets the mail, comma separated
--   watchdog.webhook    URLs to POST to as well, or instead, comma separated
--   watchdog.webhook_format  json (default: `text` and `content` for Slack,
--                       Mattermost and Discord, and the parts for anything else)
--                       or plain (the text, with a Title header, for ntfy)
--   watchdog.webhook_auth    an Authorization header to send, e.g. "Bearer ..."
--   watchdog.name       what the mail calls this server (default barchd:<port>)
--   watchdog.every      the tick, for INSTALL: 1m
--   watchdog.window     5m        watchdog.baseline  1h
--   watchdog.factor     3         watchdog.min_count 5
--   watchdog.cooldown   30m       at most one alert per counter this often
--   watchdog.restart    1         0 stops the mail about restarts
--   watchdog.counters   the counters to watch, comma separated (default: INFO
--                       ERRORS but net_errors, and foreign_errors)
--
-- Mail goes through mail.send, so mail.server and friends have to be set (see
-- barch's docs); webhooks go through http.request. Either way the cron user
-- needs the outbound category. A message a sink didn't take is tried again on
-- the next tick, through that sink only.
--
-- Samples and state live in this space, `watchdog`, whichever space the call
-- comes from.

-- net_errors isn't here: barch 0.5.8 counts a client closing its connection
-- after a command as one, so it follows connection churn rather than trouble.
-- watchdog.counters can add it back.
local COUNTERS = {
    "function_timeouts", "function_errors", "oom_avoided_inserts", "refused_connections",
    "accept_errors", "request_errors", "exceptions_raised", "foreign_errors",
}

local DEFAULTS = {
    every = "1m", window = "5m", baseline = "1h", factor = "3", min_count = "5",
    cooldown = "30m", restart = "1", webhook_format = "json",
}

local function home()
    return barch.space.watchdog
end

local function setting(name: string): string?
    local v = barch.space.configuration["watchdog." .. name]
    if v == nil or v == "" then return DEFAULTS[name] end
    return v
end

-- "90s", "5m", "1h30m", "250ms" to milliseconds
local UNITS = { ms = 1, s = 1000, m = 60000, h = 3600000, d = 86400000 }
local function duration(s: string, name: string): number
    local total, seen = 0, false
    for n, unit in string.gmatch(s, "(%d+)(%a+)") do
        local k = UNITS[unit]
        if not k then error("watchdog: " .. name .. " '" .. s .. "' has an unknown unit " .. unit) end
        total += tonumber(n) * k
        seen = true
    end
    if not seen then
        local plain = tonumber(s)
        if not plain then error("watchdog: " .. name .. " '" .. s .. "' isn't a duration like 5m") end
        total = plain * 1000
    end
    return total
end

local function number(name: string): number
    local v = tonumber(setting(name) or "")
    if not v then error("watchdog: watchdog." .. name .. " isn't a number") end
    return v
end

-- the time, from a key's expiry: the sandbox has no clock
local function now_ms(): number
    local sp = home()
    sp:call("SET", "clock", "1", "PX", "60000")
    return integer.tonumber(sp:call("PEXPIRETIME", "clock")) - 60000
end

local function info(section: string)
    local out = {}
    for line in string.gmatch(tostring(barch.call("INFO", section) or ""), "[^\r\n]+") do
        local k, v = string.match(line, "^([%w_]+):(.*)$")
        if k then out[k] = v end
    end
    return out
end

local function watched()
    local list = barch.space.configuration["watchdog.counters"]
    if list == nil or list == "" then return COUNTERS end
    local out = {}
    for name in string.gmatch(list, "[^,%s]+") do table.insert(out, name) end
    return out
end

local function load(key: string, empty)
    local raw = home()[key]
    if raw == nil or raw == "" then return empty end
    local ok, v = pcall(simdjson.parse, raw)
    if not ok or type(v) ~= "table" then return empty end
    return v
end

-- simdjson hands whole numbers back as barch integers, which don't mix with
-- Luau numbers in arithmetic
local function num(x): number
    if type(x) == "number" then return x end
    if x == nil then return 0 end
    local ok, v = pcall(integer.tonumber, x)
    if ok and v then return v end
    return tonumber(x) or 0
end

local function load_samples()
    local out = {}
    for _, s in load("samples", {}) do
        local c = {}
        for k, v in s.c or {} do c[k] = num(v) end
        table.insert(out, { t = num(s.t), up = num(s.up), c = c })
    end
    return out
end

local function load_state()
    local st = load("state", {})
    local last = {}
    for k, v in st.last_alert or {} do last[k] = num(v) end
    local on = {}
    for k, v in st.alerting or {} do if v then on[k] = true end end
    local pending = {}
    for _, msg in st.pending or {} do
        local done = {}
        for k, v in msg.done or {} do if v then done[k] = true end end
        table.insert(pending, { subject = msg.subject, text = msg.text, done = done,
                                at = msg.at and num(msg.at) or nil })
    end
    return {
        alerting = on, last_alert = last, pending = pending,
        last_sent = st.last_sent and num(st.last_sent) or nil,
        last_tick = st.last_tick and num(st.last_tick) or nil,
        last_error = st.last_error,
    }
end

local function store(key: string, value)
    home()[key] = simdjson.encode(value)
end

local function clock(ms: number): string
    local s = ms // 1000
    local days, rest = s // 86400, s % 86400
    local z = days + 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    local y = yoe + era * 400 + (m <= 2 and 1 or 0)
    return string.format("%04d-%02d-%02d %02d:%02d:%02d UTC", y, m, d,
        rest // 3600, rest % 3600 // 60, rest % 60)
end

local function span(ms: number): string
    if ms >= 3600000 and ms % 3600000 == 0 then return (ms // 3600000) .. "h" end
    if ms >= 60000 and ms % 60000 == 0 then return (ms // 60000) .. "m" end
    if ms >= 1000 then return string.format("%.0fs", ms / 1000) end
    return ms .. "ms"
end

local function per_minute(count: number, ms: number): string
    if ms <= 0 then return "-" end
    return string.format("%.2f/min", count * 60000 / ms)
end

-- errors counted between two samples: the difference, or the new value when
-- the counter went back to 0 in between
local function increase(a, b, name: string): number
    local x, y = a.c[name] or 0, b.c[name] or 0
    if y >= x and b.up >= a.up then return y - x end
    return y
end

-- what the samples say about each counter: its errors in the last window, the
-- time that covers, and the same for the baseline before it
local function measure(samples, t: number)
    local window, baseline = duration(setting("window"), "window"), duration(setting("baseline"), "baseline")
    local out = {}
    for _, name in watched() do
        local recent, recent_ms, base, base_ms = 0, 0, 0, 0
        for i = 2, #samples do
            local a, b = samples[i - 1], samples[i]
            local n, dt = increase(a, b, name), b.t - a.t
            if b.t > t - window then
                recent += n; recent_ms += dt
            elseif b.t > t - window - baseline then
                base += n; base_ms += dt
            end
        end
        out[name] = { recent = recent, recent_ms = recent_ms, base = base, base_ms = base_ms }
    end
    return out, window, baseline
end

local function alerting(m, factor: number, min_count: number): boolean
    if m.recent < min_count or m.recent_ms <= 0 then return false end
    if m.base_ms <= 0 then return true end
    return m.recent / m.recent_ms > factor * (m.base / m.base_ms)
end

local function server_name(): string
    local v = barch.space.configuration["watchdog.name"]
    if v ~= nil and v ~= "" then return v end
    return "barchd:" .. tostring(info("SERVER").tcp_port or "?")
end

local function list_of(name: string)
    local out = {}
    for item in string.gmatch(barch.space.configuration["watchdog." .. name] or "", "[^,]+") do
        item = string.match(item, "^%s*(.-)%s*$")
        if item ~= "" then table.insert(out, item) end
    end
    return out
end

local function recipients() return list_of("to") end
local function webhooks() return list_of("webhook") end

local function send_mail(msg)
    local r = mail.send{ to = recipients(), subject = "[" .. server_name() .. "] " .. msg.subject, text = msg.text }
    if not r.ok then return nil, "mail: " .. (r.error or ("the server answered " .. tostring(r.code))) end
    return true
end

-- json: `text` for Slack and Mattermost, `content` (Discord's, at most 2000
-- characters) and the parts on their own for anything else. plain: the text as
-- the body and the subject as a Title header, which is what ntfy takes
local function send_hook(url: string, msg)
    local title = "[" .. server_name() .. "] " .. msg.subject
    local headers, body = {}, nil
    local auth = barch.space.configuration["watchdog.webhook_auth"]
    if auth ~= nil and auth ~= "" then headers["Authorization"] = auth end
    if setting("webhook_format") == "plain" then
        headers["Content-Type"] = "text/plain; charset=utf-8"
        headers["Title"] = title
        body = msg.text
    else
        headers["Content-Type"] = "application/json"
        local whole = title .. "\n\n" .. msg.text
        body = simdjson.encode({
            text = whole, content = string.sub(whole, 1, 1990),
            server = server_name(), subject = msg.subject, body = msg.text,
            time = msg.at and clock(msg.at) or nil,
        })
    end
    local r = http.request(url):headers(headers):body(body):timeout(10000):post()
    if not r.ok then
        return nil, "webhook " .. url .. ": " .. (r.error or ("HTTP " .. tostring(r.status)))
    end
    return true
end

-- sends msg wherever it still has to go; `blocked` are the sinks that already
-- failed this tick, so later messages wait behind the earlier ones
local function deliver(msg, blocked)
    msg.done = msg.done or {}
    local why = nil
    if #recipients() > 0 and not msg.done.mail and not blocked.mail then
        local ok, err = send_mail(msg)
        if ok then msg.done.mail = true else blocked.mail = true; why = err end
    end
    for _, url in webhooks() do
        if not msg.done[url] and not blocked[url] then
            local ok, err = send_hook(url, msg)
            if ok then msg.done[url] = true else blocked[url] = true; why = why or err end
        end
    end
    local finished = true
    if #recipients() > 0 and not msg.done.mail then finished = false end
    for _, url in webhooks() do
        if not msg.done[url] then finished = false end
    end
    return finished, why
end

local function table_of(names, m, window: number)
    local lines = {}
    for _, name in names do
        local x = m[name]
        table.insert(lines, string.format("  %-22s %6d in the last %s (%s), baseline %s",
            name, x.recent, span(x.recent_ms), per_minute(x.recent, x.recent_ms),
            x.base_ms > 0 and per_minute(x.base, x.base_ms) or "not yet"))
    end
    return table.concat(lines, "\n")
end

-- one check: sample, compare, and send word of whatever changed
function tick()
    local t = now_ms()
    local up = tonumber(info("SERVER").uptime_in_seconds) or 0
    local counters = {}
    for section, _ in { ERRORS = true, FOREIGN = true } do
        for k, v in info(section) do counters[k] = tonumber(v) end
    end
    local samples = load_samples()
    local state = load_state()

    local last = samples[#samples]
    if last and up < last.up and setting("restart") ~= "0" then
        table.insert(state.pending, {
            subject = "barchd restarted",
            text = string.format("%s restarted: it has been up %ds at %s, and was up %ds at the tick before (%s).\n"
                .. "Its error counters started again from 0.", server_name(), up, clock(t), last.up, clock(last.t)),
        })
    end
    table.insert(samples, { t = t, up = up, c = counters })

    local m, window, baseline = measure(samples, t)
    -- the samples the next measure needs, and one before them to difference from
    local keep_from = t - window - baseline
    local first = 1
    while first < #samples and samples[first + 1].t <= keep_from do first += 1 end
    if first > 1 then
        local kept = {}
        for i = first, #samples do table.insert(kept, samples[i]) end
        samples = kept
    end
    store("samples", samples)

    local factor, min_count = number("factor"), number("min_count")
    local cooldown = duration(setting("cooldown"), "cooldown")
    local started, all = {}, {}
    local was_alerting = next(state.alerting) ~= nil
    for _, name in watched() do
        table.insert(all, name)
        local now_on = alerting(m[name], factor, min_count)
        if now_on and not state.alerting[name] then
            -- inside the cooldown it stays off, and is looked at again next tick
            local since = state.last_alert[name]
            if since == nil or t - since >= cooldown then
                table.insert(started, name)
                state.last_alert[name] = t
                state.alerting[name] = true
            end
        elseif not now_on then
            state.alerting[name] = nil
        end
    end
    if #started > 0 then
        table.insert(state.pending, {
            subject = table.concat(started, ", ") .. " climbing",
            text = string.format("At %s these error counters are climbing: more than %d in %s, and more than %gx their rate before.\n\n%s\n\nAll counters:\n%s\n",
                clock(t), min_count, span(window), factor, table_of(started, m, window), table_of(all, m, window)),
        })
    end
    if was_alerting and next(state.alerting) == nil then
        table.insert(state.pending, {
            subject = "error rates back to normal",
            text = string.format("At %s no error counter is climbing any more.\n\n%s\n", clock(t), table_of(all, m, window)),
        })
    end

    -- send what's waiting, oldest first; what a sink couldn't take is tried
    -- again on the next tick, and only through the sinks it hasn't reached
    local still, blocked = {}, {}
    state.last_error = nil
    if #state.pending > 0 and #recipients() == 0 and #webhooks() == 0 then
        state.last_error = "nowhere to send: set watchdog.to or watchdog.webhook"
        still = state.pending
    else
        for _, msg in state.pending do
            msg.at = msg.at or t
            local finished, why = deliver(msg, blocked)
            if why then state.last_error = why end
            if finished then state.last_sent = t else table.insert(still, msg) end
        end
    end
    -- a server with nowhere to send would pile these up forever
    while #still > 20 do table.remove(still, 1) end
    state.pending = still
    state.last_tick = t
    store("state", state)
    return m
end

local function status()
    local samples = load_samples()
    local state = load_state()
    local out = {}
    if #samples == 0 then
        return { "no samples yet: INSTALL adds the cron entry, or run TICK" }
    end
    local t = samples[#samples].t
    local m, window, baseline = measure(samples, t)
    local factor, min_count = number("factor"), number("min_count")
    local to = recipients()
    table.insert(out, string.format("%s: %d samples, last %s; window %s, baseline %s, factor %g, min_count %d",
        server_name(), #samples, clock(t), span(window), span(baseline), factor, min_count))
    local hooks = webhooks()
    table.insert(out, "mail to " .. (#to > 0 and table.concat(to, ", ") or "nobody")
        .. "; webhook " .. (#hooks > 0 and table.concat(hooks, ", ") .. " (" .. setting("webhook_format") .. ")" or "none")
        .. (state.last_sent and ("; last sent " .. clock(state.last_sent)) or ""))
    if state.last_error then
        table.insert(out, "last send failed: " .. state.last_error .. " (" .. #(state.pending or {}) .. " waiting)")
    end
    for _, name in watched() do
        local x = m[name]
        table.insert(out, string.format("%s%s: %d in %s (%s), baseline %s", name,
            alerting(x, factor, min_count) and " [ALERT]" or "", x.recent, span(x.recent_ms),
            per_minute(x.recent, x.recent_ms), x.base_ms > 0 and per_minute(x.base, x.base_ms) or "not yet"))
    end
    return out
end

local function install(user: string?)
    local job = string.format([[
function transport()
    return {
        kind = "cron",
        space = "watchdog",
        call = "WATCHDOG",
        args = {"TICK"},
        every = %q,
        user = %q,
        overlap = "skip",
    }
end
]], setting("every"), user or "default")
    barch.space.configuration:call("SETF", "cron/jobs/watchdog", job)
    return "OK: cron/jobs/watchdog ticks every " .. setting("every") .. " as " .. (user or "default")
end

function call(op: string?, arg: string?)
    op = string.upper(op or "")
    if op == "TICK" then
        tick()
        return "OK"
    elseif op == "STATUS" or op == "" then
        return status()
    elseif op == "TEST" then
        if #recipients() == 0 and #webhooks() == 0 then
            return "(error) nowhere to send: set watchdog.to or watchdog.webhook"
        end
        local t = now_ms()
        local msg = { subject = "test message", at = t,
                      text = "This is a test from the barch watchdog at " .. clock(t) .. "." }
        local finished, why = deliver(msg, {})
        if not finished then return "(error) " .. tostring(why) end
        local where = recipients()
        for _, url in webhooks() do table.insert(where, url) end
        return "OK: sent to " .. table.concat(where, ", ")
    elseif op == "INSTALL" then
        return install(arg)
    elseif op == "UNINSTALL" then
        barch.space.configuration:call("REMF", "cron/jobs/watchdog")
        return "OK"
    elseif op == "RESET" then
        home().samples = nil
        home().state = nil
        return "OK"
    end
    return "usage: STATUS | TICK | TEST | INSTALL [user] | UNINSTALL | RESET"
end
