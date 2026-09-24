from __future__ import annotations

import json
import time

from redis.exceptions import ResponseError

from .conftest import install, set_configuration
from .helpers import webhook_server, wait_until


def _setup(client, url, **overrides):
    client.execute_command("USE", "watchdog")
    client.execute_command("FLUSHDB")
    install(client, "watchdog", "WATCHDOG", "watchdog/watchdog.luau")
    values = {
        "watchdog.to": "",
        "watchdog.webhook": url,
        "watchdog.counters": "function_errors",
        "watchdog.window": "2s",
        "watchdog.baseline": "1h",
        "watchdog.factor": "1",
        "watchdog.min_count": "1",
        "watchdog.cooldown": "0",
        "watchdog.restart": "0",
        "watchdog.name": "testd",
        "watchdog.webhook_format": "json",
    }
    values.update(overrides)
    set_configuration(client, values)
    client.execute_command("USE", "watchdog")
    client.execute_command("SETF", "BOOM", "function call() error('boom') end")


def _tick(client):
    client.execute_command("USE", "watchdog")
    return client.execute_command("CALLF", "WATCHDOG", "TICK")


def _bos(client, count=5):
    client.execute_command("USE", "watchdog")
    for _ in range(count):
        try:
            client.execute_command("BOOM")
        except ResponseError:
            pass


def _baseline_then_errors(client):
    # Separate the samples by a few milliseconds: the clock is millisecond
    # resolution, and two samples in the same millisecond cover no time.
    _tick(client)
    time.sleep(0.05)
    _bos(client)
    time.sleep(0.05)
    _tick(client)


def test_watchdog_webhook_alert_lifecycle(client):
    with webhook_server() as hooks:
        _setup(client, f"http://127.0.0.1:{hooks.server_address[1]}/hook")
        _baseline_then_errors(client)

        assert wait_until(lambda: len(hooks.received) >= 1), "the climbing alert was not delivered"
        alert = json.loads(hooks.received[0]["body"])
        assert alert["subject"] == "function_errors climbing", alert
        assert "function_errors" in alert["text"], alert
        assert alert["server"] == "testd", alert

        # With no new errors and the window passed, the alert clears and a
        # recovery message goes out.
        time.sleep(2.2)
        _tick(client)
        assert wait_until(lambda: len(hooks.received) >= 2), "the recovery message was not delivered"
        recovery = json.loads(hooks.received[1]["body"])
        assert recovery["subject"] == "error rates back to normal", recovery


def test_watchdog_retries_a_failed_webhook(client):
    with webhook_server(fail_first=1) as hooks:
        _setup(client, f"http://127.0.0.1:{hooks.server_address[1]}/hook")
        _baseline_then_errors(client)

        # The first delivery is refused, and STATUS says so while it waits.
        assert wait_until(lambda: len(hooks.received) >= 1)
        client.execute_command("USE", "watchdog")
        status = client.execute_command("CALLF", "WATCHDOG", "STATUS")
        assert any("last send failed" in line for line in status), status

        # The next tick retries it, and it lands.
        time.sleep(2.2)
        _tick(client)
        assert wait_until(lambda: any(
            json.loads(req["body"])["subject"] == "function_errors climbing"
            for req in hooks.received[1:]
        )), hooks.received
        status = client.execute_command("CALLF", "WATCHDOG", "STATUS")
        assert not any("last send failed" in line for line in status), status


def test_watchdog_test_message_formats_and_cron_install(client):
    with webhook_server() as hooks:
        _setup(client, f"http://127.0.0.1:{hooks.server_address[1]}/hook")

        client.execute_command("USE", "watchdog")
        assert client.execute_command("CALLF", "WATCHDOG", "TEST").startswith("OK: sent to")
        assert wait_until(lambda: len(hooks.received) >= 1)
        json_req = hooks.received[-1]
        assert json.loads(json_req["body"])["subject"] == "test message"
        assert json_req["headers"].get("Content-Type") == "application/json"

        set_configuration(client, {"watchdog.webhook_format": "plain"})
        client.execute_command("USE", "watchdog")
        assert client.execute_command("CALLF", "WATCHDOG", "TEST").startswith("OK: sent to")
        assert wait_until(lambda: len(hooks.received) >= 2)
        plain_req = hooks.received[-1]
        assert plain_req["headers"].get("Content-Type") == "text/plain; charset=utf-8", plain_req["headers"]
        assert plain_req["headers"].get("Title", "").startswith("[testd]"), plain_req["headers"]
        assert b"test from the barch watchdog" in plain_req["body"]

        # INSTALL writes the cron job, UNINSTALL removes it.
        assert client.execute_command("CALLF", "WATCHDOG", "INSTALL", "monitor").startswith("OK: cron/jobs/watchdog")
        client.execute_command("USE", "configuration")
        job = client.execute_command("GETF", "cron/jobs/watchdog")
        assert job and "every" in job and 'user = "monitor"' in job, job
        client.execute_command("USE", "watchdog")
        assert client.execute_command("CALLF", "WATCHDOG", "UNINSTALL") == "OK"
        client.execute_command("USE", "configuration")
        assert client.execute_command("GETF", "cron/jobs/watchdog") is None