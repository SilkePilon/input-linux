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

# Udev popup fragments injected into dist/index.html (Step 5b).
# These are absolute paths so they remain valid after `cd "$UNPACKED_DIR"`.
HEAD_FRAG="$PATCH_DIR/dist/index-head-fragment.html"
BODY_FRAG="$PATCH_DIR/dist/index-body-fragment.html"

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

    # Copy everything except dist-electron/main/index.js, package.json,
    # and dist/index.html — those are handled by dedicated patch steps
    # below (dist/index.html is injected, not overwritten, so that the
    # version-specific <script>/<link> asset hashes from the original
    # app are preserved).
    find "$PATCH_DIR" -type f \
        ! -path "$PATCH_DIR/dist-electron/main/index.js" \
        ! -path "$PATCH_DIR/package.json" \
        ! -path "$PATCH_DIR/dist/index.html" \
        ! -path "$PATCH_DIR/dist/index-head-fragment.html" \
        ! -path "$PATCH_DIR/dist/index-body-fragment.html" \
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
# Step 5b – Inject udev popup into dist/index.html
# ---------------------------------------------------------------------------
# The original dist/index.html shipped by each Input version references
# version-specific bundled asset filenames (e.g. main-B7BunvDx.js) via
# <script>/<link> tags. Overwriting it with a static patch copy breaks
# the app on any version whose asset hashes differ — the renderer JS
# never loads, contextBridge globals like `localStorageChannel` are
# never consumed, and the window stays blank.
#
# Instead, inject the udev popup <style> before </head> and the popup
# markup + <script> before </body> into the original index.html.
echo "▸ Injecting udev popup into dist/index.html..."
(
    cd "$UNPACKED_DIR"
    python3 - "dist/index.html" "$HEAD_FRAG" "$BODY_FRAG" << 'PYEOF'
import sys

index_path, head_frag_path, body_frag_path = sys.argv[1:4]

with open(index_path, "r", encoding="utf-8") as f:
    html = f.read()

with open(head_frag_path, "r", encoding="utf-8") as f:
    head_frag = f.read()

with open(body_frag_path, "r", encoding="utf-8") as f:
    body_frag = f.read()

if "</head>" not in html:
    print("  WARNING: no </head> tag found — head fragment not injected", file=sys.stderr)
else:
    html = html.replace("</head>", head_frag + "\n  </head>", 1)
    print("  Injected head fragment before </head>")

if "</body>" not in html:
    print("  WARNING: no </body> tag found — body fragment not injected", file=sys.stderr)
else:
    html = html.replace("</body>", body_frag + "\n  </body>", 1)
    print("  Injected body fragment before </body>")

with open(index_path, "w", encoding="utf-8") as f:
    f.write(html)
print("dist/index.html patched successfully (original asset references preserved)")
PYEOF
)

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
# Step 8b – Patch edge.js for graceful .NET absence
# ---------------------------------------------------------------------------
# edge_coreclr.node initializes the .NET CLR at dlopen time.  If .NET 8
# runtime is not installed on the user's machine the require() throws and
# crashes the whole Electron main process.
# The app already handles errors from .NET calls gracefully (the callbacks
# return undefined), so we only need to prevent the startup crash.
# Wrap require(edgeNative) in try/catch and make exports.func a no-op when
# edge failed to load.
echo "▸ Patching edge.js for graceful .NET absence handling..."
(
    cd "$UNPACKED_DIR"
    python3 - << 'PYEOF'
import sys

path = "node_modules/electron-edge-js/lib/edge.js"
with open(path, "r") as f:
    content = f.read()

# 1. Wrap require(edgeNative) in try/catch so startup doesn't crash when
#    the .NET 8 runtime is absent on the end-user's machine.
old1 = "if (process.versions['electron'] || process.versions['atom-shell'] || process.env.ELECTRON_RUN_AS_NODE) {\n    edge = require(edgeNative);\n}"
new1 = ("if (process.versions['electron'] || process.versions['atom-shell'] || process.env.ELECTRON_RUN_AS_NODE) {\n"
        "    try {\n"
        "        edge = require(edgeNative);\n"
        "    } catch(e) {\n"
        "        if (process.env.EDGE_DEBUG) {\n"
        "            console.warn('electron-edge-js: .NET runtime not available, C# interop disabled:', e.message);\n"
        "        }\n"
        "    }\n"
        "}")
if old1 in content:
    content = content.replace(old1, new1)
    print("  Patched: require(edgeNative) wrapped in try/catch")
else:
    print("  WARNING: Could not find require(edgeNative) block – skipping", file=sys.stderr)

# 2. Add a guard at the top of exports.func so calling hC.func() when edge
#    failed to load returns a callback-error instead of crashing.
old2 = "exports.func = function (language, options) {"
new2 = ("exports.func = function (language, options) {\n"
        "    if (!edge) {\n"
        "        return function(input, callback) {\n"
        "            if (typeof callback === 'function') {\n"
        "                callback(new Error('electron-edge-js: .NET runtime not available on this system'), null);\n"
        "            }\n"
        "        };\n"
        "    }")
if old2 in content:
    content = content.replace(old2, new2, 1)
    print("  Patched: exports.func guard added")
else:
    print("  WARNING: Could not find exports.func – skipping", file=sys.stderr)

with open(path, "w") as f:
    f.write(content)
print("edge.js patched successfully")
PYEOF
)

# ---------------------------------------------------------------------------
# Step 8c – Patch dist-electron/main/index.js for tray icon crash on Linux
# ---------------------------------------------------------------------------
# On Linux, Electron's nativeImage/Tray cannot decode the Windows .ico file
# used for the tray icon ("Error: Failed to load image from path
# '.../tray_icon.ico'"). new Tray() throws when given an empty/undecodable
# image, and that throw happens inside the async whenReady().then() startup
# callback as an *unhandled promise rejection* — which aborts the rest of
# that callback (theme sync, device search listeners, analytics "app start"
# event, etc.) without ever showing an error dialog. The main window is
# still created, but it never receives the initialization it depends on,
# which is what shows up to users as an app that "opens" to a white page.
#
# Fix:
#   1. Use the already-bundled tray_icon_Template.png (known-good PNG) on
#      Linux instead of the .ico, mirroring what's already done for macOS.
#   2. Defensively wrap the createNewTray() call in try/catch so a tray
#      icon failure can never again take down the rest of app startup.
echo "▸ Patching dist-electron/main/index.js to fix Linux tray icon crash..."
(
    cd "$UNPACKED_DIR"
    python3 - << 'PYEOF'
import sys

path = "dist-electron/main/index.js"
with open(path, "r") as f:
    content = f.read()

# 1. Use the PNG tray icon (already shipped for macOS) on every platform
#    except Windows, since Linux can't reliably decode the .ico file.
old1 = 'process.platform === "darwin" ? "tray_icon_Template.png" : "tray_icon.ico"'
new1 = 'process.platform === "win32" ? "tray_icon.ico" : "tray_icon_Template.png"'
if old1 in content:
    content = content.replace(old1, new1)
    print("  Patched: tray icon path uses PNG on non-Windows platforms")
else:
    print("  WARNING: Could not find tray icon path expression – skipping", file=sys.stderr)

# 2. Wrap the createNewTray() call in try/catch so a failure here can't
#    abort the rest of the startup callback (theme sync, device listeners,
#    analytics, etc.) via an unhandled promise rejection.
old2 = "y.get().trayService.createNewTray(),"
new2 = ("(() => { try { y.get().trayService.createNewTray(); } "
        "catch (trayErr) { console.error('|tray_service| failed to create tray: ' + trayErr); } })(),")
if old2 in content:
    content = content.replace(old2, new2, 1)
    print("  Patched: createNewTray() call wrapped in try/catch")
else:
    print("  WARNING: Could not find createNewTray() call – skipping", file=sys.stderr)

with open(path, "w") as f:
    f.write(content)
print("index.js tray patch applied successfully")
PYEOF
)

# ---------------------------------------------------------------------------
# Step 8d – Rename ESM preloads (.mjs) to CommonJS (.cjs)
# ---------------------------------------------------------------------------
# The app's package.json has "type": "module", which makes ALL .js files
# ESM. The preload scripts are .mjs (ESM by extension) and use
# `require("electron")` to get contextBridge/ipcRenderer, then call
# `contextBridge.exposeInMainWorld(...)` to expose IPC channels
# (localStorageChannel, commonChannel, etc.) to the renderer.
#
# Per the Electron ESM docs, sandboxed preload scripts (the default since
# Electron 20) are "run as plain JavaScript without an ESM context" and
# "Sandboxed preload scripts can't use ESM imports".  In Electron 40 on
# Linux, a .mjs preload in a sandboxed renderer silently fails to load —
# contextBridge.exposeInMainWorld never runs, so every channel global
# (localStorageChannel, commonChannel, fsChannel, etc.) is undefined in
# the renderer.  The renderer JS throws
# `ReferenceError: localStorageChannel is not defined` and the window stays
# blank/white.
#
# Fix: rename the .mjs preloads to .cjs (CommonJS).  The .cjs extension
# forces CommonJS interpretation regardless of "type": "module", so
# `require("electron")` works and contextBridge.exposeInMainWorld runs
# successfully.  Update the path references in dist-electron/main/index.js
# to match.
echo "▸ Renaming ESM preloads (.mjs → .cjs) to fix contextBridge exposure..."
(
    cd "$UNPACKED_DIR"
    python3 - << 'PYEOF'
import os
import sys

# 1. Rename preload files
renames = [
    ("dist-electron/preload/preload.mjs", "dist-electron/preload/preload.cjs"),
    ("dist-electron/preload/radial_menu_preload.mjs", "dist-electron/preload/radial_menu_preload.cjs"),
]
for old_name, new_name in renames:
    if os.path.exists(old_name):
        os.rename(old_name, new_name)
        print(f"  Renamed: {old_name} → {new_name}")
    else:
        print(f"  WARNING: {old_name} not found – skipping", file=sys.stderr)

# 2. Update path references in dist-electron/main/index.js
path = "dist-electron/main/index.js"
with open(path, "r") as f:
    content = f.read()

replacements = [
    ('"../preload/preload.mjs"', '"../preload/preload.cjs"'),
    ('"../preload/radial_menu_preload.mjs"', '"../preload/radial_menu_preload.cjs"'),
]
for old, new in replacements:
    if old in content:
        content = content.replace(old, new)
        print(f"  Updated: {old} → {new}")
    else:
        print(f"  WARNING: Could not find {old} – skipping", file=sys.stderr)

with open(path, "w") as f:
    f.write(content)
print("preload rename patch applied successfully")
PYEOF
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
