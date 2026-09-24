from .conftest import install


def test_sigv4_matches_aws_published_examples(client):
    install(client, "s3", "SIGV4", "s3/sigv4.luau")
    client.execute_command("USE", "s3")

    # The module's own self-check signs the worked requests from AWS's SigV4
    # documentation and compares the signatures AWS publishes for them.
    assert client.execute_command("CALLF", "SIGV4") == "ok"