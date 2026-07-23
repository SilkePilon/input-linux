#!/bin/bash
set -euo pipefail

TEST_MODE="${TEST_MODE:-false}"
UPSTREAM_REPO="${UPSTREAM_REPO:-worklouder/input-releases}"
CHANNEL="${CHANNEL:-stable}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/patch"

if [[ -z "${VERSION:-}" ]]; then
    echo "▸ Resolving latest ${CHANNEL} Input release from ${UPSTREAM_REPO}..."
    VERSION=$(UPSTREAM_REPO="$UPSTREAM_REPO" \
        python3 "$SCRIPT_DIR/scripts/upstream-releases.py" latest --channel "$CHANNEL") \
        || { echo "✗ Could not resolve latest ${CHANNEL} Input version from ${UPSTREAM_REPO}."; \
             echo "  Pin one manually:  VERSION=0.17.2 ./build-appimage.sh"; exit 1; }
    if [[ -z "$VERSION" ]]; then
        echo "✗ Version resolver returned nothing for channel '${CHANNEL}'."
        exit 1
    fi
    echo "▸ Latest ${CHANNEL} Input release: ${VERSION}"
else
    echo "▸ Using pinned Input version: ${VERSION}"
fi

COMMUNITY_VERSION="${VERSION}-Community"
URL="https://github.com/${UPSTREAM_REPO}/releases/download/v${VERSION}/input-Setup-${VERSION}.exe"
FILENAME="input-Setup-${VERSION}.exe"

DOWNLOAD_DIR="./input_download"
EXTRACT_DIR="./input_extracted"
REBUILD_DIR="./input_rebuild"
APP_64_EXTRACT_DIR="$REBUILD_DIR/app-64"
WORK_DIR="./input_work"

OUTPUT_APPIMAGE="./Input-${COMMUNITY_VERSION}.AppImage"

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

echo "▸ Setting up Python $PY_VER virtual environment for node-gyp compatibility..."
if [[ ! -d "$VENV_DIR" ]]; then
    PY_CMD="python${PY_VER}"
    command -v "$PY_CMD" &>/dev/null || PY_CMD="python3"
    "$PY_CMD" -m venv "$VENV_DIR"
fi
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

for cmd in curl 7z asar npm node; do
    require_cmd "$cmd"
done

if ! command -v dotnet &>/dev/null && [[ -x "$HOME/.dotnet/dotnet" ]]; then
    export PATH="$HOME/.dotnet:$PATH"
    export DOTNET_ROOT="$HOME/.dotnet"
fi
if ! command -v dotnet &>/dev/null; then
    echo "✗ Missing required command: dotnet (.NET 8 SDK)"
    echo "  Install without root:"
    echo "    curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0"
    [[ "$TEST_MODE" == true ]] && echo "  (continuing due to TEST_MODE)" || exit 1
fi

mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_DIR" "$REBUILD_DIR" "$APP_64_EXTRACT_DIR" "$WORK_DIR"

if [[ -f "$DOWNLOAD_DIR/$FILENAME" ]]; then
    echo "▸ Installer already downloaded, skipping download."
else
    echo "▸ Downloading $FILENAME..."
    if ! curl -L --progress-bar "$URL" -o "$DOWNLOAD_DIR/$FILENAME"; then
        handle_error "Download failed"
    fi
fi

if [[ -f "$APP_64_EXTRACT_DIR/resources/app.asar" ]]; then
    echo "▸ Already extracted, skipping extraction."
else
    echo "▸ Extracting $FILENAME..."
    if ! 7z x "$DOWNLOAD_DIR/$FILENAME" -o"$EXTRACT_DIR" -y > /dev/null; then
        handle_error "Failed to extract EXE"
    fi

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

if [[ -n "${ELECTRON_VERSION:-}" ]]; then
    echo "▸ Using provided Electron version: $ELECTRON_VERSION"
else
    ELECTRON_VERSION=""

    if [[ -f "$APP_64_EXTRACT_DIR/version" ]]; then
        ELECTRON_VERSION=$(tr -d 'v \n\r' < "$APP_64_EXTRACT_DIR/version")
        echo "▸ Detected Electron version from version file: $ELECTRON_VERSION"
    fi

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
        echo "    ELECTRON_VERSION=40.10.6 ./build-appimage.sh"
        exit 1
    fi
fi

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

ASAR_UNPACKED="$RESOURCES_DIR/app.asar.unpacked"
if [[ -d "$ASAR_UNPACKED" ]]; then
    echo "▸ Merging app.asar.unpacked into work directory..."
    cp -a "$ASAR_UNPACKED/." "$UNPACKED_DIR/"
fi

ORIGINAL_INDEX="$UNPACKED_DIR/dist-electron/main/index.js"
if [[ ! -f "$ORIGINAL_INDEX" ]]; then
    handle_error "dist-electron/main/index.js not found in unpacked asar"
fi

if [[ -d "$PATCH_DIR" ]]; then
    echo "▸ Applying patch files from $PATCH_DIR..."

    find "$PATCH_DIR" -type f \
        ! -path "$PATCH_DIR/dist-electron/main/index.js" \
        ! -path "$PATCH_DIR/package.json" \
        ! -path "$PATCH_DIR/dist/index.html" \
        ! -name "index-head-*.html" \
        ! -name "index-body-*.html" \
        ! -name "window-controls-preload.cjs" \
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

echo "▸ Merging electron-builder build config into package.json..."
PATCH_PKG="$PATCH_DIR/package.json"
APP_PKG="$UNPACKED_DIR/package.json"

if [[ ! -f "$PATCH_PKG" ]]; then
    handle_error "patch/package.json not found"
fi

node - "$APP_PKG" "$PATCH_PKG" "$COMMUNITY_VERSION" << 'NODE_EOF'
const fs = require('fs');
const [, , appPkgPath, patchPkgPath, communityVersion] = process.argv;

const appPkg   = JSON.parse(fs.readFileSync(appPkgPath,   'utf8'));
const patchPkg = JSON.parse(fs.readFileSync(patchPkgPath, 'utf8'));

appPkg.name        = patchPkg.name        || appPkg.name;
appPkg.version     = communityVersion;
appPkg.description = patchPkg.description || appPkg.description;
appPkg.author      = patchPkg.author      || appPkg.author;
appPkg.private     = true;

appPkg.scripts = Object.assign({}, appPkg.scripts, patchPkg.scripts);

appPkg.devDependencies = Object.assign(
    {},
    appPkg.devDependencies || {},
    patchPkg.devDependencies || {}
);

appPkg.devDependencies['electron-builder'] =
    appPkg.devDependencies['electron-builder'] || '^26.0.12';

if (process.env.ELECTRON_VERSION) {
    appPkg.devDependencies['electron'] = process.env.ELECTRON_VERSION;
}

appPkg.build = patchPkg.build;

const releaseRepo = process.env.RELEASE_REPO || process.env.GITHUB_REPOSITORY;
if (releaseRepo && releaseRepo.includes('/')) {
    const [owner, repo] = releaseRepo.split('/');
    appPkg.build.publish = [{ provider: 'github', owner, repo }];
    console.log(`publish target set to ${owner}/${repo}`);
}

fs.writeFileSync(appPkgPath, JSON.stringify(appPkg, null, 2) + '\n');
console.log('package.json merged successfully.');
NODE_EOF

echo "▸ Installing dependencies (this may take a while)..."
(
    cd "$UNPACKED_DIR"

    ELECTRON_VERSION="$ELECTRON_VERSION" npm install --ignore-scripts \
        || handle_error "npm install failed"

    npm install --ignore-scripts --save-dev "electron@${ELECTRON_VERSION}" \
        || handle_error "Failed to install electron"

    echo "▸ Setting up native module prebuilts..."

    (cd node_modules/node-hid && npx pkg-prebuilds-verify ./binding-options.js) \
        || handle_error "node-hid prebuilt setup failed"

    (cd node_modules/lzma-native && npx node-gyp-build) \
        || echo "▸ lzma-native prebuilt not set up (non-fatal, loads at runtime)"

    echo "▸ Building electron-edge-js for Electron ${ELECTRON_VERSION} (CoreCLR only)..."
    (
        rm -rf node_modules/electron-edge-js
        npm install --ignore-scripts electron-edge-js \
            || handle_error "electron-edge-js reinstall failed"
        cd node_modules/electron-edge-js
        PKG_CONFIG_DIR_WITHOUT_MONO=$(mktemp -d)
        HOME=~/.electron-gyp PKG_CONFIG_LIBDIR="$PKG_CONFIG_DIR_WITHOUT_MONO" npx node-gyp rebuild \
            --target="${ELECTRON_VERSION}" \
            --arch=x64 \
            --dist-url=https://electronjs.org/headers
        rm -rf "$PKG_CONFIG_DIR_WITHOUT_MONO"
        rm -f build/Release/edge_nativeclr.node
    ) || handle_error "electron-edge-js build failed"
    echo "▸ electron-edge-js built successfully"

    echo "▸ Stashing bootstrap DLLs for AppImage packaging..."
    rm -rf electron-edge-bootstrap
    mkdir -p electron-edge-bootstrap/lib-bootstrap \
              electron-edge-bootstrap/lib-double
    cp node_modules/electron-edge-js/lib/bootstrap/bin/Release/* \
       electron-edge-bootstrap/lib-bootstrap/ 2>/dev/null || true
    find node_modules/electron-edge-js/src/double -name "*.dll" \
         -exec cp {} electron-edge-bootstrap/lib-double/ \; 2>/dev/null || true
    echo "  Bootstrap stash contents:"
    ls -lh electron-edge-bootstrap/lib-bootstrap/ 2>/dev/null || echo "  (empty — DLLs may be missing)"
    ls -lh electron-edge-bootstrap/lib-double/ 2>/dev/null || true

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

echo "▸ Applying Linux compatibility patches..."
python3 "$SCRIPT_DIR/scripts/patch-app.py" "$UNPACKED_DIR" "$PATCH_DIR" \
    || handle_error "Linux compatibility patches failed to apply"

echo "▸ Building AppImage..."
(
    cd "$UNPACKED_DIR"
    npx electron-builder --linux AppImage --publish never || handle_error "electron-builder failed"
)

BUILT_APPIMAGE=$(find "$UNPACKED_DIR/release" -name "*.AppImage" | head -n 1 || true)

if [[ -z "$BUILT_APPIMAGE" ]]; then
    handle_error "No AppImage found in $UNPACKED_DIR/release — build may have failed"
else
    [[ -f "$OUTPUT_APPIMAGE" ]] && rm -f "$OUTPUT_APPIMAGE"
    mv "$BUILT_APPIMAGE" "$OUTPUT_APPIMAGE"
    chmod +x "$OUTPUT_APPIMAGE"
    echo ""
    echo "✓ AppImage built successfully:"
    echo "  $OUTPUT_APPIMAGE"
fi

BUILT_MANIFEST="$UNPACKED_DIR/release/latest-linux.yml"
if [[ -f "$BUILT_MANIFEST" ]]; then
    cp "$BUILT_MANIFEST" ./latest-linux.yml
    echo "  ./latest-linux.yml (update manifest — publish it with the AppImage)"
else
    echo "⚠  latest-linux.yml was not generated; in-app updates will not work."
fi

if [[ "${SKIP_SMOKE_TEST:-false}" == true ]]; then
    echo "▸ Skipping smoke test (SKIP_SMOKE_TEST=true)."
elif [[ -f "$OUTPUT_APPIMAGE" ]]; then
    bash "$SCRIPT_DIR/scripts/smoke-test.sh" "$OUTPUT_APPIMAGE" \
        || handle_error "Smoke test failed — the AppImage does not start correctly"
fi

if [[ "${KEEP_BUILD_DIRS:-false}" == true ]]; then
    echo "▸ Keeping temporary build directories (KEEP_BUILD_DIRS=true)."
else
    echo "▸ Cleaning up temporary files..."
    rm -rf "$DOWNLOAD_DIR" "$EXTRACT_DIR" "$REBUILD_DIR" "$WORK_DIR"
fi

echo ""
echo "Done! Run the app with:"
echo "  $OUTPUT_APPIMAGE"
