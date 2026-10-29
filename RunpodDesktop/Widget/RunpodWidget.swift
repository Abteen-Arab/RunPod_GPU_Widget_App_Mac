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
    func loadSnapshot() async -> MonitorSnapshot {
        do {
            var snapshot = try await BridgeClient.fetch()
            // A saved account can take a moment to load after the app launches.
            // Preserve live cache during that explicit loading state; .empty still
            // clears it immediately when the user disconnects.
            if snapshot.lastUpdated == nil, let attempt = snapshot.lastAttempt, snapshot.error == nil {
                var previous = cachedSnapshot()
                previous.lastAttempt = attempt
                previous.error = nil
                return previous
            }
            // The app has no disk cache of its own. If its first request after
            // launch fails, keep the widget's last successful account values.
            if snapshot.lastUpdated == nil, let error = snapshot.error {
                let previous = cachedSnapshot()
                if previous.lastUpdated != nil {
                    snapshot = .failed(message: error, previous: previous, at: snapshot.lastAttempt ?? Date())
                }
            }
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: "lastSnapshot")
            }
            return snapshot
        } catch {
            return .failed(message: "Open Runpod Desktop to connect.", previous: cachedSnapshot(), at: Date())
        }
    }

    private func cachedSnapshot() -> MonitorSnapshot {
        let snapshot = UserDefaults.standard.data(forKey: "lastSnapshot")
            .flatMap { try? JSONDecoder().decode(MonitorSnapshot.self, from: $0) } ?? .empty
        // Older builds could cache sample data; never substitute it for a live reading.
        return snapshot.isDemo ? .empty : snapshot
    }
}

struct RunpodWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RunpodEntry
    var body: some View {
        MonitorBoard(snapshot: entry.snapshot, family: family, referenceDate: entry.date)
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: "runpoddesktop://refresh"))
    }
}

#if !RUNPOD_PROVIDER_TESTS
@main
struct RunpodDesktopWidget: Widget {
    let kind = "RunpodDesktopWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RunpodProvider()) { entry in
            RunpodWidgetView(entry: entry)
        }
        .configurationDisplayName("Runpod Desktop")
        .description("Credit time left, pod status, and GPU usage.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
#endif
