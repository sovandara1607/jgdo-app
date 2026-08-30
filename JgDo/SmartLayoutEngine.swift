import AppKit
import SwiftData

/// Detects recurring app-combination "sessions" (rapid back-and-forth
/// switching between the same 2–4 apps) from the SAME activation stream
/// `WorkflowInsightsService` already records (`AppUsageEvent`) — no second
/// event table, no second `NSWorkspace` observer. Purely rule/statistics
/// based (recurrence counting), no ML: a signature only becomes a surfaced
/// suggestion once it's recurred `suggestionThreshold` times as its own
/// separate sessions, and even then it's never applied automatically —
/// the popover tile always requires an explicit "Save as Workspace" or
/// "Ignore".
@MainActor
@Observable
final class SmartLayoutEngine {
    static let shared = SmartLayoutEngine()

    /// A session must contain apps only from this window to count, and
    /// must include at least this many switches to be more than "opened
    /// two apps once" — see `detectSignature`.
    static let sessionWindow: TimeInterval = 240   // 4 minutes
    static let appCountRange = 2...4
    static let minSwitchesForSession = 3
    /// How many separate sessions a signature needs before it's worth
    /// surfacing — matches the brief's "suggest, don't automatically
    /// create" bar: a coincidence shouldn't nag the user, a real habit should.
    static let suggestionThreshold = 3

    /// Pending suggestions that have crossed the threshold — what
    /// `SmartLayoutsTile` renders. Ignored/accepted ones are excluded.
    private(set) var suggestions: [SmartLayoutSuggestion] = []

    /// The most recently recorded signature this continuous session
    /// produced — prevents recording a new observation on every single
    /// switch while the user keeps bouncing between the same apps; only a
    /// genuinely NEW session (the signature having lapsed out of the
    /// window and reformed later) records again. Reset to nil whenever the
    /// rolling window no longer yields a valid candidate.
    private var lastRecordedSignature: String?

    private let windowService = WindowManagerService()
    private let persistence: PersistenceProviding

    /// `persistence` defaults to the real on-disk store — only tests pass
    /// something else. See `WorkspaceService.init` for why this is `nil`
    /// rather than defaulting straight to `Persistence.shared`.
    init(persistence: PersistenceProviding? = nil) {
        self.persistence = persistence ?? Persistence.shared
        reload()
    }

    func reload() {
        let ctx = persistence.context
        suggestions = ctx.fetchLogged(FetchDescriptor<SmartLayoutSuggestion>(
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]), using: AppLog.workspace)
            .filter { $0.status == .pending }
    }

    // MARK: - Recording (called from the same activation observer as WorkflowInsightsService)

    /// Called after each `AppUsageEvent` is inserted — re-derives the
    /// current rolling-window signature from persisted events (cheap: the
    /// window is only a few minutes, so the fetch is always small) rather
    /// than keeping a second in-memory event log.
    func recordActivation() {
        guard AppSettings.smartLayoutsEnabled else { return }
        let ctx = persistence.context
        let cutoff = Date().addingTimeInterval(-Self.sessionWindow)
        let recent = ctx.fetchLogged(FetchDescriptor<AppUsageEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp)]), using: AppLog.workspace)
        let events = recent.map { (bundleID: $0.bundleID, timestamp: $0.timestamp) }

        guard let signature = Self.detectSignature(
            from: events, now: Date(), windowSeconds: Self.sessionWindow,
            appCountRange: Self.appCountRange, minSwitches: Self.minSwitchesForSession
        ) else {
            lastRecordedSignature = nil
            return
        }
        guard signature != lastRecordedSignature else { return }
        lastRecordedSignature = signature
        recordObservation(signature: signature)
    }

    private func recordObservation(signature: String) {
        let ctx = persistence.context
        ctx.insert(AppCombinationObservation(signature: signature))

        let count = ctx.fetchLogged(FetchDescriptor<AppCombinationObservation>(
            predicate: #Predicate { $0.signature == signature }), using: AppLog.workspace).count
        upsertSuggestion(signature: signature, timesSeen: count)
        persistence.save()
        reload()
    }

    private func upsertSuggestion(signature: String, timesSeen: Int) {
        let ctx = persistence.context
        let existing = ctx.fetchLogged(FetchDescriptor<SmartLayoutSuggestion>(
            predicate: #Predicate { $0.appSignature == signature }), using: AppLog.workspace).first

        if let existing {
            existing.timesSeen = timesSeen
            existing.lastSeenAt = Date()
            // Deliberately don't resurrect an ignored suggestion just
            // because the pattern recurred — "Ignore" means ignore.
        } else if timesSeen >= Self.suggestionThreshold {
            let bundleIDs = signature.components(separatedBy: "|")
            let names = displayNames(for: bundleIDs)
            let suggestion = SmartLayoutSuggestion(
                appSignature: signature,
                suggestedName: names.joined(separator: " + ")
            )
            captureGeometry(for: bundleIDs, into: suggestion)
            ctx.insert(suggestion)
        }
    }

    /// Fractional on-screen geometry for whichever of `bundleIDs` currently
    /// have a window — display-only, see `SmartLayoutSuggestion.slots`.
    /// Best-effort: if a signature app isn't currently on screen (it was
    /// part of the pattern historically but got closed since), it simply
    /// gets no slot rather than blocking suggestion creation.
    private func captureGeometry(for bundleIDs: [String], into suggestion: SmartLayoutSuggestion) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let running = NSWorkspace.shared.runningApplications
        for info in windowService.fetchWindows() {
            guard let app = running.first(where: { $0.processIdentifier == info.pid }),
                  let bundleID = app.bundleIdentifier,
                  bundleIDs.contains(bundleID) else { continue }
            let appKit = CoordinateSpace.appKit(fromCG: info.bounds)
            let fraction = CGRect(x: (appKit.minX - vf.minX) / vf.width,
                                   y: (appKit.minY - vf.minY) / vf.height,
                                   width: appKit.width / vf.width,
                                   height: appKit.height / vf.height)
            let slot = SmartLayoutSlot(bundleID: bundleID, appName: info.appName, fraction: fraction)
            slot.suggestion = suggestion
            suggestion.slots.append(slot)
        }
    }

    private func displayNames(for bundleIDs: [String]) -> [String] {
        let running = NSWorkspace.shared.runningApplications
        return bundleIDs.map { id in
            running.first(where: { $0.bundleIdentifier == id })?.localizedName
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?
                    .deletingPathExtension().lastPathComponent
                ?? id
        }
    }

    // MARK: - Actions

    /// Accepting a suggestion never replays its stored (possibly stale)
    /// geometry — it captures a fresh, live snapshot via the exact same
    /// `WorkspaceService.saveCurrentLayout` the "Save Current Layout"
    /// button in `WorkspacesTile` uses, since by definition the suggestion
    /// is only showing because that app combination is active right now.
    func acceptAsWorkspace(_ suggestion: SmartLayoutSuggestion, named name: String) {
        WorkspaceService.shared.saveCurrentLayout(named: name)
        suggestion.statusRaw = SmartLayoutSuggestion.Status.accepted.rawValue
        persistence.save()
        reload()
    }

    func ignore(_ suggestion: SmartLayoutSuggestion) {
        suggestion.statusRaw = SmartLayoutSuggestion.Status.ignored.rawValue
        persistence.save()
        reload()
    }

    /// Wipes all learned patterns (observations + suggestions) — the
    /// Settings → Smart Layouts "Clear Learned Patterns" action. Doesn't
    /// touch anything already saved as a real `Workspace`.
    func resetLearning() {
        let ctx = persistence.context
        for o in ctx.fetchLogged(FetchDescriptor<AppCombinationObservation>(), using: AppLog.workspace) { ctx.delete(o) }
        for s in ctx.fetchLogged(FetchDescriptor<SmartLayoutSuggestion>(), using: AppLog.workspace) { ctx.delete(s) }
        lastRecordedSignature = nil
        persistence.save()
        reload()
    }

    // MARK: - Pure, unit-testable pattern detection

    /// Given recent (bundleID, timestamp) activation events, decides
    /// whether they describe a "session" worth recording: restricted to a
    /// rolling `windowSeconds` ending at `now`, involving somewhere
    /// between `appCountRange` distinct apps, with at least `minSwitches`
    /// transitions between them (guards against "opened two apps once in
    /// passing" registering as a pattern). Returns the sorted, `|`-joined
    /// signature, or nil if this isn't a candidate session.
    ///
    /// This is intentionally simple statistics, not ML: a real recurring
    /// workflow will keep re-triggering this across many separate days,
    /// which is what actually gates a suggestion (`suggestionThreshold`
    /// separate sessions) — this function only identifies one session.
    static func detectSignature(
        from events: [(bundleID: String, timestamp: Date)],
        now: Date,
        windowSeconds: TimeInterval,
        appCountRange: ClosedRange<Int>,
        minSwitches: Int
    ) -> String? {
        let inWindow = events.filter {
            $0.timestamp <= now && now.timeIntervalSince($0.timestamp) <= windowSeconds
        }
        guard inWindow.count - 1 >= minSwitches else { return nil }
        let distinct = Set(inWindow.map(\.bundleID))
        guard appCountRange.contains(distinct.count) else { return nil }
        return distinct.sorted().joined(separator: "|")
    }
}
