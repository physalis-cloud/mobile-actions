#!/usr/bin/env bash
# Signature automatique iOS : importe le certificat de distribution (.p12)
# dans un keychain temporaire, pour que l'export Xcode signe avec LUI plutot
# qu'avec le certificat « Cloud Managed » d'Apple. Entrees : CRED_DIR,
# P12_PASSWORD. Pose PHYSALIS_KEYCHAIN dans $GITHUB_ENV (efface par report).
#
# Pourquoi : l'export « destination: upload » signe, faute de certificat local,
# avec le certificat de distribution gere dans le cloud. Premier run de
# physalis-mobile (2026-11-15) : archive OK, puis App Store Connect rejette
# l'IPA — « Invalid Signature. Code failed to satisfy specified code
# requirement(s) » sur l'executable et chaque framework. Un vrai certificat
# Apple Distribution dans le keychain du runner contourne la signature cloud ;
# Xcode continue de creer lui-meme les profils (un par cible).
#
# `security` direct et non fastlane : en mode automatique, rien d'autre de
# fastlane n'est utilise.
set -euo pipefail
umask 077
# shellcheck source=../lib/common.sh
. "$GITHUB_ACTION_PATH/../lib/common.sh"

command -v security >/dev/null 2>&1 \
  || die "signing: automatic avec un .p12 exige un runner macOS (commande security absente)"

KC="$CRED_DIR/physalis-ci.keychain-db"
KC_PASSWORD=$(openssl rand -hex 16)
echo "::add-mask::$KC_PASSWORD"

security create-keychain -p "$KC_PASSWORD" "$KC"
# Verrouillage auto apres 6 h seulement : un build long ne doit pas perdre
# l'acces a la cle en cours de route.
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KC_PASSWORD" "$KC"
# Declare AVANT ce qui peut echouer : report le supprime quoi qu'il arrive.
echo "PHYSALIS_KEYCHAIN=$KC" >> "$GITHUB_ENV"

security import "$CRED_DIR/dist.p12" -k "$KC" -P "${P12_PASSWORD:-}" -f pkcs12 \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild >/dev/null \
  || die "security import a refuse le .p12 (mot de passe ios_p12_password errone ?)"
# Sans cette ACL, codesign reclame un mot de passe interactif et le build pend.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASSWORD" "$KC" >/dev/null

# Le keychain doit etre dans la search list pour qu'Xcode le voie ; on garde
# les keychains existants (login, systeme) derriere lui.
existing=()
while IFS= read -r k; do
  k="${k//\"/}"
  k="${k#"${k%%[![:space:]]*}"}"
  [ -n "$k" ] && existing+=("$k")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KC" "${existing[@]}"

identities=$(security find-identity -v -p codesigning "$KC")
echo "$identities"
echo "$identities" | grep -q "Apple Distribution" \
  || die "Le .p12 ne contient pas d'identite « Apple Distribution » valide (certificat de developpement, expire, ou cle privee absente)"
