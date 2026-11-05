// Run with: bash RunpodDesktop/check.sh
// The runner supplies a separate bridge configuration and an isolated test app.
import Foundation
import WidgetKit

private enum TestFailure: Error { case failed(String) }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure.failed(message) }
}

@main
struct WidgetBridgeTests {
    @MainActor static func main() async throws {
        let domain = WidgetBridgeTestConfiguration.bundleIdentifier
        try check(domain.hasPrefix("local.abteen.RunpodDesktop.Tests."), "Expected an isolated test domain")
        try check(Bundle.main.bundleIdentifier == domain, "Tests must run inside their own app bundle")
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "lastSnapshot")
        defer {
            defaults.removeObject(forKey: "lastSnapshot")
            defaults.removePersistentDomain(forName: domain)
        }

        func cached() throws -> MonitorSnapshot {
            guard let data = defaults.data(forKey: "lastSnapshot") else {
                throw TestFailure.failed("Missing widget cache")
            }
            return try JSONDecoder().decode(MonitorSnapshot.self, from: data)
        }
        func cache(_ snapshot: MonitorSnapshot) throws {
            defaults.set(try JSONEncoder().encode(snapshot), forKey: "lastSnapshot")
        }

        try cache(.demo)
        let widgetCache = WidgetSnapshotCache(defaults: defaults)
        var provider = RunpodProvider(cache: widgetCache)
        let demoFallback = await provider.loadSnapshot()
        try check(!demoFallback.isDemo && demoFallback.pods.isEmpty && demoFallback.balance == nil
                  && demoFallback.error != nil, "Cached demo data cannot become an offline live reading")

        var live = MonitorSnapshot.demo
        live.isDemo = false
        live.balance = 11.23
        live.spendPerHour = 1.50
        var served = live
        var ready = false
        var listenerError: String?
        let server = BridgeServer()
        defer { server.stop() }
        server.start(snapshot: { served }, onError: { error in
            listenerError = error
            ready = error == nil
        })
        for _ in 0..<60 {
            if ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(ready, "Test listener did not start: \(listenerError ?? "no ready event")")

        let direct = try await BridgeClient.fetch()
        try check(direct == live, "Authenticated bridge requests return the complete snapshot")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let base = "http://127.0.0.1:\(BridgeConfiguration.port)"
        let (anonymousData, anonymousResponse) = try await session.data(from: URL(string: base + "/snapshot")!)
        try check((anonymousResponse as? HTTPURLResponse)?.statusCode == 403 && anonymousData.isEmpty,
                  "Anonymous requests cannot read account metrics")
        var wrongToken = URLRequest(url: URL(string: base + "/snapshot")!)
        wrongToken.setValue("incorrect-test-token", forHTTPHeaderField: "X-Runpod-Widget-Token")
        let (wrongTokenData, wrongTokenResponse) = try await session.data(for: wrongToken)
        try check((wrongTokenResponse as? HTTPURLResponse)?.statusCode == 403 && wrongTokenData.isEmpty,
                  "Incorrect bridge credentials cannot read account metrics")
        let (_, missingResponse) = try await session.data(from: URL(string: base + "/wrong-path")!)
        try check((missingResponse as? HTTPURLResponse)?.statusCode == 404, "Only the snapshot route is served")

        let received = await provider.loadSnapshot()
        try check(received == live && cached() == live, "A live reading is displayed and cached")
        let initialWrites = await widgetCache.writeCount
        let repeated = await provider.loadSnapshot()
        let repeatedWrites = await widgetCache.writeCount
        try check(repeated == live && repeatedWrites == initialWrites,
                  "Repeated bridge reads do not encode or rewrite an unchanged cache")

        let loadingDate = Date()
        served = .empty
        served.lastAttempt = loadingDate
        let loading = await provider.loadSnapshot()
        try check(loading.pods == live.pods && loading.balance == live.balance
                  && loading.lastUpdated == live.lastUpdated && loading.lastAttempt == loadingDate
                  && loading.error == nil, "App startup keeps the widget's last successful values")
        try check(cached() == live, "A loading marker does not replace the live cache")

        let failureDate = Date()
        served = .failed(message: "Test API unavailable", at: failureDate)
        let startupFailure = await provider.loadSnapshot()
        try check(startupFailure.pods == live.pods && startupFailure.balance == live.balance
                  && startupFailure.lastUpdated == live.lastUpdated && startupFailure.lastAttempt == failureDate
                  && startupFailure.error == "Test API unavailable",
                  "A failed first request keeps cached metrics and shows the connection error")
        let failedCache = try cached()
        try check(failedCache.pods == live.pods && failedCache.error == "Test API unavailable",
                  "A failed first request preserves the cached account data")

        served = .empty
        let disconnected = await provider.loadSnapshot()
        try check(disconnected == .empty && cached() == .empty,
                  "Disconnecting immediately clears the displayed and cached account data")

        try cache(.demo)
        provider = RunpodProvider(cache: WidgetSnapshotCache(defaults: defaults))
        served.lastAttempt = Date()
        let loadingFromDemo = await provider.loadSnapshot()
        try check(!loadingFromDemo.isDemo && loadingFromDemo.pods.isEmpty && loadingFromDemo.balance == nil,
                  "A loading marker cannot restore sample data as a live reading")

        served = live
        _ = await provider.loadSnapshot()
        server.stop()
        let unavailable = await provider.loadSnapshot()
        try check(unavailable.pods == live.pods && unavailable.balance == live.balance
                  && unavailable.lastUpdated == live.lastUpdated && unavailable.error != nil,
                  "Closing the app preserves last-known values and marks the widget offline")
        try check(cached() == live, "An unavailable bridge does not destroy the successful cache")
        do {
            _ = try await BridgeClient.fetch()
            throw TestFailure.failed("A stopped bridge must reject new requests")
        } catch let failure as TestFailure { throw failure }
        catch { }

        try await checkCacheOrdering(domain: domain)
        try checkTimeline(provider: provider)
        print("Widget bridge checks passed: authentication, routing, cache deduplication and ordering, startup loading/failure, disconnect, demo rejection, offline fallback, stale timelines.")
    }

    private static func checkCacheOrdering(domain: String) async throws {
        let suite = domain + ".cache-policy"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = WidgetSnapshotCache(defaults: defaults)
        func receive(_ snapshot: MonitorSnapshot) async -> MonitorSnapshot {
            let requestID = await cache.beginRequest()
            return await cache.resolve(snapshot, requestID: requestID)
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var live = MonitorSnapshot(pods: [], lastUpdated: now, lastAttempt: now,
                                   error: nil, isDemo: false, balance: 10, spendPerHour: 1)
        _ = await receive(live)
        _ = await receive(live)
        try check(await cache.writeCount == 1, "An identical response causes one initial write only")

        let older = live
        live.lastUpdated = now.addingTimeInterval(60)
        live.lastAttempt = live.lastUpdated
        live.balance = 9
        _ = await receive(live)
        let afterOld = await receive(older)
        let writesAfterOld = await cache.writeCount
        try check(afterOld == live && writesAfterOld == 2, "An older reading cannot replace newer metrics")

        var failed = await receive(.failed(message: "Offline", previous: older, at: now.addingTimeInterval(61)))
        try check(failed.balance == live.balance && failed.lastUpdated == live.lastUpdated && failed.error == "Offline",
                  "A recent connection error cannot replace newer account values with older metrics")
        failed.lastAttempt = now.addingTimeInterval(62)
        _ = await receive(failed)
        try check(await cache.writeCount == 3, "A changed error persists once; attempt-only changes do not write")
        live.lastAttempt = now.addingTimeInterval(63)
        let recovered = await receive(live)
        let writesAfterRecovery = await cache.writeCount
        try check(recovered.error == nil && writesAfterRecovery == 4,
                  "Recovery persists even when the reading timestamp is unchanged")

        let pendingID = await cache.beginRequest()
        let disconnectID = await cache.beginRequest()
        _ = await cache.resolve(.empty, requestID: disconnectID)
        let late = await cache.resolve(live, requestID: pendingID)
        _ = await receive(.empty)
        let writesAfterDisconnect = await cache.writeCount
        try check(late == .empty && writesAfterDisconnect == 5,
                  "Disconnect clears once and a late pre-disconnect response cannot restore account data")

        let firstFailure = MonitorSnapshot.failed(message: "First request failed", at: now.addingTimeInterval(70))
        _ = await receive(firstFailure)
        try check(await cache.writeCount == 6, "A failure without a successful timestamp is persisted")
        let demo = await receive(.demo)
        let writesAfterDemo = await cache.writeCount
        try check(demo == firstFailure && writesAfterDemo == 6, "A bridge response cannot cache sample data")
        let disconnected = await receive(.empty)
        let finalWrites = await cache.writeCount
        try check(disconnected == .empty && finalWrites == 7,
                  "Disconnect clears errors with absent timestamps")

        _ = await receive(live)
        let pendingSuccessID = await cache.beginRequest()
        let unavailableID = await cache.beginRequest()
        let offline = await cache.unavailable(at: now.addingTimeInterval(80), requestID: unavailableID)
        let supersededSuccess = await cache.resolve(live, requestID: pendingSuccessID)
        let durableLive = await cache.cachedSnapshot()
        let writesAfterUnavailable = await cache.writeCount
        try check(offline.error != nil && supersededSuccess == offline && durableLive == live
                  && writesAfterUnavailable == 8,
                  "A late success cannot replace a newer transient offline result or rewrite the durable cache")

        let persistedFailure = MonitorSnapshot.failed(message: "API unavailable", previous: live,
                                                       at: now.addingTimeInterval(81))
        _ = await receive(persistedFailure)
        let pendingFailureID = await cache.beginRequest()
        let loadingID = await cache.beginRequest()
        var loadingMarker = MonitorSnapshot.empty
        loadingMarker.lastAttempt = now.addingTimeInterval(82)
        let loading = await cache.resolve(loadingMarker, requestID: loadingID)
        let supersededFailure = await cache.resolve(persistedFailure, requestID: pendingFailureID)
        let durableFailure = await cache.cachedSnapshot()
        let writesAfterLoading = await cache.writeCount
        try check(loading.error == nil && loading.pods == live.pods && supersededFailure == loading
                  && durableFailure == persistedFailure && writesAfterLoading == 9,
                  "A late failure cannot replace newer loading state while its durable fallback remains intact")
    }

    private static func checkTimeline(provider: RunpodProvider) throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var snapshot = MonitorSnapshot(pods: [], lastUpdated: now.addingTimeInterval(-600),
                                       lastAttempt: now, error: nil, isDemo: false)
        let fresh = provider.makeTimeline(snapshot: snapshot, at: now)
        try check(fresh.entries.count == 2 && fresh.entries[0].date == now,
                  "A fresh timeline contains just the reading and its required stale transition")
        let staleEntry = fresh.entries[1]
        try check(!snapshot.isStale(at: fresh.entries[0].date) && snapshot.isStale(at: staleEntry.date),
                  "A delayed WidgetKit reload still displays a stale indicator")
        try check(fresh.policy == .after(now.addingTimeInterval(900)), "One normal 15-minute refresh policy")
        snapshot.lastUpdated = now.addingTimeInterval(-900)
        try check(provider.makeTimeline(snapshot: snapshot, at: now).entries.last?.date == now.addingTimeInterval(1),
                  "The exact freshness boundary still schedules the transition to stale")
        snapshot.lastUpdated = now.addingTimeInterval(-901)
        try check(provider.makeTimeline(snapshot: snapshot, at: now).entries.count == 1,
                  "An already stale reading needs no redundant future entry")
        snapshot.lastUpdated = now
        snapshot.error = "Offline"
        try check(provider.makeTimeline(snapshot: snapshot, at: now).entries.count == 1,
                  "An offline reading already displays a warning and needs no stale entry")
    }
}
