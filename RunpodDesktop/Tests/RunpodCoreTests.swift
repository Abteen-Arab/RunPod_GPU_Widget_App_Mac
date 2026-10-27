// Run: swiftc -module-cache-path /tmp/runpod-module-cache -parse-as-library Shared/RunpodCore.swift Tests/RunpodCoreTests.swift -o /tmp/runpod-core-tests && /tmp/runpod-core-tests
import Foundation

private enum TestFailure: Error { case failed(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}
private func envelope(_ pods: String) -> Data { Data("{\"data\":{\"myself\":{\"pods\":\(pods)}}}".utf8) }
private func expect(_ expected: RunpodError, _ body: () throws -> Void) throws {
    do { try body(); throw TestFailure.failed("Expected \(expected)") }
    catch let error as RunpodError { try check(error == expected, "Unexpected error: \(error)") }
}

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var payload = envelope("[]")
    nonisolated(unsafe) static var requestWasSafe = false
    nonisolated(unsafe) static var failure: URLError.Code?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        Self.requestWasSafe = request.url == RunpodClient.endpoint && request.httpMethod == "POST"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-local-only"
            && request.value(forHTTPHeaderField: "Content-Type") == "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct RunpodCoreTests {
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func first(_ json: String) throws -> PodSummary {
            try RunpodClient.decode(data: envelope("[\(json)]"), at: now).pods[0]
        }
        let starting = try first(#"{"id":"1","name":"Train","desiredStatus":"RUNNING","runtime":null}"#)
        try check(starting.status == "STARTING" && !starting.isRunning, "Desired running alone is not an up signal")
        try check(starting.gpuPercent == nil && starting.uptimeSeconds == nil, "Null runtime must stay unavailable")
        let stopped = try first(#"{"id":"2","desiredStatus":"EXITED"}"#)
        try check(stopped.status == "EXITED" && stopped.name == "2", "Stopped and absent name")
        let zero = try first(#"{"id":"3","desiredStatus":"RUNNING","runtime":{"uptimeInSeconds":0,"gpus":[{"gpuUtilPercent":0}],"container":{"cpuPercent":0,"memoryPercent":null}}}"#)
        try check(zero.isRunning && zero.gpuPercent == 0 && zero.cpuPercent == 0 && zero.uptimeSeconds == 0, "Real zero is preserved")
        try check(zero.vramPercent == nil && zero.ramPercent == nil, "Missing metrics never become zero")
        let multi = try first(#"{"id":"4","runtime":{"gpus":[{"gpuUtilPercent":20,"memoryUtilPercent":60},{"gpuUtilPercent":80,"memoryUtilPercent":40},{}]}}"#)
        try check(multi.gpuPercent == 50 && multi.vramPercent == 50, "Device readings are averaged independently")
        let invalidMetrics = try first(#"{"id":"5","runtime":{"gpus":[{"gpuUtilPercent":-1,"memoryUtilPercent":110}],"uptimeInSeconds":-1},"costPerHr":-0.1}"#)
        try check(invalidMetrics.gpuPercent == nil && invalidMetrics.vramPercent == nil && invalidMetrics.costPerHour == nil, "Invalid values stay unavailable")
        let telemetry = try first(#"{"id":"6","desiredStatus":"RUNNING","latestTelemetry":{"state":"HOST_MAINTENANCE","time":"2023-11-14T22:13:10.123Z"}}"#)
        try check(telemetry.status == "HOST_MAINTENANCE" && !telemetry.isRunning, "Fresh arbitrary telemetry state wins")
        try check(telemetry.observedAt != nil, "Fractional ISO date parsing")
        let stale = try first(#"{"id":"7","desiredStatus":"RUNNING","latestTelemetry":{"state":"RUNNING","time":"2023-11-14T21:00:00Z"}}"#)
        try check(stale.status == "STARTING", "Stale telemetry cannot claim running")
        let future = try first(#"{"id":"8","desiredStatus":"RUNNING","latestTelemetry":{"state":"RUNNING","time":"2099-01-01T00:00:00Z"}}"#)
        try check(future.status == "STARTING", "Future telemetry cannot claim running")
        try expect(.partialResponse) {
            _ = try RunpodClient.decode(data: Data(#"{"data":{"myself":{"pods":[]}},"errors":[{"message":"private provider message"}]}"#.utf8))
        }
        try expect(.authentication) {
            _ = try RunpodClient.decode(data: Data(#"{"errors":[{"extensions":{"code":"UNAUTHENTICATED"}}]}"#.utf8))
        }
        try expect(.invalidResponse) { _ = try RunpodClient.decode(data: Data("not JSON".utf8)) }
        try expect(.invalidResponse) { _ = try RunpodClient.decode(data: Data(#"{"data":{"myself":null}}"#.utf8)) }
        let empty = try RunpodClient.decode(data: envelope("[]"), at: now)
        try check(empty.pods.isEmpty && empty.lastUpdated == now && !empty.isDemo, "Empty account is a valid live result")
        try check(empty.balance == nil && empty.spendPerHour == nil && empty.creditHoursRemaining == nil, "Missing account billing stays unavailable")
        func billing(_ balance: String, _ rate: String) throws -> MonitorSnapshot {
            let json = "{\"data\":{\"myself\":{\"pods\":[],\"clientBalance\":\(balance),\"currentSpendPerHr\":\(rate)}}}"
            return try RunpodClient.decode(data: Data(json.utf8), at: now)
        }
        let funded = try billing("227.97", "5.56")
        try check(funded.balance == 227.97 && funded.spendPerHour == 5.56, "Account billing fields parsed")
        try check(abs((funded.creditHoursRemaining ?? -1) - 41.00179856115108) < 0.000001, "Credit duration uses account spend")
        let zeroFunds = try billing("0", "5"), noSpend = try billing("50", "0")
        try check(zeroFunds.creditHoursRemaining == 0, "Zero balance means zero remaining hours")
        try check(noSpend.creditHoursRemaining == nil, "No active spend has no finite depletion time")
        let negative = try billing("-1", "-2")
        try check(negative.balance == nil && negative.spendPerHour == nil, "Negative billing fields stay unavailable")
        let missingFunds = try billing("null", "5"), missingSpend = try billing("50", "null")
        try check(missingFunds.creditHoursRemaining == nil, "Missing balance is not zero")
        try check(missingSpend.creditHoursRemaining == nil, "Missing spend is not inferred from pods")
        var nonfinite = funded
        nonfinite.balance = .infinity
        try check(nonfinite.creditHoursRemaining == nil, "Infinite balance cannot produce a duration")
        nonfinite.balance = 1
        nonfinite.spendPerHour = .nan
        try check(nonfinite.creditHoursRemaining == nil, "NaN spend cannot produce a duration")
        nonfinite.balance = Double.greatestFiniteMagnitude
        nonfinite.spendPerHour = Double.leastNonzeroMagnitude
        try check(nonfinite.creditHoursRemaining == nil, "Overflow duration is unavailable")
        let billingFailure = MonitorSnapshot.failed(message: "Offline", previous: funded)
        try check(billingFailure.balance == funded.balance && billingFailure.spendPerHour == funded.spendPerHour, "Failure preserves last known billing")
        let failed = MonitorSnapshot.failed(message: "Offline", previous: empty, at: now.addingTimeInterval(60))
        try check(failed.lastUpdated == now && failed.lastAttempt != now && failed.error == "Offline", "Failure preserves success timestamp")
        let roundtrip = try JSONDecoder().decode(MonitorSnapshot.self, from: JSONEncoder().encode(MonitorSnapshot.demo))
        try check(roundtrip.isDemo && roundtrip.pods.count == 2 && roundtrip.balance == 12.42 && roundtrip.spendPerHour == 0.69, "Demo and billing survive cache encoding")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        let client = RunpodClient(configuration: configuration)
        _ = try await client.fetch(apiKey: " test-local-only ")
        try check(MockProtocol.requestWasSafe, "Bearer header, HTTPS endpoint, and POST request")
        for (code, expected) in [(401, RunpodError.authentication), (403, .authentication), (429, .rateLimited), (503, .server(503)), (302, .redirected)] {
            MockProtocol.status = code
            do { _ = try await client.fetch(apiKey: "test-local-only"); throw TestFailure.failed("Expected HTTP \(code)") }
            catch let error as RunpodError { try check(error == expected, "HTTP error mapping") }
        }
        do { _ = try await client.fetch(apiKey: "  "); throw TestFailure.failed("Expected missing key") }
        catch let error as RunpodError { try check(error == .missingKey, "Empty credential") }
        for (code, expected) in [(URLError.Code.timedOut, RunpodError.timedOut), (.notConnectedToInternet, .network)] {
            MockProtocol.failure = code
            do { _ = try await client.fetch(apiKey: "test-local-only"); throw TestFailure.failed("Expected transport error") }
            catch let error as RunpodError { try check(error == expected, "Transport error mapping") }
        }
        try check(!RunpodClient.query.lowercased().contains("mutation"), "API query only reads data")
        print("Runpod core checks passed: parsing, missing data, GPU averaging, state freshness, credits, errors, cache, request safety.")
    }
}
