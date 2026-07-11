import AppKit
import SwiftUI
import SwiftData

// MARK: - Service

/// On-device workflow analysis. Records app activations (fed by the
/// AppDelegate's workspace observer) and derives simple, private insights:
/// where your time goes today and which app pair you bounce between most.
@Observable
final class WorkflowInsightsService {
    static let shared = WorkflowInsightsService()

    struct AppUsage: Identifiable {
        let bundleID: String
        let name: String
        let minutes: Double
        var id: String { bundleID }
    }

    struct PairSuggestion {
        let firstName: String
        let secondName: String
        let switches: Int
    }

    private(set) var todayUsage: [AppUsage] = []
    private(set) var suggestion: PairSuggestion?

    private var lastBundleID: String?

    private init() {}

    // MARK: Recording

    /// Called on every app activation. Gaps longer than `idleCap` count as
    /// idle time, not usage of the previous app.
    func recordActivation(of app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        let event = AppUsageEvent(bundleID: bundleID,
                                  appName: app.localizedName ?? bundleID,
                                  previousBundleID: lastBundleID)
        lastBundleID = bundleID
        Persistence.shared.context.insert(event)
        Persistence.shared.save()
    }

    /// Keep only the last 14 days of events — enough for pair detection
    /// without letting the store grow unbounded. Called once at launch;
    /// running it per activation would fetch the whole table on every
    /// app switch.
    func pruneOldEvents() {
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        let ctx = Persistence.shared.context
        let old = (try? ctx.fetch(FetchDescriptor<AppUsageEvent>(
            predicate: #Predicate { $0.timestamp < cutoff }))) ?? []
        guard !old.isEmpty else { return }
        for e in old { ctx.delete(e) }
        Persistence.shared.save()
    }

    // MARK: Analysis

    /// Recompute today's usage and the top app pair. Cheap enough to run
    /// every time the popover opens.
    func refresh() {
        let ctx = Persistence.shared.context
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let events = ((try? ctx.fetch(FetchDescriptor<AppUsageEvent>(
            predicate: #Predicate { $0.timestamp >= startOfDay },
            sortBy: [SortDescriptor(\.timestamp)]))) ?? [])

        todayUsage = usage(from: events)
        suggestion = topPair(from: events)
    }

    private func usage(from events: [AppUsageEvent]) -> [AppUsage] {
        // Time in an app ≈ interval until the next activation, capped so an
        // untouched Mac doesn't credit hours to the last-used app.
        let idleCap: TimeInterval = 10 * 60
        var seconds: [String: TimeInterval] = [:]
        var names: [String: String] = [:]
        for (event, next) in zip(events, events.dropFirst()) {
            let interval = min(next.timestamp.timeIntervalSince(event.timestamp), idleCap)
            seconds[event.bundleID, default: 0] += interval
            names[event.bundleID] = event.appName
        }
        if let last = events.last {
            let interval = min(Date().timeIntervalSince(last.timestamp), idleCap)
            seconds[last.bundleID, default: 0] += interval
            names[last.bundleID] = last.appName
        }
        return seconds
            .map { AppUsage(bundleID: $0.key, name: names[$0.key] ?? $0.key,
                            minutes: $0.value / 60) }
            .sorted { $0.minutes > $1.minutes }
    }

    private func topPair(from events: [AppUsageEvent]) -> PairSuggestion? {
        var counts: [String: (names: (String, String), count: Int)] = [:]
        var lastNames: [String: String] = [:]
        for event in events {
            lastNames[event.bundleID] = event.appName
            guard let prev = event.previousBundleID, prev != event.bundleID else { continue }
            let key = [prev, event.bundleID].sorted().joined(separator: "|")
            let prevName = lastNames[prev] ?? displayName(forBundleID: prev)
            counts[key, default: ((prevName, event.appName), 0)].count += 1
        }
        guard let best = counts.values.max(by: { $0.count < $1.count }),
              best.count >= 6 else { return nil }
        return PairSuggestion(firstName: best.names.0,
                              secondName: best.names.1,
                              switches: best.count)
    }

    /// Human-readable name for a bundle ID that has no recorded event yet
    /// today (e.g. the app was last activated yesterday).
    private func displayName(forBundleID bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }),
           let name = running.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }
}

// MARK: - Popover tile

/// "Focus" tile: top apps today plus a snap suggestion when the user keeps
/// bouncing between the same two apps.
struct InsightsTile: View {
    @State private var service = WorkflowInsightsService.shared

    var body: some View {
        let top = Array(service.todayUsage.prefix(3))
        if !top.isEmpty {
            MetricTile(icon: "chart.bar", title: "Focus Today", value: "", progress: nil) {
                VStack(alignment: .leading, spacing: 9) {
                    let maxMin = max(top.first?.minutes ?? 1, 1)
                    ForEach(top) { usage in
                        HStack(spacing: 8) {
                            Text(usage.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 110, alignment: .leading)
                            AccentBar(progress: usage.minutes / maxMin)
                            Text(timeString(usage.minutes))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    if let pair = service.suggestion {
                        HStack(spacing: 6) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                            Text("You've switched between \(pair.firstName) and \(pair.secondName) \(pair.switches)× today — try ⌥Space to snap them side by side.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    private func timeString(_ minutes: Double) -> String {
        if minutes >= 60 {
            return String(format: "%.0fh %02.0fm", minutes / 60,
                          minutes.truncatingRemainder(dividingBy: 60))
        }
        return String(format: "%.0fm", max(minutes, 1))
    }
}
