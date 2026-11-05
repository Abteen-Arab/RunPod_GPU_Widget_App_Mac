import AppKit
import Security
import SwiftUI
import WidgetKit

enum CredentialStore {
    static let service = "local.abteen.RunpodDesktop"
    static let account = "runpod-api-key"
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(request as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw CredentialError.operationFailed }
        return key
    }
    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let code = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if code == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Runpod Desktop API key"
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CredentialError.operationFailed }
        } else if code != errSecSuccess { throw CredentialError.operationFailed }
    }
    static func remove() throws {
        let code = SecItemDelete(query as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw CredentialError.operationFailed }
    }
    enum CredentialError: LocalizedError {
        case operationFailed
        var errorDescription: String? { "Keychain access failed. Allow access in the macOS prompt, then try again." }
    }
}

/// Keychain may wait for a macOS authorization prompt. Keep those operations
/// off the UI executor and serialize them so connect/disconnect cannot race.
actor CredentialAccess {
    func read() throws -> String? { try CredentialStore.read() }
    func save(_ key: String) throws { try CredentialStore.save(key) }
    func remove() throws { try CredentialStore.remove() }
}

struct MonitorDependencies: Sendable {
    var fetch: @Sendable (String) async throws -> MonitorSnapshot
    var readKey: @Sendable () async throws -> String?
    var saveKey: @Sendable (String) async throws -> Void
    var removeKey: @Sendable () async throws -> Void

    static func live() -> Self {
        let client = RunpodClient()
        let credentials = CredentialAccess()
        return Self(fetch: { try await client.fetch(apiKey: $0) },
                    readKey: { try await credentials.read() },
                    saveKey: { try await credentials.save($0) },
                    removeKey: { try await credentials.remove() })
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    /// Live data only; sample data never reaches the desktop widget.
    @Published var snapshot: MonitorSnapshot = .empty {
        didSet {
            if bridgeEnabled { server.update(snapshot: snapshot) }
            if !showingDemo, oldValue.pods != snapshot.pods { rebuildRows() }
        }
    }
    @Published var showingDemo = false {
        didSet { if oldValue != showingDemo { rebuildRows() } }
    }
    @Published var keyInput = ""
    @Published var connected = false {
        didSet { if oldValue != connected { configureSchedule() } }
    }
    @Published var refreshing = false
    @Published var loadingCredentials = false
    @Published var message: String?
    @Published var bridgeError: String?
    @Published private(set) var environment = RefreshEnvironment()
    private(set) var orderedPods: [PodSummary] = []
    private(set) var runningPods: [PodSummary] = []
    var sampleActivity: (() -> Void)?

    private let demoSnapshot = MonitorSnapshot.demo
    private let dependencies: MonitorDependencies
    private let scheduler: any RefreshScheduling
    private let invalidateWidget: () -> Void
    private let server = BridgeServer()
    private var apiKey: String?
    private var refreshTask: Task<Void, Never>?
    private var credentialTask: Task<Void, Never>?
    private var operationGeneration = UUID()
    private var accountGeneration = UUID()
    private var mutatingCredentials = false
    private var refreshAfterCredentials = false
    private var started = false
    private var bridgeEnabled = false
    private var scheduledCadence: RefreshCadence = .suspended
    private var widgetPolicy = WidgetReloadPolicy()
    private var pendingWidgetReload = false

    init(dependencies: MonitorDependencies = .live(), scheduler: (any RefreshScheduling)? = nil,
         invalidateWidget: @escaping () -> Void = {
             WidgetCenter.shared.reloadTimelines(ofKind: "RunpodDesktopWidget")
         }) {
        self.dependencies = dependencies
        self.scheduler = scheduler ?? EnergyRefreshScheduler()
        self.invalidateWidget = invalidateWidget
    }

    var displayed: MonitorSnapshot { showingDemo ? demoSnapshot : snapshot }
    var dashboardVisible: Bool { environment.isInteractive && environment.windowVisible }

    private func rebuildRows() {
        orderedPods = displayed.sortedPods
        runningPods = orderedPods.filter(\.isRunning)
    }

    /// Tests disable the listener and inject credentials/transport/scheduling.
    func start(startBridge: Bool = true) {
        guard !started else { return }
        started = true
        bridgeEnabled = startBridge
        if startBridge {
            server.setSuspended(!environment.isInteractive)
            server.start(snapshot: snapshot, onError: { [weak self] in self?.bridgeError = $0 })
        }
        let account = accountGeneration
        loadingCredentials = true
        snapshot.lastAttempt = Date()
        credentialTask = Task { [weak self] in
            guard let self else { return }
            defer { loadingCredentials = false }
            do {
                let key = try await dependencies.readKey()
                guard !Task.isCancelled, accountGeneration == account else { return }
                apiKey = key
                connected = key != nil
                if connected { refresh(forceWidgetReload: true) }
                else { snapshot = .empty; reloadWidget(force: true) }
            } catch {
                guard !Task.isCancelled, accountGeneration == account else { return }
                message = error.localizedDescription
                snapshot = .failed(message: error.localizedDescription)
                reloadWidget(force: true)
            }
        }
    }

    func stop() {
        started = false
        credentialTask?.cancel()
        cancelRefresh()
        scheduler.invalidate()
        scheduledCadence = .suspended
        server.stop()
        bridgeEnabled = false
    }

    func updateEnvironment(_ next: RefreshEnvironment) {
        let previous = environment
        guard previous != next else { return }
        environment = next
        if bridgeEnabled { server.setSuspended(!next.isInteractive) }
        if !next.isInteractive, !mutatingCredentials { cancelRefresh() }
        configureSchedule()
        guard started, next.isInteractive else { return }
        if !previous.isInteractive || (!previous.windowVisible && next.windowVisible) {
            if mutatingCredentials { refreshAfterCredentials = true }
            else if connected { refresh(forceWidgetReload: pendingWidgetReload) }
            else { reloadWidget(force: pendingWidgetReload) }
        }
    }

    private func configureSchedule() {
        let cadence: RefreshCadence = started && connected ? environment.cadence : .suspended
        guard cadence != scheduledCadence else { return }
        scheduledCadence = cadence
        scheduler.schedule(cadence) { [weak self] in
            guard let self else { return false }
            sampleActivity?()
            guard started, connected, environment.isInteractive else { return false }
            guard let task = beginRefresh() else { return false }
            await task.value
            return !Task.isCancelled && environment.isInteractive
        }
    }

    private func cancelRefresh() {
        operationGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        refreshing = false
        mutatingCredentials = false
        refreshAfterCredentials = false
    }

    func connect() {
        guard environment.isInteractive else { return }
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { message = "Enter your Runpod API key first."; return }
        cancelRefresh()
        accountGeneration = UUID()
        let attempt = operationGeneration
        refreshing = true
        message = nil
        refreshTask = Task {
            defer {
                if operationGeneration == attempt {
                    refreshing = false
                    refreshTask = nil
                    mutatingCredentials = false
                    if refreshAfterCredentials {
                        refreshAfterCredentials = false
                        if connected { refresh(forceWidgetReload: pendingWidgetReload) }
                    }
                }
            }
            do {
                let fetched = try await dependencies.fetch(key)
                guard !Task.isCancelled, operationGeneration == attempt else { return }
                // Once Keychain mutation begins it must reconcile with memory,
                // even if the display sleeps while authorization is pending.
                // There is no network request left to cancel at this point.
                mutatingCredentials = true
                try await dependencies.saveKey(key)
                guard !Task.isCancelled, operationGeneration == attempt else { return }
                apiKey = key
                keyInput = ""
                connected = true
                showingDemo = false
                snapshot = fetched
                reloadWidget(force: true)
            } catch {
                guard !Task.isCancelled, operationGeneration == attempt else { return }
                message = error.localizedDescription
            }
        }
    }

    func refresh(forceWidgetReload: Bool = false) {
        _ = beginRefresh(forceWidgetReload: forceWidgetReload)
    }

    @discardableResult
    private func beginRefresh(forceWidgetReload: Bool = false) -> Task<Void, Never>? {
        guard environment.isInteractive, let key = apiKey else {
            pendingWidgetReload = pendingWidgetReload || forceWidgetReload
            return nil
        }
        if refreshing {
            pendingWidgetReload = pendingWidgetReload || forceWidgetReload
            return refreshTask
        }
        let attempt = operationGeneration
        refreshing = true
        if snapshot.lastUpdated == nil { snapshot.lastAttempt = Date() }
        let task = Task {
            defer { if operationGeneration == attempt { refreshing = false; refreshTask = nil } }
            do {
                let fetched = try await dependencies.fetch(key)
                guard !Task.isCancelled, operationGeneration == attempt else { return }
                snapshot = fetched
                message = nil
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, operationGeneration == attempt else { return }
                snapshot = .failed(message: error.localizedDescription, previous: snapshot, at: Date())
            }
            reloadWidget(force: forceWidgetReload || pendingWidgetReload)
        }
        refreshTask = task
        return task
    }

    func disconnect() {
        cancelRefresh()
        accountGeneration = UUID()
        let attempt = operationGeneration
        mutatingCredentials = true
        refreshing = true
        refreshTask = Task {
            defer {
                if operationGeneration == attempt {
                    refreshing = false; refreshTask = nil; mutatingCredentials = false
                    refreshAfterCredentials = false
                }
            }
            do {
                try await dependencies.removeKey()
                guard !Task.isCancelled, operationGeneration == attempt else { return }
                apiKey = nil
                connected = false
                showingDemo = false
                keyInput = ""
                snapshot = .empty
                message = nil
                reloadWidget(force: true)
            } catch {
                guard !Task.isCancelled, operationGeneration == attempt else { return }
                message = error.localizedDescription
            }
        }
    }

    private func reloadWidget(force: Bool) {
        guard environment.isInteractive else {
            pendingWidgetReload = pendingWidgetReload || force
            return
        }
        if widgetPolicy.request(snapshot: snapshot, force: force || pendingWidgetReload) { invalidateWidget() }
        pendingWidgetReload = false
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MonitorModel()
    private lazy var activity = AppActivityMonitor { [weak self] in self?.model.updateEnvironment($0) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        activity.start()
        model.sampleActivity = { [weak self] in self?.activity.resample() }
        model.start()
    }
    func applicationWillTerminate(_ notification: Notification) { activity.stop(); model.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct ContentView: View {
    @ObservedObject var model: MonitorModel
    @State private var showingWidgetHelp = false

    var body: some View {
        Group {
            if model.connected || model.showingDemo {
                DashboardView(model: model, showWidgetHelp: { showingWidgetHelp = true })
            } else {
                ConnectView(model: model)
            }
        }
        .frame(maxWidth: 820, maxHeight: .infinity)
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(MonitorStyle.accent)
        .sheet(isPresented: $showingWidgetHelp) { WidgetHelpView() }
        .onOpenURL { url in
            guard url.scheme == "runpoddesktop" else { return }
            model.refresh(forceWidgetReload: true)
            NSApp.activate()
        }
    }
}

struct BrandMark: View {
    var body: some View {
        Image(systemName: "square.stack.3d.up.fill")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(MonitorStyle.accent)
            .frame(width: 42, height: 42)
            .background(MonitorStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

struct ConnectView: View {
    @ObservedObject var model: MonitorModel
    private var keyIsEmpty: Bool { model.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                BrandMark()
                Text("Runpod Desktop").font(.headline)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 10) {
                Text("Your GPUs. At a glance.")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Credit time, pod status, and GPU usage.\nA little less checking. A little more building.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect your account").font(.headline)
                SecureField("Read-only Runpod API key", text: $model.keyInput)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .onSubmit { if !model.refreshing && !keyIsEmpty { model.connect() } }
                HStack {
                    Button(model.refreshing ? "Connecting…" : "Connect Runpod") { model.connect() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.refreshing || keyIsEmpty)
                    if model.refreshing { ProgressView().controlSize(.small) }
                    Spacer()
                    Link("Create an API key ↗", destination: URL(string: "https://console.runpod.io/user/credentials")!)
                        .font(.callout)
                }
                if model.loadingCredentials {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Checking your saved account…")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Saved in Keychain. Read-only access.", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .background(MonitorStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 0)
            HStack {
                Text("Just looking around?").foregroundStyle(.secondary)
                Button("Try with sample data") { model.showingDemo = true }.buttonStyle(.link)
            }
            .font(.callout)
        }
        .padding(32)
        .frame(maxWidth: 560, maxHeight: .infinity)
    }
}

struct DashboardView: View {
    @ObservedObject var model: MonitorModel
    let showWidgetHelp: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var onlyRunning = false
    private var snapshot: MonitorSnapshot { model.displayed }
    private var visiblePods: [PodSummary] { onlyRunning ? model.runningPods : model.orderedPods }

    var body: some View {
        VStack(spacing: 20) {
            header
            summary
            podList
            footer
        }
        .padding(24)
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandMark()
            VStack(alignment: .leading, spacing: 3) {
                Text("Runpod").font(.system(size: 18, weight: .semibold))
                Text("GPU overview").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.showingDemo {
                Text("Sample data").font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(MonitorStyle.accent.opacity(0.10), in: Capsule())
                    .foregroundStyle(MonitorStyle.accent)
            }
            if model.refreshing {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else {
                Button { model.refresh(forceWidgetReload: true) } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless).disabled(model.showingDemo)
                .help("Refresh account and widgets").accessibilityLabel("Refresh")
            }
            Menu {
                Button("Open Runpod Console") { openURL(URL(string: "https://console.runpod.io/pods")!) }
                if !model.showingDemo { Button("Preview sample data") { model.showingDemo = true } }
                if model.connected {
                    Divider()
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More options")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("ESTIMATED CREDIT LEFT", systemImage: "hourglass")
                        .font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(.secondary)
                    Text(MonitorFormat.creditTime(snapshot))
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                        .foregroundStyle(MonitorStyle.isLow(snapshot) ? Color.orange : Color.primary)
                        .contentTransition(.numericText())
                    Text(runsOut).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 16) {
                    accountMetric("Balance", value: MonitorFormat.money(snapshot.balance))
                    accountMetric("Current spend", value: "\(MonitorFormat.money(snapshot.spendPerHour)) / hr")
                }
            }
            if let error = snapshot.error ?? model.message {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(MonitorStyle.accent.opacity(0.055))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(MonitorStyle.accent.opacity(0.12)) }
        }
    }

    private func accountMetric(_ label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .medium)).monospacedDigit()
        }
    }

    private var runsOut: String {
        guard let hours = snapshot.creditHoursRemaining, let checked = snapshot.lastUpdated, hours < 87600 else {
            return snapshot.spendPerHour == 0 ? "No active spend reported" : "At your current spending rate"
        }
        return "Until about \(checked.addingTimeInterval(hours * 3600).formatted(date: .abbreviated, time: .shortened))"
    }

    private var podList: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Pods").font(.headline)
                Text("\(snapshot.runningCount) running · \(snapshot.pods.count) total")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Show pods", selection: $onlyRunning) {
                    Text("All").tag(false)
                    Text("Running").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 124)
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("POD").frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(["GPU", "VRAM", "CPU", "RAM"], id: \.self) { title in
                        Text(title).frame(width: 52, alignment: .trailing)
                    }
                }
                .font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 11)
                Divider().opacity(0.5)
                if visiblePods.isEmpty {
                    VStack(spacing: 8) {
                        if model.refreshing && snapshot.lastUpdated == nil {
                            ProgressView().controlSize(.small)
                            Text("Loading your pods…").font(.callout).foregroundStyle(.secondary)
                        } else if snapshot.lastUpdated == nil, snapshot.error != nil {
                            Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(.orange)
                            Text("Waiting for a connection").font(.callout.weight(.medium))
                            Text("Use Refresh to try again.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "square.stack.3d.up").font(.title2).foregroundStyle(.tertiary)
                            Text(onlyRunning ? "No running pods" : "No pods yet").font(.callout.weight(.medium))
                            Text(onlyRunning ? "Switch to All to see your other pods." : "Your pods will appear here when you create one in Runpod.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visiblePods) { pod in
                                AppPodRow(pod: pod)
                                if pod.id != visiblePods.last?.id {
                                    Divider().opacity(0.35).padding(.horizontal, 16)
                                }
                            }
                        }
                    }
                }
            }
            .background(MonitorStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.055)) }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.showingDemo {
                Text("Preview only").foregroundStyle(.secondary)
                Button(model.connected ? "Back to live data" : "Back to setup") { model.showingDemo = false }
                    .buttonStyle(.link)
            } else {
                SnapshotFooter(snapshot: snapshot, refreshing: model.refreshing, enabled: model.dashboardVisible)
            }
            if let bridgeError = model.bridgeError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(bridgeError).accessibilityLabel("Widget connection unavailable")
            }
            Spacer(minLength: 8)
            Button(action: showWidgetHelp) { Label("Desktop widget", systemImage: "rectangle.on.rectangle") }
                .buttonStyle(.borderless)
        }
        .font(.system(size: 11))
    }
}

private struct FooterTaskKey: Equatable {
    var updated: Date?
    var offline: Bool
    var demo: Bool
    var enabled: Bool
}

private struct SnapshotFooter: View {
    let snapshot: MonitorSnapshot
    let refreshing: Bool
    let enabled: Bool
    @State private var referenceDate = Date()

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(snapshot.error != nil || snapshot.isStale(at: referenceDate) ? Color.orange : Color.green)
                .frame(width: 5, height: 5)
            if let date = snapshot.lastUpdated {
                Text("\(snapshot.error != nil ? "Offline" : snapshot.isStale(at: referenceDate) ? "Stale" : "Updated") \(date.formatted(date: .omitted, time: .shortened))")
            } else { Text(refreshing ? "Connecting…" : "Waiting for first update") }
        }
        .foregroundStyle(.secondary)
        .task(id: FooterTaskKey(updated: snapshot.lastUpdated, offline: snapshot.error != nil,
                                demo: snapshot.isDemo, enabled: enabled)) {
            referenceDate = Date()
            guard enabled, let deadline = FreshnessDeadline.next(for: snapshot, after: referenceDate) else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)), tolerance: .milliseconds(250)) }
            catch { return }
            guard !Task.isCancelled else { return }
            referenceDate = Date()
        }
    }
}

struct AppPodRow: View {
    let pod: PodSummary
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                StatusDot(pod: pod)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pod.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(MonitorFormat.status(pod)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if pod.isRunning {
                metric(pod.gpuPercent, emphasized: true)
                metric(pod.vramPercent)
                metric(pod.cpuPercent)
                metric(pod.ramPercent)
            } else {
                Text("—").foregroundStyle(.tertiary).frame(width: 208, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pod.name), \(MonitorFormat.status(pod))")
        .accessibilityValue(pod.isRunning ? "GPU \(MonitorFormat.percentage(pod.gpuPercent)), GPU memory \(MonitorFormat.percentage(pod.vramPercent)), CPU \(MonitorFormat.percentage(pod.cpuPercent)), RAM \(MonitorFormat.percentage(pod.ramPercent))" : "")
    }
    private func metric(_ value: Double?, emphasized: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(MonitorFormat.percentage(value))
                .font(.system(size: 12, weight: emphasized ? .medium : .regular))
                .foregroundStyle(emphasized ? Color.primary : Color.secondary)
            if emphasized {
                GeometryReader { geometry in
                    Capsule().fill(MonitorStyle.accent.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule().fill(MonitorStyle.accent)
                                .frame(width: geometry.size.width * min(max((value ?? 0) / 100, 0), 1))
                        }
                }
                .frame(width: 30, height: 3).accessibilityHidden(true)
            }
        }
        .monospacedDigit().frame(width: 52, alignment: .trailing)
    }
}

struct WidgetHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var widgetStatus = "Checking your widgets…"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                BrandMark()
                VStack(alignment: .leading, spacing: 3) {
                    Text("A glance from your desktop").font(.headline)
                    Text("Runpod Desktop widget").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                step("1", "Right-click your desktop and choose Edit Widgets.")
                step("2", "Search for Runpod Desktop.")
                step("3", "Choose a size and drag it onto your desktop.")
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(MonitorStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            Text("Keep the app running for fresh readings. Closing its window is fine. macOS controls when widgets refresh.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(widgetStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh widgets") {
                    WidgetCenter.shared.reloadTimelines(ofKind: "RunpodDesktopWidget")
                    checkWidgets()
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 420).tint(MonitorStyle.accent)
        .onAppear { checkWidgets() }
    }
    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.weight(.semibold)).foregroundStyle(MonitorStyle.accent)
                .frame(width: 20, height: 20).background(MonitorStyle.accent.opacity(0.10), in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func checkWidgets() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            Task { @MainActor in
                switch result {
                case .success(let widgets):
                    let count = widgets.filter { $0.kind == "RunpodDesktopWidget" }.count
                    widgetStatus = count == 0 ? "No widgets added yet" : "\(count) widget\(count == 1 ? "" : "s") added"
                case .failure:
                    widgetStatus = "Widget check unavailable. Try reopening the app."
                }
            }
        }
    }
}

#if !RUNPOD_PREVIEW
@main
struct RunpodDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Runpod Desktop") {
            ContentView(model: delegate.model)
                // Route widget clicks to the existing window instead of opening a new one each time.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 640, height: 620)
        .windowResizability(.contentMinSize)
    }
}
#endif
