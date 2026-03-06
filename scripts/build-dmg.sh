#!/bin/bash
set -euo pipefail

# ==============================================================================
# RONIN — Build DMG
# Builds the Swift app, bundles the Python backend + Whisper model,
# creates a self-contained .dmg installer.
# ==============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
APP_NAME="Ronin"
DMG_NAME="Ronin"
XCODE_PROJECT="$PROJECT_ROOT/RoninApp/RoninApp.xcodeproj"
BACKEND_DIR="$PROJECT_ROOT/backend"

# Python framework location (Homebrew)
PYTHON_VERSION="3.14"
PYTHON_FRAMEWORK="/opt/homebrew/Cellar/python@$PYTHON_VERSION/3.14.2/Frameworks/Python.framework/Versions/3.14"

# Whisper model cache
WHISPER_MODEL_CACHE="$HOME/.cache/huggingface/hub/models--mlx-community--whisper-small-mlx"

# ==============================================================================
# Preflight checks
# ==============================================================================
echo "=== Preflight checks ==="

if [ ! -d "$PYTHON_FRAMEWORK" ]; then
    echo "ERROR: Python framework not found at $PYTHON_FRAMEWORK"
    echo "Install Python 3.14 via Homebrew: brew install python@3.14"
    exit 1
fi

if [ ! -d "$BACKEND_DIR/.venv" ]; then
    echo "ERROR: Python venv not found at $BACKEND_DIR/.venv"
    echo "Run: cd $BACKEND_DIR && python3.14 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
    exit 1
fi

if [ ! -d "$WHISPER_MODEL_CACHE" ]; then
    echo "ERROR: Whisper model not found at $WHISPER_MODEL_CACHE"
    echo "Run the backend once to download the model, or run scripts/setup.sh"
    exit 1
fi

echo "  Python framework: OK"
echo "  Backend venv: OK"
echo "  Whisper model: OK"

# ==============================================================================
# Step 1: Clean
# ==============================================================================
echo ""
echo "=== Step 1: Clean build directory ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ==============================================================================
# Step 2: Build Swift app (Release)
# ==============================================================================
echo ""
echo "=== Step 2: Building Swift app (Release) ==="
xcodebuild -project "$XCODE_PROJECT" \
    -scheme RoninApp \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    ONLY_ACTIVE_ARCH=YES \
    build 2>&1 | tail -5

APP_PATH=$(find "$BUILD_DIR/derived" -name "$APP_NAME.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find built $APP_NAME.app"
    exit 1
fi
echo "  Built: $APP_PATH"

# ==============================================================================
# Step 3: Create Resources layout
# ==============================================================================
echo ""
echo "=== Step 3: Setting up Resources ==="
RESOURCES="$APP_PATH/Contents/Resources"
mkdir -p "$RESOURCES/python/bin"
mkdir -p "$RESOURCES/python/lib"
mkdir -p "$RESOURCES/backend"
mkdir -p "$RESOURCES/models/huggingface/hub"

# ==============================================================================
# Step 4: Copy Python runtime
# ==============================================================================
echo ""
echo "=== Step 4: Copying Python runtime ==="

# The bin/python3.14 in the framework is a GUI launcher stub that tries to exec
# Resources/Python.app. The ACTUAL interpreter is at Resources/Python.app/Contents/MacOS/Python.
# We copy the real interpreter directly.

REAL_PYTHON="$PYTHON_FRAMEWORK/Resources/Python.app/Contents/MacOS/Python"
cp "$REAL_PYTHON" "$RESOURCES/python/bin/python$PYTHON_VERSION"
chmod +x "$RESOURCES/python/bin/python$PYTHON_VERSION"

# Copy the framework Python dylib (this is what the interpreter links against)
cp "$PYTHON_FRAMEWORK/Python" "$RESOURCES/python/lib/Python"

# Copy the stdlib
echo "  Copying stdlib..."
cp -R "$PYTHON_FRAMEWORK/lib/python$PYTHON_VERSION" "$RESOURCES/python/lib/python$PYTHON_VERSION"

# Remove the stdlib's default site-packages (pip/wheel)
rm -rf "$RESOURCES/python/lib/python$PYTHON_VERSION/site-packages"

# ==============================================================================
# Step 5: Fix dylib rpaths (make relocatable)
# ==============================================================================
echo ""
echo "=== Step 5: Fixing dylib rpaths ==="

# Get the original install name the binary references
ORIGINAL_DYLIB=$(otool -L "$RESOURCES/python/bin/python$PYTHON_VERSION" | grep -o '/.*Python\b' | head -1)
echo "  Original dylib reference: $ORIGINAL_DYLIB"

# Change the dylib's install name to relative path
install_name_tool -id "@executable_path/../lib/Python" \
    "$RESOURCES/python/lib/Python"

# Change the interpreter binary to find the dylib relative to itself
install_name_tool -change "$ORIGINAL_DYLIB" \
    "@executable_path/../lib/Python" \
    "$RESOURCES/python/bin/python$PYTHON_VERSION"

# Verify
echo "  Verifying..."
otool -L "$RESOURCES/python/bin/python$PYTHON_VERSION" | head -5

# ==============================================================================
# Step 6: Copy site-packages from venv
# ==============================================================================
echo ""
echo "=== Step 6: Copying site-packages ==="

cp -R "$BACKEND_DIR/.venv/lib/python$PYTHON_VERSION/site-packages" \
    "$RESOURCES/python/lib/python$PYTHON_VERSION/site-packages"

# ==============================================================================
# Step 7: Trim site-packages (reduce size)
# ==============================================================================
echo ""
echo "=== Step 7: Trimming site-packages ==="

SP="$RESOURCES/python/lib/python$PYTHON_VERSION/site-packages"

# Remove __pycache__ and .pyc
find "$RESOURCES/python" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$RESOURCES/python" -name "*.pyc" -delete 2>/dev/null || true

# Remove pip and setuptools (not needed at runtime)
rm -rf "$SP/pip" "$SP/pip-"*.dist-info
rm -rf "$SP/setuptools" "$SP/setuptools-"*.dist-info
rm -rf "$SP/_distutils_hack"
rm -rf "$SP/wheel" "$SP/wheel-"*.dist-info
rm -rf "$SP/pkg_resources"

# Remove distutils-precedence.pth (references _distutils_hack which is removed)
rm -f "$SP/distutils-precedence.pth"

# Remove .dist-info directories
find "$SP" -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true

# Remove test directories
find "$SP" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "$SP" -type d -name "test" -maxdepth 3 -exec rm -rf {} + 2>/dev/null || true

# Trim stdlib
rm -rf "$RESOURCES/python/lib/python$PYTHON_VERSION/test"
rm -rf "$RESOURCES/python/lib/python$PYTHON_VERSION/tkinter"
rm -rf "$RESOURCES/python/lib/python$PYTHON_VERSION/idlelib"
rm -rf "$RESOURCES/python/lib/python$PYTHON_VERSION/turtledemo"
rm -rf "$RESOURCES/python/lib/python$PYTHON_VERSION/ensurepip"
rm -rf "$RESOURCES/python/lib/python$PYTHON_VERSION/lib2to3"
rm -rf "$RESOURCES/python/lib/python$PYTHON_VERSION/EXTERNALLY-MANAGED"

echo "  Site-packages trimmed"

# ==============================================================================
# Step 8: Fix native extension rpaths
# ==============================================================================
echo ""
echo "=== Step 8: Fixing native extension rpaths ==="

# Find .so/.dylib files that reference Homebrew paths
NEEDS_FIX=0
while IFS= read -r sofile; do
    # Check if this .so references the Homebrew Python framework
    if otool -L "$sofile" 2>/dev/null | grep -q "/opt/homebrew"; then
        NEEDS_FIX=$((NEEDS_FIX + 1))
        # Get all homebrew references
        while IFS= read -r ref; do
            if echo "$ref" | grep -q "Python"; then
                # Fix Python framework reference
                install_name_tool -change "$ref" \
                    "@loader_path/../../../../lib/Python" \
                    "$sofile" 2>/dev/null || true
            fi
        done < <(otool -L "$sofile" | grep "/opt/homebrew" | awk '{print $1}')
    fi
done < <(find "$RESOURCES/python" -name "*.so" -o -name "*.dylib" 2>/dev/null | grep -v "python/lib/Python$")

echo "  Fixed $NEEDS_FIX native extensions"

# ==============================================================================
# Step 9: Copy backend application code
# ==============================================================================
echo ""
echo "=== Step 9: Copying backend code ==="

cp "$BACKEND_DIR/run.py" "$RESOURCES/backend/"
cp -R "$BACKEND_DIR/app" "$RESOURCES/backend/app"
find "$RESOURCES/backend" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

echo "  Backend code copied"

# ==============================================================================
# Step 10: Copy Whisper model
# ==============================================================================
echo ""
echo "=== Step 10: Copying Whisper model ==="

# Copy the HF cache structure, resolving symlinks to real files
cp -R "$WHISPER_MODEL_CACHE" "$RESOURCES/models/huggingface/hub/"

# Resolve symlinks to real files (HF cache uses symlinks from snapshots → blobs)
find "$RESOURCES/models" -type l | while IFS= read -r link; do
    target=$(readlink "$link")
    # Resolve relative symlinks
    if [[ "$target" != /* ]]; then
        target="$(cd "$(dirname "$link")" && cd "$(dirname "$target")" && pwd)/$(basename "$target")"
    fi
    if [ -f "$target" ]; then
        rm "$link"
        cp "$target" "$link"
    fi
done

# Remove the blobs directory (snapshots now have real files, blobs are duplicates)
rm -rf "$RESOURCES/models/huggingface/hub/"*/blobs

echo "  Whisper model copied ($(du -sh "$RESOURCES/models/" | awk '{print $1}'))"

# ==============================================================================
# Step 11: Code sign
# ==============================================================================
echo ""
echo "=== Step 11: Code signing ==="

# Use Developer ID if available, otherwise fall back to ad-hoc
# Set CODESIGN_IDENTITY env var to your Developer ID, e.g.:
#   export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "  ⚠️  Using ad-hoc signing (set CODESIGN_IDENTITY for distribution)"
else
    echo "  Signing with: $SIGN_IDENTITY"
fi

# Sign inner binaries first (inside-out order is required)
# 1. Sign the Python dylib
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$RESOURCES/python/lib/Python" 2>&1

# 2. Sign all .so native extensions
find "$RESOURCES/python" -name "*.so" -exec \
    codesign --force --options runtime --sign "$SIGN_IDENTITY" {} \; 2>&1

# 3. Sign the Python interpreter binary
codesign --force --options runtime --sign "$SIGN_IDENTITY" \
    "$RESOURCES/python/bin/python$PYTHON_VERSION" 2>&1

# 4. Sign the outer app bundle last
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_PATH" 2>&1

echo "  Signed ($([ "$SIGN_IDENTITY" = "-" ] && echo "ad-hoc" || echo "Developer ID"))"

# ==============================================================================
# Step 12: Report sizes
# ==============================================================================
echo ""
echo "=== Bundle sizes ==="
echo "  Python runtime:  $(du -sh "$RESOURCES/python/" | awk '{print $1}')"
echo "  Backend code:    $(du -sh "$RESOURCES/backend/" | awk '{print $1}')"
echo "  Whisper model:   $(du -sh "$RESOURCES/models/" | awk '{print $1}')"
echo "  Total app:       $(du -sh "$APP_PATH" | awk '{print $1}')"

# ==============================================================================
# Step 13: Create DMG
# ==============================================================================
echo ""
echo "=== Step 13: Creating DMG ==="

STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"

# Create Applications symlink for drag-to-install
ln -s /Applications "$STAGING/Applications"

# Create DMG
hdiutil create -volname "$DMG_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    -fs HFS+ \
    "$BUILD_DIR/$DMG_NAME.dmg" 2>&1

# ==============================================================================
# Step 14: Notarize (if Developer ID signing was used)
# ==============================================================================
if [ "$SIGN_IDENTITY" != "-" ]; then
    echo ""
    echo "=== Step 14: Notarizing ==="

    # Requires: APPLE_ID, APPLE_TEAM_ID, and app-specific password in keychain
    # Set up once: xcrun notarytool store-credentials "ronin-notary" \
    #   --apple-id "you@email.com" --team-id "TEAMID" --password "app-specific-pw"
    NOTARY_PROFILE="${NOTARY_PROFILE:-ronin-notary}"

    echo "  Submitting to Apple for notarization..."
    xcrun notarytool submit "$BUILD_DIR/$DMG_NAME.dmg" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1

    echo "  Stapling notarization ticket..."
    xcrun stapler staple "$BUILD_DIR/$DMG_NAME.dmg" 2>&1

    echo "  ✅ Notarized and stapled"
else
    echo ""
    echo "  ⚠️  Skipping notarization (ad-hoc signing — set CODESIGN_IDENTITY for distribution)"
fi

echo ""
echo "============================================="
echo "  DMG created successfully!"
echo "  $(du -sh "$BUILD_DIR/$DMG_NAME.dmg" | awk '{print $1}')  $BUILD_DIR/$DMG_NAME.dmg"
echo "============================================="
