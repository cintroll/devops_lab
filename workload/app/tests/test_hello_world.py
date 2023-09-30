def test_request_example(client):
    response = client.get("/")
    assert b"<p>Hello, World!</p>" in response.data

