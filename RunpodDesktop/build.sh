#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${RUNPOD_BUILD_DIR:-$(dirname "$ROOT")/.build}"
DEST="${RUNPOD_OUTPUT_DIR:-$HOME/Applications}"
CACHE="${RUNPOD_MODULE_CACHE:-$BUILD/module-cache}"
# A unique build number per build keeps WidgetKit from validating against an older registration.
BUILD_NUMBER="${RUNPOD_BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"
STAGE="$BUILD/stage/Runpod Desktop.app"
EXT="$STAGE/Contents/PlugIns/RunpodWidget.appex"
INSTALLED="$DEST/Runpod Desktop.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Unregister stale staging records before replacing a bundle at that path.
"$LSREGISTER" -u "$STAGE" 2>/dev/null || true
rm -rf "$STAGE"
mkdir -p "$CACHE" "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$EXT/Contents/MacOS" "$DEST"
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
xcrun swiftc "${FLAGS[@]}" -module-name RunpodDesktop "${COMMON[@]}" "$ROOT/App/RunpodDesktopApp.swift" -o "$STAGE/Contents/MacOS/RunpodDesktop"
echo "Building the desktop widget…"
# Match Xcode's app-extension product type (DarwinProductTypes.xcspec): the
# executable must enter through NSExtensionMain. Swift's generated main returns
# on macOS 26 before an XPC run loop starts, so a plain executable exits before
# WidgetKit can even read its descriptors or list it in the gallery.
xcrun swiftc "${FLAGS[@]}" -application-extension \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -module-name RunpodWidget "${COMMON[@]}" "$ROOT/Widget/RunpodWidget.swift" \
    -o "$EXT/Contents/MacOS/RunpodWidget"
cp "$ROOT/Resources/App-Info.plist" "$STAGE/Contents/Info.plist"
cp "$ROOT/Resources/Widget-Info.plist" "$EXT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$EXT/Contents/Info.plist"
if [ -f "$ROOT/Resources/Runpod.icns" ]; then cp "$ROOT/Resources/Runpod.icns" "$STAGE/Contents/Resources/Runpod.icns"; fi
codesign --force --sign - --entitlements "$ROOT/Resources/Widget.entitlements" "$EXT"
codesign --force --sign - "$STAGE"
codesign --verify --deep --strict "$STAGE"

# Install exactly one copy. Several registered copies with the same bundle ID make
# WidgetKit reject the widget's timelines ("Bundle version did not match"), which shows as a blank widget.
echo "Installing to ${INSTALLED}…"
if /usr/bin/pgrep -x RunpodDesktop >/dev/null; then /usr/bin/pkill -x RunpodDesktop; sleep 1; fi
if /usr/bin/pgrep -x RunpodWidget >/dev/null; then /usr/bin/pkill -x RunpodWidget || true; fi
"$LSREGISTER" -u "$INSTALLED" 2>/dev/null || true
rm -rf "$INSTALLED"
ditto "$STAGE" "$INSTALLED"
"$LSREGISTER" -u "$STAGE" 2>/dev/null || true
rm -rf "$STAGE"
# Clean exact-ID registrations, including renamed backup apps. Keep those files intact.
/usr/bin/python3 "$ROOT/widget-doctor.py" "$INSTALLED" --repair
echo "Installed build $BUILD_NUMBER: $INSTALLED"
echo "Run: open \"$INSTALLED\""
