import AppKit
import CoreGraphics
import Foundation

enum RefreshCadence: Equatable {
    case suspended
    case foreground
    case background(TimeInterval)
}

struct RefreshEnvironment: Equatable {
    var systemAwake = true
    var displayAwake = true
    var sessionActive = true
    var windowVisible = false
    var lowPowerMode = false

    var isInteractive: Bool { systemAwake && displayAwake && sessionActive }
    var cadence: RefreshCadence {
        guard isInteractive else { return .suspended }
        return windowVisible ? .foreground : .background(lowPowerMode ? 60 * 60 : 15 * 60)
    }
}

@MainActor
protocol RefreshScheduling: AnyObject {
    func schedule(_ cadence: RefreshCadence, action: @escaping @MainActor @Sendable () async -> Bool)
    func invalidate()
}

/// A foreground timer never survives a policy change. Hidden-window work is
/// offered to macOS rather than maintained by another precise repeating timer.
@MainActor
final class EnergyRefreshScheduler: RefreshScheduling {
    private var timer: Timer?
    private var activity: NSBackgroundActivityScheduler?
    private var generation = UUID()

    func invalidate() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
        activity?.invalidate()
        activity = nil
    }

    func schedule(_ cadence: RefreshCadence, action: @escaping @MainActor @Sendable () async -> Bool) {
        invalidate()
        let attempt = generation
        switch cadence {
        case .suspended:
            break
        case .foreground:
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard self?.generation == attempt else { return }
                    _ = await action()
                }
            }
            timer.tolerance = 6
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        case .background(let interval):
            let activity = NSBackgroundActivityScheduler(identifier: "local.abteen.RunpodDesktop.refresh")
            activity.interval = interval
            activity.tolerance = interval / 3
            activity.repeats = true
            activity.qualityOfService = .background
            self.activity = activity
            activity.schedule { [weak self] completion in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt, let activity = self.activity,
                          !activity.shouldDefer else { completion(.deferred); return }
                    let finished = await action()
                    completion(finished && self.generation == attempt && !activity.shouldDefer ? .finished : .deferred)
                }
            }
        }
    }
}

/// Ordinary readings use the provider's timeline policy. The app invalidates
/// timelines only for explicit refreshes and visible connection-state changes.
struct WidgetReloadPolicy {
    private enum State: Equatable {
        case disconnected, loading, live, offline(String?)
    }
    private var previous: State?

    mutating func request(snapshot: MonitorSnapshot, force: Bool) -> Bool {
        let state: State
        if snapshot.error != nil {
            // Only the empty widget displays the error text itself.
            state = .offline(snapshot.lastUpdated == nil ? snapshot.error : nil)
        } else if snapshot.lastUpdated != nil { state = .live }
        else if snapshot.lastAttempt != nil { state = .loading }
        else { state = .disconnected }
        guard force || state != previous else { return false }
        previous = state
        return true
    }
}

/// The existing stale predicate is strictly greater than 900 seconds.
enum FreshnessDeadline {
    static func next(for snapshot: MonitorSnapshot, after now: Date) -> Date? {
        guard snapshot.error == nil, !snapshot.isDemo, let updated = snapshot.lastUpdated else { return nil }
        let deadline = updated.addingTimeInterval(900.001)
        return deadline > now ? deadline : nil
    }
}

/// Observe lifecycle edges rather than polling for window/display state.
@MainActor
final class AppActivityMonitor {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var environment = RefreshEnvironment()
    private let changed: @MainActor (RefreshEnvironment) -> Void

    init(changed: @escaping @MainActor (RefreshEnvironment) -> Void) { self.changed = changed }

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] _ in
            self?.environment.systemAwake = false
            self?.environment.displayAwake = false
            self?.publish()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.environment.systemAwake = true
            self?.resample()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] _ in
            self?.environment.displayAwake = false
            self?.publish()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] _ in
            self?.environment.systemAwake = true
            self?.resample()
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in
            self?.environment.sessionActive = false
            self?.publish()
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in self?.resample() }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSApplication.didBecomeActiveNotification, .NSProcessInfoPowerStateDidChange] {
            observe(.default, name) { [weak self] _ in self?.resample() }
        }
        observe(.default, NSWindow.willCloseNotification) { [weak self] windowID in
            self?.resample(excluding: windowID)
        }
        resample()
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    /// Also used at automatic refresh boundaries, covering missed lifecycle
    /// delivery while this process was suspended. A dark wake keeps displays off.
    func resample(excluding closingWindow: ObjectIdentifier? = nil) {
        environment.displayAwake = false
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 {
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if CGGetOnlineDisplayList(count, &displays, &count) == .success {
                environment.displayAwake = displays.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
            }
        }
        // User-visible displays are also evidence of a full wake if this process
        // missed a workspace wake notification while it was suspended.
        if environment.displayAwake { environment.systemAwake = true }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            environment.sessionActive = session[kCGSessionOnConsoleKey as String] as? Bool ?? true
        }
        environment.windowVisible = NSApp.windows.contains {
            ObjectIdentifier($0) != closingWindow && $0.styleMask.contains(.titled) && $0.isVisible
                && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
        environment.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        publish()
    }

    private func publish() { changed(environment) }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor @Sendable (ObjectIdentifier?) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
            let windowID = (notification.object as? NSWindow).map(ObjectIdentifier.init)
            // All sources are delivered on the main queue. Handle sleep before
            // returning to the run loop so an already-due timer cannot win a race.
            MainActor.assumeIsolated { action(windowID) }
        }
        observers.append((center, token))
    }
}
