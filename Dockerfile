# ---------- Stage 1 : builder (dépendances dans un venv isolé) ----------
FROM python:3.12.8-slim AS builder
WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---------- Stage 2 : image finale (slim, sans outils de build) ----------
FROM python:3.12.8-slim
ARG APP_VERSION=dev
ARG GIT_SHA=unknown
# Chaque stage a son propre environnement : le PATH du venv doit être redéclaré ici
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA}

RUN groupadd --system app && useradd --system --gid app --no-create-home app
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY app.py .

# USER après les COPY/RUN qui demandent les droits root
USER app
EXPOSE 5000

# Sans curl (absent des images slim) : /health interroge Redis, un 503 fait échouer la commande
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=2)"

# 1 worker + threads : les métriques prometheus_client vivent en mémoire du process
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--threads", "4", "app:app"]
