#!/usr/bin/env bash
# Physalis a deja ouvert une ligne « materiel servi » en remettant le bundle :
# cette moitie-la, il la constate. Ce qu'il ne peut PAS savoir, c'est ce que le
# pipeline a fait ensuite — d'ou ce signalement, y compris quand le run a
# echoue apres avoir pris le materiel : c'est precisement ce qu'on veut voir.
#
# Un rapport refuse ne fait PAS echouer le run : le binaire est deja chez
# Google ou Apple, rougir la publication pour de la journalisation serait
# absurde. Le nettoyage, lui, a lieu dans tous les cas.
set -uo pipefail
# shellcheck source=../lib/common.sh
. "$GITHUB_ACTION_PATH/../lib/common.sh"

cleanup() {
  # Keychain de la signature automatique (credentials/import-keychain.sh) :
  # le retirer AVANT d'effacer son dossier, sinon il reste dans la search list.
  if [ -n "${PHYSALIS_KEYCHAIN:-}" ] && command -v security >/dev/null 2>&1; then
    security delete-keychain "$PHYSALIS_KEYCHAIN" 2>/dev/null || true
  fi
  [ -n "${PHYSALIS_CRED_DIR:-}" ] && rm -rf "$PHYSALIS_CRED_DIR"
  # shellcheck disable=SC2086 # liste de chemins separes par des espaces
  [ -n "${PHYSALIS_CLEANUP_FILES:-}" ] && rm -f $PHYSALIS_CLEANUP_FILES
  # Filet si la lane iOS a echoue avant son `ensure`.
  if command -v security >/dev/null 2>&1; then
    security delete-keychain physalis-ci.keychain 2>/dev/null || true
  fi
  echo "Materiel de signature efface du runner."
}
trap cleanup EXIT

if [ -z "${PHYSALIS_APP:-}" ] || [ -z "${BUILD_NUMBER:-}" ]; then
  echo "Aucun bundle n'a ete servi (credentials n'a pas abouti) : rien a rapporter."
  exit 0
fi
if [ "${PHYSALIS_RELEASE_SKIP:-}" = "1" ] && [ -z "$IN_STATUS" ]; then
  echo "destination: none — aucune publication, rien a rapporter."
  exit 0
fi

status="${IN_STATUS:-${PHYSALIS_RELEASE_STATUS:-failed}}"
track="${IN_TRACK:-${PHYSALIS_RELEASE_TRACK:-pending}}"
detail="${IN_DETAIL:-${GITHUB_WORKFLOW} #${GITHUB_RUN_NUMBER}}"

resp="$RUNNER_TEMP/physalis-report.json"
body=$(jq -nc --arg a "$PHYSALIS_APP" --argjson b "$BUILD_NUMBER" \
  --arg t "$track" --arg s "$status" --arg d "$detail" \
  '{app: $a, buildNumber: $b, track: $t, status: $s, detail: $d}')
# Sous-shell : un jeton OIDC refuse fait `die`, ce qui ne doit coûter qu'un
# avertissement ici. Le code HTTP ressort par un fichier.
code_file="$RUNNER_TEMP/physalis-report.code"
( vault_post /api/deploy/mobile/report "$body" "$resp"; echo "$VAULT_HTTP_CODE" > "$code_file" )
VAULT_HTTP_CODE=$(cat "$code_file" 2>/dev/null || echo "000")
rm -f "$code_file"

if [ "$VAULT_HTTP_CODE" = "200" ]; then
  echo "Livraison rapportee : build $BUILD_NUMBER, piste $track, etat $status"
else
  echo "::warning::Rapport de livraison refuse (HTTP $VAULT_HTTP_CODE) — la publication, elle, a suivi son cours"
  cat "$resp" 2>/dev/null || true
fi
rm -f "$resp"
