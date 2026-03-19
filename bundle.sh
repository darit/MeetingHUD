#!/bin/bash
# Build, bundle, sign, and launch MeetingHUD.
# Run from anywhere — does not change your working directory.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/xcode"
BINARY="$BUILD_DIR/Build/Products/Debug/MeetingHUD"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/MeetingHUD.app"

# Use a stable signing identity so macOS remembers permissions across rebuilds.
# Priority: Apple Development cert > self-signed "MeetingHUD Dev" cert > create one.
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | grep -v "REVOKED" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)

if [ -z "$SIGN_IDENTITY" ]; then
    # Try our self-signed cert
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "MeetingHUD Dev" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
fi

if [ -z "$SIGN_IDENTITY" ]; then
    echo "No signing certificate found. Creating self-signed 'MeetingHUD Dev' certificate..."
    echo "You may be prompted for your login password."

    # Create a self-signed code signing certificate with proper EKUs
    cat > /tmp/mhud-cs.cnf <<'CSEOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_cs

[dn]
CN = MeetingHUD Dev

[v3_cs]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CSEOF

    openssl req -x509 -newkey rsa:2048 -keyout /tmp/mhud-key.pem -out /tmp/mhud-cert.pem \
        -days 3650 -nodes -config /tmp/mhud-cs.cnf 2>/dev/null

    # Convert to p12 with -legacy flag (required for OpenSSL 3.x + macOS Keychain)
    openssl pkcs12 -export -out /tmp/mhud.p12 -inkey /tmp/mhud-key.pem -in /tmp/mhud-cert.pem \
        -passout pass:mhud -legacy 2>/dev/null

    # Import into login keychain
    KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
    [ ! -f "$KEYCHAIN" ] && KEYCHAIN="$HOME/Library/Keychains/login.keychain"
    security import /tmp/mhud.p12 -k "$KEYCHAIN" -T /usr/bin/codesign -P "mhud" 2>/dev/null || true

    # Trust the certificate for code signing
    security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" /tmp/mhud-cert.pem 2>/dev/null || true

    # Clean up temp files
    rm -f /tmp/mhud-cs.cnf /tmp/mhud-key.pem /tmp/mhud-cert.pem /tmp/mhud.p12

    # Verify
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "MeetingHUD Dev" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)

    if [ -n "$SIGN_IDENTITY" ]; then
        echo "✓ Created 'MeetingHUD Dev' certificate — permissions will persist across rebuilds"
    else
        echo "⚠ Certificate creation failed. Falling back to ad-hoc signing."
        echo "  Permissions (audio, screen recording) will need re-granting after each build."
        SIGN_IDENTITY="-"
    fi
else
    echo "Using signing identity: $SIGN_IDENTITY"
fi

# Ensure Xcode is the active developer directory
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Generate the SPM workspace if it doesn't exist (fresh clone)
WORKSPACE="$SCRIPT_DIR/.swiftpm/xcode/package.xcworkspace"
if [ ! -d "$WORKSPACE" ]; then
    echo "Generating SPM workspace (first build)..."
    swift package generate-xcodeproj 2>/dev/null || true
    # Opening Package.swift in Xcode creates the workspace, but we can also
    # use xcodebuild directly with the package directory
fi

echo "Building..."
if [ -d "$WORKSPACE" ]; then
    xcodebuild \
        -scheme MeetingHUD \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "$BUILD_DIR" \
        -workspace "$WORKSPACE" \
        build 2>&1 | tail -3
else
    # Fallback: build using the package directory directly
    xcodebuild \
        -scheme MeetingHUD \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "$BUILD_DIR" \
        build 2>&1 | tail -3
fi

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
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true

# Copy MLX Metal library and any other .bundle resources from the build
PRODUCTS_DIR="$BUILD_DIR/Build/Products/Debug"
for bundle in "$PRODUCTS_DIR"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null
done

# Remove quarantine xattr BEFORE signing (prevents Gatekeeper from flagging)
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# Codesign with entitlements
codesign --force --deep --sign "$SIGN_IDENTITY" \
    --entitlements "$SCRIPT_DIR/Resources/MeetingHUD.entitlements" \
    --options runtime \
    "$APP_BUNDLE" 2>/dev/null

# Verify and launch (detached from terminal)
if codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null | grep -q "audio.capture"; then
    echo "✓ Signed and launching MeetingHUD.app"
    # Try open first, fall back to running binary directly if Gatekeeper blocks it
    if ! open -a "$APP_BUNDLE" 2>/dev/null; then
        echo "⚠ open failed (Gatekeeper?), launching binary directly..."
        nohup "$APP_BUNDLE/Contents/MacOS/MeetingHUD" >/dev/null 2>&1 &
        disown
        echo "✓ Launched via binary"
    fi
else
    echo "✗ Signing failed"
    exit 1
fi
