import Foundation
@preconcurrency import Network

/// Serves only the sanitized monitoring snapshot on the local loopback interface.
/// The API credential never crosses this bridge.
@MainActor
final class BridgeServer {
    private var listener: NWListener?
    private var connections: [UUID: BridgeConnection] = [:]

    func start(
        snapshot: @escaping @MainActor @Sendable () -> MonitorSnapshot,
        onError: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        stop()
        do {
            guard let port = NWEndpoint.Port(rawValue: BridgeConfiguration.port) else {
                throw BridgeError.invalidPort
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            let newListener = try NWListener(using: parameters)
            listener = newListener
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard case .failed(let error) = state else { return }
                Task { @MainActor [weak self, weak newListener] in
                    guard let self, let newListener, self.listener === newListener else { return }
                    self.stop()
                    onError("The desktop widget connection could not start: \(error.localizedDescription)")
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
                    let session = BridgeConnection(connection: connection, snapshot: snapshot) { [weak self] in
                        Task { @MainActor [weak self] in self?.connections.removeValue(forKey: id) }
                    }
                    self.connections[id] = session
                    session.start()
                }
            }
            newListener.start(queue: .global(qos: .utility))
        } catch {
            onError("The desktop widget connection could not start: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let activeConnections = connections.values
        connections.removeAll()
        activeConnections.forEach { $0.cancel() }
    }
}

private final class BridgeConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "RunpodDesktop.WidgetBridge.Connection")
    private let snapshot: @MainActor @Sendable () -> MonitorSnapshot
    private let finished: @Sendable () -> Void
    private var buffer = Data()
    private var didFinish = false

    init(connection: NWConnection, snapshot: @escaping @MainActor @Sendable () -> MonitorSnapshot,
         finished: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.snapshot = snapshot
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
            let response: Data?
            do { response = try JSONEncoder().encode(snapshot()) } catch { response = nil }
            queue.async { [self] in
                if let response { respond(status: "200 OK", body: response) }
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

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum BridgeClient {
    static func fetch() async throws -> MonitorSnapshot {
        guard let url = URL(string: "http://127.0.0.1:\(BridgeConfiguration.port)/snapshot") else {
            throw BridgeError.invalidPort
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
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
