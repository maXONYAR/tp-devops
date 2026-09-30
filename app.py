"""Application Flask du projet DevOps : santé, statut, compteur de visites et métriques."""

import os
import re
import time

import redis
from flask import Flask, Response, g, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "dev")
GIT_SHA = os.getenv("GIT_SHA", "unknown")
DEPLOY_COLOR = os.getenv("DEPLOY_COLOR", "none")

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Nombre de requêtes HTTP reçues",
    ["method", "endpoint", "code"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Durée de traitement des requêtes HTTP, par route",
    ["endpoint"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
APP_BUILD_INFO = Gauge(
    "app_build_info",
    "Version et SHA du commit actuellement déployé (valeur constante 1)",
    ["version", "sha"],
)
APP_BUILD_INFO.labels(version=APP_VERSION, sha=GIT_SHA).set(1)


def alert_threshold(value, threshold=80.0):
    """Retourne True si la valeur atteint ou dépasse le seuil d'alerte."""
    return value >= threshold


def sanitize_input(text):
    """Retire les balises HTML et les caractères de contrôle, puis les espaces autour."""
    cleaned = re.sub(r"<[^>]*>", "", text)
    cleaned = re.sub(r"[\x00-\x1f\x7f]", "", cleaned)
    return cleaned.strip()


def get_redis_client():
    """Crée un client Redis (en conteneur, l'hôte est le nom du service Compose)."""
    return redis.Redis(
        host=os.getenv("REDIS_HOST", "localhost"),
        port=int(os.getenv("REDIS_PORT", "6379")),
        socket_connect_timeout=2,
        socket_timeout=2,
        decode_responses=True,
    )


@app.before_request
def start_timer():
    g.start_time = time.perf_counter()


@app.after_request
def record_metrics(response):
    # /metrics ne doit pas se compter lui-même à chaque scrape Prometheus
    if request.path == "/metrics":
        return response
    endpoint = request.url_rule.rule if request.url_rule else "unmatched"
    elapsed = time.perf_counter() - getattr(g, "start_time", time.perf_counter())
    REQUEST_COUNT.labels(
        method=request.method, endpoint=endpoint, code=str(response.status_code)
    ).inc()
    REQUEST_LATENCY.labels(endpoint=endpoint).observe(elapsed)
    return response


@app.route("/health")
def health():
    try:
        get_redis_client().ping()
    except redis.exceptions.RedisError:
        return jsonify(status="unhealthy", redis="down"), 503
    return jsonify(status="ok", redis="up"), 200


@app.route("/status")
def status():
    return jsonify(
        status="running",
        deploy_color=DEPLOY_COLOR,
        git_sha=GIT_SHA,
        version=APP_VERSION,
    )


@app.route("/visits")
def visits():
    try:
        count = get_redis_client().incr("visits")
    except redis.exceptions.RedisError:
        return jsonify(error="redis indisponible"), 503
    return jsonify(visits=count)


@app.route("/simulate-error")
def simulate_error():
    return jsonify(error="erreur simulée"), 500


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), content_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
