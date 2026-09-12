#!/bin/sh
#
# Package a device build as an .ipa, so AltStore or SideStore can install it and then
# refresh its signature on their own — removing the weekly Xcode ritual.
#
# Product → Archive → Distribute is not the path here: it wants a distribution certificate,
# which a free personal team does not have. An .ipa is just a zip with the .app inside a
# Payload/ directory, so building for device and wrapping the result by hand works fine and
# keeps the personal-team signature Xcode already applied.
#
#   sh ios/scripts/make-ipa.sh            # Debug
#   CONFIG=Release sh ios/scripts/make-ipa.sh
#
set -eu

SCHEME="${SCHEME:-SleepTracker}"
CONFIG="${CONFIG:-Debug}"
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJECT="$HERE/$SCHEME.xcodeproj"

[ -d "$PROJECT" ] || {
    echo "No $PROJECT — generate it first:" >&2
    echo "  brew install xcodegen && cd ios && xcodegen generate" >&2
    exit 1
}

DERIVED=$(mktemp -d)
trap 'rm -rf "$DERIVED"' EXIT

# generic/platform=iOS builds for a real device without needing one plugged in. The
# signature comes from the personal team already configured in the project.
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    build

APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name "$SCHEME.app" -print -quit)
[ -n "$APP" ] || { echo "Build produced no $SCHEME.app" >&2; exit 1; }

OUT="$HERE/build"
rm -rf "$OUT/Payload" "$OUT/$SCHEME.ipa"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"

# -y preserves symlinks; frameworks and the app bundle rely on them.
(cd "$OUT" && zip -qry "$SCHEME.ipa" Payload && rm -rf Payload)

echo
echo "  → $OUT/$SCHEME.ipa"
echo "  AirDrop it to the phone and open it with AltStore, or drop it on AltServer."
echo "  AltStore then refreshes the signature itself; no weekly Xcode run."
