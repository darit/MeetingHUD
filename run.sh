#!/bin/bash
# Build and run MeetingHUD with entitlements applied.
# Xcode's SPM mode doesn't apply entitlements, so we codesign after building.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/Resources/MeetingHUD.entitlements"
BUILD_DIR="$SCRIPT_DIR/.build/debug"
BINARY="$BUILD_DIR/MeetingHUD"

echo "Building..."
cd "$SCRIPT_DIR"
xcodebuild -scheme MeetingHUD -configuration Debug -derivedDataPath .build/xcode build 2>&1 | tail -5

# Find the built binary from xcodebuild
XCODE_BINARY=$(find .build/xcode -name MeetingHUD -type f -perm +111 -path "*/Debug/*" 2>/dev/null | head -1)

if [ -z "$XCODE_BINARY" ]; then
    echo "Build failed or binary not found."
    exit 1
fi

echo "Signing with entitlements..."
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$XCODE_BINARY"

echo "Verifying entitlements..."
codesign -d --entitlements :- "$XCODE_BINARY" 2>/dev/null | grep -q "audio.capture" && echo "✓ Audio capture entitlement present" || echo "✗ Missing audio capture entitlement"

echo "Launching..."
"$XCODE_BINARY"
