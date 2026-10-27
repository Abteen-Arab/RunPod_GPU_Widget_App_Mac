import SwiftUI
import WidgetKit

enum MonitorStyle {
    static let mint = Color(red: 0.39, green: 0.91, blue: 0.78)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.35)
    static let background = Color(red: 0.065, green: 0.09, blue: 0.115)
    static func statusColor(_ pod: PodSummary) -> Color {
        if pod.isRunning { return mint }
        if ["STARTING", "RESTARTING", "CREATED"].contains(pod.status) { return amber }
        return Color.white.opacity(0.44)
    }
    static func percentage(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "—"
    }
    static func creditTime(_ snapshot: MonitorSnapshot) -> String {
        if let hours = snapshot.creditHoursRemaining {
            if hours == 0 { return "0h" }
            if hours < 0.1 { return "<0.1h" }
            return String(format: hours < 100 ? "%.1fh" : "%.0fh", hours)
        }
        if snapshot.spendPerHour == 0, snapshot.balance != nil { return "No spend" }
        return "—"
    }
    static func money(_ value: Double?) -> String {
        value.map { String(format: "$%.2f", $0) } ?? "—"
    }
}

struct MonitorBoard: View {
    let snapshot: MonitorSnapshot
    var family: WidgetFamily = .systemMedium
    var referenceDate: Date = Date()
    private var stale: Bool { snapshot.lastUpdated.map { referenceDate.timeIntervalSince($0) > 900 } ?? true }
    private var running: Int { snapshot.pods.filter(\.isRunning).count }
    private var capacity: Int { family == .systemLarge ? 6 : 2 }
    private var sortedPods: [PodSummary] {
        snapshot.pods.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(MonitorStyle.mint)
                Text("RUNPOD").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.7)
                Spacer(minLength: 0)
                if !snapshot.pods.isEmpty, family != .systemSmall {
                    Text("\(running)/\(snapshot.pods.count) up").font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
                }
                if snapshot.isDemo {
                    Text("DEMO").font(.system(size: 8, weight: .bold)).foregroundStyle(MonitorStyle.amber)
                } else if snapshot.error != nil || (snapshot.lastUpdated != nil && stale) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(MonitorStyle.amber)
                }
            }
            if snapshot.pods.isEmpty && snapshot.balance == nil {
                emptyState
            } else if family == .systemSmall {
                compactContent
            } else {
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(MonitorStyle.creditTime(snapshot)).font(.system(size: family == .systemLarge ? 28 : 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(snapshot.creditHoursRemaining.map { $0 < 6 } == true ? MonitorStyle.amber : .white)
                        Text("estimated credit time left").font(.system(size: 8)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(MonitorStyle.money(snapshot.balance)) balance").font(.system(size: 11, weight: .semibold, design: .rounded))
                        Text("\(MonitorStyle.money(snapshot.spendPerHour)) / hr").font(.system(size: 9)).foregroundStyle(.white.opacity(0.48))
                    }
                }
                VStack(spacing: family == .systemLarge ? 14 : 6) {
                    if snapshot.pods.isEmpty {
                        Text("No pods in this account").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                    ForEach(Array(sortedPods.prefix(capacity))) { pod in
                        WidgetPodRow(pod: pod)
                    }
                }
                Spacer(minLength: 0)
                footer
            }
        }
        .foregroundStyle(.white)
        .padding(1)
        .accessibilityElement(children: .contain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: snapshot.lastUpdated == nil ? "link" : "square.stack").font(.title2).foregroundStyle(MonitorStyle.mint)
            Text(snapshot.lastUpdated == nil ? "Connect Runpod" : "No pods found")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(snapshot.error ?? (snapshot.lastUpdated == nil ? "Open Runpod Desktop to add your API key." : "Your account has no pods."))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(3)
            Spacer(minLength: 0)
            footer
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(MonitorStyle.creditTime(snapshot)).font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(snapshot.creditHoursRemaining.map { $0 < 6 } == true ? MonitorStyle.amber : .white)
                if snapshot.creditHoursRemaining != nil { Text("left").font(.system(size: 10)).foregroundStyle(.white.opacity(0.58)) }
            }
            Text("\(running)/\(snapshot.pods.count) up · est. at current spend").font(.system(size: 8)).foregroundStyle(.white.opacity(0.5))
            if let pod = sortedPods.first {
                Text(pod.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text("GPU").foregroundStyle(.white.opacity(0.5))
                    Text(MonitorStyle.percentage(pod.isRunning ? pod.gpuPercent : nil)).foregroundStyle(MonitorStyle.mint)
                    Spacer(minLength: 0)
                    Circle().fill(MonitorStyle.statusColor(pod)).frame(width: 5, height: 5)
                }.font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            Spacer(minLength: 0)
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Circle().fill(snapshot.error != nil || stale ? MonitorStyle.amber : MonitorStyle.mint).frame(width: 4, height: 4)
            if snapshot.isDemo {
                Text(family == .systemSmall ? "Sample data" : "Sample data · open to connect")
            } else if snapshot.error != nil {
                Text("Offline ·")
                if let date = snapshot.lastUpdated { Text(date, style: .time) }
                else { Text("open to connect") }
            } else if let date = snapshot.lastUpdated {
                Text(stale ? "Stale ·" : "Updated")
                Text(date, style: .time)
            } else {
                Text("Tap to set up")
            }
            Spacer(minLength: 0)
            if family != .systemSmall {
                if snapshot.pods.count > capacity {
                    Text("+\(snapshot.pods.count - capacity) more").font(.system(size: 8))
                }
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.white.opacity(0.5))
        .lineLimit(1)
    }
}

struct WidgetPodRow: View {
    let pod: PodSummary
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(MonitorStyle.statusColor(pod)).frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(pod.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(pod.status.replacingOccurrences(of: "_", with: " ").lowercased())
                    .font(.system(size: 8)).foregroundStyle(.white.opacity(0.42))
            }
            Spacer(minLength: 4)
            metric("GPU", pod.isRunning ? pod.gpuPercent : nil)
            metric("VRAM", pod.isRunning ? pod.vramPercent : nil)
        }
    }
    private func metric(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(MonitorStyle.percentage(value)).font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(label == "GPU" ? MonitorStyle.mint : .white.opacity(0.8))
            Text(label).font(.system(size: 7, weight: .medium)).foregroundStyle(.white.opacity(0.4))
        }.frame(width: 37, alignment: .trailing)
    }
}
