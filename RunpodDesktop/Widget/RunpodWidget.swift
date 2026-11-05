import SwiftUI
import WidgetKit

struct RunpodEntry: TimelineEntry {
    let date: Date
    let snapshot: MonitorSnapshot
}

/// Serialize overlapping provider requests so an older response cannot overwrite a
/// newer reading. Keep the last decoded value in memory for the widget process.
actor WidgetSnapshotCache {
    static let shared = WidgetSnapshotCache()
    private let defaults: UserDefaults
    private var loaded = false
    private var current: MonitorSnapshot?
    /// Loading and bridge-unavailable states are displayed without replacing the
    /// durable reading. Superseded callbacks must return this state, not disk data.
    private var latestResolved: MonitorSnapshot?
    private var nextRequestID: UInt64 = 0
    private var lastCompletedRequestID: UInt64 = 0
    private(set) var writeCount = 0

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func beginRequest() -> UInt64 {
        nextRequestID += 1
        return nextRequestID
    }

    func cachedSnapshot() -> MonitorSnapshot {
        if !loaded {
            current = defaults.data(forKey: "lastSnapshot")
                .flatMap { try? JSONDecoder().decode(MonitorSnapshot.self, from: $0) }
            loaded = true
        }
        // Older builds could cache sample data; never make it a live reading.
        guard let current, !current.isDemo else { return .empty }
        return current
    }

    func resolve(_ incoming: MonitorSnapshot, requestID: UInt64) -> MonitorSnapshot {
        let previous = cachedSnapshot()
        guard requestID >= lastCompletedRequestID else { return latestResolved ?? previous }
        lastCompletedRequestID = requestID
        guard !incoming.isDemo else { return latestResolved ?? previous }
        // An explicit disconnect must clear values even though it has no date.
        if incoming == .empty { persistIfChanged(.empty); return recordResolved(.empty) }

        // Startup loading is transient and must not replace the successful cache.
        if incoming.lastUpdated == nil, let attempt = incoming.lastAttempt, incoming.error == nil {
            var loading = previous
            loading.lastAttempt = attempt
            loading.error = nil
            return recordResolved(loading)
        }

        var result = incoming
        if incoming.lastUpdated == nil, let error = incoming.error, previous.lastUpdated != nil {
            if let attempt = incoming.lastAttempt, let previousAttempt = previous.lastAttempt,
               attempt < previousAttempt { return recordResolved(previous) }
            result = .failed(message: error, previous: previous, at: incoming.lastAttempt ?? Date())
        } else if let updated = incoming.lastUpdated, let previousUpdated = previous.lastUpdated {
            let attempt = incoming.lastAttempt ?? updated
            let previousAttempt = previous.lastAttempt ?? previousUpdated
            if updated < previousUpdated {
                // A recent failure can describe the connection while carrying old
                // metrics. Preserve the newest account values in that case.
                guard attempt > previousAttempt else { return recordResolved(previous) }
                result = previous
                result.lastAttempt = incoming.lastAttempt
                result.error = incoming.error
            } else if updated == previousUpdated, attempt < previousAttempt {
                return recordResolved(previous)
            }
        }
        persistIfChanged(result)
        return recordResolved(result)
    }

    func unavailable(at date: Date, requestID: UInt64) -> MonitorSnapshot {
        let previous = cachedSnapshot()
        guard requestID >= lastCompletedRequestID else { return latestResolved ?? previous }
        lastCompletedRequestID = requestID
        return recordResolved(.failed(message: "Open Runpod Desktop to connect.", previous: previous, at: date))
    }

    private func recordResolved(_ snapshot: MonitorSnapshot) -> MonitorSnapshot {
        latestResolved = snapshot
        return snapshot
    }

    private func persistIfChanged(_ snapshot: MonitorSnapshot) {
        // lastAttempt alone is not displayed once a reading exists. Remember it
        // for response ordering, without rewriting the same reading/error to disk.
        var comparable = snapshot
        comparable.lastAttempt = current?.lastAttempt
        if comparable == current {
            current = snapshot
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: "lastSnapshot")
        current = snapshot
        writeCount += 1
    }
}

struct RunpodProvider: TimelineProvider {
    private let cache: WidgetSnapshotCache
    init(cache: WidgetSnapshotCache = .shared) { self.cache = cache }

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
            completion(makeTimeline(snapshot: snapshot, at: Date()))
        }
    }

    func makeTimeline(snapshot: MonitorSnapshot, at now: Date) -> Timeline<RunpodEntry> {
        var entries = [RunpodEntry(date: now, snapshot: snapshot)]
        // One local stale transition remains necessary: .after is a reload
        // request, not a deadline, and each entry renders using its fixed date.
        // Offline readings already show the warning, so need no second entry.
        if snapshot.error == nil, let updated = snapshot.lastUpdated {
            let staleDate = updated.addingTimeInterval(15 * 60 + 1)
            if staleDate > now { entries.append(RunpodEntry(date: staleDate, snapshot: snapshot)) }
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60)))
    }

    func loadSnapshot() async -> MonitorSnapshot {
        let requestID = await cache.beginRequest()
        do {
            return await cache.resolve(try await BridgeClient.fetch(), requestID: requestID)
        } catch {
            return await cache.unavailable(at: Date(), requestID: requestID)
        }
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
