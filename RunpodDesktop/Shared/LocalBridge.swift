import Foundation
@preconcurrency import Network

/// Bounded retries retain their position across failures and reset only on success.
struct BridgeRetryPolicy {
    private var interval: TimeInterval = 10

    mutating func nextDelay(jitter: Double) -> TimeInterval {
        let delay = min(300, interval * min(1.2, max(0.8, jitter)))
        interval = min(300, interval * 2)
        return delay
    }

    mutating func reset() { interval = 10 }
}

/// One serial encoder owns each coherent version. Requests never encode on the
/// UI executor, and concurrent reads of unchanged data share the same bytes.
actor BridgeSnapshotCache {
    private var snapshot: MonitorSnapshot?
    private var encoded: Data?
    private(set) var encodingCount = 0

    func data(for value: MonitorSnapshot) -> Data? {
        if snapshot != value {
            snapshot = value
            encoded = try? JSONEncoder().encode(value)
            encodingCount += 1
        }
        return encoded
    }
}

/// Serves only the sanitized monitoring snapshot on the local loopback interface.
/// The API credential never crosses this bridge.
@MainActor
final class BridgeServer {
    private var listener: NWListener?
    private var listenerReady = false
    private var connections: [UUID: BridgeConnection] = [:]
    private var retryTask: Task<Void, Never>?
    private var retryPolicy = BridgeRetryPolicy()
    private var isRunning = false
    private var isSuspended = false
    private var currentSnapshot: MonitorSnapshot = .empty
    private var snapshotProvider: (@MainActor @Sendable () -> MonitorSnapshot)?
    private var onError: @MainActor @Sendable (String?) -> Void = { _ in }
    private let cache = BridgeSnapshotCache()
    private let retrySleep: @Sendable (TimeInterval) async throws -> Void
    private let retryJitter: @Sendable () -> Double
    private let makeListener: @MainActor () throws -> NWListener

    init(
        retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        retryJitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) },
        makeListener: @escaping @MainActor () throws -> NWListener = { try BridgeServer.loopbackListener() }
    ) {
        self.retrySleep = retrySleep
        self.retryJitter = retryJitter
        self.makeListener = makeListener
    }

    /// Value-based publication keeps model changes synchronous. The next request
    /// observes the new version, including an explicit disconnect, without a race
    /// between independently scheduled encoding tasks.
    func start(
        snapshot: MonitorSnapshot = .empty,
        onError: @escaping @MainActor @Sendable (String?) -> Void = { _ in }
    ) {
        stop()
        currentSnapshot = snapshot
        self.onError = onError
        isRunning = true
        attemptStart()
    }

    /// A dynamic source remains useful for isolated provider/bridge checks.
    func start(
        snapshot: @escaping @MainActor @Sendable () -> MonitorSnapshot,
        onError: @escaping @MainActor @Sendable (String?) -> Void = { _ in }
    ) {
        start(snapshot: snapshot(), onError: onError)
        snapshotProvider = snapshot
    }

    func update(snapshot: MonitorSnapshot) { currentSnapshot = snapshot }

    /// Keep an established local listener, but do not retry a failed bind during
    /// sleep/display-off. Waking can make one new attempt without replaying work.
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            retryTask?.cancel()
            retryTask = nil
            if !listenerReady { closeListener() }
        } else if isRunning, listener == nil {
            attemptStart()
        }
    }

    private static func loopbackListener() throws -> NWListener {
        guard let port = NWEndpoint.Port(rawValue: BridgeConfiguration.port) else {
            throw BridgeError.invalidPort
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        return try NWListener(using: parameters)
    }

    private func attemptStart() {
        guard isRunning, !isSuspended, listener == nil else { return }
        do {
            let newListener = try makeListener()
            listener = newListener
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                Task { @MainActor [weak self, weak newListener] in
                    guard let self, let newListener, self.listener === newListener else { return }
                    switch state {
                    case .ready:
                        self.listenerReady = true
                        self.retryPolicy.reset()
                        self.onError(nil)
                    case .waiting(let error), .failed(let error):
                        self.failed(error)
                    default:
                        break
                    }
                }
            }
            newListener.newConnectionHandler = { [weak self, weak newListener] connection in
                Task { @MainActor [weak self, weak newListener] in
                    guard let self, let newListener, self.listener === newListener else {
                        connection.cancel()
                        return
                    }
                    // Bound resource use even if another local process floods this port.
                    guard self.connections.count < 12 else {
                        connection.cancel()
                        return
                    }
                    let id = UUID()
                    let cache = self.cache
                    let session = BridgeConnection(connection: connection, response: { [weak self] in
                        guard let self else { return nil }
                        let value = self.snapshotProvider?() ?? self.currentSnapshot
                        return await cache.data(for: value)
                    }) { [weak self] in
                        Task { @MainActor [weak self] in self?.connections.removeValue(forKey: id) }
                    }
                    self.connections[id] = session
                    session.start()
                }
            }
            newListener.start(queue: .global(qos: .utility))
        } catch {
            failed(error)
        }
    }

    private func failed(_ error: Error) {
        onError("The desktop widget connection could not start: \(error.localizedDescription)")
        closeListener()
        guard isRunning, !isSuspended else { return }
        let delay = retryPolicy.nextDelay(jitter: retryJitter())
        let sleep = retrySleep
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.isRunning, !self.isSuspended else { return }
            self.retryTask = nil
            self.attemptStart()
        }
    }

    private func closeListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        listenerReady = false
        let activeConnections = connections.values
        connections.removeAll()
        activeConnections.forEach { $0.cancel() }
    }

    func stop() {
        isRunning = false
        retryTask?.cancel()
        retryTask = nil
        closeListener()
        retryPolicy.reset()
        snapshotProvider = nil
        onError = { _ in }
    }
}

private final class BridgeConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "RunpodDesktop.WidgetBridge.Connection")
    private let response: @MainActor @Sendable () async -> Data?
    private let finished: @Sendable () -> Void
    private var buffer = Data()
    private var didFinish = false

    init(connection: NWConnection, response: @escaping @MainActor @Sendable () async -> Data?,
         finished: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.response = response
        self.finished = finished
    }

    func start() {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finish() }
        queue.async { [self] in receive() }
    }

    func cancel() { queue.async { [self] in finish() } }

    private func receive() {
        guard !didFinish else { return }
        let remaining = 8192 - buffer.count
        guard remaining > 0 else { respond(status: "431 Request Header Fields Too Large"); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [self] data, _, complete, error in
            guard !didFinish else { return }
            if let data { buffer.append(data) }
            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard headerRange.upperBound == buffer.count,
                      let header = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) else {
                    respond(status: "400 Bad Request"); return
                }
                handle(header)
            } else if complete || error != nil {
                finish()
            } else {
                receive()
            }
        }
    }

    private func handle(_ header: String) {
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first == "GET /snapshot HTTP/1.1" else {
            respond(status: "404 Not Found"); return
        }
        var token: String?
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else {
                respond(status: "400 Bad Request"); return
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "x-runpod-widget-token" {
                guard token == nil else { respond(status: "400 Bad Request"); return }
                token = value
            }
            if name == "transfer-encoding" || (name == "content-length" && value != "0") {
                respond(status: "400 Bad Request"); return
            }
        }
        guard let token, constantTimeEqual(token, BridgeConfiguration.token) else {
            respond(status: "403 Forbidden"); return
        }
        Task { @MainActor [self] in
            let data = await response()
            queue.async { [self] in
                guard !didFinish else { return }
                if let data { respond(status: "200 OK", body: data) }
                else { respond(status: "500 Internal Server Error") }
            }
        }
    }

    private func respond(status: String, body: Data = Data()) {
        guard !didFinish else { return }
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
            "", ""
        ].joined(separator: "\r\n")
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [self] _ in finish() })
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        connection.cancel()
        finished()
    }
}

private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
    let a = Array(left.utf8), b = Array(right.utf8)
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for index in a.indices { difference |= a[index] ^ b[index] }
    return difference == 0
}

enum BridgeError: LocalizedError {
    case invalidPort, invalidResponse, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidPort: "The local widget connection is misconfigured."
        case .invalidResponse: "The local widget connection returned an invalid response."
        case .unavailable: "Open Runpod Desktop to update the widget."
        }
    }
}

enum BridgeClient {
    /// A process-lifetime session retains the existing loopback transport policy.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    static func fetch() async throws -> MonitorSnapshot {
        guard let url = URL(string: "http://127.0.0.1:\(BridgeConfiguration.port)/snapshot") else {
            throw BridgeError.invalidPort
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue(BridgeConfiguration.token, forHTTPHeaderField: "X-Runpod-Widget-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.mimeType == "application/json", data.count <= 2 * 1024 * 1024 else {
            throw BridgeError.invalidResponse
        }
        return try JSONDecoder().decode(MonitorSnapshot.self, from: data)
    }
}
