import pytest

from src.app import create_app


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.setenv("ENABLE_CHAOS_ENDPOINTS", "false")
    app = create_app()
    app.config["TESTING"] = True
    return app.test_client()


@pytest.fixture()
def chaos_client(monkeypatch):
    monkeypatch.setenv("ENABLE_CHAOS_ENDPOINTS", "true")
    app = create_app()
    app.config["TESTING"] = True
    return app.test_client()


def test_index(client):
    r = client.get("/")
    assert r.status_code == 200
    assert b"sample-web" in r.data


def test_health(client):
    assert client.get("/health/live").json == {"status": "ok"}
    r = client.get("/health/ready")
    assert r.status_code == 200
    assert r.json["status"] == "ready"


def test_info(client):
    r = client.get("/api/info")
    assert r.status_code == 200
    assert r.json["chaos_enabled"] is False


def test_items_crud(client):
    assert client.get("/api/items").json["count"] == 0

    r = client.post("/api/items", json={"name": "widget", "description": "blue"})
    assert r.status_code == 201
    item_id = r.json["id"]

    assert client.get(f"/api/items/{item_id}").json["name"] == "widget"
    assert client.get("/api/items").json["count"] == 1

    assert client.delete(f"/api/items/{item_id}").status_code == 204
    assert client.get(f"/api/items/{item_id}").status_code == 404


def test_create_item_requires_name(client):
    r = client.post("/api/items", json={})
    assert r.status_code == 400


def test_chaos_disabled_by_default(client):
    assert client.post("/chaos/error").status_code == 404
    assert client.post("/chaos/cpu").status_code == 404


def test_chaos_error_when_enabled(chaos_client):
    assert chaos_client.post("/chaos/error").status_code == 500


def test_chaos_cpu_when_enabled(chaos_client):
    r = chaos_client.post("/chaos/cpu?seconds=1")
    assert r.status_code == 202
    assert r.json["seconds"] == 1
