#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-release}"
SIGN_AND_NOTARIZE="${2:-${SIGN_AND_NOTARIZE:-false}}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_CAPITALIZED="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
BUILD_DIR="$ROOT_DIR/.build/apple/Products/$CONFIG_CAPITALIZED"
EXECUTABLE="$BUILD_DIR/Nehir"
CLI_EXECUTABLE="$BUILD_DIR/nehirctl"
APP_DIR="$ROOT_DIR/dist/Nehir.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
RELEASE_ZIP_PATH="${RELEASE_ZIP_PATH:-$ROOT_DIR/dist/Nehir-$VERSION.zip}"
NOTARY_ZIP_PATH="$ROOT_DIR/dist/Nehir-notary.zip"

# Configure these via environment variables when you have an Apple Developer ID.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/Nehir.entitlements}"

if [ "$SIGN_AND_NOTARIZE" = "true" ]; then
  if [ -z "$SIGNING_IDENTITY" ]; then
    echo "SIGNING_IDENTITY must be set when SIGN_AND_NOTARIZE=true" >&2
    exit 1
  fi

  if [ -z "$NOTARIZE_PROFILE" ]; then
    echo "NOTARIZE_PROFILE must be set when SIGN_AND_NOTARIZE=true" >&2
    exit 1
  fi
fi

if [ -f "$ROOT_DIR/Makefile" ]; then
  echo "Running release checks..."
  make -C "$ROOT_DIR" release-check
else
  echo "Skipping make release-check: no Makefile found."
fi

echo "Building Nehir universal binary ($CONFIG)..."
swift build -c "$CONFIG" --arch arm64 --arch x86_64

echo "Verifying universal binary..."
lipo -info "$EXECUTABLE"
lipo -info "$CLI_EXECUTABLE"

echo "Packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/Nehir"
cp "$CLI_EXECUTABLE" "$APP_DIR/Contents/MacOS/nehirctl"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$BUILD_DIR/Nehir_Nehir.bundle" "$APP_DIR/Contents/Resources/"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
fi

if [ "$SIGN_AND_NOTARIZE" = "true" ]; then
  CODESIGN_IDENTITY="$SIGNING_IDENTITY"
else
  CODESIGN_IDENTITY="-"
fi

codesign_binary() {
  local target="$1"
  shift
  if [ "$SIGN_AND_NOTARIZE" = "true" ]; then
    codesign --force --options runtime "$@" --sign "$CODESIGN_IDENTITY" --timestamp "$target"
  else
    codesign --force --options runtime "$@" --sign "$CODESIGN_IDENTITY" "$target"
  fi
}

echo "Signing $APP_DIR with identity: $CODESIGN_IDENTITY"
codesign_binary "$APP_DIR/Contents/MacOS/nehirctl"
codesign_binary "$APP_DIR/Contents/MacOS/Nehir" --entitlements "$ENTITLEMENTS"
codesign_binary "$APP_DIR" --entitlements "$ENTITLEMENTS"

if [ "$SIGN_AND_NOTARIZE" = "true" ]; then
  echo "Verifying signature..."
  codesign --verify --verbose "$APP_DIR"

  echo "Creating temporary ZIP for notarization..."
  rm -f "$NOTARY_ZIP_PATH"
  ditto -c -k --keepParent "$APP_DIR" "$NOTARY_ZIP_PATH"

  echo "Submitting for notarization (this may take a few minutes)..."
  xcrun notarytool submit "$NOTARY_ZIP_PATH" --keychain-profile "$NOTARIZE_PROFILE" --wait

  echo "Stapling notarization ticket..."
  xcrun stapler staple "$APP_DIR"

  echo "Verifying notarization..."
  spctl --assess --verbose=2 "$APP_DIR"

  rm -f "$NOTARY_ZIP_PATH"
else
  echo "Created an ad-hoc signed app. Set SIGN_AND_NOTARIZE=true plus SIGNING_IDENTITY and NOTARIZE_PROFILE for Developer ID signing and notarization."
fi

echo "Creating release ZIP: $RELEASE_ZIP_PATH"
rm -f "$RELEASE_ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$RELEASE_ZIP_PATH"
shasum -a 256 "$RELEASE_ZIP_PATH"

echo "Done. Open $APP_DIR to grant Accessibility permissions."
