from __future__ import annotations

import json

from .helpers import http_call


def _post_json(port, path, payload, cookie=None):
    headers = {"Content-Type": "application/json"}
    if cookie:
        headers["Cookie"] = cookie
    return http_call(port, "POST", path, json.dumps(payload).encode(), headers)


def _get(port, path, cookie=None):
    headers = {"Cookie": cookie} if cookie else None
    return http_call(port, "GET", path, headers=headers)


def test_spaces_viewer_end_to_end(spaces_http):
    port = spaces_http

    # A clean server has no admin yet, and says so rather than refusing.
    reply = _get(port, "/api/admin/me")
    assert reply.status == 200, reply.body
    assert reply.json()["needs_admin"] is True

    # The first account to register becomes the admin and gets a session cookie.
    reply = _post_json(port, "/api/spaces-user/register",
                       {"name": "Alice", "email": " Alice@Example.COM ", "password": "secret1"})
    assert reply.status == 200, reply.body
    assert reply.json()["ok"] is True
    assert reply.json()["user"]["email"] == "alice@example.com", "email normalizes"
    alice = reply.cookie("sid")
    assert alice, reply.headers

    reply = _get(port, "/api/admin/me", f"sid={alice}")
    assert reply.status == 200 and reply.json()["admin"] is True, reply.body

    # The viewer page is served from the spaces.html key.
    reply = _get(port, "/spaces")
    assert reply.status == 200, reply.body
    assert b"<!doctype html" in reply.body.lower()

    # The admin API sees the spaces, including the one it runs in.
    reply = _get(port, "/api/admin/spaces", f"sid={alice}")
    assert reply.status == 200, reply.body
    names = {space["name"] for space in reply.json()["spaces"]}
    assert "spaces" in names

    # A key is written, read back, listed and removed through the API.
    reply = http_call(port, "POST", "/api/admin/key_put?space=spaces&key=demo:one",
                      b"hello", {"Cookie": f"sid={alice}"})
    assert reply.status == 200, reply.body
    reply = _get(port, "/api/admin/value?space=spaces&key=demo:one", f"sid={alice}")
    assert reply.json()["value"] == "hello", reply.body
    reply = _get(port, "/api/admin/keys?space=spaces&prefix=demo:", f"sid={alice}")
    rows = reply.json()["keys"]
    assert any(row["key"] == "demo:one" and row["value"] == "hello" for row in rows), rows
    reply = http_call(port, "POST", "/api/admin/key_rm?space=spaces&key=demo:one",
                      b"", {"Cookie": f"sid={alice}"})
    assert reply.status == 200, reply.body

    # A stored function is written and read back, with its native marker.
    reply = http_call(port, "POST", "/api/admin/function_put?space=spaces&name=VIEWFN",
                      b"function call() return 'hi' end", {"Cookie": f"sid={alice}"})
    assert reply.status == 200, reply.body
    reply = _get(port, "/api/admin/function?space=spaces&name=VIEWFN", f"sid={alice}")
    body = reply.json()
    assert body["source"].startswith("function call()"), body
    assert body["native"] is False, body
    assert http_call(port, "GET", "/api/admin/keys?space=spaces", headers={"Cookie": f"sid={alice}"}).status == 200

    # A second account is not an admin: it can look, but not change.
    reply = _post_json(port, "/api/spaces-user/register",
                       {"name": "Bob", "email": "bob@example.com", "password": "secret2"})
    assert reply.json()["ok"] is True, reply.body
    bob = reply.cookie("sid")
    reply = _get(port, "/api/admin/me", f"sid={bob}")
    assert reply.status == 200 and reply.json()["admin"] is False, reply.body
    assert _get(port, "/api/admin/spaces", f"sid={bob}").status == 200
    reply = http_call(port, "POST", "/api/admin/key_put?space=spaces&key=nope",
                      b"x", {"Cookie": f"sid={bob}"})
    assert reply.status == 403, reply.body

    # Sign-on over HTTP: the wrong password is refused, the right one gets a
    # fresh session, and sign-out ends it.
    reply = _post_json(port, "/api/spaces-user/signon",
                       {"email": "alice@example.com", "password": "wrong"})
    assert reply.status == 401, reply.body
    reply = _post_json(port, "/api/spaces-user/signon",
                       {"email": "ALICE@example.com", "password": "secret1"})
    assert reply.status == 200 and reply.json()["ok"] is True, reply.body
    again = reply.cookie("sid")
    reply = http_call(port, "POST", "/api/spaces-user/signout", b"",
                      {"Cookie": f"sid={again}"})
    assert reply.status == 200, reply.body
    reply = _get(port, "/api/admin/me", f"sid={again}")
    assert reply.status == 401, reply.body


def test_admin_can_create_and_drop_a_space(spaces_http):
    port = spaces_http
    reply = _post_json(port, "/api/spaces-user/register",
                       {"name": "Admin", "email": "admin@example.com", "password": "secret1"})
    sid = reply.cookie("sid")
    assert sid

    reply = http_call(port, "POST", "/api/admin/space_add?name=scratch",
                      b"", {"Cookie": f"sid={sid}"})
    assert reply.status == 200, reply.body
    names = {space["name"] for space in _get(port, "/api/admin/spaces", f"sid={sid}").json()["spaces"]}
    assert "scratch" in names

    reply = http_call(port, "POST", "/api/admin/space_rm?name=scratch",
                      b"", {"Cookie": f"sid={sid}"})
    assert reply.status == 200, reply.body
    names = {space["name"] for space in _get(port, "/api/admin/spaces", f"sid={sid}").json()["spaces"]}
    assert "scratch" not in names