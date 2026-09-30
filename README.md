
Dépôt : https://github.com/maXONYAR/tp-devops

Badge CI
https://github.com/maXONYAR/tp-devops/actions/workflows/ci.yml/badge.svg ; https://github.com/maXONYAR/tp-devops/actions/workflows/ci.yml

Application Flask + Redis, pipeline CI/CD GitHub Actions, image publiée sur GHCR, déploiement blue/green
sur runner self-hosted, observabilité Prometheus + Grafana.

Image publiée : `ghcr.io/maxonyar/tp-devops` (tags `latest`, SHA court, semver `1.0.N`).
https://github.com/maXONYAR/tp-devops/pkgs/container/tp-devops

## Stratégie de branches

Trunk-based : `main` est protégée (PR obligatoire, historique linéaire, check `ci-ok` requis).
Branches courtes nommées `type/sujet` (`feat/visits`, `fix/health-redis`), fusion en **squash**.
Commits au format Conventional Commits (`feat(app): ...`, `fix(deploy): ...`, `ci: ...`, `docs: ...`, `chore: ...`).
Versions : `VERSION` contient `MAJEUR.MINEUR`, le patch est le numéro de run du CD. ex 1.0.12

## Structure

| Fichier / dossier | Rôle |
|---|---|
| `app.py`, `test_app.py` | Application (`/health`, `/status`, `/visits`, `/simulate-error`, `/metrics`) et tests |
| `Dockerfile`, `Dockerfile.naif` | Image multi-stage non-root (gunicorn) et version naïve de comparaison |
| `docker-compose.yml` | Dev : `web` + `redis` + `prometheus` + `grafana` |
| `docker-compose.deploy.yml` | Blue/green : `redis`, `nginx`, `app-blue` / `app-green` (profiles) |
| `deploy/` | `deploy.sh` (bascule + smoke test + rollback), `rollback.sh`, config nginx |
| `monitoring/` | Config Prometheus, règles d'alerte, provisioning Grafana + dashboard JSON |
| `.github/` | `ci.yml`, `cd.yml`, action locale `setup-python-deps`, `CODEOWNERS` |
| `.githooks/pre-commit` | Hook anti-secret (`git config core.hooksPath .githooks`) |

## Commandes pour lancer en local

```bash
docker compose up --build -d
docker compose ps
curl localhost:5000/health
curl localhost:5000/visits
curl localhost:5000/metrics
docker compose down -v
```

Interfaces : application http://localhost:5000, Prometheus http://localhost:9090, Grafana http://localhost:3000
(identifiants `admin` / `admin` par défaut, surchargeables via `.env`, voir `.env.example`).

## Tests et lint en local

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
docker compose up -d redis
pytest -v --cov=app
flake8 . --max-line-length=100 --exclude=.venv && yamllint .
```

## Images : mesure avant / après

```bash
docker build -f Dockerfile.naif -t tp-devops-web:naif .
docker build -t tp-devops-web:multistage .
docker images tp-devops-web
```

| Image | Taille mesurée |
|---|---|
| naïve (`python:3.12`, root) | 423MB |
| multi-stage (`python:3.12-slim`, non-root) | 52.3MB |

Vérifier l'utilisateur : `docker run --rm --entrypoint whoami tp-devops-web:multistage` doit afficher `app`.

## Pipeline

**CI** (`ci.yml`, sur pull request et push `main`) : `lint` (flake8, yamllint, shellcheck, promtool, compose config),
`test` (matrice Python 3.11 / 3.12, service Redis réel, rapports JUnit + couverture HTML en artefacts même en cas d'échec),
`build` (télécharge les artefacts, build de l'image, vérifie qu'elle ne tourne pas en root), `ci-ok` (job final requis).
Le cache pip (`actions/cache`, clé basée sur `hashFiles('requirements*.txt')`) est dans l'action locale.

Preuve du cache pip (2e run : `Cache restored from key`) :
<img width="1909" height="510" alt="Cache pip restauré au second run" src="https://github.com/user-attachments/assets/575f557b-4e5e-4043-adf7-8b01367053bf" />

**CD** (`cd.yml`, après une CI verte sur `main`, ou `workflow_dispatch` avec `environment: production`) :
`build-and-push` publie sur GHCR (tags `latest`, SHA court, semver), puis `deploy` (runner self-hosted,
`environment: production`) exécute `deploy/deploy.sh`, vérifie `/health` par `curl` (3 tentatives) et lance
`deploy/rollback.sh` si cette vérification échoue.



## Déploiement blue/green

`deploy.sh <sha>` lit la couleur active (état dans `~/.tp-devops/state`), démarre la couleur inactive avec l'image
`<sha court>`, exécute un smoke test dans le conteneur (`/health` = 200, `deploy_color` et `git_sha` conformes),
réécrit la config nginx puis fait `nginx -s reload`, contrôle à travers nginx, et seulement alors arrête l'ancienne couleur.
Au moindre échec, nginx et la couleur active restent inchangés.

Test local sans registry :

```bash
SHA=$(git rev-parse HEAD)
docker build --build-arg GIT_SHA="$SHA" -t tp-devops-web:"${SHA:0:7}" .
SKIP_PULL=1 bash deploy/deploy.sh "$SHA"       # 1er déploiement : blue
curl localhost:8080/status                      # deploy_color=blue, git_sha=<sha>
# 2e déploiement (autre commit) : bascule vers green
# Échec volontaire : docker compose -f docker-compose.deploy.yml stop redis, puis relancer deploy.sh
```

Rollback manuel : `git revert <commit>` puis push (repart dans le pipeline). En urgence : `bash deploy/rollback.sh`.

## Observabilité

- Métriques : `http_requests_total{method,endpoint,code}`, `http_request_duration_seconds` (histogramme par route),
  `app_build_info{version,sha}`. `/metrics` n'est pas compté.
- Dashboard Grafana « TP DevOps - Vue d'ensemble » (provisionné) : débit par endpoint, taux d'erreur 5xx, latence p95, version déployée.
- Alertes (`monitoring/alert.rules.yml`) : `HighErrorRate` (5xx > 5 %, `for: 30s`) et `HighLatencyP95` (p95 > 500 ms, `for: 2m`).
  Pour déclencher la première : `while true; do curl -s localhost:5000/simulate-error >/dev/null; curl -s localhost:5000/health >/dev/null; done`
  puis suivre http://localhost:9090/alerts (inactive, pending, firing).

## Prérequis GitHub

Workflow permissions « Read and write », protection de `main` avec check `ci-ok`, runner self-hosted (Docker installé),
`CODEOWNERS` par @maXONYAR.
