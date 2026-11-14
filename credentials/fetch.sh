#!/usr/bin/env bash
# POST /api/deploy/mobile { app } -> { app, buildNumber, versionName,
#   credentials: [ {kind, value, sha256, ...} ] }
#
# Chaque credential « fichier » arrive en base64, chaque « texte » en clair.
# Toutes les valeurs sont masquees avant le moindre traitement.
#
# Repris des gabarits Physalis qui ont publie pour de vrai (Google Play et
# TestFlight) : chaque controle ci-dessous a ete ajoute apres un run qui
# echouait plus loin, sur un message qui ne designait pas la cause.
set -euo pipefail
umask 077
# shellcheck source=../lib/common.sh
. "$GITHUB_ACTION_PATH/../lib/common.sh"

case "$IN_PLATFORM" in
  ios|android) ;;
  *) die "platform doit valoir ios ou android, pas « $IN_PLATFORM »" ;;
esac
IN_SIGNING="${IN_SIGNING:-manual}"
case "$IN_SIGNING" in
  manual) ;;
  automatic)
    [ "$IN_PLATFORM" = "ios" ] \
      || die "signing: automatic n'existe que pour iOS (Android signe toujours avec le keystore)"
    ;;
  *) die "signing doit valoir manual ou automatic, pas « $IN_SIGNING »" ;;
esac

PHYSALIS_AUDIENCE="${PHYSALIS_AUDIENCE_IN:-$(default_audience "$PHYSALIS_URL")}"
export PHYSALIS_AUDIENCE

CRED_DIR="$RUNNER_TEMP/physalis-signing"
mkdir -p "$CRED_DIR"
BUNDLE="$CRED_DIR/bundle.json"
# Declare AVANT tout ce qui peut echouer : l'action report efface ce dossier
# quoi qu'il arrive, a condition de le connaitre.
echo "PHYSALIS_CRED_DIR=$CRED_DIR" >> "$GITHUB_ENV"

body=$(jq -nc --arg a "$IN_APP" '{app: $a}')
vault_post /api/deploy/mobile "$body" "$BUNDLE"
if [ "$VAULT_HTTP_CODE" != "200" ]; then
  cat "$BUNDLE" 2>/dev/null || true
  rm -rf "$CRED_DIR"
  die "HTTP $VAULT_HTTP_CODE depuis /api/deploy/mobile (app $IN_APP) — policy mobile manquante, publications en pause, ou app inconnue ?"
fi

while IFS= read -r v; do
  [ -n "$v" ] && echo "::add-mask::$v"
done < <(jq -r '.credentials[].value' "$BUNDLE")

{
  echo "PHYSALIS_URL=$PHYSALIS_URL"
  echo "PHYSALIS_AUDIENCE=$PHYSALIS_AUDIENCE"
  echo "PHYSALIS_APP=$IN_APP"
} >> "$GITHUB_ENV"

# La policy ASSIGNE l'app : creee sur la mauvaise, elle servirait un keystore
# Android a un build iOS. Autant le dire ici qu'au fond de xcodebuild.
platform=$(jq -r '.app.platform // empty' "$BUNDLE")
[ "$platform" = "$IN_PLATFORM" ] \
  || die "La policy mobile de ce workflow pointe une app « $platform », attendu « $IN_PLATFORM »"

get_file() { # $1 = kind, $2 = chemin de sortie ; decode le base64
  # `openssl base64 -d -A` et NON `base64 --decode` : option longue GNU que le
  # base64 BSD de macOS ne traite pas de la meme facon. Un decodage
  # silencieusement faux produit un fichier que `security import` avale sans
  # rien ajouter au keychain.
  jq -r --arg k "$1" '.credentials[] | select(.kind==$k) | .value' "$BUNDLE" \
    | openssl base64 -d -A > "$2"

  # Physalis calcule le sha256 sur les octets DECODES : l'empreinte verifie le
  # materiel de bout en bout, du coffre jusqu'au disque du runner.
  local expected actual
  expected=$(jq -r --arg k "$1" '.credentials[] | select(.kind==$k) | .sha256 // empty' "$BUNDLE")
  if [ -n "$expected" ]; then
    actual=$(sha_of "$2")
    [ "$expected" = "$actual" ] \
      || die "$1 corrompu au transport : sha256 attendu $expected, obtenu $actual ($(wc -c < "$2") octets ecrits)"
  fi
}
get_text() { # $1 = kind ; valeur deja en clair
  jq -r --arg k "$1" '.credentials[] | select(.kind==$k) | .value // empty' "$BUNDLE"
}
require() { # kinds dont la valeur vide ne casserait que bien plus loin
  local missing="" k
  for k in "$@"; do
    [ -n "$(get_text "$k")" ] || missing="$missing $k"
  done
  [ -z "$missing" ] \
    || die "Credentials absents ou vides cote Physalis :$missing — a completer dans l'onglet Mobile de l'application"
}

# Diagnostic : quels kinds ont ete servis. Aucune valeur.
echo "Credentials servis : $(jq -r '[.credentials[].kind] | join(", ")' "$BUNDLE")"

BUILD_NUMBER=$(jq -r '.buildNumber // empty' "$BUNDLE")
[ -n "$BUILD_NUMBER" ] || die "Physalis n'a pas servi de buildNumber"
VERSION_NAME=$(jq -r '.versionName // empty' "$BUNDLE")

if [ "$IN_PLATFORM" = "ios" ] && [ "$IN_SIGNING" = "automatic" ]; then
  # Signature automatique : Xcode cree certificat et profils (un par cible, app
  # ET extensions) a partir de la cle d'API — role Admin requis cote App Store
  # Connect. Ni .p12 ni profil : s'ils existent dans Physalis, ils sont ignores.
  require asc_api_key asc_key_id asc_issuer_id
  VENDOR_TEAM_ID=$(jq -r '.app.vendorTeamId // empty' "$BUNDLE")
  [ -n "$VENDOR_TEAM_ID" ] \
    || die "signing: automatic exige le Team ID de l'app (champ « Team ID / éditeur » de l'application, onglet Mobile de Physalis)"
  get_file asc_api_key "$CRED_DIR/AuthKey.p8"
  {
    echo "ASC_KEY_PATH=$CRED_DIR/AuthKey.p8"
    echo "ASC_KEY_ID=$(get_text asc_key_id)"
    echo "ASC_ISSUER_ID=$(get_text asc_issuer_id)"
    echo "VENDOR_TEAM_ID=$VENDOR_TEAM_ID"
    echo "TEAM_ID=$VENDOR_TEAM_ID"
    echo "PHYSALIS_SIGNING=automatic"
  } >> "$GITHUB_ENV"
elif [ "$IN_PLATFORM" = "ios" ]; then
  # `ios_p12_password` n'est PAS exige : un .p12 sans mot de passe est legitime.
  require ios_p12 ios_profile asc_api_key asc_key_id asc_issuer_id
  get_file ios_p12     "$CRED_DIR/dist.p12"
  get_file ios_profile "$CRED_DIR/profile.mobileprovision"
  get_file asc_api_key "$CRED_DIR/AuthKey.p8"
  P12_PASSWORD=$(get_text ios_p12_password)
  # Transite par $GITHUB_ENV : masque une seconde fois.
  [ -n "$P12_PASSWORD" ] && echo "::add-mask::$P12_PASSWORD"
  {
    echo "P12_PATH=$CRED_DIR/dist.p12"
    echo "P12_PASSWORD=$P12_PASSWORD"
    echo "PROFILE_PATH=$CRED_DIR/profile.mobileprovision"
    echo "ASC_KEY_PATH=$CRED_DIR/AuthKey.p8"
    echo "ASC_KEY_ID=$(get_text asc_key_id)"
    echo "ASC_ISSUER_ID=$(get_text asc_issuer_id)"
    echo "VENDOR_TEAM_ID=$(jq -r '.app.vendorTeamId // empty' "$BUNDLE")"
  } >> "$GITHUB_ENV"
  VENDOR_TEAM_ID=$(jq -r '.app.vendorTeamId // empty' "$BUNDLE") \
    P12_PASSWORD="$P12_PASSWORD" CRED_DIR="$CRED_DIR" MOBILE_APP="$IN_APP" \
    bash "$GITHUB_ACTION_PATH/verify-ios.sh"
else
  require android_keystore android_keystore_password android_key_alias \
          android_key_password play_service_account
  get_file android_keystore     "$CRED_DIR/release.keystore"
  get_file play_service_account "$CRED_DIR/play-service-account.json"
  KEYSTORE_PASSWORD=$(get_text android_keystore_password)
  KEY_PASSWORD=$(get_text android_key_password)
  KEY_ALIAS=$(get_text android_key_alias)
  # Transitent par $GITHUB_ENV et par la ligne de commande gradle.
  echo "::add-mask::$KEYSTORE_PASSWORD"
  echo "::add-mask::$KEY_PASSWORD"
  {
    echo "KEYSTORE_PATH=$CRED_DIR/release.keystore"
    echo "KEYSTORE_PASSWORD=$KEYSTORE_PASSWORD"
    echo "KEY_ALIAS=$KEY_ALIAS"
    echo "KEY_PASSWORD=$KEY_PASSWORD"
    echo "PLAY_JSON_PATH=$CRED_DIR/play-service-account.json"
  } >> "$GITHUB_ENV"

  # gradle ne verifie l'alias qu'a `signReleaseBundle`, sa toute derniere
  # tache : ~4 min de build avant de se manifester. keytool tranche en une
  # seconde. Les images ubuntu de GitHub embarquent un JDK ; sinon,
  # android-release refera le controle apres setup-java.
  if command -v keytool >/dev/null 2>&1; then
    KEYSTORE_PATH="$CRED_DIR/release.keystore" KEYSTORE_PASSWORD="$KEYSTORE_PASSWORD" \
      KEY_ALIAS="$KEY_ALIAS" bash "$GITHUB_ACTION_PATH/../lib/verify-alias.sh"
  else
    echo "keytool absent : controle de l'alias reporte a android-release."
  fi
fi

{
  echo "BUILD_NUMBER=$BUILD_NUMBER"
  echo "VERSION_NAME=$VERSION_NAME"
} >> "$GITHUB_ENV"
{
  echo "build-number=$BUILD_NUMBER"
  echo "version-name=$VERSION_NAME"
} >> "$GITHUB_OUTPUT"

echo "Build ${VERSION_NAME:-(version du projet)} ($BUILD_NUMBER)"
