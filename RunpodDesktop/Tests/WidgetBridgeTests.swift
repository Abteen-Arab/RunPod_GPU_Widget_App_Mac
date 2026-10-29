// Run with: bash RunpodDesktop/check.sh
// The runner supplies a separate bridge configuration and an isolated test app.
import Foundation

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

        let provider = RunpodProvider()
        try cache(.demo)
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

        print("Widget bridge checks passed: authentication, routing, live cache, startup loading, startup failure, disconnect, demo rejection, offline fallback.")
    }
}
