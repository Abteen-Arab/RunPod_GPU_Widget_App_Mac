#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${RUNPOD_BUILD_DIR:-$(dirname "$ROOT")/.build}"
OUTPUT="${1:-$BUILD/previews}"
if [ ! -f "$ROOT/Shared/BridgeConfiguration.swift" ]; then
    echo "Build the app with bash RunpodDesktop/build.sh first."
    exit 1
fi
mkdir -p "$BUILD/preview-module-cache" "$OUTPUT"
FLAGS=(-sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 -module-cache-path "$BUILD/preview-module-cache" -parse-as-library -D RUNPOD_PREVIEW)
if [ -f "$BUILD/toolchain-overlay.json" ]; then FLAGS+=(-vfsoverlay "$BUILD/toolchain-overlay.json"); fi
xcrun swiftc "${FLAGS[@]}" \
    "$ROOT/Shared/RunpodCore.swift" "$ROOT/Shared/BridgeConfiguration.swift" \
    "$ROOT/Shared/LocalBridge.swift" "$ROOT/Shared/MonitorViews.swift" \
    "$ROOT/App/RunpodDesktopApp.swift" "$ROOT/Tools/RenderPreviews.swift" \
    -o "$BUILD/render-previews"
"$BUILD/render-previews" "$OUTPUT"
