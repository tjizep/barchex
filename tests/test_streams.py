from __future__ import annotations

import json
import threading

import pytest
from redis.exceptions import ResponseError

from .conftest import install
from .helpers import connect, wait_until


# `USE 0` selects the global space, where a fresh connection starts and where
# a bare command name falls back to. `USE default` is a separate named space,
# and the client fixture flushes that one, so the global space is flushed here.
GLOBAL = "0"


def _setup(client):
    client.execute_command("USE", GLOBAL)
    client.execute_command("FLUSHDB")
    install(client, GLOBAL, "STREAMS", "streams/streams.luau")


def _declare_queue(client, tmp_path, name, handler):
    """A queue `name` whose messages the stored function `handler` takes."""
    assert client.execute_command("CONFIG", "SET", "queue_dir", str(tmp_path)) in ("OK", b"OK")
    client.execute_command("USE", "configuration")
    assert client.execute_command("SETF", "queues/" + name, f'''
        function service()
            return {{
                kind = "queue", name = "{name}", space = "default",
                call = "{handler}", user = "default", durability = "each",
                poll = "200ms", max_attempts = 3,
            }}
        end
    ''') == "OK"
    client.execute_command("USE", GLOBAL)


def test_xadd_and_read_back(client):
    _setup(client)
    first = client.execute_command("XADD", "orders", "*", "id", "1", "total", "9.50")
    second = client.execute_command("XADD", "orders", "*", "id", "2")
    ms, seq = (int(x) for x in first.split("-"))
    ms2, seq2 = (int(x) for x in second.split("-"))
    assert (ms2, seq2) > (ms, seq)

    assert client.execute_command("XLEN", "orders") == 2
    assert client.xrange("orders") == [
        (first, {"id": "1", "total": "9.50"}),
        (second, {"id": "2"}),
    ]
    assert client.xrevrange("orders", count=1) == [(second, {"id": "2"})]
    assert client.xrange("orders", min="(" + first) == [(second, {"id": "2"})]
    assert client.xrange("missing") == []
    assert client.execute_command("XLEN", "missing") == 0


def test_explicit_ids(client):
    _setup(client)
    assert client.execute_command("XADD", "s", "5-1", "a", "1") == "5-1"
    assert client.execute_command("XADD", "s", "5-*", "a", "2") == "5-2"
    assert client.execute_command("XADD", "s", "7", "a", "3") == "7-0"
    assert client.execute_command("XADD", "s", "7-*", "a", "4") == "7-1"
    with pytest.raises(ResponseError, match="equal or smaller"):
        client.execute_command("XADD", "s", "7-1", "a", "5")
    with pytest.raises(ResponseError, match="greater than 0-0"):
        client.execute_command("XADD", "fresh", "0-0", "a", "1")
    assert client.execute_command("XADD", "fresh", "0-*", "a", "1") == "0-1"
    with pytest.raises(ResponseError, match="Invalid stream ID"):
        client.execute_command("XADD", "s", "x-1", "a", "1")
    with pytest.raises(ResponseError, match="wrong number of arguments"):
        client.execute_command("XADD", "s", "*", "a")

    # a "*" after explicit ids in the future keeps counting from them
    client.execute_command("XADD", "future", "99999999999999-5", "a", "1")
    assert client.execute_command("XADD", "future", "*", "a", "2") == "99999999999999-6"

    assert [i for i, _ in client.xrange("s", "5", "5")] == ["5-1", "5-2"]
    assert [i for i, _ in client.xrange("s", "5-2", "7-0")] == ["5-2", "7-0"]
    assert [i for i, _ in client.xrevrange("s", "7", "(5-2")] == ["7-1", "7-0"]


def test_nomkstream(client):
    _setup(client)
    assert client.execute_command("XADD", "none", "NOMKSTREAM", "*", "a", "1") is None
    assert client.execute_command("XLEN", "none") == 0
    client.execute_command("XADD", "none", "*", "a", "1")
    assert client.execute_command("XADD", "none", "NOMKSTREAM", "*", "a", "2") is not None


def test_trim_and_delete(client):
    _setup(client)
    for i in range(1, 11):
        client.execute_command("XADD", "t", f"{i}-0", "n", str(i))
    assert client.execute_command("XADD", "t", "MAXLEN", "=", "8", "11-0", "n", "11") == "11-0"
    assert client.execute_command("XLEN", "t") == 8
    assert client.xrange("t", count=1)[0][0] == "4-0"

    assert client.execute_command("XTRIM", "t", "MINID", "6") == 2
    assert client.xrange("t", count=1)[0][0] == "6-0"
    assert client.execute_command("XTRIM", "t", "MAXLEN", "~", "0", "LIMIT", "2") == 2
    assert client.execute_command("XLEN", "t") == 4
    with pytest.raises(ResponseError, match="LIMIT cannot be used"):
        client.execute_command("XTRIM", "t", "MAXLEN", "0", "LIMIT", "2")

    assert client.execute_command("XDEL", "t", "9-0", "10-0", "500-0") == 2
    assert [i for i, _ in client.xrange("t")] == ["8-0", "11-0"]
    assert client.execute_command("XLEN", "t") == 2
    # the last id stays after its entry is deleted
    assert client.execute_command("XDEL", "t", "11-0") == 1
    with pytest.raises(ResponseError, match="equal or smaller"):
        client.execute_command("XADD", "t", "11-0", "n", "x")


def test_xread(client):
    _setup(client)
    client.execute_command("XADD", "a", "1-0", "x", "1")
    client.execute_command("XADD", "a", "2-0", "x", "2")
    client.execute_command("XADD", "b", "3-0", "y", "3")
    assert client.xread({"a": "0", "b": "0"}) == [
        ["a", [("1-0", {"x": "1"}), ("2-0", {"x": "2"})]],
        ["b", [("3-0", {"y": "3"})]],
    ]
    assert client.xread({"a": "1-0", "b": "3-0"}, count=5) == [["a", [("2-0", {"x": "2"})]]]
    assert client.xread({"a": "0"}, count=1) == [["a", [("1-0", {"x": "1"})]]]
    assert not client.xread({"a": "$"})
    with pytest.raises(ResponseError, match="BLOCK is not supported"):
        client.xread({"a": "$"}, block=100)
    with pytest.raises(ResponseError, match="Unbalanced"):
        client.execute_command("XREAD", "STREAMS", "a", "b", "0")


def test_reads_page_past_a_range_batch(client):
    _setup(client)
    total = 10_050
    pipe = client.pipeline(transaction=False)
    for i in range(1, total + 1):
        pipe.execute_command("XADD", "big", f"{i}-0", "n", str(i))
    pipe.execute()
    assert client.execute_command("XLEN", "big") == total

    every = client.xrange("big")
    assert len(every) == total
    assert every[-1] == (f"{total}-0", {"n": str(total)})
    back = client.xrevrange("big", count=10_020)
    assert len(back) == 10_020
    assert back[0][0] == f"{total}-0"
    assert back[-1][0] == f"{total - 10_019}-0"


def test_streams_follow_the_selected_space(client):
    _setup(client)
    client.execute_command("XADD", "s", "*", "a", "1")
    client.execute_command("USE", "streamsother")
    client.execute_command("FLUSHDB")
    assert client.execute_command("XLEN", "s") == 0
    client.execute_command("XADD", "s", "*", "a", "1")
    client.execute_command("XADD", "s", "*", "a", "2")
    assert client.execute_command("XLEN", "s") == 2
    client.execute_command("USE", GLOBAL)
    assert client.execute_command("XLEN", "s") == 1


def test_concurrent_writers_get_increasing_ids(server, client):
    _setup(client)
    writers, each = 8, 200
    errors = []

    def write(n):
        c = connect(server.port)
        try:
            for i in range(each):
                c.execute_command("XADD", "hot", "*", "w", str(n), "i", str(i))
        except Exception as e:  # noqa: BLE001 - reported below
            errors.append(e)
        finally:
            c.close()

    threads = [threading.Thread(target=write, args=(n,)) for n in range(writers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []
    entries = client.xrange("hot")
    assert len(entries) == writers * each
    assert client.execute_command("XLEN", "hot") == writers * each
    ids = [tuple(int(x) for x in i.split("-")) for i, _ in entries]
    assert ids == sorted(set(ids))
    # each writer's own entries stay in the order it sent them
    for n in range(writers):
        mine = [int(f["i"]) for _, f in entries if f["w"] == str(n)]
        assert mine == list(range(each))


def test_xqueue_forwards_entries_to_a_queue(client, tmp_path):
    _setup(client)
    client.execute_command("SETF", "TAKE", '''
        function call(message, sequence, attempts)
            local n = tonumber(barch.store.get("taken") or "0") or 0
            barch.store.set("taken", tostring(n + 1))
            barch.store.set("taken:" .. tostring(n + 1), message)
        end
    ''')
    _declare_queue(client, tmp_path, "cdc", "TAKE")

    assert client.execute_command("XQUEUE", "ADD", "shop.public.*", "cdc") == 1
    assert client.execute_command("XQUEUE", "ADD", "shop.public.*", "cdc") == 0
    assert client.execute_command("XQUEUE", "ADD", "audit", "cdc") == 1
    assert client.execute_command("XQUEUE", "LIST") == [["shop.public.*", "cdc"], ["audit", "cdc"]]

    # the shape Debezium Server's Redis sink sends: one field, the record key
    # as its name and the change as its value
    key = json.dumps({"id": 7})
    change = json.dumps({"op": "c", "after": {"id": 7, "name": "pen"}})
    pipe = client.pipeline(transaction=False)
    pipe.execute_command("XADD", "shop.public.items", "*", key, change)
    pipe.execute_command("XADD", "shop.other.items", "*", "k", "v")
    pipe.execute_command("XADD", "audit", "*", "who", 'al "the" pal')
    first, _, third = pipe.execute()

    assert wait_until(lambda: client.get("taken") == "2")
    got = [json.loads(client.get(f"taken:{n}")) for n in (1, 2)]
    assert got == [
        {"stream": "shop.public.items", "id": first, "fields": [key, change]},
        {"stream": "audit", "id": third, "fields": ["who", 'al "the" pal']},
    ]
    # the entries stay in their streams too
    assert client.execute_command("XLEN", "shop.public.items") == 1

    assert client.execute_command("XQUEUE", "REMOVE", "audit", "cdc") == 1
    assert client.execute_command("XQUEUE", "REMOVE", "audit", "cdc") == 0
    client.execute_command("XADD", "audit", "*", "who", "nobody")
    client.execute_command("XADD", "shop.public.items", "*", key, change)
    assert wait_until(lambda: client.get("taken") == "3")
    assert json.loads(client.get("taken:3"))["stream"] == "shop.public.items"


def test_xadd_fails_when_the_queue_is_not_declared(client):
    _setup(client)
    client.execute_command("XQUEUE", "ADD", "s", "nowhere")
    with pytest.raises(ResponseError, match="but queue nowhere refused it"):
        client.execute_command("XADD", "s", "*", "a", "1")
    # the entry was stored before the queue refused it
    assert client.execute_command("XLEN", "s") == 1


def test_xqueue_nostore_forwards_without_keeping_entries(client, tmp_path):
    _setup(client)
    client.execute_command("SETF", "TAKE", '''
        function call(message, sequence, attempts)
            local n = tonumber(barch.store.get("taken") or "0") or 0
            barch.store.set("taken", tostring(n + 1))
            barch.store.set("taken:" .. tostring(n + 1), message)
        end
    ''')
    _declare_queue(client, tmp_path, "cdc", "TAKE")

    assert client.execute_command("XQUEUE", "ADD", "cdc.*", "cdc", "NOSTORE") == 1
    assert client.execute_command("XQUEUE", "ADD", "cdc.*", "cdc", "NOSTORE") == 0
    assert client.execute_command("XQUEUE", "LIST") == [["cdc.*", "cdc", "NOSTORE"]]

    first = client.execute_command("XADD", "cdc.items", "*", "k", "1")
    second = client.execute_command("XADD", "cdc.items", "*", "k", "2")
    assert wait_until(lambda: client.get("taken") == "2")
    assert [json.loads(client.get(f"taken:{n}"))["id"] for n in (1, 2)] == [first, second]
    # only the last id is kept, so ids still increase
    assert client.execute_command("XLEN", "cdc.items") == 0
    assert client.xrange("cdc.items") == []
    with pytest.raises(ResponseError, match="equal or smaller"):
        client.execute_command("XADD", "cdc.items", second, "k", "3")

    # a forward that stores, matching the same stream, keeps the entries again
    assert client.execute_command("XQUEUE", "ADD", "cdc.items", "cdc") == 1
    client.execute_command("XADD", "cdc.items", "*", "k", "3")
    assert client.execute_command("XLEN", "cdc.items") == 1
    assert wait_until(lambda: client.get("taken") == "3")

    # ADD without NOSTORE turns the option off on an existing forward
    assert client.execute_command("XQUEUE", "ADD", "cdc.*", "cdc") == 1
    assert client.execute_command("XQUEUE", "LIST") == [["cdc.*", "cdc"], ["cdc.items", "cdc"]]
    with pytest.raises(ResponseError, match="XQUEUE takes"):
        client.execute_command("XQUEUE", "ADD", "cdc.*", "cdc", "KEEP")


def test_nostore_xadd_fails_when_the_queue_is_not_declared(client):
    _setup(client)
    client.execute_command("XQUEUE", "ADD", "s", "nowhere", "NOSTORE")
    with pytest.raises(ResponseError, match="without storing it but queue nowhere refused it"):
        client.execute_command("XADD", "s", "*", "a", "1")
    assert client.execute_command("XLEN", "s") == 0
