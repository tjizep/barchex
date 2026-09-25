from __future__ import annotations

import json
import math
import os
import random
import shutil
import signal
import statistics
import struct
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from redis.exceptions import ConnectionError as RedisConnectionError
from redis.exceptions import ResponseError, TimeoutError as RedisTimeoutError

from .conftest import install
from .helpers import connect, free_port, http_call, wait_for_tcp


STRESS = os.environ.get("BARCH_STRESS") == "1"
pytestmark = pytest.mark.skipif(not STRESS, reason="set BARCH_STRESS=1 to run stress tests")


def _positive_env(name: str, default: int, maximum: int) -> int:
    value = int(os.environ.get(name, default))
    if not 1 <= value <= maximum:
        raise ValueError(f"{name} must be between 1 and {maximum}")
    return value


CHAOS_TRIALS = (
    _positive_env("BARCH_CHAOS_TRIALS", 3, 10)
    if STRESS and os.environ.get("BARCH_SOAK") == "1"
    else 1
)
CHAOS_AOF_MODES = (
    (False, True)
    if STRESS and os.environ.get("BARCH_SOAK") == "1"
    and os.environ.get("BARCH_AOF_CHAOS") == "1"
    else (False,)
)


def _percentile(values: list[float], pct: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(pct * len(ordered)) - 1)]


def _report(label: str, elapsed: float, latencies: list[float], operations: int) -> None:
    print(
        f"{label}: operations={operations} elapsed_s={elapsed:.2f} "
        f"ops_per_s={operations / elapsed:.1f} "
        f"p50_ms={statistics.median(latencies) * 1000:.2f} "
        f"p95_ms={_percentile(latencies, 0.95) * 1000:.2f} "
        f"p99_ms={_percentile(latencies, 0.99) * 1000:.2f} "
        f"max_ms={max(latencies) * 1000:.2f}",
        flush=True,
    )


def _pack(values: tuple[float, ...]) -> bytes:
    return struct.pack(f"<{len(values)}f", *values)


def _post_json(port: int, path: str, payload: dict) -> object:
    body = json.dumps(payload).encode()
    return http_call(port, "POST", path, body, {"Content-Type": "application/json"})


def test_hnsw_thousands_of_vectors_under_concurrent_clients(client, server):
    count = _positive_env("BARCH_STRESS_VECTORS", 2000, 5000)
    dim = _positive_env("BARCH_STRESS_DIM", 32, 256)
    workers = min(8, _positive_env("BARCH_STRESS_WORKERS", 8, 32))
    rng = random.Random(20260925)
    points = [
        (f"stress-{i:06d}", tuple(rng.uniform(-1, 1) for _ in range(dim)))
        for i in range(count)
    ]

    client.execute_command("USE", "vectors")
    client.execute_command("FLUSHDB")
    install(client, "vectors", "vgraph", "vectors/vgraph.luau")
    install(client, "vectors", "VECTORS", "vectors/vectors.luau")
    client.execute_command("USE", "vectors")

    def insert_batch(batch):
        conn = connect(server.port)
        conn.execute_command("USE", "vectors")
        latencies = []
        try:
            for name, vector in batch:
                started = time.perf_counter()
                reply = conn.execute_command("vectors.SET", name, _pack(vector))
                latencies.append(time.perf_counter() - started)
                assert reply[0] == "OK", (name, reply)
        finally:
            conn.close()
        return latencies

    batches = [points[i::workers] for i in range(workers)]
    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        insert_latencies = [latency for batch in pool.map(insert_batch, batches) for latency in batch]
    build_elapsed = time.perf_counter() - started
    assert client.execute_command("vectors.PARAMS")[0] == count

    samples = random.Random(20260926).sample(points, min(200, count))

    def query_batch(batch):
        conn = connect(server.port)
        conn.execute_command("USE", "vectors")
        latencies = []
        found = 0
        try:
            for expected, vector in batch:
                started = time.perf_counter()
                reply = conn.execute_command("vectors.CLOSEST", _pack(vector))
                latencies.append(time.perf_counter() - started)
                found += reply == expected
        finally:
            conn.close()
        return latencies, found

    query_batches = [samples[i::workers] for i in range(workers)]
    query_started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        query_results = list(pool.map(query_batch, query_batches))
    query_elapsed = time.perf_counter() - query_started
    query_latencies = [latency for latencies, _ in query_results for latency in latencies]
    exact_hits = sum(found for _, found in query_results)

    print(f"HNSW exact-self recall={exact_hits}/{len(samples)}", flush=True)
    assert exact_hits >= math.ceil(len(samples) * 0.8), exact_hits
    p99_limit_ms = float(os.environ.get("BARCH_STRESS_P99_MS", "2000"))
    insert_p99_limit_ms = float(os.environ.get("BARCH_STRESS_INSERT_P99_MS", "2000"))
    assert _percentile(insert_latencies, 0.99) * 1000 <= insert_p99_limit_ms
    assert _percentile(query_latencies, 0.99) * 1000 <= p99_limit_ms, query_latencies
    _report("HNSW insert", build_elapsed, insert_latencies, count)
    _report("HNSW concurrent query", query_elapsed, query_latencies, len(samples))


def test_thousands_of_signon_sessions_under_cpu_pressure(spaces_http, server):
    port = spaces_http
    sessions = _positive_env("BARCH_STRESS_SESSIONS", 1000, 5000)
    workers = min(32, _positive_env("BARCH_STRESS_HTTP_WORKERS", 24, 64))
    email = "stress-admin@example.test"
    password = "stress-password-1"
    created = _post_json(
        port,
        "/api/spaces-user/register",
        {"name": "Stress Admin", "email": email, "password": password},
    )
    assert created.status == 200, created.body
    assert created.cookie("sid")

    hog = None
    yes = shutil.which("yes")
    if yes:
        hog = subprocess.Popen([yes], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def signon(_index: int):
        started = time.perf_counter()
        reply = _post_json(
            port,
            "/api/spaces-user/signon",
            {"email": email, "password": password},
        )
        elapsed = time.perf_counter() - started
        assert reply.status == 200, reply.body
        cookie = reply.cookie("sid")
        assert cookie, reply.headers
        return cookie, elapsed

    started = time.perf_counter()
    try:
        with ThreadPoolExecutor(max_workers=workers) as pool:
            results = list(pool.map(signon, range(sessions)))
    finally:
        if hog is not None:
            hog.terminate()
            try:
                hog.wait(timeout=2)
            except subprocess.TimeoutExpired:
                hog.kill()
                hog.wait()
    elapsed = time.perf_counter() - started

    cookies = [cookie for cookie, _ in results]
    assert len(set(cookies)) == sessions, "sign-on returned duplicate session IDs"
    latencies = [duration for _, duration in results]
    pressure = "on" if hog is not None else "off"
    _report(f"HTTP sign-on cpu_pressure={pressure}", elapsed, latencies, sessions)
    assert _percentile(latencies, 0.99) * 1000 <= float(
        os.environ.get("BARCH_STRESS_HTTP_P99_MS", "10000")
    )

    client = server.client
    client.execute_command("USE", "spaces")
    stored = client.keys("sess:*")
    assert len(stored) == sessions + 1, f"expected {sessions + 1} sessions, got {len(stored)}"
    probe = cookies[0]
    reply = http_call(port, "GET", "/api/admin/me", headers={"Cookie": f"sid={probe}"})
    assert reply.status == 200 and reply.json()["admin"] is True, reply.body
    signed_out = http_call(
        port,
        "POST",
        "/api/spaces-user/signout",
        b"",
        {"Cookie": f"sid={probe}"},
    )
    assert signed_out.status == 200, signed_out.body
    assert client.get(f"sess:{probe}") is None
    assert client.ping() is True


def test_memory_ceiling_rejects_writes_without_killing_server(fresh_server):
    client = fresh_server.client
    info = client.info("memory")
    baseline = int(info["barch_leaf_bytes_logical"] + info["barch_interior_bytes_logical"])
    memory_limit = baseline + 16 * 1024 * 1024
    client.execute_command("CONFIG", "SET", "max_memory_bytes", str(memory_limit))
    client.execute_command("CONFIG", "SET", "eviction_policy", "none")
    configured = int(client.execute_command("CONFIG", "GET", "max_memory_bytes")[1])
    assert configured == memory_limit, configured
    chunk_size = 256 * 1024
    chunks_per_burst = (10 * 1024 * 1024) // chunk_size
    accepted_keys = []
    accepted_small = 0
    accepted_large = 0
    oom = None
    sequence = 0

    for burst in range(4):
        for chunk in range(chunks_per_burst):
            small_key = f"pressure:small:{sequence:06d}"
            try:
                client.set(small_key, b"x")
                accepted_keys.append(small_key)
                accepted_small += 1
                large_key = f"pressure:large:{sequence:06d}"
                client.set(large_key, os.urandom(chunk_size))
                accepted_keys.append(large_key)
                accepted_large += 1
            except ResponseError as exc:
                oom = str(exc)
                break
            sequence += 1
        if oom is not None:
            break

    assert accepted_small > 0 and accepted_large > 0, f"the cap rejected early: {oom}"
    if oom is None:
        current = client.info("memory")
        pytest.fail(
            "bounded writes did not reach the memory cap: "
            f"baseline={baseline} configured={configured} "
            f"logical={current['barch_leaf_bytes_logical'] + current['barch_interior_bytes_logical']} "
            f"keys={current['barch_keys']}"
        )
    assert "oom" in oom.lower() or "memory" in oom.lower(), oom
    assert client.ping() is True
    assert client.exists(accepted_keys[0]) == 1
    assert client.exists(accepted_keys[1]) == 1
    client.delete(*accepted_keys[0::4])
    client.delete(*accepted_keys[1::4])
    assert client.set("pressure:recovered", "ok")
    assert client.get("pressure:recovered") == "ok"
    assert client.set("pressure:recovered-large", os.urandom(chunk_size))
    after = client.info("memory")
    client.execute_command("CONFIG", "SET", "max_memory_bytes", "1")
    with pytest.raises(ResponseError, match="not enough memory"):
        client.set("pressure:tiny-limit", b"x")
    assert client.ping() is True
    client.execute_command("CONFIG", "SET", "max_memory_bytes", str(memory_limit))
    assert client.set("pressure:after-tiny-limit", "ok")
    print(
        f"memory cap: baseline_bytes={baseline} limit_bytes={memory_limit} "
        f"small_keys={accepted_small} large_keys={accepted_large} "
        f"frag_ratio={after['allocator_frag_ratio']} "
        f"reusable_bytes={after['barch_bytes_reusable']} "
        f"tiny_limit_rejected=not enough memory initial_rejection={oom}",
        flush=True,
    )


def test_hnsw_bounded_soak(client):
    if os.environ.get("BARCH_SOAK") != "1":
        pytest.skip("set BARCH_SOAK=1 with BARCH_STRESS=1 to run the soak test")

    seconds = _positive_env("BARCH_SOAK_SECONDS", 60, 600)
    max_ops = _positive_env("BARCH_SOAK_MAX_OPS", 50000, 100000)
    rng = random.Random(20260927)
    dim = 16
    points = [tuple(rng.uniform(-1, 1) for _ in range(dim)) for _ in range(256)]
    client.execute_command("USE", "vectors")
    client.execute_command("FLUSHDB")
    install(client, "vectors", "vgraph", "vectors/vgraph.luau")
    install(client, "vectors", "VECTORS", "vectors/vectors.luau")
    client.execute_command("USE", "vectors")
    for index, point in enumerate(points):
        client.execute_command("vectors.SET", f"soak-{index:06d}", _pack(point))

    latencies = []
    inserts = 0
    operations = 0
    soak_started = time.monotonic()
    deadline = soak_started + seconds
    while operations < max_ops and time.monotonic() < deadline:
        if operations % 10 == 0:
            point = tuple(rng.uniform(-1, 1) for _ in range(dim))
            started = time.perf_counter()
            reply = client.execute_command("vectors.SET", f"soak-grow-{inserts:06d}", _pack(point))
            inserts += 1
        else:
            point = rng.choice(points)
            started = time.perf_counter()
            reply = client.execute_command("vectors.CLOSEST", _pack(point))
        latencies.append(time.perf_counter() - started)
        assert reply is not None
        operations += 1
        if operations % 500 == 0:
            assert client.ping() is True

    assert operations > 0
    expected = len(points) + inserts
    assert client.execute_command("vectors.PARAMS")[0] == expected
    _report("HNSW soak", time.monotonic() - soak_started, latencies, operations)


@pytest.mark.parametrize("trial", range(CHAOS_TRIALS))
@pytest.mark.parametrize("aof_enabled", CHAOS_AOF_MODES, ids=("no-aof", "aof-each")[:len(CHAOS_AOF_MODES)])
def test_ungraceful_hnsw_stream_recovery(fresh_server, trial, aof_enabled):
    if os.environ.get("BARCH_SOAK") != "1":
        pytest.skip("set BARCH_SOAK=1 with BARCH_STRESS=1 to run crash chaos")

    server = fresh_server
    client = server.client
    rng = random.Random(20260928 + trial)
    points = [tuple(rng.uniform(-1, 1) for _ in range(16)) for _ in range(256)]
    aof_dir = str(Path(server.data) / "aof")
    if aof_enabled:
        client.execute_command("CONFIG", "SET", "aof_dir", aof_dir)
        client.execute_command("CONFIG", "SET", "aof_durability", "each")
        client.execute_command("USE", "configuration")
        client.set("vectors.aof", "on")
    client.execute_command("USE", "vectors")
    install(client, "vectors", "vgraph", "vectors/vgraph.luau")
    install(client, "vectors", "VECTORS", "vectors/vectors.luau")
    client.execute_command("USE", "vectors")
    for index, point in enumerate(points):
        name = f"chaos-seed-{index:06d}"
        client.execute_command("vectors.SET", name, _pack(point))
    # Let ordinary shard autosaves checkpoint a stable baseline without SAVE.
    client.execute_command("CONFIG", "SET", "save_interval", "1")
    time.sleep(1.0)
    aof_bytes = 0
    if aof_enabled:
        aof_files = list(Path(aof_dir).glob("*.aof"))
        assert aof_files, f"AOF was enabled but no log was created under {aof_dir}"
        aof_bytes = sum(path.stat().st_size for path in aof_files)
        assert aof_bytes > 32, f"AOF log has no appended records: {aof_files}"

    stop = threading.Event()
    lock = threading.Lock()
    ready = [threading.Event() for _ in range(4)]
    streaming = threading.Event()
    counts = {"attempted": 0, "acked": 0, "inflight": 0, "disconnects": 0}
    attempted_names = set()
    acknowledged_names = set()
    failures = []

    def writer(worker_id):
        conn = connect(server.port)
        writer_rng = random.Random(20261000 + trial * 4 + worker_id)
        seq = 0
        try:
            conn.execute_command("USE", "vectors")
            ready[worker_id].set()
            while not stop.is_set():
                batch = []
                for _ in range(8):
                    if stop.is_set():
                        break
                    name = f"chaos-write-{worker_id}-{seq:08d}"
                    vector = tuple(writer_rng.uniform(-1, 1) for _ in range(16))
                    batch.append((name, vector))
                    seq += 1
                if not batch:
                    break

                with lock:
                    counts["attempted"] += len(batch)
                    counts["inflight"] += len(batch)
                    attempted_names.update(name for name, _ in batch)
                streaming.set()
                pipeline = conn.pipeline(transaction=False)
                for name, vector in batch:
                    pipeline.execute_command("vectors.SET", name, _pack(vector))
                try:
                    replies = pipeline.execute(raise_on_error=False)
                    with lock:
                        for (name, _), reply in zip(batch, replies):
                            if isinstance(reply, Exception):
                                failures.append(f"{name}: {reply!r}")
                            elif reply[0] == "OK":
                                acknowledged_names.add(name)
                                counts["acked"] += 1
                            else:
                                failures.append(f"{name}: unexpected reply {reply!r}")
                except (RedisConnectionError, RedisTimeoutError):
                    with lock:
                        counts["disconnects"] += 1
                    break
                except Exception as exc:
                    with lock:
                        failures.append(repr(exc))
                    break
                finally:
                    with lock:
                        counts["inflight"] -= len(batch)
        finally:
            conn.close()

    workers = [
        threading.Thread(target=writer, args=(i,), daemon=True)
        for i in range(4)
    ]
    for worker in workers:
        worker.start()

    idle = None
    try:
        assert all(event.wait(10) for event in ready), "writers did not connect"
        assert streaming.wait(10), "writers did not start streaming inserts"
        delay = random.SystemRandom().uniform(0.005, 0.05)
        time.sleep(delay)
        with lock:
            active_at_kill = counts["inflight"]
            assert counts["attempted"] >= 32, counts
            assert active_at_kill > 0, counts

        idle = connect(server.port)
        assert idle.ping() is True
        client.close()
        server.process.kill()
        server.process.wait(timeout=10)
        assert server.process.returncode == -signal.SIGKILL
        stop.set()
        with pytest.raises((RedisConnectionError, RedisTimeoutError)):
            idle.ping()
        for worker in workers:
            worker.join(timeout=10)
            assert not worker.is_alive(), "writer did not exit after SIGKILL"

        with open(server.log_path, "ab") as log:
            process = subprocess.Popen(
                [str(server.binary), "--port", str(server.port), "--bind", "127.0.0.1", "--dir", server.data],
                stdout=log,
                stderr=subprocess.STDOUT,
            )
        server.process = process
        try:
            wait_for_tcp(server.port, timeout=30)
            client = connect(server.port, decode_responses=False)
            assert client.ping() is True
        except Exception as exc:
                log = Path(server.log_path).read_text(errors="replace")
                pytest.fail(f"barchd failed to restart after SIGKILL: {exc}\n{log[-6000:]}")

        if aof_enabled:
            client.execute_command("CONFIG", "SET", "aof_dir", aof_dir)
            client.execute_command("CONFIG", "SET", "aof_durability", "each")
            client.execute_command("USE", "configuration")
            client.set("vectors.aof", "on")
        client.execute_command("USE", "vectors")
        install(client, "vectors", "vgraph", "vectors/vgraph.luau")
        install(client, "vectors", "VECTORS", "vectors/vectors.luau")
        client.execute_command("USE", "vectors")
        if aof_enabled:
            replay_log = Path(server.log_path).read_text(errors="replace")
            replay_messages = [
                line for line in replay_log.splitlines()
                if "replayed " in line and " from its change log" in line
            ]
            assert replay_messages, replay_log[-6000:]
            aof_replay = replay_messages[-1].split("replayed ", 1)[1].split(
                " from its change log", 1
            )[0]
        else:
            aof_replay = "off"

        params = client.execute_command("vectors.PARAMS")
        graph_count = int(params[0])
        names_by_id = {}
        name_ids = set()
        defects = []
        for key in client.keys("vec.name.*"):
            try:
                key_name = key.decode()
                node_id = int(key_name.rsplit(".", 1)[1])
            except (UnicodeError, ValueError):
                defects.append(f"invalid name key: {key}")
                continue
            name_ids.add(node_id)
            name = client.get(key)
            try:
                name_text = name.decode() if name is not None else None
            except UnicodeError:
                defects.append(f"node name is not text: {key}")
                continue
            reverse = client.get(f"vec.id.{name_text}") if name_text is not None else None
            vector = client.get(f"vec.v.{node_id}")
            level = client.get(f"vec.lv.{node_id}")
            if name_text is None or reverse != str(node_id).encode() or vector is None or level is None:
                missing = []
                if name_text is None:
                    missing.append("name")
                if reverse != str(node_id).encode():
                    missing.append("reverse ID")
                if vector is None:
                    missing.append("vector")
                if level is None:
                    missing.append("level")
                defects.append(f"node {node_id} has missing/invalid {', '.join(missing)}")
                continue
            if len(vector) != 16 * 2:
                defects.append(f"node {node_id} vector has {len(vector)} bytes")
                continue
            names_by_id[node_id] = name_text

        def ids_for(pattern):
            ids = set()
            for key in client.keys(pattern):
                try:
                    ids.add(int(key.rsplit(b".", 1)[1]))
                except ValueError:
                    defects.append(f"invalid key for {pattern}: {key}")
            return ids

        vector_ids = ids_for("vec.v.*")
        level_ids = ids_for("vec.lv.*")
        if vector_ids != name_ids:
            defects.append("vector keys do not match name IDs")
        if level_ids != name_ids:
            defects.append("level keys do not match name IDs")
        reverse_names = set()
        for key in client.keys("vec.id.*"):
            key_name = key.decode()
            reverse_name = key_name[len("vec.id."):]
            reverse_names.add(reverse_name)
            reverse_id = client.get(key)
            try:
                if names_by_id.get(int(reverse_id)) != reverse_name:
                    defects.append(f"reverse ID does not match name: {key_name}")
            except (TypeError, ValueError):
                defects.append(f"invalid reverse ID: {key_name}")
        if reverse_names != set(names_by_id.values()):
            defects.append("reverse ID keys do not match complete names")

        if graph_count != len(names_by_id):
            defects.append(f"vec.count={graph_count}, complete nodes={len(names_by_id)}")
        if set(names_by_id) != set(range(1, graph_count + 1)):
            defects.append("node IDs are missing or non-contiguous")

        for key in client.keys("vec.n.*"):
            raw = client.get(key)
            parts = key.split(b".")
            if len(parts) != 4 or raw is None or not raw.startswith(b"\x01") or (len(raw) - 1) % 4:
                defects.append(f"malformed neighbor list: {key}")
                continue
            try:
                owner, layer = int(parts[2]), int(parts[3])
            except ValueError:
                defects.append(f"invalid neighbor key: {key}")
                continue
            if owner not in names_by_id:
                defects.append(f"neighbor list has missing owner: {key}")
            if owner in names_by_id:
                try:
                    if layer > int(client.get(f"vec.lv.{owner}")):
                        defects.append(f"neighbor list exceeds node level: {key}")
                except (TypeError, ValueError):
                    defects.append(f"invalid node level for: {key}")
            for offset in range(1, len(raw), 4):
                neighbor = struct.unpack_from("<I", raw, offset)[0]
                if neighbor not in names_by_id:
                    defects.append(f"{key} points to missing node {neighbor}")

        entry = client.get("vec.entry")
        try:
            if graph_count and (entry is None or int(entry) not in names_by_id):
                defects.append(f"invalid entry point: {entry}")
        except ValueError:
            defects.append(f"invalid entry point: {entry}")
        persisted_names = set(names_by_id.values())
        with lock:
            result = dict(counts)
            acked = set(acknowledged_names)
            attempted = set(attempted_names)
        acked_lost = acked - persisted_names
        seed_retained = sum(name.startswith("chaos-seed-") for name in persisted_names)
        outcome = (
            f"aof={'each' if aof_enabled else 'off'} aof_replay={aof_replay} "
            f"delay_ms={delay * 1000:.1f} active_at_kill={active_at_kill} "
            f"attempted={len(attempted)} acked={len(acked)} "
            f"unknown_outcome={len(attempted - acked)} graph_count={graph_count} "
            f"complete_nodes={len(persisted_names)} seed_retained={seed_retained}/{len(points)} "
            f"acked_lost={len(acked_lost)} disconnects={result['disconnects']}"
        )
        print(f"ungraceful recovery: {outcome}", flush=True)
        assert seed_retained == len(points), f"auto-saved seed loss: {outcome}"
        if defects:
            pytest.fail(f"{outcome}; structural defects: " + "; ".join(defects[:20]))

        for node_id in sorted(names_by_id)[:min(20, graph_count)]:
            query_name = client.execute_command(
                "vectors.CLOSEST", _pack(points[node_id - 1])
            )
            assert query_name is not None and query_name.decode() in names_by_id.values(), (
                node_id,
                query_name,
            )

        server.client = client
    finally:
        stop.set()
        for worker in workers:
            worker.join(timeout=5)
        if idle is not None:
            idle.close()

    assert not failures, failures
