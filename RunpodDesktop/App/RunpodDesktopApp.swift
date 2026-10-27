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

@MainActor
final class MonitorModel: ObservableObject {
    @Published var snapshot: MonitorSnapshot = .empty
    @Published var keyInput = ""
    @Published var connected = false
    @Published var refreshing = false
    @Published var message: String?
    @Published var bridgeError: String?
    private var apiKey: String?
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastWidgetReload = Date.distantPast
    private let server = BridgeServer()

    init() {
        server.start(snapshot: { [weak self] in self?.snapshot ?? .empty }, onError: { [weak self] text in
            self?.bridgeError = text
        })
        do {
            apiKey = try CredentialStore.read()
            connected = apiKey != nil
            if connected { refresh(forceWidgetReload: true) }
        } catch { message = error.localizedDescription }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                self?.refresh()
            }
        }
    }

    func connect() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { message = "Enter your Runpod API key first."; return }
        refreshTask?.cancel()
        generation = UUID()
        let attempt = generation
        refreshing = true
        message = nil
        refreshTask = Task {
            defer { if generation == attempt { refreshing = false } }
            do {
                let fetched = try await RunpodClient().fetch(apiKey: key)
                guard !Task.isCancelled, generation == attempt else { return }
                try CredentialStore.save(key)
                apiKey = key
                keyInput = ""
                connected = true
                snapshot = fetched
                reloadWidget(force: true)
            } catch {
                guard !Task.isCancelled, generation == attempt else { return }
                message = error.localizedDescription
            }
        }
    }

    func refresh(forceWidgetReload: Bool = false) {
        guard let key = apiKey, !refreshing, !snapshot.isDemo else { return }
        let attempt = generation
        refreshing = true
        refreshTask = Task {
            defer { if generation == attempt { refreshing = false } }
            do {
                let fetched = try await RunpodClient().fetch(apiKey: key)
                guard !Task.isCancelled, generation == attempt else { return }
                snapshot = fetched
                message = nil
            } catch {
                guard !Task.isCancelled, generation == attempt else { return }
                snapshot = .failed(message: error.localizedDescription, previous: snapshot, at: Date())
            }
            reloadWidget(force: forceWidgetReload)
        }
    }

    func useDemo() {
        refreshTask?.cancel()
        generation = UUID()
        refreshing = false
        snapshot = .demo
        message = nil
        reloadWidget(force: true)
    }

    func resumeLive() {
        snapshot = .empty
        refresh(forceWidgetReload: true)
    }

    func disconnect() {
        do {
            try CredentialStore.remove()
            refreshTask?.cancel()
            generation = UUID()
            apiKey = nil
            connected = false
            refreshing = false
            keyInput = ""
            snapshot = .empty
            message = nil
            reloadWidget(force: true)
        } catch { message = error.localizedDescription }
    }

    private func reloadWidget(force: Bool) {
        if force || Date().timeIntervalSince(lastWidgetReload) >= 15 * 60 {
            WidgetCenter.shared.reloadTimelines(ofKind: "RunpodDesktopWidget")
            lastWidgetReload = Date()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct SetupView: View {
    @ObservedObject var model: MonitorModel
    @State private var showInstructions = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Runpod, at a glance.").font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("Your GPU fleet and remaining credit time, right on your desktop.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 30)).foregroundStyle(MonitorStyle.mint)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.connected ? "ACCOUNT CONNECTED" : "CONNECT YOUR ACCOUNT").font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(.secondary)
                    if model.connected {
                        Label("API key saved in Keychain", systemImage: "checkmark.shield.fill").font(.system(size: 13)).foregroundStyle(MonitorStyle.mint)
                        Text("Checks your pods every minute while this app is open. You can close this window.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(model.snapshot.isDemo ? "Resume live data" : "Refresh now") {
                                if model.snapshot.isDemo { model.resumeLive() } else { model.refresh(forceWidgetReload: true) }
                            }.disabled(model.refreshing)
                            if model.refreshing { ProgressView().controlSize(.small) }
                            Spacer()
                            Button("Disconnect") { model.disconnect() }.foregroundStyle(.secondary)
                        }
                    } else {
                        SecureField("Runpod API key", text: $model.keyInput)
                            .textFieldStyle(.roundedBorder).onSubmit { model.connect() }
                        HStack {
                            Button { model.connect() } label: {
                                Text("Connect & save in Keychain").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.black).padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(MonitorStyle.mint, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                                .disabled(model.refreshing || model.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .opacity(model.refreshing || model.keyInput.isEmpty ? 0.5 : 1)
                            if model.refreshing { ProgressView().controlSize(.small) }
                        }
                        Link("Create a read-only Runpod API key ↗", destination: URL(string: "https://console.runpod.io/user/credentials")!)
                            .font(.system(size: 11))
                        Text("Only reads pod status and usage. Your key stays in this app’s Keychain storage.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = model.message {
                        Text(error).font(.system(size: 11)).foregroundStyle(MonitorStyle.amber).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider().padding(.vertical, 2)
                    Button("Add desktop widget…") { showInstructions = true }
                    Button(model.snapshot.isDemo ? "Showing sample data" : "Preview with sample data") { model.useDemo() }
                        .font(.system(size: 11)).foregroundStyle(.secondary).disabled(model.snapshot.isDemo)
                }.frame(width: 305, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    Text("WIDGET PREVIEW").font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(.secondary)
                    MonitorBoard(snapshot: model.snapshot, family: .systemMedium)
                        .padding(16).frame(width: 340, height: 180)
                        .background(LinearGradient(colors: [Color(red: 0.10, green: 0.15, blue: 0.18), MonitorStyle.background], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08)))
                    Text("macOS schedules widget refreshes. Click the widget to open this app and request an update.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(width: 340, alignment: .leading)
                }
            }
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ESTIMATED CREDIT TIME LEFT").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                    Text(MonitorStyle.creditTime(model.snapshot)).font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(model.snapshot.creditHoursRemaining.map { $0 < 6 } == true ? MonitorStyle.amber : MonitorStyle.mint)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(MonitorStyle.money(model.snapshot.balance)) balance · \(MonitorStyle.money(model.snapshot.spendPerHour))/hr")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                    Text("Balance ÷ current hourly spend. Actual time changes with usage.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let hours = model.snapshot.creditHoursRemaining, let checked = model.snapshot.lastUpdated,
                       hours < 87600 {
                        Text("Estimated to run out \(checked.addingTimeInterval(hours * 3600).formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }.padding(16).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            if let error = model.bridgeError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(MonitorStyle.amber)
            }
            HStack {
                Text("YOUR PODS").font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(.secondary)
                Spacer()
                if model.snapshot.isDemo { Text("SAMPLE DATA").foregroundStyle(MonitorStyle.amber).font(.system(size: 10, weight: .semibold)) }
                else if let date = model.snapshot.lastUpdated { Text("Last updated \(date.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if let error = model.snapshot.error {
                Text(error).font(.system(size: 11)).foregroundStyle(MonitorStyle.amber)
            }
            if model.snapshot.pods.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text(model.connected ? "No pods found in this account." : "Connect your account to see your pods.").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.snapshot.pods) { pod in
                            HStack {
                                WidgetPodRow(pod: pod)
                                Text("CPU \(MonitorStyle.percentage(pod.isRunning ? pod.cpuPercent : nil))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                                Text("RAM \(MonitorStyle.percentage(pod.isRunning ? pod.ramPercent : nil))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                            }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.frame(minHeight: 100, maxHeight: 170)
            }
            Spacer(minLength: 0)
            HStack(alignment: .top) {
                Text("Pod status comes from Runpod; it does not check the health of the service inside the pod.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Link("Open Runpod ↗", destination: URL(string: "https://console.runpod.io/pods")!).font(.system(size: 11))
            }
        }
        .padding(28).frame(minWidth: 730, minHeight: 710)
        .background(Color(red: 0.065, green: 0.08, blue: 0.10))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showInstructions) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add Runpod to your desktop").font(.title2.weight(.semibold))
                Text("1. Right-click an empty area of your desktop.\n2. Choose Edit Widgets.\n3. Search for Runpod Desktop.\n4. Choose a size and add it to your desktop.").lineSpacing(7)
                Text("Keep Runpod Desktop running for fresh readings. Closing its window is fine. After restarting your Mac, open the app again.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("The desktop widget refreshes on macOS’s schedule, usually much less often than this app. Its timestamp shows how current the readings are.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Done") { showInstructions = false }.keyboardShortcut(.defaultAction)
            }.padding(28).frame(width: 460)
        }
        .onOpenURL { url in
            guard url.scheme == "runpoddesktop" else { return }
            if model.snapshot.isDemo, model.connected { model.resumeLive() }
            else { model.refresh(forceWidgetReload: true) }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct RunpodDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = MonitorModel()
    var body: some Scene {
        WindowGroup("Runpod Desktop") { SetupView(model: model) }
            .defaultSize(width: 730, height: 750)
            .windowResizability(.contentMinSize)
    }
}
