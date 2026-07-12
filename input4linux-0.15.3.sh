#!/bin/bash
set -euo pipefail

# This script downloads the Input v0.15.3 Windows installer, extracts the app,
# rebuilds native modules for Linux, and packages everything as an AppImage.
#
# Usage:
#   ./input4linux-0.15.3.sh
#   TEST_MODE=true ./input4linux-0.15.3.sh   # continue past non-critical errors

TEST_MODE="${TEST_MODE:-false}"

# Versions and URLs
VERSION="0.15.3"
COMMUNITY_VERSION="${VERSION}-Community"
URL="https://github.com/worklouder/input-releases/releases/download/v${VERSION}/input-Setup-${VERSION}.exe"
FILENAME="input-Setup-${VERSION}.exe"

# Working directories
DOWNLOAD_DIR="./input_download"
EXTRACT_DIR="./input_extracted"
REBUILD_DIR="./input_rebuild"
APP_64_EXTRACT_DIR="$REBUILD_DIR/app-64"
WORK_DIR="./input_work"

# Output
OUTPUT_APPIMAGE="./Input-${COMMUNITY_VERSION}.AppImage"

# Patch directory (relative to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/patch"

# Linux preamble injected at the top of dist-electron/main/index.js
LINUX_PREAMBLE='// From Input-Linux Patch
import { app } from '"'"'electron'"'"';

if (process.env.APPIMAGE) {
  app.commandLine.appendSwitch('"'"'no-sandbox'"'"');
}

// ^^^^^^^^^^^^^^^^^^^^^^^^^^^^'

# Python virtualenv for node-gyp compatibility
# Auto-detect: prefer 3.11, then 3.12, 3.10, 3.13, 3.14, or generic python3
PY_VER=""
for candidate in 3.11 3.12 3.10 3.13 3.14; do
    if command -v "python$candidate" &>/dev/null; then
        PY_VER="$candidate"
        break
    fi
done
if [[ -z "$PY_VER" ]] && command -v python3 &>/dev/null; then
    PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
fi
if [[ -z "$PY_VER" ]]; then
    echo "✗ No suitable Python 3 found. Please install Python 3.10 or newer."
    exit 1
fi
VENV_DIR="$HOME/.node-build-env-py${PY_VER}"
PYTHON="$VENV_DIR/bin/python"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

handle_error() {
    local message="$1"
    if [[ "$TEST_MODE" == true ]]; then
        echo "⚠  $message (ignored — TEST_MODE=true)"
    else
        echo "✗ $message"
        exit 1
    fi
}

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "✗ Missing required command: $1"
        [[ "$TEST_MODE" == true ]] && echo "  (continuing due to TEST_MODE)" || exit 1
    fi
}

# ---------------------------------------------------------------------------
# Python virtualenv setup (node-gyp needs a compatible Python + distutils)
# ---------------------------------------------------------------------------

echo "▸ Setting up Python $PY_VER virtual environment for node-gyp compatibility..."
if [[ ! -d "$VENV_DIR" ]]; then
    PY_CMD="python${PY_VER}"
    # If the versioned command doesn't exist, fall back to python3
    command -v "$PY_CMD" &>/dev/null || PY_CMD="python3"
    "$PY_CMD" -m venv "$VENV_DIR"
fi
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip setuptools wheel

DISTUTILS_SHIM="$VENV_DIR/lib/python${PY_VER}/site-packages/distutils/__init__.py"
if [[ ! -f "$DISTUTILS_SHIM" ]]; then
    mkdir -p "$(dirname "$DISTUTILS_SHIM")"
    cat > "$DISTUTILS_SHIM" <<'SHIM'
import setuptools._distutils as distutils
globals().update(vars(distutils))
SHIM
fi

export PYTHON="$PYTHON"

# ---------------------------------------------------------------------------
# Required tool check
# ---------------------------------------------------------------------------

for cmd in curl 7z asar npm node; do
    require_cmd "$cmd"
done

# ---------------------------------------------------------------------------
# Prepare working directories
# ---------------------------------------------------------------------------

mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_DIR" "$REBUILD_DIR" "$APP_64_EXTRACT_DIR" "$WORK_DIR"

# ---------------------------------------------------------------------------
# Step 1 – Download installer
# ---------------------------------------------------------------------------

if [[ -f "$DOWNLOAD_DIR/$FILENAME" ]]; then
    echo "▸ Installer already downloaded, skipping download."
else
    echo "▸ Downloading $FILENAME..."
    if ! curl -L --progress-bar "$URL" -o "$DOWNLOAD_DIR/$FILENAME"; then
        handle_error "Download failed"
    fi
fi

# ---------------------------------------------------------------------------
# Step 2 – Extract Windows installer
# ---------------------------------------------------------------------------

if [[ -f "$APP_64_EXTRACT_DIR/resources/app.asar" ]]; then
    echo "▸ Already extracted, skipping extraction."
else
    echo "▸ Extracting $FILENAME..."
    if ! 7z x "$DOWNLOAD_DIR/$FILENAME" -o"$EXTRACT_DIR" -y > /dev/null; then
        handle_error "Failed to extract EXE"
    fi

    # Locate and copy app-64.7z
    APP_64_FILE=$(find "$EXTRACT_DIR" -type f -name "app-64.7z" | head -n 1 || true)
    if [[ -z "$APP_64_FILE" ]]; then
        handle_error "app-64.7z not found in extracted installer"
    else
        cp "$APP_64_FILE" "$REBUILD_DIR/"
    fi

    echo "▸ Extracting app-64.7z..."
    if ! 7z x "$REBUILD_DIR/app-64.7z" -o"$APP_64_EXTRACT_DIR" -y > /dev/null; then
        handle_error "Failed to extract app-64.7z"
    fi
fi

# ---------------------------------------------------------------------------
# Step 3 – Detect Electron version
# ---------------------------------------------------------------------------

# Allow manual override (e.g. ELECTRON_VERSION=40.10.6 ./input4linux-0.15.3.sh)
if [[ -n "${ELECTRON_VERSION:-}" ]]; then
    echo "▸ Using provided Electron version: $ELECTRON_VERSION"
else
    ELECTRON_VERSION=""

    # Method 1: 'version' file — present in Linux/macOS Electron builds
    if [[ -f "$APP_64_EXTRACT_DIR/version" ]]; then
        ELECTRON_VERSION=$(tr -d 'v \n\r' < "$APP_64_EXTRACT_DIR/version")
        echo "▸ Detected Electron version from version file: $ELECTRON_VERSION"
    fi

    # Method 2: Read the bundled Chrome version from a binary, then resolve
    #           to an Electron version via the official releases API.
    #           Windows builds don't ship a 'version' file, so this is the
    #           primary detection path when building from the Windows installer.
    if [[ -z "$ELECTRON_VERSION" ]] && command -v strings &>/dev/null; then
        CHROME_VER=""
        for bin in "$APP_64_EXTRACT_DIR/input.exe" "$APP_64_EXTRACT_DIR/libEGL.dll"; do
            if [[ -f "$bin" ]]; then
                CHROME_VER=$(strings "$bin" 2>/dev/null \
                    | grep -oE "Chrome/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" \
                    | head -1 | cut -d/ -f2 || true)
                [[ -n "$CHROME_VER" ]] && break
            fi
        done

        if [[ -n "$CHROME_VER" ]]; then
            echo "▸ Detected bundled Chrome $CHROME_VER — resolving Electron version..."
            ELECTRON_VERSION=$(curl -sSL "https://releases.electronjs.org/releases.json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data:
    v = r.get('version', '')
    if r.get('chrome') == '${CHROME_VER}' and not any(x in v for x in ('nightly', 'alpha', 'beta', 'rc')):
        print(v)
        break
" 2>/dev/null || true)
            [[ -n "$ELECTRON_VERSION" ]] && echo "▸ Resolved Electron $ELECTRON_VERSION"
        fi
    fi

    if [[ -z "$ELECTRON_VERSION" ]]; then
        echo "✗ Could not auto-detect Electron version."
        echo "  Set ELECTRON_VERSION manually and re-run, for example:"
        echo "    ELECTRON_VERSION=40.10.6 ./input4linux-0.15.3.sh"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 4 – Unpack app.asar
# ---------------------------------------------------------------------------

RESOURCES_DIR="$APP_64_EXTRACT_DIR/resources"
ASAR_FILE="$RESOURCES_DIR/app.asar"

if [[ ! -f "$ASAR_FILE" ]]; then
    handle_error "app.asar not found at $ASAR_FILE"
fi

echo "▸ Unpacking app.asar..."
UNPACKED_DIR="$WORK_DIR/app"
mkdir -p "$UNPACKED_DIR"
if ! asar extract "$ASAR_FILE" "$UNPACKED_DIR"; then
    handle_error "Failed to unpack app.asar"
fi

# Also copy any unpacked native modules from app.asar.unpacked if present
ASAR_UNPACKED="$RESOURCES_DIR/app.asar.unpacked"
if [[ -d "$ASAR_UNPACKED" ]]; then
    echo "▸ Merging app.asar.unpacked into work directory..."
    cp -a "$ASAR_UNPACKED/." "$UNPACKED_DIR/"
fi

# ---------------------------------------------------------------------------
# Step 5 – Patch dist-electron/main/index.js (prepend Linux preamble)
# ---------------------------------------------------------------------------

ORIGINAL_INDEX="$UNPACKED_DIR/dist-electron/main/index.js"

if [[ ! -f "$ORIGINAL_INDEX" ]]; then
    handle_error "dist-electron/main/index.js not found in unpacked asar"
fi

echo "▸ Patching dist-electron/main/index.js with Linux preamble..."
TEMP_INDEX="${ORIGINAL_INDEX}.orig"
cp "$ORIGINAL_INDEX" "$TEMP_INDEX"
{
    printf '%s\n' "$LINUX_PREAMBLE"
    cat "$TEMP_INDEX"
} > "$ORIGINAL_INDEX"
rm "$TEMP_INDEX"

# ---------------------------------------------------------------------------
# Step 6 – Apply patch files (except dist-electron/main/index.js and
#           package.json — those are handled separately)
# ---------------------------------------------------------------------------

if [[ -d "$PATCH_DIR" ]]; then
    echo "▸ Applying patch files from $PATCH_DIR..."

    # Copy everything except dist-electron/main/index.js and package.json
    find "$PATCH_DIR" -type f \
        ! -path "$PATCH_DIR/dist-electron/main/index.js" \
        ! -path "$PATCH_DIR/package.json" \
        | while IFS= read -r src; do
            rel="${src#$PATCH_DIR/}"
            dest="$UNPACKED_DIR/$rel"
            mkdir -p "$(dirname "$dest")"
            cp "$src" "$dest"
        done

    if [[ -f "$UNPACKED_DIR/AppRun" ]]; then
        chmod +x "$UNPACKED_DIR/AppRun"
    fi
fi

# ---------------------------------------------------------------------------
# Step 7 – Merge electron-builder config into app's package.json
# ---------------------------------------------------------------------------

echo "▸ Merging electron-builder build config into package.json..."
PATCH_PKG="$PATCH_DIR/package.json"
APP_PKG="$UNPACKED_DIR/package.json"

if [[ ! -f "$PATCH_PKG" ]]; then
    handle_error "patch/package.json not found"
fi

# Use node to merge: keep original app deps, add/override build config and version
node - "$APP_PKG" "$PATCH_PKG" "$COMMUNITY_VERSION" << 'NODE_EOF'
const fs = require('fs');
const [, , appPkgPath, patchPkgPath, communityVersion] = process.argv;

const appPkg   = JSON.parse(fs.readFileSync(appPkgPath,   'utf8'));
const patchPkg = JSON.parse(fs.readFileSync(patchPkgPath, 'utf8'));

// Override fields from patch
appPkg.name        = patchPkg.name        || appPkg.name;
appPkg.version     = communityVersion;
appPkg.description = patchPkg.description || appPkg.description;
appPkg.author      = patchPkg.author      || appPkg.author;
appPkg.private     = true;

// Carry over scripts needed for building
appPkg.scripts = Object.assign({}, appPkg.scripts, patchPkg.scripts);

// Merge devDependencies (patch overrides app for same keys)
appPkg.devDependencies = Object.assign(
    {},
    appPkg.devDependencies || {},
    patchPkg.devDependencies || {}
);

// Add electron-builder for the build step (electron-rebuild is not used
// since all native modules ship N-API prebuilts and don't need recompiling)
appPkg.devDependencies['electron-builder'] =
    appPkg.devDependencies['electron-builder'] || '^26.0.12';

// Electron version: use the one detected from the installer (passed via env)
if (process.env.ELECTRON_VERSION) {
    appPkg.devDependencies['electron'] = process.env.ELECTRON_VERSION;
}

// Apply the full electron-builder configuration from the patch
appPkg.build = patchPkg.build;

fs.writeFileSync(appPkgPath, JSON.stringify(appPkg, null, 2) + '\n');
console.log('package.json merged successfully.');
NODE_EOF

# ---------------------------------------------------------------------------
# Step 8 – Install dependencies and rebuild native modules
# ---------------------------------------------------------------------------

echo "▸ Installing dependencies (this may take a while)..."
(
    cd "$UNPACKED_DIR"

    # Install JS dependencies without running native-module build scripts.
    # Most native modules ship N-API prebuilts. The exception is
    # electron-edge-js which has no Linux prebuilts and must be compiled
    # from source (handled explicitly below).
    ELECTRON_VERSION="$ELECTRON_VERSION" npm install --ignore-scripts \
        || handle_error "npm install failed"

    # Pin electron to exact detected version
    npm install --ignore-scripts --save-dev "electron@${ELECTRON_VERSION}" \
        || handle_error "Failed to install electron"

    # Set up native module prebuilts.
    # Most native modules ship platform-specific N-API prebuilt binaries which
    # are ABI-stable and work with both Node.js and Electron without recompiling.
    echo "▸ Setting up native module prebuilts..."

    # node-hid: uses pkg-prebuilds to install the bundled N-API prebuilt
    (cd node_modules/node-hid && npx pkg-prebuilds-verify ./binding-options.js) \
        || handle_error "node-hid prebuilt setup failed"

    # lzma-native: uses node-gyp-build which copies the bundled prebuilt
    (cd node_modules/lzma-native && npx node-gyp-build) \
        || echo "▸ lzma-native prebuilt not set up (non-fatal, loads at runtime)"

    # @serialport/bindings-cpp: uses node-gyp-build at runtime — no setup needed

    # electron-edge-js: ships no Linux prebuilt — must compile edge_coreclr.node
    # from source using node-gyp against Electron headers.
    # The existing node_modules/electron-edge-js comes from the Windows app.asar
    # and doesn't include binding.gyp or source files. Remove it and reinstall
    # fresh from npm to get all sources, then compile.
    #
    # Build CoreCLR-only: set PKG_CONFIG_LIBDIR to an empty directory so that
    # pkg-config mono-2 fails. binding.gyp only links libmonosgen-2.0 when BOTH
    # `which mono` AND `pkg-config mono-2 --libs` succeed. Preventing pkg-config
    # from finding mono-2.pc ensures the resulting .node file has no
    # libmonosgen-2.0.so.1 dependency — which most users don't have installed.
    # Also remove edge_nativeclr.node after build: binding.gyp still compiles it
    # when `which mono` succeeds (even without pkg-config). edge.js picks
    # edge_nativeclr.node over edge_coreclr.node when it exists, so we delete it
    # to force the CoreCLR path. AppRun also sets EDGE_USE_CORECLR=1 as a runtime
    # safety net.
    echo "▸ Building electron-edge-js for Electron ${ELECTRON_VERSION} (CoreCLR only)..."
    (
        rm -rf node_modules/electron-edge-js
        npm install --ignore-scripts electron-edge-js \
            || handle_error "electron-edge-js reinstall failed"
        cd node_modules/electron-edge-js
        FAKE_PC=$(mktemp -d)
        HOME=~/.electron-gyp PKG_CONFIG_LIBDIR="$FAKE_PC" npx node-gyp rebuild \
            --target="${ELECTRON_VERSION}" \
            --arch=x64 \
            --dist-url=https://electronjs.org/headers
        rm -rf "$FAKE_PC"
        # Remove the Mono-based native CLR module if compiled: it can't work
        # without libmonosgen installed, and edge.js prefers it over edge_coreclr.
        rm -f build/Release/edge_nativeclr.node
    ) || handle_error "electron-edge-js build failed"
    echo "▸ electron-edge-js built successfully"

    # electron-builder excludes .dll files on non-Windows platforms.
    # Copy all compiled bootstrap/EdgeJs DLLs to a staging directory outside
    # node_modules so they survive any electron-builder file filtering. They are
    # brought back into the AppImage at the exact runtime path via extraFiles.
    echo "▸ Stashing bootstrap DLLs for AppImage packaging..."
    rm -rf electron-edge-bootstrap
    mkdir -p electron-edge-bootstrap/lib-bootstrap \
              electron-edge-bootstrap/lib-double
    # All files from bootstrap output dir (bootstrap.dll, bootstrap.runtimeconfig.json,
    # EdgeJs.dll that dotnet copied there, plus any other .dll/.json files)
    cp node_modules/electron-edge-js/lib/bootstrap/bin/Release/* \
       electron-edge-bootstrap/lib-bootstrap/ 2>/dev/null || true
    # EdgeJs.dll from the double bridge build
    find node_modules/electron-edge-js/src/double -name "*.dll" \
         -exec cp {} electron-edge-bootstrap/lib-double/ \; 2>/dev/null || true
    echo "  Bootstrap stash contents:"
    ls -lh electron-edge-bootstrap/lib-bootstrap/ 2>/dev/null || echo "  (empty — DLLs may be missing)"
    ls -lh electron-edge-bootstrap/lib-double/ 2>/dev/null || true

    # bootstrap.runtimeconfig.json is only generated for executable (.exe) projects.
    # bootstrap.csproj is a class library, so dotnet never creates it.
    # Without this file, coreclrembedding.cpp fails with "Could not find any
    # runtimeconfig file". Create a minimal one targeting net8.0.
    if [ ! -f electron-edge-bootstrap/lib-bootstrap/bootstrap.runtimeconfig.json ]; then
        echo "▸ Creating bootstrap.runtimeconfig.json (not generated for library targets)..."
        cat > electron-edge-bootstrap/lib-bootstrap/bootstrap.runtimeconfig.json << 'RUNTIMECONFIG'
{
  "runtimeOptions": {
    "tfm": "net8.0",
    "framework": {
      "name": "Microsoft.NETCore.App",
      "version": "8.0.0"
    }
  }
}
RUNTIMECONFIG
    fi
)

# ---------------------------------------------------------------------------
# Step 9 – Build AppImage with electron-builder
# ---------------------------------------------------------------------------

echo "▸ Building AppImage..."
(
    cd "$UNPACKED_DIR"
    npx electron-builder --linux AppImage --publish never || handle_error "electron-builder failed"
)

# ---------------------------------------------------------------------------
# Step 10 – Move AppImage to repo root
# ---------------------------------------------------------------------------

BUILT_APPIMAGE=$(find "$UNPACKED_DIR/release" -name "*.AppImage" | head -n 1 || true)

if [[ -z "$BUILT_APPIMAGE" ]]; then
    handle_error "No AppImage found in $UNPACKED_DIR/release — build may have failed"
else
    # Remove any existing output file
    [[ -f "$OUTPUT_APPIMAGE" ]] && rm -f "$OUTPUT_APPIMAGE"
    mv "$BUILT_APPIMAGE" "$OUTPUT_APPIMAGE"
    chmod +x "$OUTPUT_APPIMAGE"
    echo ""
    echo "✓ AppImage built successfully:"
    echo "  $OUTPUT_APPIMAGE"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

echo "▸ Cleaning up temporary files..."
rm -rf "$DOWNLOAD_DIR" "$EXTRACT_DIR" "$REBUILD_DIR" "$WORK_DIR"

echo ""
echo "Done! Run the app with:"
echo "  $OUTPUT_APPIMAGE"
