import json
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

import main


@pytest.fixture
def publisher(monkeypatch):
    pub = MagicMock()
    pub.topic_path.return_value = "projects/p/topics/orders"
    monkeypatch.setattr(main, "get_publisher", lambda: pub)
    monkeypatch.setenv("GCP_PROJECT_ID", "p")
    monkeypatch.setenv("PUBSUB_TOPIC", "orders")
    return pub


client = TestClient(main.app)


def test_healthz():
    assert client.get("/healthz").json() == {"status": "ok"}


def test_version():
    assert client.get("/version").json() == {"version": "1.1.0"}


def test_create_order_publishes_message(publisher):
    resp = client.post("/orders", json={"item": "book", "quantity": 2})
    assert resp.status_code == 202
    topic, data = publisher.publish.call_args.args
    assert topic == "projects/p/topics/orders"
    body = json.loads(data)
    assert body["order_id"] == resp.json()["order_id"]
    assert body["item"] == "book" and body["quantity"] == 2


def test_invalid_order_is_rejected_and_not_published(publisher):
    assert client.post("/orders", json={"item": "book", "quantity": 0}).status_code == 422
    publisher.publish.assert_not_called()


def test_publish_failure_returns_503(publisher):
    publisher.publish.return_value.result.side_effect = RuntimeError("boom")
    assert client.post("/orders", json={"item": "book", "quantity": 1}).status_code == 503


def test_metrics_counts_requests():
    client.get("/healthz")
    text = client.get("/metrics").text
    assert 'http_requests_total{method="GET",path="/healthz",status="200"}' in text
    assert "http_request_duration_seconds_bucket" in text
