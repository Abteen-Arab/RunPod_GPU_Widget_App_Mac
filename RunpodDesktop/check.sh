#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${RUNPOD_BUILD_DIR:-$(dirname "$ROOT")/.build}"
CACHE="${RUNPOD_TEST_MODULE_CACHE:-$BUILD/test-module-cache}"
mkdir -p "$BUILD" "$CACHE"
TEST_BUILD="$(mktemp -d "$BUILD/checks.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
SDK="$(xcrun --show-sdk-path)"
FLAGS=(-sdk "$SDK" -module-cache-path "$CACHE" -parse-as-library)

# Mirror the build's local workaround for duplicate SwiftBridging modules.
SWIFT_INCLUDE="$(xcrun --find swiftc)"
SWIFT_INCLUDE="$(dirname "$(dirname "$SWIFT_INCLUDE")")/include/swift"
if [ -f "$SWIFT_INCLUDE/bridging.modulemap" ] && [ -f "$SWIFT_INCLUDE/module.modulemap" ]; then
    if /usr/bin/grep -q 'module SwiftBridging' "$SWIFT_INCLUDE/bridging.modulemap" && /usr/bin/grep -q 'module SwiftBridging' "$SWIFT_INCLUDE/module.modulemap"; then
        printf '// Duplicate module intentionally hidden for these checks.\n' > "$TEST_BUILD/empty.modulemap"
        /usr/bin/python3 - "$SWIFT_INCLUDE/module.modulemap" "$TEST_BUILD/empty.modulemap" "$TEST_BUILD/toolchain-overlay.json" <<'PY'
import json, sys
with open(sys.argv[3], "w") as destination:
    json.dump({"version": 0, "roots": [{"type": "file", "name": sys.argv[1], "external-contents": sys.argv[2]}]}, destination)
PY
        FLAGS+=(-vfsoverlay "$TEST_BUILD/toolchain-overlay.json")
    fi
fi

echo "Checking Runpod data and estimates…"
xcrun swiftc "${FLAGS[@]}" "$ROOT/Shared/RunpodCore.swift" "$ROOT/Tests/RunpodCoreTests.swift" -o "$TEST_BUILD/core-tests"
"$TEST_BUILD/core-tests"

TEST_APP="$TEST_BUILD/WidgetBridgeTests.app"
mkdir -p "$TEST_APP/Contents/MacOS"
# Never compile or read the real BridgeConfiguration.swift for these checks.
/usr/bin/python3 - "$TEST_APP" "$TEST_BUILD/BridgeConfiguration.swift" <<'PY'
from pathlib import Path
import plistlib, secrets, sys, uuid
bundle = Path(sys.argv[1]) / "Contents"
identifier = "local.abteen.RunpodDesktop.Tests.run" + uuid.uuid4().hex
with (bundle / "Info.plist").open("wb") as destination:
    plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleName": "WidgetBridgeTests",
                  "CFBundleExecutable": "WidgetBridgeTests", "CFBundlePackageType": "APPL"}, destination)
Path(sys.argv[2]).write_text('''import Foundation
enum BridgeConfiguration {
    static let port: UInt16 = {
        guard let value = ProcessInfo.processInfo.environment["RUNPOD_TEST_PORT"],
              let port = UInt16(value), port > 0 else { fatalError("Missing test bridge port") }
        return port
    }()
    static let token = "test-only-''' + secrets.token_hex(32) + '''"
}
enum WidgetBridgeTestConfiguration {
    static let bundleIdentifier = "''' + identifier + '''"
}
''')
PY

echo "Checking the widget and local bridge…"
xcrun swiftc "${FLAGS[@]}" -D RUNPOD_PROVIDER_TESTS \
    "$ROOT/Shared/RunpodCore.swift" "$ROOT/Shared/LocalBridge.swift" \
    "$ROOT/Shared/MonitorViews.swift" "$TEST_BUILD/BridgeConfiguration.swift" \
    "$ROOT/Widget/RunpodWidget.swift" "$ROOT/Tests/WidgetBridgeTests.swift" \
    -o "$TEST_APP/Contents/MacOS/WidgetBridgeTests"
# Pick a free loopback port immediately before execution. RUNPOD_TEST_PORT can
# override it; occupied ports fail here without contacting an installed app.
TEST_PORT="$(/usr/bin/python3 - "${RUNPOD_TEST_PORT:-0}" <<'PY'
import socket, sys
try:
    port = int(sys.argv[1])
    if not 0 <= port <= 65535 or port == 47361:
        raise ValueError("Use port 0 or an available port other than the app's default 47361")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", port))
        print(listener.getsockname()[1])
except (ValueError, OSError) as error:
    raise SystemExit("Cannot select test bridge port: " + str(error))
PY
)"
RUNPOD_TEST_PORT="$TEST_PORT" "$TEST_APP/Contents/MacOS/WidgetBridgeTests"
