#!/usr/bin/env bash
# Alias du keystore, version servie par Physalis, fastlane present.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$GITHUB_ACTION_PATH/../lib/common.sh"

if [ -z "${PHYSALIS_CRED_DIR:-}" ] || [ -z "${KEYSTORE_PATH:-}" ]; then
  die "Materiel Android absent : appelez physalis-cloud/mobile-actions/credentials (platform: android) avant android-release"
fi

# Refait ici au cas ou credentials n'avait pas de keytool sous la main ; sans
# cout si c'etait deja fait (une seconde).
command -v keytool >/dev/null 2>&1 \
  || die "keytool introuvable : installez un JDK (actions/setup-java) avant android-release"
bash "$GITHUB_ACTION_PATH/../lib/verify-alias.sh"

dir=$(abs_path "$IN_PROJECT_DIR")
[ -d "$dir" ] || die "project-dir introuvable : $IN_PROJECT_DIR"

case "$IN_VERSION" in
  gradle)
    # `android.injected.version.*` est IGNORE par l'AGP de Capacitor : l'AAB
    # partait avec le versionCode 1 du build.gradle, rejete par Google apres un
    # build complet et un upload. On patche donc le fichier, et on RELIT : une
    # substitution sed qui ne matche rien ne dit rien.
    if [ -n "$IN_GRADLE_FILE" ]; then
      gradle_file=$(abs_path "$IN_GRADLE_FILE")
    elif [ -f "$dir/app/build.gradle" ]; then
      gradle_file="$dir/app/build.gradle"
    else
      gradle_file="$dir/app/build.gradle.kts"
    fi
    [ -f "$gradle_file" ] || die "build.gradle introuvable : $gradle_file (input gradle-file)"

    # Groovy (`versionCode 1`) et Kotlin DSL (`versionCode = 1`).
    # `sed -i.bak` : portable GNU / BSD.
    sed -i.bak -E "s/(versionCode[[:space:]]*=?[[:space:]]*)[0-9]+/\1$BUILD_NUMBER/" "$gradle_file"
    if [ -n "${VERSION_NAME:-}" ]; then
      sed -i.bak -E "s/(versionName[[:space:]]*=?[[:space:]]*)\"[^\"]*\"/\1\"$VERSION_NAME\"/" "$gradle_file"
    fi
    rm -f "$gradle_file.bak"

    grep -E 'versionCode|versionName' "$gradle_file" || true
    grep -qE "versionCode[[:space:]]*=?[[:space:]]*$BUILD_NUMBER\b" "$gradle_file" \
      || die "versionCode $BUILD_NUMBER absent de $gradle_file apres substitution — la forme du fichier a change (ou le versionCode est calcule : passez version: none)"
    ;;
  none)
    echo "Version laissee au workflow (BUILD_NUMBER=$BUILD_NUMBER)."
    ;;
  *)
    die "version doit valoir gradle ou none, pas « $IN_VERSION »"
    ;;
esac

command -v fastlane >/dev/null 2>&1 || gem install fastlane --no-document
fastlane --version | tail -1
