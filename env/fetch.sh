#!/usr/bin/env bash
# POST /api/deploy { project, environment } -> { secrets: { NOM: valeur } }
#
# Les valeurs vont dans un FICHIER, jamais dans $GITHUB_ENV : elles n'ont pas a
# etre visibles des etapes qui n'en ont pas besoin. Le fichier est efface par
# l'action `report` en fin de run.
set -euo pipefail
umask 077
# shellcheck source=../lib/common.sh
. "$GITHUB_ACTION_PATH/../lib/common.sh"

PHYSALIS_AUDIENCE="${PHYSALIS_AUDIENCE_IN:-$(default_audience "$PHYSALIS_URL")}"
export PHYSALIS_AUDIENCE

resp="$RUNNER_TEMP/physalis-deploy.json"
body=$(jq -nc --arg p "$IN_PROJECT" --arg e "$IN_ENV" '{project: $p, environment: $e}')
vault_post /api/deploy "$body" "$resp"
if [ "$VAULT_HTTP_CODE" != "200" ]; then
  cat "$resp" 2>/dev/null || true
  rm -f "$resp"
  die "HTTP $VAULT_HTTP_CODE depuis /api/deploy (projet $IN_PROJECT, env $IN_ENV) — policy serveur manquante ou ne couvrant pas ce (repo, workflow, branche) ?"
fi

# shellcheck disable=SC2016 # filtre jq, $p est une variable jq
filter='.secrets | to_entries[] | select(.key | startswith($p))'
while IFS= read -r v; do
  [ -n "$v" ] && echo "::add-mask::$v"
done < <(jq -r --arg p "$IN_PREFIX" "$filter | .value" "$resp")

out=$(abs_path "$IN_OUTPUT")
mkdir -p "$(dirname "$out")"
jq -r --arg p "$IN_PREFIX" "$filter | \"\\(.key)=\\(.value)\"" "$resp" > "$out"
rm -f "$resp"

count=$(wc -l < "$out" | tr -d ' ')
echo "Variables ecrites dans $IN_OUTPUT : $count"
echo "count=$count" >> "$GITHUB_OUTPUT"
# Retenu pour le nettoyage de fin de run (action report).
echo "PHYSALIS_CLEANUP_FILES=${PHYSALIS_CLEANUP_FILES:-} $out" >> "$GITHUB_ENV"
