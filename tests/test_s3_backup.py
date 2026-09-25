from __future__ import annotations

from .conftest import install, set_configuration
from .helpers import fake_s3


def _configure(client, port):
    set_configuration(client, {
        "s3.endpoint": f"http://127.0.0.1:{port}",
        "s3.region": "us-east-1",
        "s3.access_key": "test-access",
        "s3.secret_key": "test-secret",
        "s3.path_style": "1",
    })


def _install_s3(client):
    install(client, "s3", "SIGV4", "s3/sigv4.luau")
    install(client, "s3", "S3", "s3/s3.luau")
    install(client, "s3", "BACKUP", "s3/backup.luau")
    client.execute_command("USE", "s3")


def test_s3_commands_against_a_bucket(client):
    with fake_s3() as server:
        _configure(client, server.server_address[1])
        _install_s3(client)

        assert client.execute_command("CALLF", "S3", "CHECK").startswith("ok:")
        assert client.execute_command("CALLF", "S3", "PUT", "my-bucket", "hello", "hello world", "text/plain") == "OK etag-object"
        assert client.execute_command("CALLF", "S3", "GET", "my-bucket", "hello") == "hello world"

        stat = client.execute_command("CALLF", "S3", "STAT", "my-bucket", "hello")
        assert stat[0] == "size 11", stat
        assert stat[1] == "type text/plain", stat

        reply = client.execute_command("CALLF", "S3", "GET", "my-bucket", "missing")
        assert reply.startswith("(error) s3: 404 NoSuchKey"), reply

        listing = client.execute_command("CALLF", "S3", "LS", "my-bucket")
        assert any(line.startswith("hello") for line in listing), listing
        assert "my-bucket" in client.execute_command("CALLF", "S3", "BUCKETS")

        url = client.execute_command("CALLF", "S3", "URL", "my-bucket", "hello", "60")
        assert "X-Amz-Signature=" in url and "X-Amz-Expires=60" in url, url

        assert client.execute_command("CALLF", "S3", "DEL", "my-bucket", "hello") == "OK"
        assert client.execute_command("CALLF", "S3", "GET", "my-bucket", "hello").startswith("(error) s3: 404")

        # Multipart: parts go up one at a time and finish joins them.
        client.execute_command("SETF", "MULTI", '''
function call()
    local s3 = require("s3.S3")
    local up = s3.upload("my-bucket", "multi/object")
    if up == nil then return {"no-upload"} end
    up:part("hello ")
    up:part("world")
    local etag = up:finish()
    return {tostring(etag)}
end
''')
        assert client.execute_command("CALLF", "MULTI") == ["etag-multipart"]
        assert client.execute_command("CALLF", "S3", "GET", "my-bucket", "multi/object") == "hello world"


def test_backup_save_list_load_and_drop(client):
    with fake_s3() as server:
        _configure(client, server.server_address[1])
        _install_s3(client)
        set_configuration(client, {"orders.shards": "4"})

        client.execute_command("USE", "orders")
        client.execute_command("FLUSHDB")
        original = {f"order:{i:04d}": f"value-{i}" for i in range(300)}
        for key, value in original.items():
            client.execute_command("SET", key, value)

        client.execute_command("USE", "s3")
        name = client.execute_command("CALLF", "BACKUP", "SAVE", "orders", "my-bucket/nightly")
        assert name and isinstance(name, str) and "T" in name, name

        objects = [key for (bucket, key) in server.state.objects if bucket == "my-bucket"]
        assert f"nightly/orders/{name}/manifest.json" in objects, objects
        assert any(key.startswith(f"nightly/orders/{name}/shard-") for key in objects), objects

        listing = client.execute_command("CALLF", "BACKUP", "LIST", "orders", "my-bucket/nightly")
        assert listing[0].startswith(name) and "(unfinished)" not in listing[0], listing

        # Writes after the save are lost when the earlier moment is restored.
        client.execute_command("USE", "orders")
        client.execute_command("SET", "order:9999", "after the save")
        client.execute_command("DEL", "order:0000")
        client.execute_command("USE", "s3")
        restored = client.execute_command("CALLF", "BACKUP", "LOAD", "orders", "my-bucket/nightly")
        assert restored.startswith("OK " + name), restored

        client.execute_command("USE", "orders")
        assert {key: client.get(key) for key in client.keys("*")} == original

        # A second save; its manifest is removed to look like an interruption.
        client.execute_command("USE", "s3")
        second = client.execute_command("CALLF", "BACKUP", "SAVE", "orders", "my-bucket/nightly")
        assert second != name
        manifest = f"nightly/orders/{second}/manifest.json"
        server.state.objects.pop(("my-bucket", manifest))

        listing = client.execute_command("CALLF", "BACKUP", "LIST", "orders", "my-bucket/nightly")
        assert any(line.startswith(second) and "(unfinished)" in line for line in listing), listing
        assert any(line.startswith(name) and "(unfinished)" not in line for line in listing), listing

        # A load with no name skips the unfinished one and takes the complete one.
        assert client.execute_command("CALLF", "BACKUP", "LOAD", "orders", "my-bucket/nightly").startswith("OK " + name)

        # Dropping removes every object of that backup.
        dropped = client.execute_command("CALLF", "BACKUP", "DROP", "orders", "my-bucket/nightly", second)
        assert dropped.startswith("OK "), dropped
        assert not any(key.startswith(f"nightly/orders/{second}/") for (_, key) in server.state.objects)


def test_backup_refuses_a_corrupt_restore_before_touching_the_space(client):
    with fake_s3() as server:
        _configure(client, server.server_address[1])
        _install_s3(client)
        set_configuration(client, {"orders.shards": "4"})

        client.execute_command("USE", "orders")
        client.execute_command("FLUSHDB")
        original = {f"order:{i:04d}": f"value-{i}" for i in range(40)}
        for key, value in original.items():
            client.execute_command("SET", key, value)

        client.execute_command("USE", "s3")
        name = client.execute_command("CALLF", "BACKUP", "SAVE", "orders", "my-bucket/nightly")
        root = f"nightly/orders/{name}/"
        shards = sorted(key for (bucket, key) in server.state.objects
                        if bucket == "my-bucket" and key.startswith(root) and "shard-" in key)
        assert shards, list(server.state.objects)
        lengths = {key: len(server.state.objects[("my-bucket", key)]) for key in shards}

        # A shard whose size disagrees with the manifest stops the load.
        server.state.objects[("my-bucket", shards[0])] += b"tampered"
        reply = client.execute_command("CALLF", "BACKUP", "LOAD", "orders", "my-bucket/nightly", name)
        assert "the manifest says" in reply, reply

        # A missing shard object stops it too.
        server.state.objects[("my-bucket", shards[0])] = (
            server.state.objects[("my-bucket", shards[0])][:lengths[shards[0]]]
        )
        server.state.objects.pop(("my-bucket", shards[-1]))
        reply = client.execute_command("CALLF", "BACKUP", "LOAD", "orders", "my-bucket/nightly", name)
        assert "(error) s3:" in reply and shards[-1] in reply, reply

        # The space is left exactly as it was.
        client.execute_command("USE", "orders")
        assert {key: client.get(key) for key in client.keys("*")} == original


def test_backup_carries_the_dictionary_of_a_compressed_space(client, fresh_server):
    with fake_s3() as server:
        _configure(client, server.server_address[1])
        _install_s3(client)
        set_configuration(client, {"orders.shards": "4"})
        client.execute_command("CONFIG", "SET", "compression", "zstd")
        try:
            client.execute_command("USE", "orders")
            client.execute_command("FLUSHDB")
            # zstd's trainer refuses one repeated sample, so the samples vary
            left, n = 512000, 0
            while left > 0:
                chunk = f"sample {n} ".encode() + bytes([(n * 7 + i) % 251 + 1 for i in range(30000)])
                left = client.execute_command("TRAIN", chunk)
                n += 1
                assert n < 60, "the dictionary never trained"

            original = {}
            for i in range(300):
                key, value = f"order:{i:04d}", f"repeat {i} " * 40
                client.execute_command("SET", key, value)
                original[key] = value
                assert client.execute_command("COMPRESS", key) == 1, key

            client.execute_command("USE", "s3")
            name = client.execute_command("CALLF", "BACKUP", "SAVE", "orders", "my-bucket/nightly")
            assert name and isinstance(name, str) and "T" in name, name
            assert ("my-bucket", f"nightly/orders/{name}/dictionary.bin") in server.state.objects

            # A server that never held the dictionary restores the compressed values.
            other = fresh_server.client
            other.execute_command("USE", "configuration")
            other.execute_command("SET", "orders.shards", "4")
            other.execute_command("CONFIG", "SET", "compression", "zstd")
            _configure(other, server.server_address[1])
            _install_s3(other)
            other.execute_command("USE", "orders")
            other.execute_command("FLUSHDB")
            other.execute_command("USE", "s3")
            restored = other.execute_command("CALLF", "BACKUP", "LOAD", "orders", "my-bucket/nightly", name)
            assert restored.startswith("OK " + name), restored

            other.execute_command("USE", "orders")
            assert {key: other.get(key) for key in other.keys("*")} == original

            # With compression off, the dictionary cannot be set, so the restore
            # is refused before any shard lands.
            client.execute_command("CONFIG", "SET", "compression", "none")
            client.execute_command("USE", "s3")
            reply = client.execute_command("CALLF", "BACKUP", "LOAD", "orders", "my-bucket/nightly", name)
            assert "compression is off here" in reply, reply
        finally:
            client.execute_command("CONFIG", "SET", "compression", "none")


def test_backup_restore_rejects_a_differently_sharded_server(client, fresh_server):
    with fake_s3() as server:
        _configure(client, server.server_address[1])
        _install_s3(client)
        set_configuration(client, {"orders.shards": "4"})
        client.execute_command("USE", "orders")
        client.execute_command("FLUSHDB")
        for i in range(40):
            client.execute_command("SET", f"order:{i:04d}", f"value-{i}")
        client.execute_command("USE", "s3")
        name = client.execute_command("CALLF", "BACKUP", "SAVE", "orders", "my-bucket/nightly")

        # A second server opened its orders space with one shard. The same backup
        # is refused there, because a restore needs the matching count.
        other = fresh_server.client
        other.execute_command("USE", "configuration")
        other.execute_command("SET", "orders.shards", "1")
        _configure(other, server.server_address[1])
        _install_s3(other)
        other.execute_command("USE", "orders")
        other.execute_command("SET", "mine", "1")
        other.execute_command("USE", "s3")
        reply = other.execute_command("CALLF", "BACKUP", "LOAD", "orders", "my-bucket/nightly", name)
        assert "needs the same number" in reply, reply

        other.execute_command("USE", "orders")
        assert other.get("mine") == "1"


def test_file_source_falls_through_to_the_bucket(client):
    with fake_s3() as server:
        _configure(client, server.server_address[1])
        _install_s3(client)
        set_configuration(client, {
            "photos.fs_source": "S3SOURCE",
            "photos.fs_source_list": "S3LIST",
            "s3.source.photos": "my-bucket/photos",
            "photos.function_deadline_ms": "30000",
        })
        server.state.objects[("my-bucket", "photos/logo.txt")] = b"logo bytes"
        server.state.types[("my-bucket", "photos/logo.txt")] = "text/plain"

        client.execute_command("USE", "photos")
        client.execute_command("SETF", "S3SOURCE",
                               "function call(path) return require('s3.S3').source(path) end")
        client.execute_command("SETF", "S3LIST",
                               "function call(dir) return require('s3.S3').listing(dir) end")

        assert client.execute_command("CALLF", "S3SOURCE", "logo.txt") == ["logo bytes", "text/plain"]
        assert "logo.txt" in client.execute_command("CALLF", "S3LIST", "")