#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${RUNPOD_BUILD_DIR:-$ROOT/../../work/runpod-build}"
DEST="${RUNPOD_OUTPUT_DIR:-$(dirname "$ROOT")}"
APP="$BUILD/Runpod Desktop.app"
EXT="$APP/Contents/PlugIns/RunpodWidget.appex"
CACHE="${RUNPOD_MODULE_CACHE:-$BUILD/module-cache}"
mkdir -p "$CACHE" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS" "$DEST"
SDK="$(xcrun --show-sdk-path)"
FLAGS=(-sdk "$SDK" -target arm64-apple-macos14.0 -module-cache-path "$CACHE" -parse-as-library -O)

# Some CLT installations ship the SwiftBridging module twice. Mask only the
# duplicate through a local, read-only compiler overlay; system files are untouched.
SWIFT_INCLUDE="$(xcrun --find swiftc)"
SWIFT_INCLUDE="$(dirname "$(dirname "$SWIFT_INCLUDE")")/include/swift"
if [ -f "$SWIFT_INCLUDE/bridging.modulemap" ] && [ -f "$SWIFT_INCLUDE/module.modulemap" ]; then
    if /usr/bin/grep -q 'module SwiftBridging' "$SWIFT_INCLUDE/bridging.modulemap" && /usr/bin/grep -q 'module SwiftBridging' "$SWIFT_INCLUDE/module.modulemap"; then
        printf '// Duplicate module intentionally hidden for this build.\n' > "$BUILD/empty.modulemap"
        /usr/bin/python3 - "$SWIFT_INCLUDE/module.modulemap" "$BUILD/empty.modulemap" "$BUILD/toolchain-overlay.json" <<'PY'
import json, sys
with open(sys.argv[3], "w") as destination:
    json.dump({"version": 0, "roots": [{"type": "file", "name": sys.argv[1], "external-contents": sys.argv[2]}]}, destination)
PY
        FLAGS+=(-vfsoverlay "$BUILD/toolchain-overlay.json")
    fi
fi

if [ ! -f "$ROOT/Shared/BridgeConfiguration.swift" ]; then
    TOKEN="$(/usr/bin/openssl rand -hex 32)"
    cat > "$ROOT/Shared/BridgeConfiguration.swift" <<EOF
enum BridgeConfiguration {
    static let port: UInt16 = 47361
    static let token = "$TOKEN"
}
EOF
fi
COMMON=("$ROOT/Shared/RunpodCore.swift" "$ROOT/Shared/LocalBridge.swift" "$ROOT/Shared/BridgeConfiguration.swift" "$ROOT/Shared/MonitorViews.swift")
echo "Building Runpod Desktop…"
xcrun swiftc "${FLAGS[@]}" -module-name RunpodDesktop "${COMMON[@]}" "$ROOT/App/RunpodDesktopApp.swift" -o "$APP/Contents/MacOS/RunpodDesktop"
echo "Building the desktop widget…"
xcrun swiftc "${FLAGS[@]}" -application-extension -module-name RunpodWidget "${COMMON[@]}" "$ROOT/Widget/RunpodWidget.swift" -o "$EXT/Contents/MacOS/RunpodWidget"
cp "$ROOT/Resources/App-Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Widget-Info.plist" "$EXT/Contents/Info.plist"
if [ -f "$ROOT/Resources/Runpod.icns" ]; then cp "$ROOT/Resources/Runpod.icns" "$APP/Contents/Resources/Runpod.icns"; fi
codesign --force --sign - --entitlements "$ROOT/Resources/Widget.entitlements" "$EXT"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto "$APP" "$DEST/Runpod Desktop.app"
echo "Built: $DEST/Runpod Desktop.app"
