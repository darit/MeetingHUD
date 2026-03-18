#!/bin/bash
# Build, bundle, sign, and launch MeetingHUD.
# Run from anywhere — does not change your working directory.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/xcode"
BINARY="$BUILD_DIR/Build/Products/Debug/MeetingHUD"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/MeetingHUD.app"

# Use the Apple Development certificate if available (stable identity = permissions persist).
# Falls back to ad-hoc signing if no dev cert found.
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Using signing identity: $SIGN_IDENTITY"
else
    SIGN_IDENTITY="-"
    echo "⚠ No Apple Development cert found, using ad-hoc signing (permissions will reset on rebuild)"
fi

echo "Building..."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild \
    -scheme MeetingHUD \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$BUILD_DIR" \
    -workspace "$SCRIPT_DIR/.swiftpm/xcode/package.xcworkspace" \
    build 2>&1 | tail -3

if [ ! -f "$BINARY" ]; then
    echo "Build failed — binary not found."
    exit 1
fi

# Kill any running instance (try graceful quit first, then force)
pkill -x MeetingHUD 2>/dev/null && sleep 0.3 || true
pkill -9 -x MeetingHUD 2>/dev/null && sleep 0.2 || true

# Create .app bundle
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/MeetingHUD"
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy MLX Metal library and any other .bundle resources from the build
PRODUCTS_DIR="$BUILD_DIR/Build/Products/Debug"
for bundle in "$PRODUCTS_DIR"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null
done

# Codesign with entitlements
codesign --force --deep --sign "$SIGN_IDENTITY" \
    --entitlements "$SCRIPT_DIR/Resources/MeetingHUD.entitlements" \
    "$APP_BUNDLE" 2>/dev/null

# Verify and launch
if codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null | grep -q "audio.capture"; then
    echo "✓ Signed and launching MeetingHUD.app"
    open "$APP_BUNDLE"
else
    echo "✗ Signing failed"
    exit 1
fi
