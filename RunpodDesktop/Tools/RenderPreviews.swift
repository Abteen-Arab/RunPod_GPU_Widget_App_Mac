import AppKit
import SwiftUI
import WidgetKit

/// Render the actual app and widget views, using sample data only.
@main
struct RenderPreviews {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = MonitorModel()
        model.showingDemo = true
        let app = ContentView(model: model).frame(width: 640, height: 596)
        try save(app.environment(\.colorScheme, .light), to: output.appendingPathComponent("RunpodAppPreview.png"))
        try save(app.environment(\.colorScheme, .dark), to: output.appendingPathComponent("RunpodAppPreview-dark.png"))
        let setup = ContentView(model: MonitorModel()).frame(width: 640, height: 596)
        try save(setup.environment(\.colorScheme, .light), to: output.appendingPathComponent("RunpodSetupPreview.png"))
        try save(PreviewSheet().environment(\.colorScheme, .light), to: output.appendingPathComponent("RunpodWidgetPreview.png"))
        try save(PreviewSheet().environment(\.colorScheme, .dark), to: output.appendingPathComponent("RunpodWidgetPreview-dark.png"))
        print("Rendered sample app, setup, and three widget sizes to \(output.path)")
    }

    @MainActor static func save<V: View>(_ view: V, to url: URL) throws {
        // AppKit-backed controls and lazy lists require a hosting window. ImageRenderer
        // replaces them with placeholders, so use the native view's drawing path.
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.display()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}

private struct PreviewSheet: View {
    @Environment(\.colorScheme) private var scheme
    private var demo: MonitorSnapshot {
        var snapshot = MonitorSnapshot.demo
        let now = snapshot.lastUpdated
        snapshot.pods = [
            snapshot.pods[0],
            PodSummary(id: "sdxl", name: "sdxl-inference", status: "RUNNING", gpuPercent: 61, vramPercent: 42,
                       cpuPercent: 12, ramPercent: 28, uptimeSeconds: 4200, costPerHour: 0.69, observedAt: now),
            PodSummary(id: "batch", name: "whisper-batch", status: "RUNNING", gpuPercent: 24, vramPercent: 35,
                       cpuPercent: 8, ramPercent: 19, uptimeSeconds: 1260, costPerHour: 0.69, observedAt: now),
            snapshot.pods[1],
            PodSummary(id: "starting", name: "embeddings-worker", status: "STARTING", gpuPercent: nil, vramPercent: nil,
                       cpuPercent: nil, ramPercent: nil, uptimeSeconds: nil, costPerHour: nil, observedAt: now),
            PodSummary(id: "eval", name: "eval-runner", status: "EXITED", gpuPercent: nil, vramPercent: nil,
                       cpuPercent: nil, ramPercent: nil, uptimeSeconds: nil, costPerHour: nil, observedAt: now)
        ]
        return snapshot
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(spacing: 14) {
                BrandMark()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Runpod Desktop").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("Your GPUs. At a glance.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("SAMPLE DATA").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    title("THE APP", detail: "A clear view of your account")
                    let model = previewModel()
                    ContentView(model: model).frame(width: 580, height: 560)
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.06)) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    title("ON YOUR DESKTOP", detail: "Three sizes. The essentials.")
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 16) {
                            widget(.systemSmall, width: 164, height: 164)
                            widget(.systemMedium, width: 344, height: 164)
                            Text("Credit left · Pod status · GPU usage")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        widget(.systemLarge, width: 344, height: 360)
                    }
                }
            }
            HStack {
                Label("Native macOS app", systemImage: "macwindow")
                Spacer()
                Label("Read-only monitoring", systemImage: "eye")
                Spacer()
                Label("API key in Keychain", systemImage: "lock")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(width: 1384)
        .background(scheme == .dark ? Color(white: 0.075) : Color(red: 0.945, green: 0.945, blue: 0.963))
    }
    @MainActor private func previewModel() -> MonitorModel {
        let model = MonitorModel()
        // This model is never started, so it cannot contact Runpod or the local bridge.
        model.snapshot = demo
        model.connected = true
        return model
    }
    private func title(_ label: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(MonitorStyle.accent)
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private func widget(_ family: WidgetFamily, width: CGFloat, height: CGFloat) -> some View {
        MonitorBoard(snapshot: demo, family: family)
            .padding(16).frame(width: width, height: height)
            .background(MonitorStyle.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.055)) }
    }
}
