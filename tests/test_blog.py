import re

import pytest

from .conftest import install

redis = pytest.importorskip("redis")


@pytest.fixture
def blog(client, request):
    for name, path in [("KEYCODEC", "ent/keycodec.luau"), ("ROWCODEC", "ent/rowcodec.luau"),
                       ("SCHEMA", "ent/schema.luau"), ("LAYOUT", "ent/layout.luau"),
                       ("MIGRATE", "ent/migrate.luau"), ("CLIENT", "ent/client.luau")]:
        install(client, "ent", name, path)
    install(client, "blog", "SCHEMA", "examples/blog/schema.luau")
    # BLOG requires blog.SCHEMA, and keeps its rows in the space it runs in,
    # so each test gets a space of its own
    install(client, "blog_" + re.sub(r"\W", "_", request.node.name), "BLOG",
            "examples/blog/blog.luau")
    return lambda *args: client.execute_command("CALLF", "BLOG", *args)


def test_blog_example(client, blog):
    assert blog("migrate") == 1
    assert blog("migrate") == 1
    for email, name in [("ann@x", "Ann"), ("bob@x", "Bob"), ("cy@x", "Cy")]:
        blog("user", email, name)
    for email, title in [("ann@x", "hello"), ("bob@x", "first"), ("ann@x", "again"),
                         ("cy@x", "lurking")]:
        blog("post", email, title, "body of " + title)
    blog("follow", "cy@x", "ann@x")
    blog("follow", "cy@x", "bob@x")
    assert [blog("star", "2") for _ in range(3)] == [1, 2, 3]
    blog("star", "1")

    assert blog("posts", "ann@x") == ["3 0 again", "1 1 hello"]
    assert blog("timeline", "cy@x", "2") == ["3 0 again", "2 3 first"]
    assert blog("timeline", "ann@x") == []
    assert blog("top", "2") == ["2 3 first", "1 1 hello"]


@pytest.mark.parametrize("args, error", [
    (("post", "zed@x", "t", "b"), "BLOG has no user zed@x"),
    (("user", "ann@x", "Again"), "ENT table User index by_email is unique, and row 1"),
    (("star", "9"), "BLOG has no post 9"),
    (("top", "0"), "BLOG wants a count of 1 or more, got 0"),
    (("tweet",), "BLOG has no command tweet"),
])
def test_blog_errors(client, blog, args, error):
    blog("migrate")
    blog("user", "ann@x", "Ann")
    with pytest.raises(redis.ResponseError, match=error):
        blog(*args)


def test_blog_schema_module(client, blog):
    client.execute_command("USE", "blog")
    assert client.execute_command("CALLF", "SCHEMA") == ["User", "Post"]
