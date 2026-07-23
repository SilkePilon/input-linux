#!/bin/bash
set -euo pipefail

APPIMAGE="${1:-}"
if [[ -z "$APPIMAGE" ]]; then
    APPIMAGE=$(ls -t Input-*.AppImage 2>/dev/null | head -n1 || true)
fi

if [[ -z "$APPIMAGE" || ! -f "$APPIMAGE" ]]; then
    echo "✗ No AppImage to test. Build one first, or pass a path." >&2
    exit 1
fi

chmod +x "$APPIMAGE"

TIMEOUT_S="${SMOKE_TEST_TIMEOUT_S:-120}"

runner=(timeout --signal=KILL "$TIMEOUT_S")
if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    if ! command -v xvfb-run &>/dev/null; then
        echo "✗ No display and xvfb-run is not installed." >&2
        exit 1
    fi
    runner+=(xvfb-run -a)
fi

echo "▸ Smoke-testing $APPIMAGE..."
set +e
INPUT_SMOKE_TEST=1 \
INPUT_SMOKE_TEST_SCREENSHOT="${SMOKE_TEST_SCREENSHOT:-$PWD/smoke-test.png}" \
    "${runner[@]}" "./$APPIMAGE" --no-sandbox 2>&1 | tee smoke-test.log
status=${PIPESTATUS[1]}
set -e

echo ""
if grep -q '^SMOKE_TEST_OK' smoke-test.log; then
    grep -E '^SMOKE_TEST_(DETAILS|WARNING)' smoke-test.log || true
    echo "✓ Smoke test passed."
    exit 0
fi

echo "✗ Smoke test failed (exit status $status)."
grep -E '^SMOKE_TEST_(FAIL|PROBLEM|DETAILS)' smoke-test.log || \
    echo "  The harness produced no verdict — see smoke-test.log."
exit 1
