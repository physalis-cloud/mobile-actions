#!/usr/bin/env bash
# Lance la lane embarquee. fastlane cherche ./fastlane/Fastfile : on l'execute
# depuis le dossier de l'action, tous les chemins passes etant absolus.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$GITHUB_ACTION_PATH/../lib/common.sh"

case "$IN_DESTINATION" in
  testflight|appstore|none) ;;
  *) die "destination doit valoir testflight, appstore ou none, pas « $IN_DESTINATION »" ;;
esac

out_dir="$GITHUB_WORKSPACE/build/ios"
export IOS_SCHEME="$IN_SCHEME"
export IOS_OUTPUT_DIR="$out_dir"
export IOS_DESTINATION="$IN_DESTINATION"
export MOBILE_APP="$PHYSALIS_APP"
if [ "$IN_EXPECT_PUSH" = "true" ]; then export IOS_EXPECT_PUSH=1; else export IOS_EXPECT_PUSH=0; fi

# Lus par l'action report. La piste est posee AVANT la lane (un echec doit
# pouvoir etre rapporte sur sa piste) ; le statut APRES, et seulement en cas de
# succes : son absence vaut « failed ».
if [ "$IN_DESTINATION" = "none" ]; then
  echo "PHYSALIS_RELEASE_SKIP=1" >> "$GITHUB_ENV"
else
  echo "PHYSALIS_RELEASE_TRACK=$IN_DESTINATION" >> "$GITHUB_ENV"
fi

cd "$GITHUB_ACTION_PATH"
fastlane ios release

ipa=$(find "$out_dir" -maxdepth 1 -name '*.ipa' | head -n 1)
echo "ipa-path=$ipa" >> "$GITHUB_OUTPUT"

if [ "$IN_DESTINATION" != "none" ]; then
  echo "PHYSALIS_RELEASE_STATUS=uploaded" >> "$GITHUB_ENV"
fi
