import SwiftUI
import WidgetKit

enum MonitorStyle {
    static let accent = Color.indigo
    static let surface = Color(nsColor: .textBackgroundColor)

    /// Credit estimates under this many hours are highlighted.
    static let lowCreditHours = 6.0

    static func statusColor(_ pod: PodSummary) -> Color {
        if pod.isRunning { return .green }
        if ["STARTING", "RESTARTING", "CREATED"].contains(pod.status.uppercased()) { return .orange }
        return .gray
    }
    static func isLow(_ snapshot: MonitorSnapshot) -> Bool {
        snapshot.creditHoursRemaining.map { $0 < lowCreditHours } ?? false
    }
}

struct StatusDot: View {
    let pod: PodSummary
    var body: some View {
        Circle().fill(MonitorStyle.statusColor(pod)).frame(width: 6, height: 6)
    }
}

/// Desktop widget content. Uses semantic colors only, so it adapts to light, dark,
/// and the tinted or clear widget styles where macOS removes the background.
struct MonitorBoard: View {
    let snapshot: MonitorSnapshot
    var family: WidgetFamily = .systemMedium
    var referenceDate: Date = Date()

    private var stale: Bool { snapshot.isStale(at: referenceDate) }
    private var capacity: Int { family == .systemLarge ? 6 : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if snapshot.lastUpdated == nil && snapshot.pods.isEmpty && snapshot.balance == nil {
                emptyState
            } else if family == .systemSmall {
                credit
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(MonitorFormat.money(snapshot.balance)) · \(MonitorFormat.money(snapshot.spendPerHour))/hr")
                    Text("\(snapshot.runningCount) of \(snapshot.pods.count) running")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Spacer(minLength: 6)
                footer
            } else {
                HStack(alignment: .firstTextBaseline) {
                    credit
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(MonitorFormat.money(snapshot.balance)).font(.system(size: 13, weight: .medium))
                        Text("\(MonitorFormat.money(snapshot.spendPerHour))/hr").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
                if family == .systemLarge {
                    pods.padding(.top, 20)
                } else {
                    Spacer(minLength: 8)
                    pods
                }
                Spacer(minLength: 8)
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var credit: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("CREDIT LEFT")
                .font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            Text(MonitorFormat.creditTime(snapshot))
                .font(.system(size: family == .systemLarge ? 36 : 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(MonitorStyle.isLow(snapshot) ? Color.orange : MonitorStyle.accent)
                .widgetAccentable()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var pods: some View {
        let shown = Array(snapshot.sortedPods.prefix(capacity))
        if shown.isEmpty {
            Text("No pods").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 3) {
                if shown.contains(where: \.isRunning) {
                    HStack(spacing: 0) {
                        Spacer()
                        Text("GPU").frame(width: 38, alignment: .trailing)
                        Text("VRAM").frame(width: 42, alignment: .trailing)
                    }
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
                VStack(spacing: family == .systemLarge ? 12 : 7) {
                    ForEach(shown) { pod in
                        WidgetPodRow(pod: pod)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if snapshot.isDemo {
                Text("Sample data")
            } else if let date = snapshot.lastUpdated {
                if snapshot.error != nil || stale {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(snapshot.error != nil ? "Offline · \(date, style: .time)" : "Stale · \(date, style: .time)")
                } else {
                    Text("Updated \(date, style: .time)")
                }
            } else {
                Text("Not connected")
            }
            Spacer(minLength: 4)
            if family != .systemSmall {
                Text(snapshot.pods.count > capacity
                     ? "+\(snapshot.pods.count - capacity) more"
                     : "\(snapshot.runningCount) of \(snapshot.pods.count) running")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 20)).foregroundStyle(MonitorStyle.accent).padding(.bottom, 6)
            Text(snapshot.lastAttempt != nil && snapshot.error == nil ? "Loading account…" : "Connect Runpod")
                .font(.system(size: 15, weight: .semibold))
            Text(snapshot.error ?? (snapshot.lastAttempt != nil ? "Your readings will appear shortly." : "Open Runpod Desktop to add your API key."))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            Spacer(minLength: 0)
        }
    }
}

struct WidgetPodRow: View {
    let pod: PodSummary
    var body: some View {
        HStack(spacing: 0) {
            StatusDot(pod: pod).padding(.trailing, 7)
            Text(pod.name).lineLimit(1)
            Spacer(minLength: 8)
            if pod.isRunning {
                Text(MonitorFormat.percentage(pod.gpuPercent)).frame(width: 38, alignment: .trailing)
                Text(MonitorFormat.percentage(pod.vramPercent)).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
            } else {
                Text(MonitorFormat.status(pod)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pod.name), \(MonitorFormat.status(pod))")
        .accessibilityValue(pod.isRunning ? "GPU \(MonitorFormat.percentage(pod.gpuPercent)), GPU memory \(MonitorFormat.percentage(pod.vramPercent))" : "")
    }
}
