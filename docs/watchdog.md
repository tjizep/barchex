# WATCHDOG

WATCHDOG monitors barch's error counters (`INFO ERRORS` and `foreign_errors`
from `INFO FOREIGN`) and sends an alert when one starts climbing, when all of
them become quiet again, and when barchd restarts. A counter triggers an alert
when the last `window` contains at least `min_count` errors at more than
`factor` times the rate during the preceding `baseline`; bursts that continue
become the baseline. It sends at most one alert per counter per `cooldown`.
If a mail server or webhook rejects a message, WATCHDOG retries it on the next
tick through that sink only.

```
USE configuration
SET mail.server   smtp://smtp.example.com:587     # see barch's docs for mail.*
SET mail.from     "barch <barch@example.com>"
SET watchdog.to   ops@example.com, oncall@example.com
SET watchdog.webhook https://hooks.slack.com/services/...   # and/or instead of mail

watchdog.WATCHDOG INSTALL        # a cron entry, configuration:cron/jobs/watchdog
watchdog.WATCHDOG TEST           # a test message to every sink
watchdog.WATCHDOG STATUS         # each counter's window, rate and baseline
```

| setting | default | |
|---|---|---|
| `watchdog.every` | `1m` | the tick, for INSTALL |
| `watchdog.window`, `watchdog.baseline` | `5m`, `1h` | |
| `watchdog.factor`, `watchdog.min_count` | `3`, `5` | |
| `watchdog.cooldown` | `30m` | |
| `watchdog.restart` | `1` | `0` disables restart messages |
| `watchdog.webhook_format` | `json` | `text` and `content`, which Slack, Mattermost, and Discord read, plus the fields individually; `plain` sends the text with a `Title` header for ntfy |
| `watchdog.webhook_auth` | | an `Authorization` header to send |
| `watchdog.counters` | all but `net_errors` | comma-separated list |
| `watchdog.name` | `barchd:<port>` | name used for this server in messages |

`net_errors` is not watched by default: barch 0.5.8 counts a client closing
its connection after a command as one. The webhook's `Authorization` value
cannot be a `…password` key, since scripts cannot read those. Anyone who can
read `configuration` can therefore see it. The cron user needs `outbound`.
After a restart, barch 0.5.8 does not load the `watchdog` space until something
touches it, so cron cannot call into it until `watchdog:DBSIZE` wakes it up.
An install from `package.luau` opens `watchdog` on every sync, including the
first one after a restart.
