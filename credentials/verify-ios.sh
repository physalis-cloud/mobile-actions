#!/usr/bin/env bash
# Controles iOS immediats, avant toute installation d'outillage. Entrees :
# CRED_DIR, P12_PASSWORD, MOBILE_APP, VENDOR_TEAM_ID. Pose PROFILE_NAME et
# TEAM_ID dans $GITHUB_ENV (signature manuelle de la lane).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$GITHUB_ACTION_PATH/../lib/common.sh"

command -v security >/dev/null 2>&1 \
  || die "Runner sans outils Apple (security) : le build iOS exige un runner macOS"

# ── Profil de provisioning ─────────────────────────────────────────────────
# Le .mobileprovision est un conteneur CMS signe : on en tire le nom du profil
# et le Team ID, exiges par la signature manuelle. Rien n'est code en dur —
# changer de profil cote Physalis suffit.
PLIST="$CRED_DIR/profile.plist"
security cms -D -i "$CRED_DIR/profile.mobileprovision" > "$PLIST"

PROFILE_NAME=$(/usr/libexec/PlistBuddy -c "Print :Name" "$PLIST")
TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$PLIST")
APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "$PLIST")
EXPIRES=$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" "$PLIST")
APS=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:aps-environment" "$PLIST" 2>/dev/null || true)

echo "Profil    : $PROFILE_NAME"
echo "Team      : $TEAM_ID"
echo "App ID    : $APP_ID"
echo "Expire le : $EXPIRES"
echo "Push      : ${APS:-(non autorise par le profil)}"

[ "$APP_ID" = "$TEAM_ID.$MOBILE_APP" ] \
  || die "Le profil couvre $APP_ID, attendu $TEAM_ID.$MOBILE_APP"

# Le profil reste la source de verite — c'est lui qui signe — mais un ecart
# avec le Team ID de la fiche Physalis signale une fiche mal renseignee.
if [ -n "${VENDOR_TEAM_ID:-}" ] && [ "$VENDOR_TEAM_ID" != "$TEAM_ID" ]; then
  echo "::warning::vendorTeamId Physalis ($VENDOR_TEAM_ID) != Team du profil ($TEAM_ID)"
fi

{
  echo "PROFILE_NAME=$PROFILE_NAME"
  echo "TEAM_ID=$TEAM_ID"
} >> "$GITHUB_ENV"

# ── Certificat .p12 ────────────────────────────────────────────────────────
# xcodebuild ne dit pas « mauvais mot de passe » ni « pas de cle privee » : il
# dit, 30 s apres le debut de l'archive, "No signing certificate with a private
# key was found" — le meme message pour trois causes. openssl tranche ici.
#
# ⚠️ Ces sondes ORIENTENT, elles ne tranchent pas : le verdict revient a
# `security import` (lane fastlane). Un .p12 exporte du Trousseau est en
# RC2-40-CBC, qu'OpenSSL 3 refuse sans provider legacy ; LibreSSL
# (/usr/bin/openssl sur macOS) le lit mais ignore `-legacy`. D'ou les
# combinaisons, et un echec de lecture qui n'est qu'un avertissement.

# `security import` ne lit QUE les PKCS12 a MAC SHA-1. Devant un MAC SHA-256 —
# defaut d'OpenSSL 3 — il repond « MAC verification failed (wrong password?) »
# avec un mot de passe parfaitement correct. `-info` imprime le MAC AVANT de
# verifier le mot de passe.
mac_line=$(openssl pkcs12 -in "$CRED_DIR/dist.p12" -info -nokeys -noout \
             -passin "pass:${P12_PASSWORD}" 2>&1 | grep -i "^MAC:" | head -1 || true)
echo "Algorithme du MAC : ${mac_line:-inconnu}"
if printf '%s' "$mac_line" | grep -qi "sha256"; then
  die "Ce .p12 a un MAC SHA-256, que security import de macOS refuse. Regenerez-le : openssl pkcs12 -export -legacy -macalg sha1 -inkey ios_distribution.key -in distribution.pem -out ios_distribution_macos.p12 — puis reimportez-le dans Physalis"
fi

# On collecte la SORTIE, pas seulement le code de retour : « MAC verify error »
# et « unsupported algorithm » sont deux verdicts opposes.
probe_out=""
p12_probe() { # $1 = -nokeys (certificats) | -nocerts (cle privee)
  local ossl legacy out
  probe_out=""
  for ossl in /usr/bin/openssl openssl; do
    command -v "$ossl" >/dev/null 2>&1 || continue
    for legacy in "" "-legacy"; do
      # shellcheck disable=SC2086 # $legacy vide doit disparaitre
      out=$("$ossl" pkcs12 $legacy -in "$CRED_DIR/dist.p12" "$1" -noout \
              -passin "pass:${P12_PASSWORD}" 2>&1) && return 0
      probe_out="$probe_out$out"
    done
  done
  return 1
}

if p12_probe -nokeys; then
  # Physalis ne lit jamais la cle privee : une date d'expiration correcte dans
  # l'interface ne prouve donc PAS sa presence.
  p12_probe -nocerts \
    || die "Le .p12 s'ouvre mais ne contient PAS de cle privee — reexportez-le en selectionnant le certificat ET sa cle"
  echo "Certificat et cle privee lisibles avec le mot de passe fourni."
elif printf '%s' "$probe_out" | grep -qiE "mac verify error|invalid password"; then
  # Verdict FIABLE ici : le sha256 a deja valide les octets, il ne reste que
  # le mot de passe.
  die "ios_p12_password ne dechiffre pas le .p12, pourtant intact (sha256 conforme) : le mot de passe enregistre dans Physalis est faux"
else
  echo "::warning::Aucun openssl n'a su ouvrir ce .p12, sans erreur de mot de passe explicite. Ce n'est PAS un verdict : l'import dans le keychain tranchera."
fi
