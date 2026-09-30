#!/usr/bin/env bash
# Déploiement blue/green : démarre la couleur inactive, la valide (health + smoke test couleur/SHA),
# bascule nginx, puis arrête l'ancienne couleur. En cas d'échec, la couleur active ne change JAMAIS.
#
# Usage     : deploy/deploy.sh <git_sha_complet>
# Variables : IMAGE_NAME (défaut tp-devops-web), DEPLOY_HOME (défaut ~/.tp-devops),
#             SKIP_PULL=1 (image locale), SMOKE_RETRIES (défaut 10), SMOKE_DELAY (défaut 3)
set -euo pipefail

cd "$(dirname "$0")/.."

SHA="${1:?usage: deploy/deploy.sh <git_sha_complet>}"
TAG="${SHA:0:7}"
export IMAGE_NAME="${IMAGE_NAME:-tp-devops-web}"
DEPLOY_HOME="${DEPLOY_HOME:-$HOME/.tp-devops}"
STATE_DIR="$DEPLOY_HOME/state"
export NGINX_ACTIVE_DIR="$DEPLOY_HOME/nginx-active"
SMOKE_RETRIES="${SMOKE_RETRIES:-10}"
SMOKE_DELAY="${SMOKE_DELAY:-3}"

# L'état vit hors du dépôt : actions/checkout nettoie l'espace de travail à chaque run
mkdir -p "$STATE_DIR" "$NGINX_ACTIVE_DIR"

log() { echo "[deploy] $*"; }

# Les deux profils sont activés, mais on cible toujours des services nommés explicitement
compose() { docker compose -f docker-compose.deploy.yml --profile blue --profile green "$@"; }

write_upstream() {
  # shellcheck disable=SC2016
  printf 'set $active_upstream http://app-%s:5000;\n' "$1" > "$NGINX_ACTIVE_DIR/upstream.conf.tmp"
  mv "$NGINX_ACTIVE_DIR/upstream.conf.tmp" "$NGINX_ACTIVE_DIR/upstream.conf"
}

reload_nginx() {
  compose exec -T nginx nginx -t >/dev/null 2>&1 && compose exec -T nginx nginx -s reload >/dev/null 2>&1
}

retry() {
  local attempts=$1 delay=$2 i
  shift 2
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then return 0; fi
    log "tentative $i/$attempts échouée"
    sleep "$delay"
  done
  return 1
}

# Exécuté DANS le conteneur (python présent, pas de curl) : santé + couleur + SHA attendus
smoke_test_app() {
  compose exec -T "app-$1" python - "$1" "$SHA" <<'PY'
import json
import sys
import urllib.request

color, sha = sys.argv[1], sys.argv[2]
base = "http://127.0.0.1:5000"
health = urllib.request.urlopen(base + "/health", timeout=3)
status = json.load(urllib.request.urlopen(base + "/status", timeout=3))
if health.status != 200:
    sys.exit("health KO")
if status.get("deploy_color") != color:
    sys.exit("couleur inattendue : %s" % status.get("deploy_color"))
if status.get("git_sha") != sha:
    sys.exit("SHA inattendu : %s (attendu %s)" % (status.get("git_sha"), sha))
PY
}

# Vérifie, à travers nginx, que le trafic arrive bien sur la nouvelle couleur / le bon SHA
verify_via_nginx() {
  local body
  body="$(compose exec -T nginx wget -qO- http://127.0.0.1/status)" || return 1
  echo "$body" | grep -Eq "\"deploy_color\"[[:space:]]*:[[:space:]]*\"${TARGET}\"" &&
    echo "$body" | grep -Eq "\"git_sha\"[[:space:]]*:[[:space:]]*\"${SHA}\""
}

rollback() {
  log "ÉCHEC : rollback, la couleur active reste '$ACTIVE'"
  if [ "$ACTIVE" != none ]; then
    write_upstream "$ACTIVE"
    reload_nginx || true
  fi
  compose stop "app-$TARGET" >/dev/null 2>&1 || true
  compose rm -f "app-$TARGET" >/dev/null 2>&1 || true
  if [ "$ACTIVE" != none ]; then
    # Re-pull du SHA précédent puis remise en route de l'ancienne couleur si besoin
    if [ "${SKIP_PULL:-0}" != 1 ]; then compose pull "app-$ACTIVE" || true; fi
    compose up -d --no-deps "app-$ACTIVE" || true
  fi
}

die() {
  log "ERREUR : $*"
  rollback
  exit 1
}

ACTIVE="$(cat "$STATE_DIR/active_color" 2>/dev/null || echo none)"
ACTIVE_SHA="$(cat "$STATE_DIR/active_sha" 2>/dev/null || echo none)"
if [ ! -f "$NGINX_ACTIVE_DIR/upstream.conf" ]; then write_upstream blue; fi

if [ "$ACTIVE" = blue ]; then TARGET=green; else TARGET=blue; fi

OLD_TAG=unused
if [ "$ACTIVE_SHA" != none ]; then OLD_TAG="${ACTIVE_SHA:0:7}"; fi
if [ "$TARGET" = blue ]; then
  export BLUE_TAG="$TAG" GREEN_TAG="$OLD_TAG"
else
  export GREEN_TAG="$TAG" BLUE_TAG="$OLD_TAG"
fi

log "active : $ACTIVE ($ACTIVE_SHA) -> cible : $TARGET ($SHA)"

# Premier déploiement seulement : infra (redis + nginx). Ensuite on la suppose en place,
# sinon un Redis arrêté serait redémarré en douce et masquerait la panne.
if [ "$ACTIVE" = none ]; then
  compose up -d redis nginx || die "impossible de démarrer redis/nginx"
fi

if [ "${SKIP_PULL:-0}" != 1 ]; then
  compose pull "app-$TARGET" || die "pull de l'image $IMAGE_NAME:$TAG impossible"
fi
compose up -d --no-deps --force-recreate "app-$TARGET" || die "démarrage de app-$TARGET impossible"

log "smoke test de app-$TARGET (santé, couleur, SHA)"
retry "$SMOKE_RETRIES" "$SMOKE_DELAY" smoke_test_app "$TARGET" || die "smoke test en échec"

log "bascule du trafic vers $TARGET"
write_upstream "$TARGET"
reload_nginx || die "reload nginx impossible"
retry 3 2 verify_via_nginx || die "nginx ne sert pas la bonne version après bascule"

if [ "$ACTIVE_SHA" != none ]; then echo "$ACTIVE_SHA" > "$STATE_DIR/previous_sha"; fi
echo "$TARGET" > "$STATE_DIR/active_color"
echo "$SHA" > "$STATE_DIR/active_sha"

if [ "$ACTIVE" != none ]; then
  log "arrêt de l'ancienne couleur $ACTIVE"
  compose stop "app-$ACTIVE" >/dev/null 2>&1 || log "avertissement : arrêt de app-$ACTIVE impossible"
  compose rm -f "app-$ACTIVE" >/dev/null 2>&1 || true
fi

log "OK : $TARGET actif ($SHA)"
