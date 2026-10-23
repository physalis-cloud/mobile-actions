#!/usr/bin/env bash
# Localise le projet Xcode, puis pose la version servie par Physalis.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$GITHUB_ACTION_PATH/../lib/common.sh"

dir=$(abs_path "$IN_PROJECT_DIR")
[ -d "$dir" ] || die "project-dir introuvable : $IN_PROJECT_DIR"

# Workspace (CocoaPods / SPM) OU projet seul. Le .xcodeproj est requis meme
# avec un workspace : update_code_signing_settings ecrit dans le projet.
workspace=$(find "$dir" -maxdepth 1 -name '*.xcworkspace' | head -n 1)
project=$(find "$dir" -maxdepth 1 -name '*.xcodeproj' | head -n 1)
[ -n "$project" ] || die "Aucun .xcodeproj dans $IN_PROJECT_DIR — requis pour inscrire la signature manuelle"
{
  echo "IOS_XCODEPROJ=$project"
  if [ -n "$workspace" ]; then
    echo "IOS_WORKSPACE=$workspace"
  else
    echo "IOS_PROJECT=$project"
  fi
} >> "$GITHUB_ENV"
echo "Workspace : ${workspace:-(aucun)} · Projet : $project"

case "$IN_VERSION" in
  info-plist)
    # Capacitor genere un Info.plist a valeurs LITTERALES, qu'agvtool ne sait
    # pas lire : on ecrit directement les valeurs. plutil et non PlistBuddy :
    # la valeur passe en ARGUMENT, aucune apostrophe ne peut casser le parsing.
    plist=$(abs_path "${IN_INFO_PLIST:-$IN_PROJECT_DIR/App/Info.plist}")
    [ -f "$plist" ] || die "Info.plist introuvable : $plist (input info-plist)"
    # Un CFBundleVersion en $(CURRENT_PROJECT_VERSION) signe un projet natif :
    # l'ecraser par un litteral deconnecterait le plist des build settings.
    current=$(plutil -extract CFBundleVersion raw -o - "$plist" 2>/dev/null || true)
    # shellcheck disable=SC2016 # motif litteral « $( »
    case "$current" in
      *'$('*) die "CFBundleVersion vaut « $current » : la valeur vit dans les build settings, utilisez version: pbxproj (ou agvtool)" ;;
    esac
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$plist"
    if [ -n "${VERSION_NAME:-}" ]; then
      plutil -replace CFBundleShortVersionString -string "$VERSION_NAME" "$plist"
    fi
    echo "CFBundleVersion            = $(plutil -extract CFBundleVersion raw -o - "$plist")"
    echo "CFBundleShortVersionString = $(plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || echo '?')"
    ;;
  pbxproj)
    # Info.plist en $(CURRENT_PROJECT_VERSION) / $(MARKETING_VERSION) — cas
    # d'un ios/ Capacitor versionne — sans versioning Apple Generic, qu'agvtool
    # exigerait. On ecrit les deux build settings dans toutes les
    # configurations du .xcodeproj, puis on RELIT : un sed sans effet ne dit
    # rien.
    pbx="$project/project.pbxproj"
    sed -i.bak -E "s/(CURRENT_PROJECT_VERSION = )[^;]*;/\1$BUILD_NUMBER;/" "$pbx"
    if [ -n "${VERSION_NAME:-}" ]; then
      sed -i.bak -E "s/(MARKETING_VERSION = )[^;]*;/\1$VERSION_NAME;/" "$pbx"
    fi
    rm -f "$pbx.bak"
    grep -qE "CURRENT_PROJECT_VERSION = $BUILD_NUMBER;" "$pbx" \
      || die "Aucun CURRENT_PROJECT_VERSION dans $pbx : le projet ne versionne pas par build settings (essayez version: info-plist)"
    grep -E "(CURRENT_PROJECT_VERSION|MARKETING_VERSION) = " "$pbx" | sort | uniq -c
    ;;
  agvtool)
    # Projet natif : la valeur vit dans les build settings
    # (CFBundleVersion = $(CURRENT_PROJECT_VERSION)). Un literal pose au plutil
    # deconnecterait le plist des reglages. `-all` couvre app ET extensions.
    cd "$(dirname "$project")"
    xcrun agvtool what-version -terse >/dev/null 2>&1 \
      || die "agvtool ne sait pas lire ce projet : activez le versioning « Apple Generic » (VERSIONING_SYSTEM = apple-generic), ou passez version: none"
    xcrun agvtool new-version -all "$BUILD_NUMBER"
    if [ -n "${VERSION_NAME:-}" ]; then
      xcrun agvtool new-marketing-version "$VERSION_NAME"
    fi
    got=$(xcrun agvtool what-version -terse)
    echo "CFBundleVersion = $got"
    [ "$got" = "$BUILD_NUMBER" ] \
      || die "agvtool n'a pas pose $BUILD_NUMBER — la configuration de versioning du projet ne suit pas"
    ;;
  none)
    echo "Version laissee au workflow (BUILD_NUMBER=$BUILD_NUMBER)."
    ;;
  *)
    die "version doit valoir info-plist, pbxproj, agvtool ou none, pas « $IN_VERSION »"
    ;;
esac
