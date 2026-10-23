#!/usr/bin/env bash
# Lance la lane embarquee depuis le dossier de l'action (chemins absolus).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$GITHUB_ACTION_PATH/../lib/common.sh"

case "$IN_TRACK" in
  internal|alpha|beta|production) ;;
  *) die "track doit valoir internal, alpha, beta ou production, pas « $IN_TRACK »" ;;
esac

export ANDROID_PROJECT_DIR
ANDROID_PROJECT_DIR=$(abs_path "$IN_PROJECT_DIR")
export MOBILE_APP="$PHYSALIS_APP"
export PLAY_TRACK="$IN_TRACK"
if [ "$IN_FIRST_RELEASE" = "true" ]; then export PLAY_FIRST_RELEASE=true; else export PLAY_FIRST_RELEASE=false; fi

# Piste posee AVANT la lane (un echec se rapporte sur sa piste), statut APRES.
echo "PHYSALIS_RELEASE_TRACK=$IN_TRACK" >> "$GITHUB_ENV"

cd "$GITHUB_ACTION_PATH"
fastlane android release

aab=$(find "$ANDROID_PROJECT_DIR" -path '*/outputs/bundle/release/*.aab' | head -n 1)
echo "aab-path=$aab" >> "$GITHUB_OUTPUT"
echo "PHYSALIS_RELEASE_STATUS=uploaded" >> "$GITHUB_ENV"
