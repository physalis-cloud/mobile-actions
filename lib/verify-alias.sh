#!/usr/bin/env bash
# L'alias declare existe-t-il dans le keystore ? Entrees : KEYSTORE_PATH,
# KEYSTORE_PASSWORD, KEY_ALIAS.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if keytool -list -keystore "$KEYSTORE_PATH" -storepass "$KEYSTORE_PASSWORD" \
     -alias "$KEY_ALIAS" >/dev/null 2>&1; then
  echo "Alias present dans le keystore."
  exit 0
fi

# On ne LISTE pas les alias reels (ils sont masques comme credentials) : leur
# nombre suffit a distinguer « keystore vide » de « alias mal orthographie ».
count=$(keytool -list -keystore "$KEYSTORE_PATH" -storepass "$KEYSTORE_PASSWORD" 2>/dev/null \
          | grep -c "PrivateKeyEntry" || true)
die "android_key_alias ne correspond a aucune entree du keystore, qui contient $count cle(s) privee(s). Listez les alias reels en local : keytool -list -keystore release-keystore.jks"
