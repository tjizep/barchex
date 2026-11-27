# STREAMS

STREAMS gives barch the Redis stream commands a producer uses to publish:
`XADD`, `XLEN`, `XRANGE`, `XREVRANGE`, `XREAD`, `XDEL` and `XTRIM`. A Redis
client, or Debezium Server's Redis sink, connects to barchd and sends `XADD`
as it would to Redis. `XQUEUE` hands each new entry of a stream to a barch
queue, where a stored function applies it.

```
XADD orders * id 1 total 9.50          # "1795773495735-0"
XLEN orders                            # 1
XRANGE orders - +                      # [["1795773495735-0", ["id", "1", "total", "9.50"]]]
XQUEUE ADD orders apply                # every later entry of orders goes to queue apply
```

## Install

`package.luau` loads `streams/streams.luau` into the global space as the
function `STREAMS`. The global space is the one a connection starts in, and
`USE 0` selects it again. Commands stored there answer by their bare names on
every connection and in every space.

To install it by hand, store it from a connection in the global space:

```
USE 0
SETF STREAMS "<contents of streams/streams.luau>"
```

The named space `default` is a separate space. A copy stored there answers
only connections that have run `USE default`.

barch lets one repository load into each space, and the barchex package owns
the global space. A `FUNCTIONS SYNC` of barchex fails with
`key space (default) is owned by repository <name>` when another repository
already loads into the global space. Load that repository's functions into a
space of their own. A script there reaches the global space's keys through
`barch.space["0"]`, as in `barch.space["0"]:get(key)`.

## Where streams live

A stream lives in the space the connection has selected with `USE`, the way a
Redis key lives in its database. `XADD orders` after `USE shop` and `XADD
orders` in the global space write two different streams. `XQUEUE` forwards are
kept per space too.

A stream is stored as ordinary keys under the prefix `xs\x01`, so they appear
in `KEYS` and count in `DBSIZE`:

| key | holds |
|---|---|
| `xs\x01<stream>\x01m` | the last id, the length and the number of entries ever added |
| `xs\x01<stream>\x01e<id>` | one entry, with the id as 28 hex digits so key order is id order |
| `xs\x01\x01q` | the space's `XQUEUE` forwards |

A stream name can hold any byte except `\x01`. A name with that byte fails
with `ERR a stream name can't hold the byte \x01`.

Every write (`XADD`, `XDEL`, `XTRIM`, `XQUEUE ADD` and `XQUEUE REMOVE`) locks
the whole space while it runs. Writes to one space run one at a time, and each
`XADD` gets an id above every id before it, also with many writers.

## Commands

| command | reply |
|---|---|
| `XADD key [NOMKSTREAM] [MAXLEN\|MINID [=\|~] threshold [LIMIT count]] id field value [field value ...]` | the new entry's id, or null when `NOMKSTREAM` is given and the stream is missing |
| `XLEN key` | the number of entries; `0` for a missing stream |
| `XRANGE key start end [COUNT count]` | entries from `start` to `end`, oldest first |
| `XREVRANGE key end start [COUNT count]` | entries from `end` to `start`, newest first |
| `XREAD [COUNT count] STREAMS key [key ...] id [id ...]` | for each stream with newer entries, `[key, entries]`; null when none has any |
| `XDEL key id [id ...]` | the number of entries removed |
| `XTRIM key MAXLEN\|MINID [=\|~] threshold [LIMIT count]` | the number of entries removed |
| `XQUEUE ADD pattern queue [NOSTORE]` | `1` when added or changed, `0` when that forward already exists as given |
| `XQUEUE REMOVE pattern queue` | `1` when removed, `0` when there was none |
| `XQUEUE LIST` | `[[pattern, queue], ...]` in the order they were added, with `NOSTORE` as a third item on those forwards |

Each entry in a reply is `[id, [field, value, ...]]`, the shape Redis
clients decode.

Every command needs the `function` and `data` categories, which calling any
stored function takes. `XADD`, `XDEL`, `XTRIM` and `XQUEUE` also need `write`,
and `XLEN`, `XRANGE`, `XREVRANGE` and `XREAD` also need `read`.

### Ids

An id is `ms-seq`, two whole numbers below 2^53. `XADD` takes:

| id | stores |
|---|---|
| `*` | the current time in milliseconds from `barch.time()`, with `seq` `0`; when the last id is at or after that time, the last `ms` and the next `seq` |
| `ms-*` | `ms` with the next free `seq` |
| `ms` or `ms-seq` | that id |

The id has to be above the stream's last id, or `XADD` fails with
`ERR The ID specified in XADD is equal or smaller than the target stream top item`.
`0-0` fails with `ERR The ID specified in XADD must be greater than 0-0`.
The last id stays after its entry is deleted or trimmed, so ids never repeat.

`XRANGE` and `XREVRANGE` take `-` for the first id, `+` for the last, and
`(` before an id to leave that id out. An id without `seq` covers every `seq`
of that millisecond.

`XREAD` returns entries after each given id. `$` stands for the stream's
last id, so `XREAD` with `$` always answers null; poll from the last id you
read.

### Trimming

`MAXLEN threshold` removes the oldest entries until `threshold` remain.
`MINID threshold` removes entries with ids below `threshold`. `XADD` trims after
it stores the new entry.

`=` and `~` both trim exactly. `LIMIT count` caps how many entries one call
removes, and needs `~`, as in Redis:
`ERR syntax error, LIMIT cannot be used without the special ~ option`.
`LIMIT 0` removes without a cap.

### Large reads

The commands read the store 10000 entries at a time, so `XRANGE` and
`XREVRANGE` return streams of any length. The whole reply is built in memory
first; use `COUNT` on long streams and continue from the last id with `(`.
`XREVRANGE` counts the entries in its range before it reads, so its cost grows
with the range even when `COUNT` is small.

### What is left out

`XREAD BLOCK` fails with
`ERR XREAD BLOCK is not supported: read without BLOCK, or use XQUEUE to have each entry pushed to a queue`.
Consumer groups (`XGROUP`, `XREADGROUP`, `XACK`, `XPENDING`, `XCLAIM`) and
`XINFO` are not provided. A consumer either polls with `XREAD` from its last
id or takes entries from a queue through `XQUEUE`.

## Forward entries to a queue

`XQUEUE ADD pattern queue` sends every entry later added to a matching stream
to the barch queue `queue`. A pattern is a stream name, or a prefix ending in
`*`: `shop.public.*` matches `shop.public.items` and `shop.public.orders`.
An entry that matches several patterns of one queue goes to that queue once.
Entries added before the `XQUEUE ADD` stay where they are.

Add `NOSTORE` when the queue is the only consumer, so the stream does not
grow: `XQUEUE ADD shop.* apply NOSTORE`. `XADD` still gives each entry a new
id, and the stream keeps that last id, but the entry goes only to the queue.
`XLEN` stays `0` and `XRANGE` returns nothing for it. When a stream matches
several forwards, it keeps an entry if any of them is without `NOSTORE`.
`XQUEUE ADD` of an existing pattern and queue switches `NOSTORE` on or off.

Each message is JSON:

```json
{"stream": "shop.public.items", "id": "1795773495735-0", "fields": ["{\"id\":7}", "{\"op\":\"c\", ...}"]}
```

`fields` keeps the entry's field and value strings in order, as a flat list.

Declare the queue before forwarding to it. `XADD` stores the entry first and
then hands it to each queue. When a queue refuses it, for example because it
is not declared, `XADD` fails with
`ERR XADD stored <id> in <stream> but queue <queue> refused it: ...`.
The entry stays in the stream. Under `NOSTORE` the error reads
`ERR XADD gave <id> to <stream> without storing it but queue <queue> refused it: ...`,
and the entry is lost unless the producer retries it. A producer that retries the failed `XADD`
stores the entry again under a new id, so the stream and the queue can hold a
duplicate with a different id. Recognise those by their content, such as the
source position a change event carries.

The queue delivers each message at least once, so its handler can see one
message twice. Use `stream` and `id` together to recognise a message the
handler has already applied. With several writers, messages can reach the
queue in a different order from their ids; order by `id` when it matters.

### Example handler

`queue_dir` sets where queues keep their files. The declaration goes under
`configuration:queues/<name>`, and `space = "default"` there names the global
space.

```
CONFIG SET queue_dir /var/lib/barch/queues

USE configuration
SETF queues/apply "
function service()
    return {
        kind = 'queue', name = 'apply', space = 'default',
        call = 'APPLY', user = 'default', durability = 'each',
        poll = '200ms', max_attempts = 3,
    }
end"

USE 0
SETF APPLY "
function call(message, sequence, attempts)
    local m = simdjson.parse(message)
    local done = 'applied:' .. m.stream .. ':' .. m.id
    if barch.store.get(done) then return end     -- a second delivery
    -- apply m.fields here
    barch.store.set(done, '1')
end"

XQUEUE ADD shop.public.* apply
```

A handler that raises an error is called again, up to `max_attempts` times.

## Publish from Debezium Server

Debezium Server's Redis sink sends `XADD` to one stream per table, named by
the topic: `<topic.prefix>.<schema>.<table>`. Point the sink at barchd's port:

```properties
debezium.sink.type=redis
debezium.sink.redis.address=barch.internal:14000
debezium.sink.redis.user=debezium
debezium.sink.redis.password=...

debezium.source.connector.class=io.debezium.connector.postgresql.PostgresConnector
debezium.source.topic.prefix=shop
debezium.source.offset.storage.file.filename=data/offsets.dat
# the database, slot and table settings for your connector
```

With the default `compact` message format, each entry has one field: the
record key as its name and the change event as its value. With
`debezium.sink.redis.message.format=extended`, the entry has `key`, `value`
and the headers as separate fields. Both reach a queue handler unchanged in
`fields`.

The user the sink logs in as needs `function`, `data` and `write` in the
space it publishes to. Run `XQUEUE ADD shop.* apply NOSTORE` in that space
before starting the sink, so every change goes to the handler and the streams
stay empty. The sink sends no `MAXLEN`, so without `NOSTORE` the streams keep
every change until you run `XTRIM`. Debezium retries a
batch whose `XADD` failed, so a refused forward arrives again under a new id;
see [Forward entries to a queue](#forward-entries-to-a-queue).
