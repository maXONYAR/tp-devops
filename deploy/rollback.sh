#!/usr/bin/env bash
# Rollback d'urgence : redéploie (re-pull) le SHA précédent via le même chemin que deploy.sh.
# Le rollback "propre" reste un git revert qui repart dans la CI (voir README).
set -euo pipefail
DEPLOY_HOME="${DEPLOY_HOME:-$HOME/.tp-devops}"
PREVIOUS="$(cat "$DEPLOY_HOME/state/previous_sha" 2>/dev/null || true)"
if [ -z "$PREVIOUS" ]; then
  echo "[rollback] aucun SHA précédent enregistré" >&2
  exit 1
fi
echo "[rollback] retour au SHA $PREVIOUS"
exec bash "$(dirname "$0")/deploy.sh" "$PREVIOUS"
