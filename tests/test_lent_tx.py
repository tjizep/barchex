"""The transaction guarantees lent's unique indexes depend on.

A unique insert reads the index key, finds it missing, and writes it. Two
inserts of the same value at once both find it missing, so COMMITTX has to
treat a read of a missing key as a read: whichever commits second must get
TXCONFLICT. These tests check that for GET, EXISTS and an empty range, from
RESP and from Luau inside a client's transaction.
"""
import pytest

from .helpers import connect

redis = pytest.importorskip("redis")

# Reads a key, a missing key's existence, and a range of keys inside the
# caller's transaction, and answers what it saw.
PEEK = """
function call(how, key)
    if how == "get" then return barch.store.get(key) or "missing" end
    if how == "exists" then return barch.store.exists(key) and "yes" or "no" end
    return #barch.store.range(key, key .. "\\255", 10)
end
"""


@pytest.fixture
def other(server, client):
    second = connect(server.port)
    second.execute_command("USE", "default")
    yield second
    second.close()


def commit_conflicts(conn) -> bool:
    try:
        conn.execute_command("COMMITTX")
    except redis.ResponseError as e:
        assert "TXCONFLICT" in str(e), str(e)
        return True
    return False


def test_missing_key_read_conflicts_with_a_plain_write(client, other):
    client.execute_command("BEGINTX")
    assert client.execute_command("GET", "u.email.a") is None
    client.execute_command("SET", "row.1", "a")
    other.execute_command("SET", "u.email.a", "2")
    assert commit_conflicts(client)
    assert client.execute_command("GET", "row.1") is None


def test_two_inserts_of_one_unique_value(client, other):
    # both look for the index key, both find it missing, both claim it
    for conn, pk in ((client, "1"), (other, "2")):
        conn.execute_command("BEGINTX")
        assert conn.execute_command("GET", "u.email.a") is None
        conn.execute_command("SET", "u.email.a", pk)
        conn.execute_command("SET", "row." + pk, "a")
    assert not commit_conflicts(client)
    assert commit_conflicts(other)
    assert client.execute_command("GET", "u.email.a") == "1"
    assert client.execute_command("GET", "row.2") is None


@pytest.mark.parametrize("how", ["get", "exists", "range"])
def test_missing_key_read_from_luau_conflicts(client, other, how):
    client.execute_command("SETF", "PEEK", PEEK)
    client.execute_command("BEGINTX")
    seen = client.execute_command("CALLF", "PEEK", how, "u.email.b")
    assert seen in ("missing", "no", 0)
    client.execute_command("SET", "row.3", "b")
    other.execute_command("BEGINTX")
    other.execute_command("SET", "u.email.b", "4")
    assert not commit_conflicts(other)
    assert commit_conflicts(client)
    assert client.execute_command("GET", "row.3") is None
