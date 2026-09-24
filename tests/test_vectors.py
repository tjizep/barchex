from __future__ import annotations

import math
import random
import struct

import pytest
from redis.exceptions import ResponseError

from .conftest import install
from .helpers import connect

DIM = 8
CLUSTERS = 5
PER_CLUSTER = 40
SEED = 20260924


def _pack(values, kind="f"):
    return struct.pack("<%d%s" % (len(values), kind), *values)


def _cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return 1.0 - dot / (na * nb)


def _euclidean(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def _dataset():
    rng = random.Random(SEED)
    centers = [[rng.uniform(-1, 1) for _ in range(DIM)] for _ in range(CLUSTERS)]
    points = []
    for cluster, center in enumerate(centers):
        for i in range(PER_CLUSTER):
            point = [c + rng.gauss(0, 0.12) for c in center]
            points.append((f"p{cluster}{i:03d}", point))
    queries = [
        [c + rng.gauss(0, 0.04) for c in rng.choice(centers)]
        for _ in range(15)
    ]
    return points, queries


def _nearest(query, points, k, distance):
    ranked = sorted(points, key=lambda named: distance(query, named[1]))
    return [name for name, _ in ranked[:k]]


def _setup(client):
    client.execute_command("USE", "vectors")
    client.execute_command("FLUSHDB")
    install(client, "vectors", "vgraph", "vectors/vgraph.luau")
    install(client, "vectors", "VECTORS", "vectors/vectors.luau")
    client.execute_command("USE", "vectors")


def test_realistic_vector_search(client):
    _setup(client)
    points, queries = _dataset()

    for name, point in points:
        got = client.execute_command("vectors.SET", name, _pack(point))
        assert got[0] == "OK", (name, got)

    # An existing name keeps its point: the id comes back unchanged.
    name, point = points[0]
    got = client.execute_command("vectors.SET", name, _pack(point))
    assert got[0] == "exists", got

    # Every query finds its true closest point under cosine, the default metric.
    for query in queries:
        want = _nearest(query, points, 1, _cosine)[0]
        got = client.execute_command("vectors.CLOSEST", _pack(query))
        assert got == want, query

    # k nearest come back as name/distance pairs, closest first.
    query = queries[0]
    reply = client.execute_command("vectors.CLOSEST", _pack(query), 5)
    got_names = [reply[i] for i in range(0, len(reply), 2)]
    got_dists = [float(reply[i]) for i in range(1, len(reply), 2)]
    want = _nearest(query, points, 5, _cosine)
    recall = len(set(got_names) & set(want)) / len(want)
    assert recall >= 0.8, (got_names, want)
    assert got_dists == sorted(got_dists), got_dists
    assert _cosine(query, dict(points)[got_names[0]]) == pytest.approx(got_dists[0], abs=0.02)

    # Switching to euclidean changes the answer without a rebuild.
    params = client.execute_command("vectors.TUNE", "metric", "euclidean")
    assert params[5] == "euclidean", params
    for query in queries:
        reply = client.execute_command("vectors.CLOSEST", _pack(query), 5)
        got_names = [reply[i] for i in range(0, len(reply), 2)]
        want = _nearest(query, points, 5, _euclidean)
        true_nearest = want[0]
        assert true_nearest in got_names, (true_nearest, got_names)

    # Tuning presets update the reported parameters.
    fast = client.execute_command("vectors.TUNE", "fast")
    assert (fast[1], fast[2], fast[3], fast[4]) == (8, 16, 8, 0), fast
    accurate = client.execute_command("vectors.TUNE", "accurate")
    assert (accurate[1], accurate[2], accurate[3], accurate[4]) == (32, 200, 100, 1), accurate
    assert client.execute_command("vectors.PARAMS")[0] == len(points)

    # A dimension that does not match the space is refused, on both doors.
    with pytest.raises(ResponseError, match="dimension mismatch"):
        client.execute_command("vectors.SET", "wrong", _pack([1.0, 2.0, 3.0]))
    with pytest.raises(ResponseError, match="dimension mismatch"):
        client.execute_command("vectors.CLOSEST", _pack([1.0, 2.0, 3.0]))
    with pytest.raises(ResponseError, match="k is at least 1"):
        client.execute_command("vectors.CLOSEST", _pack(queries[0]), 0)


def test_vector_graph_is_shared_across_connections(client, server):
    _setup(client)
    points, queries = _dataset()
    for name, point in points:
        client.execute_command("vectors.SET", name, _pack(point))

    # The graph lives in the store, so a second connection sees the same points
    # under the default cosine metric.
    other = connect(server.port)
    other.execute_command("USE", "vectors")
    want = _nearest(queries[0], points, 1, _cosine)[0]
    assert other.execute_command("vectors.CLOSEST", _pack(queries[0])) == want
    other.close()