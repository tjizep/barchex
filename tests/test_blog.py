import re

import pytest

from .conftest import install

redis = pytest.importorskip("redis")


@pytest.fixture
def blog(client, request):
    for name, path in [("KEYCODEC", "lent/keycodec.luau"), ("ROWCODEC", "lent/rowcodec.luau"),
                       ("SCHEMA", "lent/schema.luau"), ("LAYOUT", "lent/layout.luau"),
                       ("MIGRATE", "lent/migrate.luau"), ("CLIENT", "lent/client.luau")]:
        install(client, "lent", name, path)
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
    ids = {}
    for email, title in [("ann@x", "hello"), ("bob@x", "first"), ("ann@x", "again"),
                         ("cy@x", "lurking")]:
        ids[title] = blog("post", email, title, "body of " + title)
    # barch.uuid() ids sort in creation order
    assert sorted(ids.values()) == list(ids.values())
    blog("follow", "cy@x", "ann@x")
    blog("follow", "cy@x", "bob@x")
    assert [blog("star", ids["first"]) for _ in range(3)] == [1, 2, 3]
    blog("star", ids["hello"])

    def line(title, stars):
        return f"{ids[title]} {stars} {title}"

    assert blog("posts", "ann@x") == [line("again", 0), line("hello", 1)]
    assert blog("timeline", "cy@x", "2") == [line("again", 0), line("first", 3)]
    assert blog("timeline", "ann@x") == []
    assert blog("top", "2") == [line("first", 3), line("hello", 1)]


@pytest.mark.parametrize("args, error", [
    (("post", "zed@x", "t", "b"), "BLOG has no user zed@x"),
    (("user", "ann@x", "Again"), "LENT table User index by_email is unique, and row "),
    (("star", "9"), "LENT table Post wants a uuid id, got 9"),
    (("star", "01890000-0000-7000-8000-000000000000"), "BLOG has no post 0189"),
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
