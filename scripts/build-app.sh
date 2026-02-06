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

# Build the executable and the agent
swift build $BUILD_FLAGS --product WellWhaddyaKnow
swift build $BUILD_FLAGS --product WellWhaddyaKnowAgent

# Create app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$CONTENTS_DIR/Library/LaunchAgents"

# Copy main executable
cp "$PROJECT_ROOT/.build/$BUILD_CONFIG/WellWhaddyaKnow" "$MACOS_DIR/$APP_NAME"

# Embed agent binary in app bundle (required for SMAppService)
cp "$PROJECT_ROOT/.build/$BUILD_CONFIG/WellWhaddyaKnowAgent" "$MACOS_DIR/wwkd"

# Embed launchd agent plist (required for SMAppService.agent(plistName:))
cp "$PROJECT_ROOT/Sources/WellWhaddyaKnowApp/LaunchAgents/com.daylily.wellwhaddyaknow.agent.plist" \
    "$CONTENTS_DIR/Library/LaunchAgents/com.daylily.wellwhaddyaknow.agent.plist"

# Copy and process Info.plist (replace Xcode variables)
sed -e "s/\$(EXECUTABLE_NAME)/$APP_NAME/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.daylily.wellwhaddyaknow/g" \
    "$PROJECT_ROOT/Sources/WellWhaddyaKnowApp/Info.plist" > "$CONTENTS_DIR/Info.plist"

# Copy PrivacyInfo.xcprivacy
cp "$PROJECT_ROOT/Sources/WellWhaddyaKnowApp/PrivacyInfo.xcprivacy" "$RESOURCES_DIR/PrivacyInfo.xcprivacy"

# Create PkgInfo
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Sign the app with developer identity (falls back to ad-hoc)
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    # Auto-detect: pick the first valid codesigning identity
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Apple Development" \
        | head -1 \
        | sed 's/.*"\(.*\)"/\1/' || true)
fi

ENTITLEMENTS="$PROJECT_ROOT/Sources/WellWhaddyaKnowApp/WellWhaddyaKnow.entitlements"

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with: $SIGN_IDENTITY"
    # Sign the embedded agent binary first (inner → outer)
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$MACOS_DIR/wwkd"
    echo "Signed embedded agent: $MACOS_DIR/wwkd"
    # Sign the main executable
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$MACOS_DIR/$APP_NAME"
    # Sign the whole bundle last
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_BUNDLE"
    # Also sign the standalone agent build artifact
    AGENT_BIN="$PROJECT_ROOT/.build/$BUILD_CONFIG/WellWhaddyaKnowAgent"
    if [ -f "$AGENT_BIN" ]; then
        codesign --force --sign "$SIGN_IDENTITY" "$AGENT_BIN"
        echo "Signed standalone agent: $AGENT_BIN"
    fi
else
    echo "⚠ No Apple Development identity found — using ad-hoc signing"
    echo "  Accessibility permissions may reset on each rebuild"
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
fi

echo ""
echo "✅ Built: $APP_BUNDLE"
echo ""
echo "To run:"
echo "  open '$APP_BUNDLE'"
echo ""
echo "To install to /Applications (requires sudo):"
echo "  sudo cp -R '$APP_BUNDLE' /Applications/"

