import SwiftUI
import WidgetKit

struct RunpodEntry: TimelineEntry {
    let date: Date
    let snapshot: MonitorSnapshot
}

struct RunpodProvider: TimelineProvider {
    func placeholder(in context: Context) -> RunpodEntry {
        RunpodEntry(date: Date(), snapshot: .demo)
    }
    func getSnapshot(in context: Context, completion: @escaping (RunpodEntry) -> Void) {
        if context.isPreview {
            completion(RunpodEntry(date: Date(), snapshot: .demo))
        } else {
            Task { completion(RunpodEntry(date: Date(), snapshot: await loadSnapshot())) }
        }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RunpodEntry>) -> Void) {
        Task {
            let snapshot = await loadSnapshot()
            let now = Date()
            var entries = [RunpodEntry(date: now, snapshot: snapshot)]
            // Force old readings to visibly become stale even if macOS delays a reload.
            if let updated = snapshot.lastUpdated, updated.addingTimeInterval(15 * 60) > now {
                entries.append(RunpodEntry(date: updated.addingTimeInterval(15 * 60 + 1), snapshot: snapshot))
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }
    private func loadSnapshot() async -> MonitorSnapshot {
        do {
            let snapshot = try await BridgeClient.fetch()
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: "lastSnapshot")
            }
            return snapshot
        } catch {
            let previous = UserDefaults.standard.data(forKey: "lastSnapshot")
                .flatMap { try? JSONDecoder().decode(MonitorSnapshot.self, from: $0) } ?? .empty
            return .failed(message: "Open Runpod Desktop to reconnect.", previous: previous, at: Date())
        }
    }
}

struct RunpodWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RunpodEntry
    var body: some View {
        MonitorBoard(snapshot: entry.snapshot, family: family, referenceDate: entry.date)
            .containerBackground(for: .widget) {
                LinearGradient(colors: [Color(red: 0.10, green: 0.15, blue: 0.18), MonitorStyle.background], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .widgetURL(URL(string: "runpoddesktop://refresh"))
    }
}

@main
struct RunpodDesktopWidget: Widget {
    let kind = "RunpodDesktopWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RunpodProvider()) { entry in
            RunpodWidgetView(entry: entry)
        }
        .configurationDisplayName("Runpod Desktop")
        .description("Estimate hours before credits run out, and see pod status, GPU usage, and memory. Open the app to refresh.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
