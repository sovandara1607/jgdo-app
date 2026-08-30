import Foundation

/// Clipboard privacy controls layered on top of `ClipboardService`: per-app
/// exclusion, timed pauses, time-based retention (alongside the existing
/// count-based `ClipboardService.limit`), and storage-usage reporting. Kept
/// separate from `ClipboardService` so the capture/dedupe/trim pipeline
/// there isn't buried under settings plumbing.
@Observable
final class ClipboardPrivacyService {
    static let shared = ClipboardPrivacyService()

    // MARK: Per-app exclusion

    private static let excludedBundleIDsKey = "clipboardExcludedBundleIDs"
    private(set) var excludedBundleIDs: Set<String>

    // MARK: Pause

    private static let pausedUntilKey = "clipboardPausedUntil"
    /// `nil` = not paused. `.distantFuture` = paused until manually resumed
    /// (rather than a separate bool, so `isPaused` has one code path).
    private(set) var pausedUntil: Date?

    enum PauseDuration: CaseIterable {
        case fiveMinutes, thirtyMinutes, untilResumed

        var label: String {
            switch self {
            case .fiveMinutes:   return "5 Minutes"
            case .thirtyMinutes: return "30 Minutes"
            case .untilResumed:  return "Until Resumed"
            }
        }

        fileprivate var interval: TimeInterval? {
            switch self {
            case .fiveMinutes:   return 5 * 60
            case .thirtyMinutes: return 30 * 60
            case .untilResumed:  return nil
            }
        }
    }

    // MARK: Retention

    private static let retentionDaysKey = "clipboardRetentionDays"
    /// Days of history to keep regardless of the count-based limit; 0 means
    /// no time-based retention (count limit still applies).
    var retentionDays: Int {
        get { UserDefaults.standard.integer(forKey: Self.retentionDaysKey) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: Self.retentionDaysKey) }
    }

    // MARK: Max storage

    private static let maxStorageBytesKey = "clipboardMaxStorageBytes"
    /// Soft cap on total clipboard storage in bytes; 0 means unlimited.
    /// Enforced by `ClipboardService.trim()` alongside the count limit.
    var maxStorageBytes: Int {
        get { UserDefaults.standard.integer(forKey: Self.maxStorageBytesKey) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: Self.maxStorageBytesKey) }
    }

    private init() {
        excludedBundleIDs = Set(UserDefaults.standard.stringArray(forKey: Self.excludedBundleIDsKey) ?? [])
        pausedUntil = UserDefaults.standard.object(forKey: Self.pausedUntilKey) as? Date
    }

    // MARK: Exclusion

    func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }

    func setExcluded(_ excluded: Bool, bundleID: String) {
        if excluded { excludedBundleIDs.insert(bundleID) } else { excludedBundleIDs.remove(bundleID) }
        UserDefaults.standard.set(Array(excludedBundleIDs), forKey: Self.excludedBundleIDsKey)
    }

    // MARK: Pause

    /// True while capture should be suppressed. A timed pause that has
    /// expired auto-clears itself here, so callers never see a stale
    /// "paused" state and don't need to poll separately for expiry.
    var isPaused: Bool {
        guard let pausedUntil else { return false }
        guard pausedUntil != .distantFuture else { return true }
        if Date() >= pausedUntil {
            resume()
            return false
        }
        return true
    }

    func pause(for duration: PauseDuration) {
        let until = duration.interval.map { Date().addingTimeInterval($0) } ?? .distantFuture
        pausedUntil = until
        UserDefaults.standard.set(until, forKey: Self.pausedUntilKey)
    }

    func resume() {
        pausedUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.pausedUntilKey)
    }

    // MARK: Retention sweep

    /// Unpinned items older than `retentionDays` — `ClipboardService.trim()`
    /// deletes whatever this returns. Returns an empty array (not a no-op
    /// flag) so the caller has one code path whether or not a retention
    /// period is configured.
    func expiredItems(in items: [ClipboardItem]) -> [ClipboardItem] {
        guard retentionDays > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        return items.filter { !$0.isPinned && $0.createdAt < cutoff }
    }

    /// Oldest-first unpinned items to drop so total storage stays at or
    /// under `maxStorageBytes`. Empty if no cap is set or usage is already
    /// under it. Pinned items are never counted against the cap for
    /// removal purposes (they're never dropped), only for the running total.
    func itemsExceedingStorageCap(in items: [ClipboardItem]) -> [ClipboardItem] {
        guard maxStorageBytes > 0 else { return [] }
        let total = storageUsageBytes(items: items)
        guard total > maxStorageBytes else { return [] }

        let unpinnedOldestFirst = items.filter { !$0.isPinned }.sorted { $0.createdAt < $1.createdAt }
        var overBy = total - maxStorageBytes
        var toDrop: [ClipboardItem] = []
        for item in unpinnedOldestFirst {
            guard overBy > 0 else { break }
            toDrop.append(item)
            overBy -= Self.byteSize(of: item)
        }
        return toDrop
    }

    // MARK: Storage usage

    /// Approximate on-disk footprint of clipboard history — text/UTF8 size
    /// plus image/OCR bytes, summed across every stored item. Cheap enough
    /// to compute on demand for a Settings readout; not cached.
    func storageUsageBytes(items: [ClipboardItem]) -> Int {
        items.reduce(0) { $0 + Self.byteSize(of: $1) }
    }

    private static func byteSize(of item: ClipboardItem) -> Int {
        var size = 0
        if let text = item.text { size += text.utf8.count }
        if let imageData = item.imageData { size += imageData.count }
        if let recognized = item.recognizedText { size += recognized.utf8.count }
        size += item.filePaths.reduce(0) { $0 + $1.utf8.count }
        return size
    }

    /// Human-readable "1.2 MB" style string for the Settings readout.
    static func formattedByteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
