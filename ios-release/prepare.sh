#!/usr/bin/env bash
# Toolchain : Xcode recent + SDK verifie, fastlane present.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$GITHUB_ACTION_PATH/../lib/common.sh"

[ -n "${PHYSALIS_CRED_DIR:-}" ] && [ -n "${P12_PATH:-}" ] \
  || die "Materiel iOS absent : appelez physalis-cloud/mobile-actions/credentials (platform: ios) avant ios-release"

# L'image livre plusieurs Xcode et ne selectionne pas forcement le plus recent.
# On VERIFIE ensuite le SDK : sans ce controle, le rejet d'Apple n'arrive qu'a
# la toute fin, apres l'archive et l'upload complet du binaire.
if [ "$IN_SELECT_XCODE" = "true" ]; then
  latest=$(find /Applications -maxdepth 1 -name 'Xcode*.app' | sort -V | tail -1)
  [ -n "$latest" ] || die "Aucun Xcode dans /Applications"
  sudo xcode-select -s "$latest/Contents/Developer"
fi
xcodebuild -version

sdk_ver=$(xcodebuild -showsdks 2>/dev/null \
  | sed -n 's/.*-sdk iphoneos\([0-9][0-9]*\).*/\1/p' | sort -n | tail -1)
echo "SDK iOS le plus recent : ${sdk_ver:-inconnu}"
if [ "${sdk_ver:-0}" -lt "$IN_MIN_SDK" ]; then
  die "SDK iOS ${sdk_ver:-inconnu} — App Store Connect exige le SDK iOS $IN_MIN_SDK. Verifiez le label runs-on (macos-latest)."
fi

# Preinstalle sur les images macOS GitHub ; installe seulement s'il manque,
# pour ne pas payer 2 min de compilation de gems.
command -v fastlane >/dev/null 2>&1 || gem install fastlane --no-document
fastlane --version | tail -1
