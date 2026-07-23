#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELECTRON_BIN="$SCRIPT_DIR/node_modules/.bin/electron"
SANDBOX="$SCRIPT_DIR/node_modules/electron/dist/chrome-sandbox"

if [[ -f "$SANDBOX" && ! -u "$SANDBOX" ]]; then
    echo "Fixing sandbox permissions..."
    sudo chown root:root "$SANDBOX"
    sudo chmod 4755 "$SANDBOX"
fi

"$ELECTRON_BIN" "$SCRIPT_DIR"
