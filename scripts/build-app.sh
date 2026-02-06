#!/bin/bash
# Build WellWhaddyaKnow.app bundle for local testing
# Usage: ./scripts/build-app.sh [--release]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# Parse arguments
BUILD_CONFIG="debug"
if [[ "${1:-}" == "--release" ]]; then
    BUILD_CONFIG="release"
    BUILD_FLAGS="--configuration release"
else
    BUILD_FLAGS=""
fi

APP_NAME="WellWhaddyaKnow"
APP_BUNDLE="$PROJECT_ROOT/.build/$BUILD_CONFIG/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Building $APP_NAME ($BUILD_CONFIG)..."

# Build the executable
swift build $BUILD_FLAGS --product WellWhaddyaKnow

# Create app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
cp "$PROJECT_ROOT/.build/$BUILD_CONFIG/WellWhaddyaKnow" "$MACOS_DIR/$APP_NAME"

# Copy and process Info.plist (replace Xcode variables)
sed -e "s/\$(EXECUTABLE_NAME)/$APP_NAME/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.daylily.wellwhaddyaknow/g" \
    "$PROJECT_ROOT/Sources/WellWhaddyaKnowApp/Info.plist" > "$CONTENTS_DIR/Info.plist"

# Copy PrivacyInfo.xcprivacy
cp "$PROJECT_ROOT/Sources/WellWhaddyaKnowApp/PrivacyInfo.xcprivacy" "$RESOURCES_DIR/PrivacyInfo.xcprivacy"

# Create PkgInfo
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Sign the app (ad-hoc for local testing)
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo "✅ Built: $APP_BUNDLE"
echo ""
echo "To run:"
echo "  open '$APP_BUNDLE'"
echo ""
echo "To install to /Applications (requires sudo):"
echo "  sudo cp -R '$APP_BUNDLE' /Applications/"

