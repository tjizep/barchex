from __future__ import annotations

import http.server
import struct
import threading
from contextlib import contextmanager

import pytest
from redis.exceptions import ResponseError

from .conftest import install, set_configuration


def test_sigv4_matches_aws_published_examples(client):
    install(client, "s3", "SIGV4", "s3/sigv4.luau")
    client.execute_command("USE", "s3")

    assert client.execute_command("CALLF", "SIGV4") == "ok"


def test_users_register_signon_and_signout(client):
    install(client, "spaces", "USERS", "spaces/users.luau")
    client.execute_command(
        "USE", "spaces"
    )
    flow = r'''
local users = require("spaces.USERS")

function call()
    local response = {
        cookie = function(self, name, value) self.sid = value end,
        header = function(self, name, value) self[name] = value end,
    }
    local request = {
        body = '{"name":"Alice","email":" Alice@Example.COM ","password":"secret1"}',
        cookie = function(self, name) return self.sid end,
    }
    local first = users.register(request, response)
    local sid = response.sid
    local current = users.current({cookie = function() return sid end})
    local duplicate = users.register(request, response)
    local wrong = users.signon({
        body = '{"email":"alice@example.com","password":"wrong"}',
        cookie = function() return nil end,
    }, response)
    local right = users.signon({
        body = '{"email":"ALICE@example.com","password":"secret1"}',
        cookie = function() return nil end,
    }, response)
    local admin = users.is_admin({cookie = function() return response.sid end})
    local signed_out = users.signout({cookie = function() return response.sid end}, response)
    local after = users.current({cookie = function() return response.sid end})
    return {
        first.ok, first.user.email, first.user.name, current.email,
        duplicate.code, wrong.code, right.ok, admin, signed_out.ok, after == nil,
    }
end
'''
    assert client.execute_command("SETF", "USER_FLOW", flow) == "OK"

    got = client.execute_command("CALLF", "USER_FLOW")
    assert got == [
        True,
        "alice@example.com",
        "Alice",
        "alice@example.com",
        409,
        401,
        True,
        True,
        True,
        True,
    ]


def test_vectors_insert_search_tune_and_validate_arguments(client):
    install(client, "vectors", "vgraph", "vectors/vgraph.luau")
    install(client, "vectors", "VECTORS", "vectors/vectors.luau")
    client.execute_command("USE", "vectors")

    x_axis = struct.pack("<2f", 1.0, 0.0)
    y_axis = struct.pack("<2f", 0.0, 1.0)
    three_dimensions = struct.pack("<3f", 1.0, 0.0, 0.0)

    assert client.execute_command("vectors.SET", "x", x_axis) == ["OK", "1"]
    assert client.execute_command("vectors.SET", "y", y_axis) == ["OK", "2"]
    assert client.execute_command("vectors.SET", "x", x_axis) == ["exists", "1"]
    assert client.execute_command("vectors.CLOSEST", x_axis) == "x"

    closest = client.execute_command("vectors.CLOSEST", x_axis, 2)
    assert closest[0] == "x"
    assert closest[2] == "y"
    assert float(closest[1]) == pytest.approx(0.0, abs=1e-5)
    assert float(closest[3]) == pytest.approx(1.0, abs=1e-5)

    with pytest.raises(ResponseError, match="dimension mismatch"):
        client.execute_command("vectors.CLOSEST", three_dimensions)
    with pytest.raises(ResponseError, match="metric is cosine or euclidean"):
        client.execute_command("vectors.TUNE", "metric", "manhattan")

    params = client.execute_command("vectors.TUNE", "metric", "euclidean")
    assert params[5] == "euclidean"
    assert client.execute_command("vectors.CLOSEST", x_axis) == "x"


class _S3Handler(http.server.BaseHTTPRequestHandler):
    requests: list[tuple[str, str, str | None]] = []

    def log_message(self, *_args):
        pass

    def do_GET(self):
        range_header = self.headers.get("Range")
        self.requests.append((self.command, self.path, range_header))
        if "list-type=2" in self.path:
            body = """<ListBucketResult>
              <Contents><Key>nightly/orders/20260101T000000Z/shard-0000</Key><Size>11</Size></Contents>
              <Contents><Key>nightly/orders/20260101T000000Z/manifest.json</Key><Size>100</Size></Contents>
              <Contents><Key>nightly/orders/20260201T000000Z/shard-0000</Key><Size>4</Size></Contents>
            </ListBucketResult>"""
            self._send(200, body, "application/xml")
        elif self.path.endswith("/missing"):
            self._send(404, "<Error><Code>NoSuchKey</Code><Message>missing</Message></Error>", "application/xml")
        else:
            body = "hello world"
            if range_header:
                self._send(206, body[:1], "text/plain", "bytes 0-0/11")
            else:
                self._send(200, body, "text/plain")

    def _send(self, status, body, content_type, content_range=None):
        encoded = body.encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Content-Type", content_type)
        self.send_header("ETag", '"etag-1"')
        if content_range:
            self.send_header("Content-Range", content_range)
        self.end_headers()
        self.wfile.write(encoded)


@contextmanager
def s3_server():
    _S3Handler.requests = []
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _S3Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_address[1]
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()


def test_s3_commands_parse_success_errors_and_backup_listing(client):
    install(client, "s3", "SIGV4", "s3/sigv4.luau")
    install(client, "s3", "S3", "s3/s3.luau")
    install(client, "s3", "BACKUP", "s3/backup.luau")

    with s3_server() as port:
        set_configuration(
            client,
            {
                "s3.endpoint": f"http://127.0.0.1:{port}",
                "s3.region": "us-east-1",
                "s3.access_key": "test-access",
                "s3.secret_key": "test-secret",
                "s3.path_style": "1",
            },
        )
        client.execute_command("USE", "s3")

        assert client.execute_command("CALLF", "S3", "GET", "bucket", "hello") == "hello world"
        assert client.execute_command("CALLF", "S3", "STAT", "bucket", "hello") == [
            "size 11",
            "type text/plain",
            "etag etag-1",
            "modified nil",
        ]
        assert client.execute_command("CALLF", "S3", "GET", "bucket", "missing").startswith(
            "(error) s3: 404 NoSuchKey: missing"
        )

        assert client.execute_command(
            "CALLF", "BACKUP", "LIST", "orders", "bucket/nightly"
        ) == [
            "20260101T000000Z  11 bytes",
            "20260201T000000Z  4 bytes  (unfinished)",
        ]


def test_watchdog_ticks_and_reports_missing_sinks(client):
    install(client, "watchdog", "WATCHDOG", "watchdog/watchdog.luau")
    set_configuration(client, {"watchdog.counters": "function_errors", "watchdog.to": ""})
    client.execute_command("USE", "watchdog")

    assert client.execute_command("CALLF", "WATCHDOG", "TICK") == "OK"
    status = client.execute_command("CALLF", "WATCHDOG", "STATUS")
    assert status[0].startswith("barchd:")
    assert "function_errors:" in status[-1]
    assert client.execute_command("CALLF", "WATCHDOG", "TEST") == (
        "(error) nowhere to send: set watchdog.to or watchdog.webhook"
    )
