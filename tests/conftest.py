from __future__ import annotations

import os
import shutil
import socket
import subprocess
import time
from pathlib import Path

import pytest

redis = pytest.importorskip("redis")


ROOT = Path(__file__).resolve().parents[1]


def _barchd() -> Path | None:
    configured = os.environ.get("BARCHD")
    candidates = [
        Path(configured) if configured else None,
        ROOT / ".." / "barch" / "cmake-build-release" / "barchd",
        ROOT / ".." / "barch" / "cmake-build-relwithdebinfo" / "barchd",
        Path(shutil.which("barchd")) if shutil.which("barchd") else None,
    ]
    for candidate in candidates:
        if candidate is not None and candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    return None


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _wait_for_server(process: subprocess.Popen[bytes], port: int) -> None:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"barchd exited before listening (status {process.returncode})")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.25):
                return
        except OSError:
            time.sleep(0.02)
    process.kill()
    raise RuntimeError("barchd did not listen within 30 seconds")


@pytest.fixture(scope="session")
def barchd(tmp_path_factory):
    binary = _barchd()
    if binary is None:
        pytest.skip("barchd is required; set BARCHD to a built barchd executable")

    data = tmp_path_factory.mktemp("barch-data")
    port = _free_port()
    process = subprocess.Popen(
        [str(binary), "--port", str(port), "--bind", "127.0.0.1", "--dir", str(data)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )
    try:
        _wait_for_server(process, port)
        client = redis.Redis(
            host="127.0.0.1",
            port=port,
            db=0,
            protocol=2,
            decode_responses=True,
            socket_timeout=10,
        )
        client.ping()
        yield client
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


@pytest.fixture
def client(barchd):
    barchd.execute_command("FLUSHDB")
    barchd.execute_command("USE", "default")
    return barchd


def source(name: str) -> str:
    return (ROOT / name).read_text()


def install(client, space: str, name: str, path: str) -> None:
    client.execute_command("USE", space)
    assert client.execute_command("SETF", name, source(path)) == "OK"


def set_configuration(client, values: dict[str, str]) -> None:
    client.execute_command("USE", "configuration")
    for key, value in values.items():
        client.execute_command("SET", key, value)
