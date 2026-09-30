import re

import pytest
import redis

import app as app_module
from app import alert_threshold, get_redis_client, sanitize_input


@pytest.fixture()
def client():
    app_module.app.config["TESTING"] = True
    with app_module.app.test_client() as c:
        yield c


@pytest.fixture()
def clean_visits():
    get_redis_client().delete("visits")


def metric_value(text, name, **labels):
    """Lit la valeur d'une série dans le format texte Prometheus (ordre des labels indifférent)."""
    for line in text.splitlines():
        if not line.startswith(name + "{"):
            continue
        found = dict(re.findall(r'(\w+)="([^"]*)"', line))
        if all(found.get(k) == v for k, v in labels.items()):
            return float(line.rsplit(" ", 1)[1])
    return 0.0


def test_alert_threshold():
    assert alert_threshold(95) is True
    assert alert_threshold(80) is True
    assert alert_threshold(79.9) is False
    assert alert_threshold(10, threshold=5) is True


def test_sanitize_input():
    assert sanitize_input("  <script>alert(1)</script>hello\x00 ") == "alert(1)hello"
    assert sanitize_input("texte propre") == "texte propre"


def test_health_ok_when_redis_up(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok", "redis": "up"}


def test_health_503_when_redis_down(client, monkeypatch):
    class BrokenClient:
        def ping(self):
            raise redis.exceptions.ConnectionError("redis coupé")

    monkeypatch.setattr(app_module, "get_redis_client", lambda: BrokenClient())
    response = client.get("/health")
    assert response.status_code == 503
    assert response.get_json()["redis"] == "down"


def test_status_exposes_color_and_sha(client, monkeypatch):
    monkeypatch.setattr(app_module, "DEPLOY_COLOR", "green")
    monkeypatch.setattr(app_module, "GIT_SHA", "abc1234")
    body = client.get("/status").get_json()
    assert body["status"] == "running"
    assert body["deploy_color"] == "green"
    assert body["git_sha"] == "abc1234"


def test_visits_increments_and_is_stored_in_redis(client, clean_visits):
    assert client.get("/visits").get_json() == {"visits": 1}
    assert client.get("/visits").get_json() == {"visits": 2}
    # la valeur est bien côté Redis, pas en mémoire de l'application
    assert get_redis_client().get("visits") == "2"


def test_visits_503_when_redis_down(client, monkeypatch):
    class BrokenClient:
        def incr(self, *_):
            raise redis.exceptions.ConnectionError("redis coupé")

    monkeypatch.setattr(app_module, "get_redis_client", lambda: BrokenClient())
    assert client.get("/visits").status_code == 503


def test_simulate_error_returns_500(client):
    assert client.get("/simulate-error").status_code == 500


def test_metrics_counter_increments_and_excludes_metrics_endpoint(client):
    labels = {"method": "GET", "endpoint": "/status", "code": "200"}
    first = client.get("/metrics").get_data(as_text=True)
    before = metric_value(first, "http_requests_total", **labels)
    client.get("/status")
    client.get("/status")
    text = client.get("/metrics").get_data(as_text=True)
    assert metric_value(text, "http_requests_total", **labels) == before + 2
    assert 'endpoint="/metrics"' not in text


def test_metrics_expose_histogram_and_build_info(client):
    client.get("/simulate-error")
    text = client.get("/metrics").get_data(as_text=True)
    assert 'http_requests_total{code="500"' in text or 'code="500"' in text
    assert "http_request_duration_seconds_bucket" in text
    assert "http_request_duration_seconds_count" in text
    assert "http_request_duration_seconds_sum" in text
    assert "app_build_info{" in text
#fdf