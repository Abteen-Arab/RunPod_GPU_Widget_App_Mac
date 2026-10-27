# Runpod Desktop

A native macOS app and desktop widget for keeping an eye on your Runpod GPU pods, account balance, and estimated credit time remaining.

![Runpod Desktop widget previews with sample data](RunpodWidgetPreview.png)

## Features

- Account balance, current hourly spend, and estimated hours of credit remaining.
- Pod status, GPU utilization, and GPU memory utilization, plus CPU and RAM usage in the app.
- Small, medium, and large desktop widgets. The medium widget shows two pods; the large widget shows up to six.
- Manual refresh, sample data previews, and timestamps that flag stale or offline readings.
- API key storage in macOS Keychain. The app only reads account and pod information.

## Requirements

- An Apple silicon Mac running macOS 14 Sonoma or later. The build script currently targets `arm64` only.
- Apple's Command Line Tools with a Swift compiler and macOS SDK supporting macOS 14 or later. Install them with `xcode-select --install` if needed.
- A Runpod account and a read-only API key for live readings. Sample data works without an account.

There are no third-party package dependencies, and an Xcode project is not required.

## Build and run

```bash
git clone git@github.com:Abteen-Arab/RunPod_GPU_Widget_App_Mac.git
cd RunPod_GPU_Widget_App_Mac
RUNPOD_BUILD_DIR="$PWD/.build" bash RunpodDesktop/build.sh
open "Runpod Desktop.app"
```

The script compiles the app and its WidgetKit extension, signs them locally, verifies the signatures, and copies `Runpod Desktop.app` into the repository root. This is an ad hoc signed personal build; it is not notarized or distributed through the App Store.

On the first build, the script generates `RunpodDesktop/Shared/BridgeConfiguration.swift` with a random credential shared by the app and its widget. This file and all compiled app bundles are excluded from Git. Build the app and extension together so they use the same credential.

Build paths can be customized:

| Variable | Default |
| --- | --- |
| `RUNPOD_BUILD_DIR` | `../work/runpod-build`, relative to the repository root |
| `RUNPOD_OUTPUT_DIR` | Repository root |
| `RUNPOD_MODULE_CACHE` | `module-cache` inside the build directory |

The command above keeps intermediate files inside the ignored `.build` directory. The script also handles duplicate SwiftBridging module definitions in some Command Line Tools installations through a local compiler overlay, without changing system files.

## Connect your account

1. Open **Runpod Desktop**.
2. Create a read-only API key with access to your pod and account information in [Runpod Console → Credentials](https://console.runpod.io/user/credentials).
3. Enter the key in the app and click **Connect & save in Keychain**.
4. Right-click an empty area of the desktop, choose **Edit Widgets**, search for **Runpod Desktop**, and add your preferred size.

Keep the app running for fresh readings; closing its window is fine. Open it again after restarting your Mac. Use **Preview with sample data** to try the interface without connecting an account. **Disconnect** removes the saved API key from Keychain.

## Updates and estimates

The app polls Runpod every minute while running. The widget requests a new timeline every 15 minutes, but macOS controls when it actually refreshes. Clicking the widget opens the app and requests an update; an immediate widget redraw is not guaranteed.

Readings older than 15 minutes are marked stale. Connection failures preserve the last known values and show an offline indicator.

Estimated credit time is **account balance ÷ current account hourly spend**. It assumes spending stays constant; workload changes, storage, and other charges can change the result. Zero reported spend displays **No spend**. Missing values display a dash. GPU percentages average the available readings across a pod's GPUs. Pod status reflects Runpod's reported state and does not check the health of a service running inside the pod.

## Privacy and architecture

The app queries `https://api.runpod.io/graphql` over HTTPS using a bearer token. It does not start, stop, or delete pods. Your API key is stored in the app's macOS Keychain item and is never sent to the widget.

The widget receives monitoring snapshots through an authenticated local connection at `127.0.0.1:47361`. It caches the last snapshot in its own preferences so readings remain visible when the app is unavailable. These snapshots include account balances and pod metrics, but not the API key.

## Run the offline checks

From the repository root:

```bash
mkdir -p .build/test-module-cache
xcrun swiftc -module-cache-path "$PWD/.build/test-module-cache" \
  -parse-as-library \
  RunpodDesktop/Shared/RunpodCore.swift \
  RunpodDesktop/Tests/RunpodCoreTests.swift \
  -o .build/runpod-core-tests
.build/runpod-core-tests
```

The checks cover response parsing, missing and invalid metrics, GPU averaging, status freshness, credit calculations, cached snapshots, HTTP and network errors, and request construction. They use mocked responses and do not require a Runpod key. If your compiler reports duplicate SwiftBridging modules, first run the build script, then add `-vfsoverlay "$PWD/.build/toolchain-overlay.json"` to the compiler command above.

## Source layout

```text
RunpodDesktop/
├── App/          SwiftUI app, account setup, Keychain access, and polling
├── Widget/       WidgetKit timeline provider and desktop widget
├── Shared/       API client, data models, local bridge, and shared views
├── Resources/    App icon, bundle metadata, and widget entitlements
├── Tests/        Offline core checks
└── build.sh      Command-line build and local signing
```

The preview image uses sample data. Live account behavior and placement in the macOS widget gallery require manual verification on the target Mac.
