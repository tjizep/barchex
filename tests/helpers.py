from __future__ import annotations

import http.client
import http.server
import json
import re
import socket
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from urllib.parse import parse_qs, urlsplit

import redis


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_until(pred, timeout: float = 15.0, step: float = 0.05) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(step)
    return pred()


def wait_for_tcp(port: int, host: str = "127.0.0.1", timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.25):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError(f"nothing accepted a connection on {host}:{port} in {timeout:g}s")


def connect(port: int, decode_responses: bool = True) -> redis.Redis:
    return redis.Redis(
        host="127.0.0.1",
        port=port,
        db=0,
        protocol=2,
        decode_responses=decode_responses,
        socket_timeout=30,
    )


@dataclass
class Reply:
    status: int
    body: bytes
    headers: list[tuple[str, str]]

    def header(self, name: str) -> str | None:
        want = name.lower()
        for key, value in self.headers:
            if key.lower() == want:
                return value
        return None

    def json(self):
        return json.loads(self.body.decode())

    def cookie(self, name: str) -> str | None:
        for key, value in self.headers:
            if key.lower() != "set-cookie":
                continue
            if value.startswith(name + "="):
                return value.split(";", 1)[0].split("=", 1)[1]
        return None


def http_call(port: int, method: str, path: str, body: bytes | None = None,
              headers: dict[str, str] | None = None, timeout: float = 30.0) -> Reply:
    hdrs = dict(headers or {})
    if body is not None:
        hdrs.setdefault("Content-Length", str(len(body)))
    hdrs.setdefault("Connection", "close")
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        conn.request(method, path, body=body, headers=hdrs)
        response = conn.getresponse()
        return Reply(response.status, response.read(), response.getheaders())
    finally:
        conn.close()


def read_body(handler) -> bytes:
    length = handler.headers.get("Content-Length")
    if length:
        return handler.rfile.read(int(length))
    if "chunked" in handler.headers.get("Transfer-Encoding", "").lower():
        chunks = []
        while True:
            size = int(handler.rfile.readline().split(b";", 1)[0].strip(), 16)
            if size == 0:
                handler.rfile.readline()
                break
            chunks.append(handler.rfile.read(size))
            handler.rfile.read(2)
        return b"".join(chunks)
    return b""


class _S3State:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.buckets: set[str] = set()
        self.objects: dict[tuple[str, str], bytes] = {}
        self.types: dict[tuple[str, str], str] = {}
        self.uploads: dict[str, dict] = {}
        self.next_upload = 1
        self.requests: list[tuple[str, str, str]] = []

    def new_upload(self) -> str:
        uid = f"upload-{self.next_upload}"
        self.next_upload += 1
        return uid


class _S3Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        self._route("GET")

    def do_PUT(self):
        self._route("PUT")

    def do_POST(self):
        self._route("POST")

    def do_DELETE(self):
        self._route("DELETE")

    def _route(self, method):
        state: _S3State = self.server.state
        parsed = urlsplit(self.path)
        parts = parsed.path.split("/", 2)
        bucket = parts[1] if len(parts) > 1 else ""
        key = parts[2] if len(parts) > 2 else ""
        query = parse_qs(parsed.query, keep_blank_values=True)
        body = read_body(self)
        with state.lock:
            state.requests.append((method, parsed.path, parsed.query))
            if bucket == "":
                if method == "GET":
                    return self._send(200, self._bucket_xml(state))
                return self._send(405, b"")
            if method == "GET":
                if "list-type" in query:
                    return self._send(200, self._list_xml(state, bucket, query))
                return self._get(state, bucket, key)
            if method == "PUT":
                if "partNumber" in query and "uploadId" in query:
                    return self._put_part(state, query, body)
                if key == "":
                    state.buckets.add(bucket)
                    return self._send(200, b"")
                return self._put(state, bucket, key, body)
            if method == "POST":
                if "uploads" in query:
                    return self._initiate(state, bucket, key)
                if "uploadId" in query:
                    return self._complete(state, query)
                return self._send(405, b"")
            if method == "DELETE":
                if "uploadId" in query:
                    state.uploads.pop(query["uploadId"][0], None)
                    return self._send(204, b"")
                state.objects.pop((bucket, key), None)
                state.types.pop((bucket, key), None)
                return self._send(204, b"")
        return self._send(405, b"")

    def _get(self, state, bucket, key):
        payload = state.objects.get((bucket, key))
        if payload is None:
            return self._send(404, self._error("NoSuchKey", key), "application/xml")
        content_type = state.types.get((bucket, key), "application/octet-stream")
        wanted = self.headers.get("Range")
        if wanted:
            match = re.match(r"bytes=(\d+)-(\d*)", wanted)
            start = int(match.group(1))
            end = int(match.group(2)) if match.group(2) else len(payload) - 1
            if not payload or start >= len(payload):
                return self._send(416, b"", content_type)
            end = min(end, len(payload) - 1)
            return self._send(
                206, payload[start:end + 1], content_type,
                {"Content-Range": f"bytes {start}-{end}/{len(payload)}"},
            )
        return self._send(200, payload, content_type)

    def _put(self, state, bucket, key, body):
        state.buckets.add(bucket)
        state.objects[(bucket, key)] = body
        state.types[(bucket, key)] = self.headers.get("Content-Type", "application/octet-stream")
        return self._send(200, b"", extra={"ETag": '"etag-object"'})

    def _initiate(self, state, bucket, key):
        uid = state.new_upload()
        state.uploads[uid] = {"bucket": bucket, "key": key, "parts": {}}
        body = ("<InitiateMultipartUploadResult><Bucket>%s</Bucket><Key>%s</Key>"
                "<UploadId>%s</UploadId></InitiateMultipartUploadResult>") % (bucket, key, uid)
        return self._send(200, body.encode())

    def _put_part(self, state, query, body):
        uid = query["uploadId"][0]
        number = int(query["partNumber"][0])
        state.uploads[uid]["parts"][number] = body
        return self._send(200, b"", extra={"ETag": f'"part-{number}"'})

    def _complete(self, state, query):
        upload = state.uploads.pop(query["uploadId"][0])
        payload = b"".join(upload["parts"][n] for n in sorted(upload["parts"]))
        state.objects[(upload["bucket"], upload["key"])] = payload
        state.types[(upload["bucket"], upload["key"])] = "application/octet-stream"
        body = ("<CompleteMultipartUploadResult><ETag>\"etag-multipart\"</ETag>"
                "</CompleteMultipartUploadResult>")
        return self._send(200, body.encode())

    def _list_xml(self, state, bucket, query):
        prefix = query.get("prefix", [""])[0]
        delimiter = query.get("delimiter", [None])[0]
        keys = sorted(k for (b, k) in state.objects if b == bucket and k.startswith(prefix))
        contents, prefixes = [], set()
        for key in keys:
            rest = key[len(prefix):]
            if delimiter and delimiter in rest:
                prefixes.add(prefix + rest.split(delimiter, 1)[0] + delimiter)
            else:
                contents.append(key)
        out = [f"<ListBucketResult><Name>{bucket}</Name><IsTruncated>false</IsTruncated>"]
        for key in contents:
            out.append(
                f"<Contents><Key>{key}</Key><Size>{len(state.objects[(bucket, key)])}</Size>"
                f"<ETag>\"etag-list\"</ETag>"
                f"<LastModified>2026-01-01T00:00:00.000Z</LastModified></Contents>"
            )
        for folder in sorted(prefixes):
            out.append(f"<CommonPrefixes><Prefix>{folder}</Prefix></CommonPrefixes>")
        out.append("</ListBucketResult>")
        return "".join(out).encode()

    def _bucket_xml(self, state):
        out = ["<ListAllMyBucketsResult><Buckets>"]
        for bucket in sorted(state.buckets):
            out.append(f"<Bucket><Name>{bucket}</Name>"
                       f"<CreationDate>2026-01-01T00:00:00.000Z</CreationDate></Bucket>")
        out.append("</Buckets></ListAllMyBucketsResult>")
        return "".join(out).encode()

    def _error(self, code, message):
        return f"<Error><Code>{code}</Code><Message>{message}</Message></Error>".encode()

    def _send(self, status, body, content_type="application/xml", extra=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)


class _S3Server(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


@contextmanager
def fake_s3():
    server = _S3Server(("127.0.0.1", 0), _S3Handler)
    server.state = _S3State()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()


class _WebhookHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        server = self.server
        body = read_body(self)
        with server.lock:
            index = len(server.received)
            server.received.append({
                "path": self.path,
                "headers": {k: v for k, v in self.headers.items()},
                "body": body,
            })
        status = 500 if index < server.fail_first else 200
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()


class _WebhookServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


@contextmanager
def webhook_server(fail_first: int = 0):
    server = _WebhookServer(("127.0.0.1", 0), _WebhookHandler)
    server.lock = threading.Lock()
    server.received = []
    server.fail_first = fail_first
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()
