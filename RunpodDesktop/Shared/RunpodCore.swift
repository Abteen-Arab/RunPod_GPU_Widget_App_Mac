import Foundation

struct PodSummary: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Latest fresh telemetry state, or a conservative inference from desired state and runtime.
    let status: String
    /// GPU percentages are the arithmetic mean of available device readings.
    let gpuPercent: Double?
    let vramPercent: Double?
    let cpuPercent: Double?
    let ramPercent: Double?
    let uptimeSeconds: Int?
    let costPerHour: Double?
    let observedAt: Date?

    var isRunning: Bool { status.uppercased() == "RUNNING" }
}

struct MonitorSnapshot: Codable, Equatable, Sendable {
    var pods: [PodSummary]
    var lastUpdated: Date?
    var lastAttempt: Date?
    var error: String?
    var isDemo: Bool
    var balance: Double? = nil
    var spendPerHour: Double? = nil

    func isStale(at date: Date = Date()) -> Bool { lastUpdated.map { date.timeIntervalSince($0) > 900 } ?? true }
    var runningCount: Int { pods.filter(\.isRunning).count }
    /// Running pods first, then by name.
    var sortedPods: [PodSummary] {
        pods.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    /// Estimated credit duration at the account's current spend, excluding future usage changes.
    var creditHoursRemaining: Double? {
        guard let balance, balance.isFinite, balance >= 0,
              let spendPerHour, spendPerHour.isFinite, spendPerHour > 0 else { return nil }
        let hours = balance / spendPerHour
        return hours.isFinite ? hours : nil
    }
    static let empty = MonitorSnapshot(pods: [], lastUpdated: nil, lastAttempt: nil, error: nil, isDemo: false)
    static var demo: MonitorSnapshot {
        let now = Date()
        return MonitorSnapshot(pods: [
            PodSummary(id: "demo-training", name: "llama-finetune", status: "RUNNING", gpuPercent: 83,
                       vramPercent: 68, cpuPercent: 24, ramPercent: 41, uptimeSeconds: 7380,
                       costPerHour: 0.69, observedAt: now),
            PodSummary(id: "demo-stopped", name: "dev-sandbox", status: "EXITED", gpuPercent: nil,
                       vramPercent: nil, cpuPercent: nil, ramPercent: nil, uptimeSeconds: nil,
                       costPerHour: nil, observedAt: nil)
        ], lastUpdated: now, lastAttempt: now, error: nil, isDemo: true, balance: 12.42, spendPerHour: 0.69)
    }

    static func failed(message: String, previous: MonitorSnapshot = .empty, at date: Date = Date()) -> MonitorSnapshot {
        var result = previous
        result.lastAttempt = date
        result.error = message
        return result
    }
}

enum RunpodError: Error, LocalizedError, Equatable {
    case missingKey, authentication, rateLimited, network, timedOut, redirected, invalidResponse, partialResponse, server(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your Runpod API key in the app."
        case .authentication: "Runpod rejected the API key. Check its read permissions."
        case .rateLimited: "Runpod is limiting requests. Try again later."
        case .network: "Could not reach Runpod. Check your internet connection."
        case .timedOut: "Runpod took too long to respond. Try again."
        case .redirected: "Runpod returned an unexpected redirect."
        case .invalidResponse: "Runpod returned an unreadable response."
        case .partialResponse: "Runpod could not return complete pod data. Try again later."
        case .server(let code): "Runpod returned an error (HTTP \(code))."
        }
    }
}

/// Display strings shared by the app and widget.
enum MonitorFormat {
    static func percentage(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "—"
    }
    static func money(_ value: Double?) -> String {
        value.map { String(format: "$%.2f", $0) } ?? "—"
    }
    /// Rounds down, so the estimate never overstates remaining time.
    static func creditTime(_ snapshot: MonitorSnapshot) -> String {
        guard let hours = snapshot.creditHoursRemaining else {
            return snapshot.spendPerHour == 0 && snapshot.balance != nil ? "No spend" : "—"
        }
        guard hours < 100 * 24 else { return "99d+" }
        let minutes = Int((hours * 60).rounded(.down))
        if minutes == 0 { return hours > 0 ? "<1m" : "0m" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 48 * 60 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
        }
        return "\(minutes / 1440)d \(minutes % 1440 / 60)h"
    }
    static func status(_ pod: PodSummary) -> String {
        pod.status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward credentials to a redirected location, including another Runpod URL.
        completionHandler(nil)
    }
}

final class RunpodClient: Sendable {
    static let endpoint = URL(string: "https://api.runpod.io/graphql")!
    static let query = """
    query DesktopPodMonitor {
      myself { clientBalance currentSpendPerHr pods {
        id name desiredStatus costPerHr
        runtime { uptimeInSeconds gpus { id gpuUtilPercent memoryUtilPercent } container { cpuPercent memoryPercent } }
        latestTelemetry { state time }
      } }
    }
    """
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func fetch(apiKey: String) async throws -> MonitorSnapshot {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw RunpodError.missingKey }
        guard !key.contains("\r"), !key.contains("\n") else { throw RunpodError.authentication }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["query": Self.query])
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? RunpodError.timedOut : RunpodError.network
        } catch is CancellationError { throw CancellationError() }
        catch { throw RunpodError.network }
        guard let http = response as? HTTPURLResponse else { throw RunpodError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 300..<400: throw RunpodError.redirected
        case 401, 403: throw RunpodError.authentication
        case 429: throw RunpodError.rateLimited
        default: throw RunpodError.server(http.statusCode)
        }
        return try Self.decode(data: data)
    }

    static func decode(data: Data, at date: Date = Date()) throws -> MonitorSnapshot {
        guard data.count <= 2_000_000 else { throw RunpodError.invalidResponse }
        let response: Envelope
        do { response = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw RunpodError.invalidResponse }
        // Partial GraphQL results must not replace a known-good snapshot.
        if let errors = response.errors, !errors.isEmpty {
            if errors.contains(where: { ["UNAUTHENTICATED", "FORBIDDEN"].contains($0.extensions?.code?.uppercased() ?? "") }) {
                throw RunpodError.authentication
            }
            throw RunpodError.partialResponse
        }
        guard let account = response.data?.myself, let records = account.pods else { throw RunpodError.invalidResponse }
        let pods = records.map { pod -> PodSummary in
            let timestamp = parseDate(pod.latestTelemetry?.time)
            let fresh = timestamp.map { (-60...300).contains(date.timeIntervalSince($0)) } ?? false
            let telemetryState = pod.latestTelemetry?.state?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let desired = pod.desiredStatus?.uppercased() ?? "UNKNOWN"
            let status: String
            if fresh, let state = telemetryState, !state.isEmpty { status = state }
            else if desired == "RUNNING" { status = pod.runtime == nil ? "STARTING" : "RUNNING" }
            else { status = desired }
            let gpus = pod.runtime?.gpus ?? []
            return PodSummary(id: pod.id, name: pod.name?.isEmpty == false ? pod.name! : pod.id, status: status,
                              gpuPercent: mean(gpus.compactMap { percent($0.gpuUtilPercent) }),
                              vramPercent: mean(gpus.compactMap { percent($0.memoryUtilPercent) }),
                              cpuPercent: percent(pod.runtime?.container?.cpuPercent),
                              ramPercent: percent(pod.runtime?.container?.memoryPercent),
                              uptimeSeconds: pod.runtime?.uptimeInSeconds.flatMap { $0 >= 0 ? $0 : nil },
                              costPerHour: pod.costPerHr.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                              observedAt: timestamp)
        }
        return MonitorSnapshot(pods: pods, lastUpdated: date, lastAttempt: date, error: nil, isDemo: false,
                               balance: nonnegative(account.clientBalance), spendPerHour: nonnegative(account.currentSpendPerHr))
    }

    private static func percent(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
    }
    private static func nonnegative(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }
}

private struct Envelope: Decodable {
    struct Payload: Decodable {
        struct Account: Decodable {
            let pods: [Record]?
            let clientBalance: Double?
            let currentSpendPerHr: Double?
        }
        let myself: Account?
    }
    struct Issue: Decodable {
        struct Extensions: Decodable { let code: String? }
        let extensions: Extensions?
    }
    let data: Payload?
    let errors: [Issue]?
}

private struct Record: Decodable {
    struct Runtime: Decodable {
        struct GPU: Decodable { let gpuUtilPercent: Double?; let memoryUtilPercent: Double? }
        struct Container: Decodable { let cpuPercent: Double?; let memoryPercent: Double? }
        let uptimeInSeconds: Int?
        let gpus: [GPU]?
        let container: Container?
    }
    struct Telemetry: Decodable { let state: String?; let time: String? }
    let id: String
    let name: String?
    let desiredStatus: String?
    let costPerHr: Double?
    let runtime: Runtime?
    let latestTelemetry: Telemetry?
}
