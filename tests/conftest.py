from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

import pytest

from .helpers import connect, free_port, wait_for_tcp

redis = pytest.importorskip("redis")


ROOT = Path(__file__).resolve().parents[1]


def _barchd() -> Path | None:
    configured = os.environ.get("BARCHD")
    which = shutil.which("barchd")
    candidates = [
        Path(configured) if configured else None,
        ROOT / ".." / "barch" / "cmake-build-release" / "barchd",
        ROOT / ".." / "barch" / "cmake-build-relwithdebinfo" / "barchd",
        Path(which) if which else None,
    ]
    for candidate in candidates:
        if candidate is not None and candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    return None


def _wait_for_server(process: subprocess.Popen, port: int) -> None:
    import time

    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"barchd exited before listening (status {process.returncode})")
        try:
            import socket

            with socket.create_connection(("127.0.0.1", port), timeout=0.25):
                return
        except OSError:
            time.sleep(0.02)
    process.kill()
    raise RuntimeError("barchd did not listen within 30 seconds")


@dataclass
class Server:
    port: int
    client: "redis.Redis"
    process: subprocess.Popen
    data: str
    binary: Path
    log_path: str


@contextmanager
def _spawn_barchd():
    binary = _barchd()
    if binary is None:
        pytest.skip("barchd is required; set BARCHD to a built barchd executable")

    data = tempfile.mkdtemp(prefix="barchex-data-")
    log_path = data + ".log"
    port = free_port()
    with open(log_path, "ab") as log:
        process = subprocess.Popen(
            [str(binary), "--port", str(port), "--bind", "127.0.0.1", "--dir", data],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
    try:
        _wait_for_server(process, port)
        client = connect(port)
        client.ping()
        spawned = Server(port, client, process, data, binary, log_path)
        yield spawned
    finally:
        current = spawned.process if "spawned" in locals() else process
        if current.poll() is None:
            current.terminate()
            try:
                current.wait(timeout=10)
            except subprocess.TimeoutExpired:
                current.kill()
                current.wait()
        if "spawned" in locals():
            spawned.client.close()
        shutil.rmtree(data, ignore_errors=True)
        Path(log_path).unlink(missing_ok=True)


@pytest.fixture(scope="session")
def server():
    with _spawn_barchd() as spawned:
        yield spawned


@pytest.fixture
def fresh_server():
    with _spawn_barchd() as spawned:
        yield spawned


@pytest.fixture
def client(server):
    server.client.execute_command("USE", "default")
    server.client.execute_command("FLUSHDB")
    server.client.execute_command("USE", "configuration")
    server.client.execute_command("FLUSHDB")
    server.client.execute_command("USE", "default")
    return server.client


def source(name: str) -> str:
    return (ROOT / name).read_text()


def install(client, space: str, name: str, path: str) -> None:
    client.execute_command("USE", space)
    assert client.execute_command("SETF", name, source(path)) in ("OK", b"OK")


def set_configuration(client, values: dict[str, str]) -> None:
    client.execute_command("USE", "configuration")
    for key, value in values.items():
        client.execute_command("SET", key, value)


WEB_ACL = ["on", "+read", "+write", "+data", "+keys", "+function", "+config", "+dangerous"]


@pytest.fixture
def spaces_http(server):
    client = server.client
    port = free_port()
    client.execute_command("ACL", "SETUSER", "web", *WEB_ACL)
    client.execute_command("USE", "spaces")
    client.execute_command("FLUSHDB")
    install(client, "spaces", "USERS", "spaces/users.luau")
    install(client, "spaces", "SPACESUI", "spaces/spacesui.luau")
    install(client, "spaces", "SPACESAPI", "spaces/spacesapi.luau")
    client.execute_command("SET", "spaces.html", source("spaces/spaces.html"))
    client.execute_command("SET", "commands.json", source("spaces/commands.json"))
    conf = f'''
function call() return "http" end
function transport()
    return {{
        kind = "http",
        port = {port},
        bind = "127.0.0.1",
        user = "web",
        keys = {{"USERS", "SPACESUI", "SPACESAPI"}},
    }}
end
'''
    client.execute_command("SETF", "HTTPCONF", conf)
    client.execute_command("HTTP", "START", "HTTPCONF", str(port), "127.0.0.1")
    wait_for_tcp(port)
    try:
        yield port
    finally:
        try:
            client.execute_command("HTTP", "STOP")
        except Exception:
            pass


__all__ = [
    "Server",
    "client",
    "server",
    "spaces_http",
    "source",
    "install",
    "set_configuration",
]
