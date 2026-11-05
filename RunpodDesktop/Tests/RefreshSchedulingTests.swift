// Run with: bash RunpodDesktop/check.sh
// The app is compiled with RUNPOD_PREVIEW; all external effects are injected.
import Foundation

private enum TestFailure: Error { case failed(String) }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure.failed(message) }
}

@MainActor
private func eventually(_ message: String, _ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw TestFailure.failed("Timed out: \(message)")
}

@MainActor
private final class ManualScheduler: RefreshScheduling {
    private(set) var cadences: [RefreshCadence] = []
    private(set) var invalidations = 0
    private(set) var fires = 0
    var action: (@MainActor @Sendable () async -> Bool)?

    func schedule(_ cadence: RefreshCadence, action: @escaping @MainActor @Sendable () async -> Bool) {
        cadences.append(cadence)
        self.action = action
    }
    func invalidate() { invalidations += 1; action = nil }
    func fire() async -> Bool { fires += 1; return await action?() ?? false }
}

/// Cancellation is recorded without resuming the request. This simulates a
/// transport that completes late, after its owning refresh has been canceled.
private actor ControlledTransport {
    private(set) var keys: [String] = []
    private(set) var cancellations: Set<Int> = []
    private(set) var completions: Set<Int> = []
    private var pending: [Int: CheckedContinuation<MonitorSnapshot, Error>] = [:]

    func fetch(_ key: String) async throws -> MonitorSnapshot {
        let request = keys.count
        keys.append(key)
        defer { completions.insert(request) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[request] = $0 }
        } onCancel: {
            Task { await self.cancel(request) }
        }
    }
    private func cancel(_ request: Int) { cancellations.insert(request) }
    func finish(_ request: Int, with value: MonitorSnapshot) {
        pending.removeValue(forKey: request)?.resume(returning: value)
    }
    func fail(_ request: Int) {
        pending.removeValue(forKey: request)?.resume(throwing: CancellationError())
    }
}

private actor ControlledCredentials {
    private let savedKey: String?
    private let delayRead: Bool
    private let delaySave: Bool
    private var pendingRead: CheckedContinuation<String?, Never>?
    private var pendingSave: CheckedContinuation<Void, Never>?
    private(set) var reads = 0
    private(set) var saves: [String] = []
    private(set) var removals = 0

    init(key: String?, delayRead: Bool, delaySave: Bool) {
        savedKey = key; self.delayRead = delayRead; self.delaySave = delaySave
    }
    func read() async -> String? {
        reads += 1
        if delayRead { return await withCheckedContinuation { pendingRead = $0 } }
        return savedKey
    }
    func releaseRead() { pendingRead?.resume(returning: savedKey); pendingRead = nil }
    func save(_ key: String) async {
        saves.append(key)
        if delaySave { await withCheckedContinuation { pendingSave = $0 } }
    }
    func releaseSave() { pendingSave?.resume(); pendingSave = nil }
    func remove() { removals += 1 }
}

@MainActor
private final class ReloadCounter { var count = 0 }

@MainActor
private final class Fixture {
    let scheduler = ManualScheduler()
    let transport = ControlledTransport()
    let credentials: ControlledCredentials
    let reloads = ReloadCounter()
    let model: MonitorModel

    init(key: String? = "saved-test-key", delayRead: Bool = false, delaySave: Bool = false) {
        credentials = ControlledCredentials(key: key, delayRead: delayRead, delaySave: delaySave)
        let transport = transport
        let credentials = credentials
        let reloads = reloads
        model = MonitorModel(dependencies: MonitorDependencies(
            fetch: { try await transport.fetch($0) }, readKey: { await credentials.read() },
            saveKey: { await credentials.save($0) }, removeKey: { await credentials.remove() }),
            scheduler: scheduler, invalidateWidget: { reloads.count += 1 })
    }

    func start(visible: Bool = true) {
        model.updateEnvironment(RefreshEnvironment(windowVisible: visible))
        model.start(startBridge: false)
    }
}

@main
struct RefreshSchedulingTests {
    @MainActor static func main() async throws {
        try checkPolicies()
        try await checkSchedulingAndCancellation()
        try await checkSleepingCredentialCompletion()
        try await checkCredentialSaveAcrossSleep()
        try await checkLateRequestCompletion()
        try await checkLateCredentialCompletion()
        try checkDashboardRows()
        print("Refresh checks passed: power/visibility cadence, cancellation, dark wake, manual refresh, disconnect, late completions, widget reload policy, stale deadlines, cached rows.")
    }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static func live(_ balance: Double = 10, seconds: TimeInterval = 0) -> MonitorSnapshot {
        MonitorSnapshot(pods: [], lastUpdated: now.addingTimeInterval(seconds), lastAttempt: now.addingTimeInterval(seconds),
                        error: nil, isDemo: false, balance: balance, spendPerHour: 1)
    }

    @MainActor private static func checkPolicies() throws {
        var environment = RefreshEnvironment()
        try check(environment.cadence == .background(900), "Hidden windows use a 15-minute background cadence")
        environment.lowPowerMode = true
        try check(environment.cadence == .background(3_600), "Low Power Mode stretches background work to one hour")
        environment.windowVisible = true
        try check(environment.cadence == .foreground, "Visible windows retain foreground updates in Low Power Mode")
        environment.systemAwake = false
        try check(environment.cadence == .suspended, "System sleep suspends refreshes")
        environment.systemAwake = true
        environment.displayAwake = false
        try check(environment.cadence == .suspended, "Dark wake remains suspended")
        environment.displayAwake = true
        environment.sessionActive = false
        try check(environment.cadence == .suspended, "An inactive session remains suspended")

        var policy = WidgetReloadPolicy()
        try check(policy.request(snapshot: .empty, force: false), "The first connection state is published")
        try check(!policy.request(snapshot: .empty, force: false), "Repeated disconnected state is suppressed")
        var loading = MonitorSnapshot.empty
        loading.lastAttempt = now
        try check(policy.request(snapshot: loading, force: false), "Loading is a connection-state change")
        loading.lastAttempt = now.addingTimeInterval(60)
        try check(!policy.request(snapshot: loading, force: false), "Attempt-only changes do not reload widgets")
        try check(policy.request(snapshot: live(), force: false), "First live data reloads the widget")
        try check(!policy.request(snapshot: live(9, seconds: 60), force: false), "Ordinary metric/timestamp changes use the provider timeline")
        let offline = MonitorSnapshot.failed(message: "Offline", previous: live())
        try check(policy.request(snapshot: offline, force: false), "An offline transition reloads the widget")
        try check(!policy.request(snapshot: .failed(message: "Different error", previous: live()), force: false),
                  "Hidden error-text changes do not repeat the same offline presentation")
        try check(policy.request(snapshot: live(), force: false), "Recovery reloads the widget")
        try check(policy.request(snapshot: live(), force: true), "Manual refresh bypasses state deduplication")
        try check(!policy.request(snapshot: live(), force: false), "Forced refresh does not poison subsequent deduplication")
        try check(policy.request(snapshot: .empty, force: false), "Disconnect reloads the cleared widget")
        try check(policy.request(snapshot: .failed(message: "First error"), force: false), "Empty error state is displayed")
        try check(policy.request(snapshot: .failed(message: "Second error"), force: false), "Visible error-text changes are displayed")

        let snapshot = live()
        let boundary = now.addingTimeInterval(900)
        let deadline = FreshnessDeadline.next(for: snapshot, after: boundary)
        try check(!snapshot.isStale(at: boundary) && deadline.map { $0 > boundary && snapshot.isStale(at: $0) } == true,
                  "The stale deadline falls just after the existing strict 900-second boundary")
        try check(FreshnessDeadline.next(for: snapshot, after: now) == deadline, "A fresh snapshot has one stable stale deadline")
        try check(FreshnessDeadline.next(for: snapshot, after: deadline!) == nil, "An elapsed stale deadline is not rescheduled")
        try check(FreshnessDeadline.next(for: .empty, after: now) == nil
                  && FreshnessDeadline.next(for: .demo, after: now) == nil
                  && FreshnessDeadline.next(for: .failed(message: "Offline", previous: snapshot), after: now) == nil,
                  "Missing, sample, and already-offline data need no stale timer")
    }

    @MainActor private static func checkSchedulingAndCancellation() async throws {
        let fixture = Fixture()
        let model = fixture.model
        defer { model.stop() }
        fixture.start()
        try await eventually("startup request") { await fixture.transport.keys.count == 1 }
        try check(fixture.scheduler.cadences == [.foreground], "Connected visible startup creates one foreground schedule")
        await fixture.transport.finish(0, with: live())
        try await eventually("first live reading") { model.snapshot == live() && !model.refreshing }
        let firstReloads = fixture.reloads.count
        try check(firstReloads == 1, "Startup publishes one widget update")
        let foregroundAction = fixture.scheduler.action!

        var environment = model.environment
        model.updateEnvironment(environment)
        try check(fixture.scheduler.cadences.count == 1, "Repeated environment notifications do not replace the schedule")
        environment.windowVisible = false
        model.updateEnvironment(environment)
        environment.lowPowerMode = true
        model.updateEnvironment(environment)
        model.updateEnvironment(environment)
        try check(fixture.scheduler.cadences == [.foreground, .background(900), .background(3_600)],
                  "Closing the window and enabling Low Power Mode reconfigure cadence once each")
        try check(await fixture.transport.keys.count == 1, "Hiding a window does not immediately fetch again")

        model.refresh()
        try await eventually("request before sleep") { await fixture.transport.keys.count == 2 }
        environment.systemAwake = false
        environment.displayAwake = false
        model.updateEnvironment(environment)
        try await eventually("transport cancellation") { await fixture.transport.cancellations.contains(1) }
        try check(!model.refreshing && fixture.scheduler.cadences.last == .suspended, "Sleep releases refresh state and suspends automatic work")
        await fixture.transport.fail(1)
        try await eventually("canceled transport exits") { await fixture.transport.completions.contains(1) }
        try check(model.snapshot == live() && model.snapshot.error == nil && fixture.reloads.count == firstReloads,
                  "Sleep cancellation preserves the successful reading without an offline update")

        environment.systemAwake = true
        model.updateEnvironment(environment)
        model.refresh(forceWidgetReload: true)
        try check(!(await foregroundAction()), "A callback queued before sleep is blocked during dark wake")
        try check(await fixture.transport.keys.count == 2 && fixture.reloads.count == firstReloads,
                  "Dark wake and manual requests defer all network/widget work while displays remain asleep")

        environment.displayAwake = true
        environment.windowVisible = true
        model.updateEnvironment(environment)
        model.updateEnvironment(environment)
        model.refresh(forceWidgetReload: true)
        let overlappingTick = Task { @MainActor in await fixture.scheduler.fire() }
        try await eventually("interactive wake request") { await fixture.transport.keys.count == 3 && fixture.scheduler.fires == 1 }
        await fixture.transport.finish(2, with: live(9, seconds: 60))
        let tickFinished = await overlappingTick.value
        try await eventually("wake request completion") { !model.refreshing }
        try check(await fixture.transport.keys.count == 3 && tickFinished,
                  "Interactive wake and concurrent triggers share one request")
        try check(fixture.reloads.count == firstReloads + 1, "Deferred manual force is delivered once after interactive wake")

        model.refresh(forceWidgetReload: true)
        try await eventually("manual request") { await fixture.transport.keys.count == 4 }
        await fixture.transport.finish(3, with: live(9, seconds: 60))
        try await eventually("manual completion") { !model.refreshing }
        try check(fixture.reloads.count == firstReloads + 2, "An explicit refresh reloads unchanged successful data")

        let automatic = Task { @MainActor in await fixture.scheduler.fire() }
        try await eventually("automatic request") { await fixture.transport.keys.count == 5 }
        await fixture.transport.finish(4, with: live(8, seconds: 120))
        try check(await automatic.value, "An awake automatic refresh finishes normally")
        try check(fixture.reloads.count == firstReloads + 2, "Ordinary metric changes do not invalidate the provider's timeline")

        environment.displayAwake = false
        model.updateEnvironment(environment)
        model.disconnect()
        try await eventually("disconnect while asleep") { !model.connected && !model.refreshing }
        try check(await fixture.credentials.removals == 1 && model.snapshot == .empty,
                  "Disconnect removes credentials and clears account readings during sleep")
        try check(fixture.reloads.count == firstReloads + 2, "Disconnect defers widget invalidation while asleep")
        environment.displayAwake = true
        model.updateEnvironment(environment)
        try check(await fixture.transport.keys.count == 5 && fixture.reloads.count == firstReloads + 3,
                  "Wake publishes the deferred cleared widget without fetching a disconnected account")
    }

    @MainActor private static func checkSleepingCredentialCompletion() async throws {
        let fixture = Fixture(delayRead: true)
        let model = fixture.model
        defer { model.stop() }
        fixture.start()
        try await eventually("pending credential read") { await fixture.credentials.reads == 1 }
        var environment = model.environment
        environment.systemAwake = false
        environment.displayAwake = false
        model.updateEnvironment(environment)
        await fixture.credentials.releaseRead()
        try await eventually("credentials finish during sleep") { model.connected && !model.loadingCredentials }
        try check(await fixture.transport.keys.isEmpty && fixture.reloads.count == 0 && fixture.scheduler.cadences.isEmpty,
                  "Saved credentials completing during sleep do not start polling or invalidate widgets")
        environment.systemAwake = true
        model.updateEnvironment(environment)
        try check(await fixture.transport.keys.isEmpty, "Credential startup remains blocked during a dark wake")
        environment.displayAwake = true
        model.updateEnvironment(environment)
        try await eventually("first interactive request") { await fixture.transport.keys.count == 1 }
        await fixture.transport.finish(0, with: live())
        try await eventually("first interactive result") { !model.refreshing }
        try check(fixture.reloads.count == 1, "The deferred startup force is delivered after a successful interactive fetch")
    }

    @MainActor private static func checkCredentialSaveAcrossSleep() async throws {
        for wakeBeforeSaving in [false, true] {
            let fixture = Fixture(key: nil, delaySave: true)
            let model = fixture.model
            defer { model.stop() }
            fixture.start()
            try await eventually("initial credential lookup") { !model.loadingCredentials }
            let initialReloads = fixture.reloads.count
            model.keyInput = "new-account-key"
            model.connect()
            try await eventually("connection validation") { await fixture.transport.keys.count == 1 }
            await fixture.transport.finish(0, with: live())
            try await eventually("pending credential save") { await fixture.credentials.saves == ["new-account-key"] }
            var environment = model.environment
            environment.displayAwake = false
            model.updateEnvironment(environment)
            try check(model.refreshing && !model.connected, "Sleep lets an already-started credential mutation reconcile")
            if wakeBeforeSaving {
                environment.displayAwake = true
                model.updateEnvironment(environment)
                model.updateEnvironment(environment)
                try check(await fixture.transport.keys.count == 1, "Wake while saving credentials does not start an overlapping request")
            }
            await fixture.credentials.releaseSave()
            try await eventually("saved account reconciles") { model.connected && model.snapshot == live() }
            if !wakeBeforeSaving {
                try check(!model.refreshing && fixture.reloads.count == initialReloads,
                          "A save finishing asleep connects memory without reloading widgets")
                environment.displayAwake = true
                model.updateEnvironment(environment)
            }
            try await eventually("single post-save refresh") { await fixture.transport.keys.count == 2 }
            await fixture.transport.finish(1, with: live(9, seconds: 60))
            try await eventually("post-save result") { !model.refreshing && model.snapshot.balance == 9 }
            try check(await fixture.transport.keys == ["new-account-key", "new-account-key"]
                      && fixture.reloads.count == initialReloads + 1,
                      "Sleep/wake around credential save schedules one follow-up request and one connection widget update")
        }
    }

    @MainActor private static func checkLateRequestCompletion() async throws {
        let fixture = Fixture()
        let model = fixture.model
        defer { model.stop() }
        fixture.start()
        try await eventually("old pending request") { await fixture.transport.keys.count == 1 }
        var environment = model.environment
        environment.displayAwake = false
        model.updateEnvironment(environment)
        environment.displayAwake = true
        model.updateEnvironment(environment)
        try await eventually("replacement request") { await fixture.transport.keys.count == 2 }
        await fixture.transport.finish(1, with: live(8, seconds: 60))
        try await eventually("replacement data published") { model.snapshot.balance == 8 && !model.refreshing }
        let reloads = fixture.reloads.count
        await fixture.transport.finish(0, with: live(99))
        try await eventually("late canceled request exits") { await fixture.transport.completions.contains(0) }
        for _ in 0..<10 { await Task.yield() }
        try check(model.snapshot == live(8, seconds: 60) && fixture.reloads.count == reloads && !model.refreshing,
                  "A canceled request completing after its replacement cannot overwrite data or reload widgets")

        model.refresh()
        try await eventually("request before disconnect") { await fixture.transport.keys.count == 3 }
        model.disconnect()
        try await eventually("disconnect completes") { !model.connected && !model.refreshing }
        await fixture.transport.finish(2, with: live(77))
        try await eventually("late disconnected request exits") { await fixture.transport.completions.contains(2) }
        for _ in 0..<10 { await Task.yield() }
        try check(model.snapshot == .empty && !model.connected, "Late account data cannot repopulate a disconnected model")
    }

    @MainActor private static func checkLateCredentialCompletion() async throws {
        let fixture = Fixture(key: "old-saved-key", delayRead: true)
        let model = fixture.model
        defer { model.stop() }
        fixture.start()
        try await eventually("old credential read") { await fixture.credentials.reads == 1 }
        model.keyInput = "new-account-key"
        model.connect()
        try await eventually("new account validation") { await fixture.transport.keys == ["new-account-key"] }
        await fixture.transport.finish(0, with: live(7))
        try await eventually("new account connected") { model.connected && !model.refreshing }
        await fixture.credentials.releaseRead()
        try await eventually("stale credential read exits") { !model.loadingCredentials }
        try check(await fixture.credentials.saves == ["new-account-key"] && model.snapshot.balance == 7,
                  "A newly connected account survives an older credential read")
        model.refresh()
        try await eventually("new account refresh") { await fixture.transport.keys.count == 2 }
        try check(await fixture.transport.keys == ["new-account-key", "new-account-key"], "A late credential read cannot replace the active API key")
        await fixture.transport.finish(1, with: live(6))
        try await eventually("new account refresh completes") { !model.refreshing }
    }

    @MainActor private static func checkDashboardRows() throws {
        let fixture = Fixture(key: nil)
        let model = fixture.model
        func pod(_ id: String, _ name: String, running: Bool) -> PodSummary {
            PodSummary(id: id, name: name, status: running ? "RUNNING" : "EXITED", gpuPercent: nil,
                       vramPercent: nil, cpuPercent: nil, ramPercent: nil, uptimeSeconds: nil,
                       costPerHour: nil, observedAt: nil)
        }
        var snapshot = live()
        snapshot.pods = [pod("a", "zeta", running: false), pod("b", "Beta", running: true),
                         pod("c", "alpha", running: true), pod("d", "Alpha", running: false)]
        model.snapshot = snapshot
        try check(model.orderedPods.map(\.id) == ["c", "b", "d", "a"] && model.runningPods.map(\.id) == ["c", "b"],
                  "Cached dashboard arrays keep running-first, case-insensitive name ordering and the running filter")
        model.showingDemo = true
        let demo = model.displayed
        let demoRows = model.orderedPods
        try check(demo.isDemo && demoRows == demo.sortedPods && model.runningPods == demoRows.filter(\.isRunning),
                  "Demo mode rebuilds both cached row arrays")
        snapshot.pods = [pod("new", "new pod", running: false)]
        model.snapshot = snapshot
        try check(model.orderedPods == demoRows && model.displayed == demo && !model.snapshot.isDemo,
                  "Live updates do not mutate stable sample data or its cached rows")
        model.showingDemo = false
        try check(model.orderedPods == snapshot.pods && model.runningPods.isEmpty && model.displayed == snapshot,
                  "Leaving demo mode restores current live rows and updates the running filter")
    }
}
