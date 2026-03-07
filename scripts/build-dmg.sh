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

# Python framework location (Homebrew — auto-detect patch version)
PYTHON_VERSION="3.14"
PYTHON_CELLAR="/opt/homebrew/Cellar/python@$PYTHON_VERSION"
if [ -d "$PYTHON_CELLAR" ]; then
    PYTHON_PATCH=$(ls -1 "$PYTHON_CELLAR" | sort -V | tail -1)
    PYTHON_FRAMEWORK="$PYTHON_CELLAR/$PYTHON_PATCH/Frameworks/Python.framework/Versions/$PYTHON_VERSION"
else
    PYTHON_FRAMEWORK=""
fi

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

SKIP_WHISPER=false
if [ ! -d "$WHISPER_MODEL_CACHE" ]; then
    echo "  ⚠️  Whisper model not found at $WHISPER_MODEL_CACHE"
    echo "     The DMG will download the model on first run."
    echo "     To bundle offline: disconnect VPN, run 'scripts/setup.sh', rebuild."
    SKIP_WHISPER=true
fi

echo "  Python framework: OK"
echo "  Backend venv: OK"
if [ "$SKIP_WHISPER" = true ]; then
    echo "  Whisper model: SKIP (will download on first run)"
else
    echo "  Whisper model: OK"
fi

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
    ONLY_ACTIVE_ARCH=NO \
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

# Directory for bundled third-party dylibs
BUNDLED_LIBS="$RESOURCES/python/lib/bundled"
mkdir -p "$BUNDLED_LIBS"

# Helper: bundle a Homebrew dylib and rewrite the reference in the calling binary
bundle_homebrew_dylib() {
    local sofile="$1"
    local ref="$2"
    local LIBNAME=$(basename "$ref")

    # Copy the dylib to bundled/ if not already there
    if [ ! -f "$BUNDLED_LIBS/$LIBNAME" ]; then
        if [ -f "$ref" ]; then
            cp "$ref" "$BUNDLED_LIBS/$LIBNAME"
            chmod 644 "$BUNDLED_LIBS/$LIBNAME"
            install_name_tool -id "@loader_path/$LIBNAME" \
                "$BUNDLED_LIBS/$LIBNAME" 2>/dev/null || true
            BUNDLED_COUNT=$((BUNDLED_COUNT + 1))
            echo "    Bundled: $LIBNAME"
        fi
    fi

    # Rewrite the reference in the calling binary
    SODIR=$(dirname "$sofile")
    RELPATH=$(python3 -c "import os.path; print(os.path.relpath('$BUNDLED_LIBS', '$SODIR'))")
    install_name_tool -change "$ref" \
        "@loader_path/$RELPATH/$LIBNAME" \
        "$sofile" 2>/dev/null || true
}

# Find .so/.dylib files that reference Homebrew paths and fix ALL references
# (Python framework + third-party libs like libssl, libmpdec, libzstd, libomp)
NEEDS_FIX=0
BUNDLED_COUNT=0
while IFS= read -r sofile; do
    if otool -L "$sofile" 2>/dev/null | grep -q "/opt/homebrew"; then
        NEEDS_FIX=$((NEEDS_FIX + 1))
        while IFS= read -r ref; do
            if echo "$ref" | grep -q "Python"; then
                # Fix Python framework reference
                install_name_tool -change "$ref" \
                    "@loader_path/../../../../lib/Python" \
                    "$sofile" 2>/dev/null || true
            else
                bundle_homebrew_dylib "$sofile" "$ref"
            fi
        done < <(otool -L "$sofile" | grep "/opt/homebrew" | awk '{print $1}')
    fi
done < <(find "$RESOURCES/python" -name "*.so" -o -name "*.dylib" 2>/dev/null | grep -v "python/lib/Python$" | grep -v "python/lib/bundled/")

# Second pass: fix Homebrew references in the bundled dylibs themselves
# (e.g., libssl references libcrypto, scipy references libomp)
echo "  Resolving transitive dependencies in bundled dylibs..."
for _pass in 1 2; do
    FOUND_NEW=false
    while IFS= read -r dylib; do
        REFS=$(otool -L "$dylib" 2>/dev/null | grep "/opt/homebrew" | awk '{print $1}' || true)
        if [ -n "$REFS" ]; then
            while IFS= read -r ref; do
                bundle_homebrew_dylib "$dylib" "$ref"
                FOUND_NEW=true
            done <<< "$REFS"
        fi
    done < <(find "$BUNDLED_LIBS" -name "*.dylib" 2>/dev/null || true)
    if [ "$FOUND_NEW" = false ]; then
        break
    fi
done

echo "  Fixed $NEEDS_FIX native extensions, bundled $BUNDLED_COUNT third-party dylibs"

# Fix install names of ALL .dylib files to remove Homebrew references.
# Some packages (e.g., PyTorch) ship .dylib files with Homebrew install names.
# The install name is metadata only (not a runtime dependency), but fixing it
# ensures the bundle is clean and verification passes.
echo "  Cleaning up dylib install names..."
while IFS= read -r dylib; do
    INSTALL_NAME=$(otool -D "$dylib" 2>/dev/null | tail -1 || true)
    if echo "$INSTALL_NAME" | grep -q "/opt/homebrew"; then
        LIBNAME=$(basename "$dylib")
        install_name_tool -id "@loader_path/$LIBNAME" "$dylib" 2>/dev/null || true
    fi
done < <(find "$RESOURCES/python" -name "*.dylib" 2>/dev/null | grep -v "python/lib/Python$" || true)

# Verify no remaining Homebrew references (check dependencies only, not install names)
echo "  Verifying no remaining Homebrew references..."
REMAINING=""
while IFS= read -r sofile; do
    # Get dependency references (skip the file's own install name via tail +3)
    # otool -L output: line 1 = filename, line 2 = install name (for dylibs), line 3+ = deps
    # For .so files: line 1 = filename, line 2+ = deps (no install name)
    REFS=$(otool -L "$sofile" 2>/dev/null | grep "/opt/homebrew" | awk '{print $1}' || true)
    if [ -n "$REFS" ]; then
        # Filter out the file's own install name
        OWN_NAME=$(otool -D "$sofile" 2>/dev/null | tail -1 || true)
        while IFS= read -r ref; do
            if [ "$ref" != "$OWN_NAME" ]; then
                REMAINING="$REMAINING  ⚠️  $(basename "$sofile") → $ref"$'\n'
            fi
        done <<< "$REFS"
    fi
done < <(find "$RESOURCES/python" \( -name "*.so" -o -name "*.dylib" \) 2>/dev/null || true)
if [ -n "$REMAINING" ]; then
    echo "$REMAINING"
    echo "  ⚠️  Some references could not be fixed. The DMG may not work on machines without Homebrew."
else
    echo "  ✅ All Homebrew references resolved — bundle is self-contained"
fi

# Verify all binaries include arm64
echo "  Verifying architecture..."
NON_ARM64=""
while IFS= read -r sofile; do
    # Check if the binary has an arm64 slice (fat or thin)
    if ! file "$sofile" 2>/dev/null | grep -q "arm64"; then
        NON_ARM64="$NON_ARM64  $(basename "$sofile"): $(file -b "$sofile" | head -1)"$'\n'
    fi
done < <(find "$RESOURCES/python" \( -name "*.so" -o -name "*.dylib" \) 2>/dev/null || true)
if [ -n "$NON_ARM64" ]; then
    echo "  ⚠️  Binaries without arm64 slice:"
    echo "$NON_ARM64"
fi

# Clean up broken symlinks and config dir
find "$RESOURCES/python" -type l ! -exec test -e {} \; -delete 2>/dev/null || true

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

if [ "$SKIP_WHISPER" = true ]; then
    echo "  Skipped — model will be downloaded on first run"
    # Remove the empty models directory so bundled mode detection doesn't trigger
    rm -rf "$RESOURCES/models"
else
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
fi

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

# Sign inner binaries first (inside-out order is required).
#
# For ad-hoc signing: Python components are signed WITHOUT --options runtime
# because Hardened Runtime enforces library validation — with ad-hoc signing,
# the Python binary and dylib get different identities, causing dyld to reject
# the dylib load ("different Team IDs").
#
# For Developer ID signing: all components get Hardened Runtime + entitlements.
# The disable-library-validation entitlement allows loading the bundled Python
# dylib/extensions which have a different code signature.

ENTITLEMENTS="$PROJECT_ROOT/RoninApp/RoninApp/RoninApp.entitlements"

if [ "$SIGN_IDENTITY" != "-" ]; then
    # Developer ID: use Hardened Runtime + entitlements everywhere
    PYTHON_SIGN_FLAGS="--force --options runtime --entitlements $ENTITLEMENTS --sign $SIGN_IDENTITY"
else
    # Ad-hoc: no Hardened Runtime for Python components
    PYTHON_SIGN_FLAGS="--force --sign $SIGN_IDENTITY"
fi

# 1. Sign the Python dylib
codesign $PYTHON_SIGN_FLAGS "$RESOURCES/python/lib/Python" 2>&1

# 2. Sign all bundled third-party dylibs (libssl, libcrypto, libmpdec, etc.)
find "$RESOURCES/python/lib/bundled" -name "*.dylib" -exec \
    codesign $PYTHON_SIGN_FLAGS {} \; 2>&1

# 3. Sign all .so native extensions AND any other .dylib files
find "$RESOURCES/python" \( -name "*.so" -o -name "*.dylib" \) \
    ! -path "*/lib/Python" ! -path "*/lib/bundled/*" -exec \
    codesign $PYTHON_SIGN_FLAGS {} \; 2>&1

# 4. Sign the Python interpreter binary
codesign $PYTHON_SIGN_FLAGS \
    "$RESOURCES/python/bin/python$PYTHON_VERSION" 2>&1

# 4. Sign the outer app bundle (always with Hardened Runtime + entitlements)
codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP_PATH" 2>&1

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
