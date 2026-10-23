# shellcheck shell=bash
# Fonctions partagees par les actions. Sourcees, jamais executees.
#
# Une action `uses: physalis-cloud/mobile-actions/<dossier>@ref` recoit le depot
# ENTIER : ce fichier est donc joignable par $GITHUB_ACTION_PATH/../lib.

# Sur stderr : appelee dans un $(...), elle finirait sinon dans la valeur
# capturee, et l'erreur disparaitrait des logs. Le runner interprete les
# commandes ::error:: sur les deux flux.
die() {
  echo "::error::$*" >&2
  exit 1
}

# Jeton OIDC du job, demande DIRECTEMENT au runner plutot que par
# actions/github-script : aucune dependance tierce a epingler, et l'identite
# reste celle du workflow APPELANT — une action composite s'execute dans le job
# qui l'appelle, `job_workflow_ref` designe donc le workflow du client, celui
# que la policy Physalis connait. (Un workflow reutilisable, lui, aurait mis le
# sien a la place : c'est la raison d'etre de ce depot sous forme d'actions.)
#
# $1 = audience. Les deux variables n'existent que si le workflow declare
# `permissions: id-token: write`.
oidc_token() {
  local audience="$1" token
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    die "Pas de jeton OIDC disponible : ajoutez « permissions: id-token: write » au workflow (ou au job)"
  fi
  token=$(curl -sSf -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
            "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience}" | jq -r '.value // empty') \
    || die "Le runner a refuse de delivrer un jeton OIDC"
  [ -n "$token" ] || die "Jeton OIDC vide"
  # Pas de ::add-mask:: ICI : appelee dans $(...), la commande finirait dans la
  # valeur capturee au lieu d'atteindre le runner. L'appelant masque.
  printf '%s' "$token"
}

# POST JSON vers Physalis. $1 = chemin d'API, $2 = corps, $3 = fichier de
# reponse. Pose le code HTTP dans VAULT_HTTP_CODE ; ne fait PAS echouer
# (l'appelant decide). Un jeton neuf par appel : chaque endpoint a sa policy,
# et un jeton frais evite toute question d'expiration ou de rejeu.
#
# Ne s'appelle PAS dans $(...) : le ::add-mask:: doit atteindre le stdout du
# runner, pas une variable.
vault_post() {
  local path="$1" body="$2" out="$3" token
  token=$(oidc_token "$PHYSALIS_AUDIENCE") || exit 1
  echo "::add-mask::$token"
  # shellcheck disable=SC2034 # lu par les scripts qui sourcent ce fichier
  VAULT_HTTP_CODE=$(curl -s -o "$out" -w "%{http_code}" -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${PHYSALIS_URL%/}${path}") || VAULT_HTTP_CODE="000"
}

# Audience par defaut = l'hote de l'URL (convention Physalis).
default_audience() {
  local host="${1#*://}"
  printf '%s' "${host%%/*}"
}

# Chemin absolu d'un chemin donne relatif au depot (ou deja absolu).
abs_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s' "$GITHUB_WORKSPACE/$1" ;;
  esac
}

sha_of() { # sha256sum cote GNU, shasum sur macOS
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
