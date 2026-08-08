#!/bin/bash
set -euo pipefail

# Decode Alpha DMG Builder
# Usage: ./scripts/build-dmg.sh
#
# Produces: build/Decode-<version>.dmg
# No Apple Developer Program, notarization, or CI/CD required.
#
# Uses xcodebuild build (not archive) to avoid a Swift compiler stack
# overflow triggered by the archive action on Xcode 16.2. The app is
# signed with Apple Development and hardened runtime is enabled via
# Release config, so testers can bypass Gatekeeper via right-click → Open.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
SCHEME="Decode"
CONFIG="Release"

cd "$PROJECT_DIR"

# Read version from project.yml
VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | awk '{print $2}')
if [ -z "$VERSION" ]; then
    echo "ERROR: Could not read MARKETING_VERSION from project.yml"
    exit 1
fi

APP_PATH="$BUILD_DIR/Decode.app"
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/Decode-${VERSION}.dmg"

echo "=== Decode Alpha Build ==="
echo "Version:  $VERSION"
echo "Config:   $CONFIG"
echo "Output:   $DMG_PATH"
echo ""

# ── Step 1: Clean previous build artifacts ──
echo "[1/5] Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Step 2: Build ──
echo "[2/5] Building (this takes a few minutes)..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
    -project Decode.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -arch arm64 \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM=P5Y864DV5S \
    -quiet

# Find the built app in DerivedData
DERIVED_APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Decode-*/Build/Products/$CONFIG/Decode.app" -maxdepth 6 2>/dev/null | head -1)
if [ -z "$DERIVED_APP" ] || [ ! -d "$DERIVED_APP" ]; then
    echo "ERROR: Build succeeded but Decode.app not found in DerivedData"
    exit 1
fi

echo "    Build succeeded."

# ── Step 3: Copy app from DerivedData ──
echo "[3/5] Copying app..."
cp -R "$DERIVED_APP" "$APP_PATH"
echo "    App copied (Apple Development signed)."

# ── Step 4: Verify ──
echo "[4/5] Verifying..."

# Check signing identity
SIGN_INFO=$(codesign -dv --verbose=2 "$APP_PATH" 2>&1)
if echo "$SIGN_INFO" | grep -q "Authority=Apple Development"; then
    echo "    ✓ Apple Development signature"
else
    echo "    ✗ WARNING: Expected Apple Development signature"
fi

if echo "$SIGN_INFO" | grep -q "TeamIdentifier=P5Y864DV5S"; then
    echo "    ✓ TeamIdentifier present"
else
    echo "    ✗ WARNING: TeamIdentifier missing"
fi

if echo "$SIGN_INFO" | grep -q "runtime"; then
    echo "    ✓ Hardened runtime enabled"
else
    echo "    ✗ WARNING: Hardened runtime not detected"
fi

# Check entitlements
ENTITLEMENTS=$(codesign -d --entitlements - "$APP_PATH" 2>&1)
if echo "$ENTITLEMENTS" | grep -q "get-task-allow"; then
    echo "    ✗ WARNING: get-task-allow present (Debug entitlement)"
else
    echo "    ✓ get-task-allow stripped"
fi

if echo "$ENTITLEMENTS" | grep -q "app-sandbox"; then
    echo "    ✗ WARNING: app-sandbox entitlement present"
else
    echo "    ✓ No sandbox entitlement"
fi

# Check app icon
if [ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]; then
    echo "    ✓ App icon present"
else
    echo "    ✗ WARNING: App icon missing"
fi

# ── Step 5: Create DMG ──
echo "[5/5] Creating DMG..."
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "Decode" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" \
    -quiet

rm -rf "$DMG_STAGING"

echo "    DMG created."

# ── Summary ──
echo ""
echo "=== Build Summary ==="
echo "App:      $APP_PATH"
echo "DMG:      $DMG_PATH"
echo "Size:     $(du -h "$DMG_PATH" | cut -f1)"
echo "Version:  $VERSION"
echo ""
echo "Distribute $DMG_PATH to alpha testers."
echo "Testers must right-click → Open on first launch to bypass Gatekeeper."
