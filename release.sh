#!/bin/bash
#
# Prepares a CallRec release, in the order the pins depend on each other:
#   1. when this version introduces a new tools revision (TOOLS_TAG in setup.sh is this version), builds
#      the tools archive (tools/build-tools.sh) unless it is already built and pins its sha256 in setup.sh;
#      otherwise checks that the published archive still matches the pin (setup.sh is bundled inside
#      the app, so this comes first)
#   2. builds the app (app/build.sh) and pins its version and the zip's sha256 in install.sh
#   3. lays the assets out as a local release, so the one-command install can be tested before
#      anything is published, and prints the commands that publish it.
# It never commits, tags, uploads or pushes anything itself.
#
# Usage: ./release.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

sha256_of()  { shasum -a 256 "$1" | awk '{print $1}'; }
setting()    { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$2"; }
die()        { printf '\nError: %s\n' "$1" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' app/Info.plist)"
TOOLS_REVISION="$(setting TOOLS_REVISION setup.sh)"
TOOLS_TAG="$(setting TOOLS_TAG setup.sh)"
[ "$(setting TOOLS_REVISION tools/build-tools.sh)" = "$TOOLS_REVISION" ] \
  || die "TOOLS_REVISION differs between setup.sh and tools/build-tools.sh."
TOOLS_FILE="callrec-tools-${TOOLS_REVISION}-macos-arm64.tar.gz"
TOOLS_ARCHIVE="build/$TOOLS_FILE"

if [ "$TOOLS_TAG" = "v$VERSION" ]; then
  [ -f "$TOOLS_ARCHIVE" ] || tools/build-tools.sh
  TOOLS_SHA256="$(sha256_of "$TOOLS_ARCHIVE")"
  sed -i '' "s/^TOOLS_SHA256=\".*\"\$/TOOLS_SHA256=\"$TOOLS_SHA256\"/" setup.sh
  [ "$(setting TOOLS_SHA256 setup.sh)" = "$TOOLS_SHA256" ] || die "Could not pin the tools sha256 in setup.sh."
else
  TOOLS_SHA256="$(setting TOOLS_SHA256 setup.sh)"
  if [ ! -f "$TOOLS_ARCHIVE" ] || [ "$(sha256_of "$TOOLS_ARCHIVE")" != "$TOOLS_SHA256" ]; then
    rm -f "$TOOLS_ARCHIVE"
    gh release download "$TOOLS_TAG" -R shacharPash/callrec -p "$TOOLS_FILE" -D build \
      || die "Could not download $TOOLS_FILE from release $TOOLS_TAG."
  fi
  [ "$(sha256_of "$TOOLS_ARCHIVE")" = "$TOOLS_SHA256" ] \
    || die "The published $TOOLS_FILE does not match the sha256 pinned in setup.sh."
fi

app/build.sh
APP_SHA256="$(sha256_of build/CallRec.zip)"
sed -i '' -e "s/^APP_VERSION=\".*\"\$/APP_VERSION=\"$VERSION\"/" \
          -e "s/^APP_ZIP_SHA256=\".*\"\$/APP_ZIP_SHA256=\"$APP_SHA256\"/" install.sh
[ "$(setting APP_ZIP_SHA256 install.sh)" = "$APP_SHA256" ] || die "Could not pin the app sha256 in install.sh."

LOCAL="$ROOT/build/release"
rm -rf "$LOCAL"
mkdir -p "$LOCAL/v$VERSION" "$LOCAL/$TOOLS_TAG"
cp build/CallRec.zip "$LOCAL/v$VERSION/"
cp "$TOOLS_ARCHIVE" "$LOCAL/$TOOLS_TAG/"

ASSETS="build/CallRec.zip"
[ "$TOOLS_TAG" != "v$VERSION" ] || ASSETS="$ASSETS $TOOLS_ARCHIVE"

cat <<EOF

CallRec $VERSION is ready to release.
  app zip   build/CallRec.zip  sha256 $APP_SHA256
  tools     $TOOLS_ARCHIVE  sha256 $TOOLS_SHA256 (release $TOOLS_TAG)

Test the one-command install against these files before publishing:
  CALLREC_RELEASE_URL="file://$LOCAL" bash install.sh

Publish, in this order (the one-liner reads install.sh from main, so the release must exist first):
  git add -A && git commit -m "Release CallRec $VERSION"
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION $ASSETS --verify-tag --title "CallRec $VERSION"
  git push origin main
EOF
